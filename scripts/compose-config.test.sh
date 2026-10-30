#!/usr/bin/env bash
# compose / Prometheus 配置静态回归检查（issue #26 #27 #33）。
# 这些配置错误只在容器启动后才暴露，且只表现为「容器退出」或「指标为空」，
# 用静态断言把已知的三处错误钉住。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I - "$SCRIPT_DIR/../compose" <<'PY'
import sys, pathlib
try:
    import yaml
except ImportError:
    sys.exit("缺少 PyYAML（pip install pyyaml）")

root = pathlib.Path(sys.argv[1])
errors = []

compose = yaml.safe_load((root / "podman-compose.yml").read_text())
lsp = compose["services"]["lsp"]
cmd = lsp["command"]
# #26：aster-cloud 的 LSP 入口是仓库根目录的 lsp-server.mjs，不存在 dist/
if "dist/" in cmd or "lsp-server.mjs" not in cmd:
    errors.append(f"lsp command 必须执行根目录 lsp-server.mjs，实际: {cmd!r}")
# 本地开发的页面 origin 不在 lsp-server 默认白名单内，必须显式放行
if "ALLOWED_ORIGINS" not in (lsp.get("environment") or {}):
    errors.append("lsp 缺少 ALLOWED_ORIGINS（默认白名单不含 localhost，WebSocket 会被拒绝）")
# lsp 依赖 cloud 安装好的 node_modules（ws / aster-lang-ts）
if not any("node_modules" in v for v in lsp.get("volumes", [])):
    errors.append("lsp 未挂载 cloud 的 node_modules 卷，宿主机 node_modules 可能含不兼容的原生产物")

# #33：叠加 --profile full 时 aster-api 是 compose 网络内的 api:8080
prom = yaml.safe_load((root / "observability/prometheus.yml").read_text())
targets = [t for job in prom["scrape_configs"] if job["job_name"] == "aster-api"
           for sc in job["static_configs"] for t in sc["targets"]]
if targets != ["api:8080"]:
    errors.append(f"aster-api 抓取目标应为 ['api:8080']，实际: {targets}")

# #27：建库不能依赖 initdb.d（数据卷已初始化时不会执行）
test_compose = yaml.safe_load((root / "podman-compose.test.yml").read_text())
pg_vols = (test_compose["services"].get("postgres") or {}).get("volumes", [])
if any("docker-entrypoint-initdb.d" in v for v in pg_vols):
    errors.append("test 覆盖层不应再依赖 docker-entrypoint-initdb.d 建库")
entry = (root / "scripts/cloud-entrypoint.sh").read_text()
if "ensure-database.sh" not in entry:
    errors.append("cloud-entrypoint.sh 未调用 ensure-database.sh")

if errors:
    print("\n".join(f"✗ {e}" for e in errors), file=sys.stderr)
    sys.exit(1)
print("✓ compose / prometheus 配置检查通过")
PY
