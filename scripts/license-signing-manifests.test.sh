#!/usr/bin/env bash
# license-signing-api 部署清单回归检查（issue #23 #28 #30）：
#   #23 服务状态在进程内存且审计卷 RWO → 单副本 + Recreate
#   #28 NetworkPolicy 必须放行到 IdP JWKS 的公网 443 出站
#   #30 helm 默认不渲染 cert-manager 注解与 tls（.internal 域名签不出证书）
# helm 优先用本机命令，否则回退到 alpine/helm 容器。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SVC="$(cd "${SCRIPT_DIR}/../services/license-signing-api" && pwd)"
CHART="${SVC}/helm/aster-license-signing-api"

helm_template() {
  if command -v helm >/dev/null 2>&1; then
    helm template t "$CHART" "$@"
  else
    local cli
    cli="$(command -v podman || command -v docker)"
    "$cli" run --rm -v "${CHART}:/chart:ro" docker.io/alpine/helm:3.16.3 template t /chart "$@"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
helm_template > "$TMP/default.yaml"
helm_template --set ingress.clusterIssuer=letsencrypt-prod > "$TMP/issuer.yaml"
helm_template --set "networkPolicy.publicEgress.cidr={198.51.100.0/24,203.0.113.0/24}" > "$TMP/cidrlist.yaml"

python3 -I - "$SVC/k8s" "$TMP/default.yaml" "$TMP/issuer.yaml" "$TMP/cidrlist.yaml" <<'PY'
import sys, pathlib
try:
    import yaml
except ImportError:
    sys.exit("缺少 PyYAML（pip install pyyaml）")

k8s, default_f, issuer_f, cidrlist_f = (pathlib.Path(p) for p in sys.argv[1:5])
errors = []

def load(path):
    return [d for d in yaml.safe_load_all(path.read_text()) if d]

def by_kind(docs, kind):
    return next(d for d in docs if d["kind"] == kind)

sets = {
    "kustomize": [d for f in sorted(k8s.glob("*.yaml")) if f.name != "kustomization.yaml" for d in load(f)],
    "helm": load(default_f),
}
for name, docs in sets.items():
    dep = by_kind(docs, "Deployment")["spec"]
    if dep.get("replicas") != 1:
        errors.append(f"[{name}] replicas 必须为 1（进程内存状态 + RWO 审计卷），实际 {dep.get('replicas')}")
    if (dep.get("strategy") or {}).get("type") != "Recreate":
        errors.append(f"[{name}] strategy 必须为 Recreate（RWO 卷不能被新旧 Pod 同时挂载）")

    egress = by_kind(docs, "NetworkPolicy")["spec"]["egress"]
    jwks = [r for r in egress
            if any("ipBlock" in t for t in r.get("to", []))
            and any(p.get("port") == 443 for p in r.get("ports", []))]
    if not jwks:
        errors.append(f"[{name}] NetworkPolicy 缺少到 IdP JWKS 的公网 443 出站（ipBlock）")
    for r in jwks:
        for t in r["to"]:
            ex = set(t.get("ipBlock", {}).get("except", []))
            missing = {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10"} - ex
            if missing:
                errors.append(f"[{name}] 公网出站 except 缺少 {sorted(missing)}")
    if any(t.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name") == "cloudflare-tunnel"
           for r in egress for t in r.get("to", [])):
        errors.append(f"[{name}] 不应再把 cloudflare-tunnel（入站隧道）当作出站代理")

ing = by_kind(sets["helm"], "Ingress")
if "cert-manager.io/cluster-issuer" in (ing["metadata"].get("annotations") or {}) or "tls" in ing["spec"]:
    errors.append("[helm] 默认不应渲染 cluster-issuer 注解与 tls 段")
ing2 = by_kind(load(issuer_f), "Ingress")
if ing2["metadata"]["annotations"].get("cert-manager.io/cluster-issuer") != "letsencrypt-prod" or not ing2["spec"].get("tls"):
    errors.append("[helm] 显式设置 ingress.clusterIssuer 后必须同时渲染注解与 tls 段")

cidrs = [t["ipBlock"]["cidr"] for r in by_kind(load(cidrlist_f), "NetworkPolicy")["spec"]["egress"]
         for t in r.get("to", []) if "ipBlock" in t]
# except 必须是所属 cidr 的子网，否则 apiserver 拒绝该 NetworkPolicy
import ipaddress
def check_subset(label, docs):
    for r in by_kind(docs, "NetworkPolicy")["spec"]["egress"]:
        for t in r.get("to", []):
            blk = t.get("ipBlock")
            if not blk:
                continue
            net = ipaddress.ip_network(blk["cidr"])
            for e in blk.get("except", []):
                if not ipaddress.ip_network(e).subnet_of(net):
                    errors.append(f"[{label}] except {e} 不是 cidr {blk['cidr']} 的子网")
check_subset("kustomize", sets["kustomize"])
check_subset("helm-default", sets["helm"])
check_subset("helm-cidrlist", load(cidrlist_f))
for t in [t for r in by_kind(load(cidrlist_f), "NetworkPolicy")["spec"]["egress"] for t in r.get("to", []) if "ipBlock" in t]:
    if t["ipBlock"].get("except"):
        errors.append(f"[helm] 白名单网段 {t['ipBlock']['cidr']} 不应带 except")
if cidrs != ["198.51.100.0/24", "203.0.113.0/24"]:
    errors.append(f"[helm] publicEgress.cidr 列表写法未渲染为多条 ipBlock: {cidrs}")

if errors:
    print("\n".join(f"✗ {e}" for e in errors), file=sys.stderr)
    sys.exit(1)
print("✓ license-signing-api 部署清单检查通过")
PY
