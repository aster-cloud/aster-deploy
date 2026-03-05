#!/usr/bin/env bash
# 生产环境冒烟测试
# 用法: ./scripts/verify.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/retry.sh"

ERRORS=0

check_url() {
  local label="$1" url="$2"
  if retry 3 5 curl -sf --max-time 10 "$url" >/dev/null; then
    log_success "${label} (${url})"
  else
    log_error "${label} (${url})"
    ERRORS=$((ERRORS + 1))
  fi
}

echo "=== 生产环境冒烟测试 ==="
check_url "aster-api 健康检查" "https://policy.aster-lang.dev/q/health"
check_url "aster-cloud 首页" "https://aster-lang.cloud"
check_url "aster-lsp 健康检查" "https://lsp.aster-lang.dev/health"

echo ""
if [ "$ERRORS" -gt 0 ]; then
  log_error "冒烟测试失败：${ERRORS} 个服务不可用"
  exit 1
else
  log_success "所有生产服务正常"
fi
