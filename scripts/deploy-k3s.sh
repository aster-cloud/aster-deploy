#!/usr/bin/env bash
# K3S 部署脚本（rollout restart + status wait）
# 用法: ./scripts/deploy-k3s.sh <target>  (target: api|lsp)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

TARGET="$1"
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/k3s-config}"

case "$TARGET" in
  api)
    DEPLOYMENT="aster-api"
    NAMESPACE="${K3S_API_NAMESPACE:-aster-cloud}"
    ;;
  lsp)
    DEPLOYMENT="aster-lsp"
    NAMESPACE="${K3S_LSP_NAMESPACE:-aster-lsp}"
    ;;
  *)
    log_error "未知部署目标: ${TARGET}（支持: api, lsp）"
    exit 1
    ;;
esac

KUBECTL=(kubectl --kubeconfig "$KUBECONFIG_PATH" -n "$NAMESPACE")

log_info "重启 ${DEPLOYMENT} (${NAMESPACE})"
run_cmd "${KUBECTL[@]}" rollout restart "deployment/${DEPLOYMENT}"

log_info "等待滚动更新完成 ..."
run_cmd "${KUBECTL[@]}" rollout status "deployment/${DEPLOYMENT}" --timeout=120s

log_success "${DEPLOYMENT} 部署完成"
