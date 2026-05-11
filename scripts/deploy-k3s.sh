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

# 验证集群连通性和身份，避免将错误的上下文部署到生产环境
EXPECTED_CONTEXT="${K3S_EXPECTED_CONTEXT:-default}"
CURRENT_CONTEXT=$(kubectl --kubeconfig "$KUBECONFIG_PATH" config current-context 2>/dev/null || true)
if [[ -z "$CURRENT_CONTEXT" ]]; then
  log_error "无法获取当前 kubeconfig context，请检查 ${KUBECONFIG_PATH}"
  exit 1
fi
log_info "当前 kubeconfig context: ${CURRENT_CONTEXT}"

# 校验 context 身份，防止误部署到错误集群
if [[ "$CURRENT_CONTEXT" != "$EXPECTED_CONTEXT" ]]; then
  log_error "Context 不匹配: 当前='${CURRENT_CONTEXT}', 期望='${EXPECTED_CONTEXT}'"
  log_error "如需覆盖，请设置环境变量 K3S_EXPECTED_CONTEXT"
  exit 1
fi

if ! kubectl --kubeconfig "$KUBECONFIG_PATH" cluster-info --request-timeout=5s &>/dev/null; then
  log_error "无法连接集群（context: ${CURRENT_CONTEXT}），请确认 VPN / 网络连通性"
  exit 1
fi

log_info "重启 ${DEPLOYMENT} (${NAMESPACE})"
run_cmd "${KUBECTL[@]}" rollout restart "deployment/${DEPLOYMENT}"

log_info "等待滚动更新完成 ..."
run_cmd "${KUBECTL[@]}" rollout status "deployment/${DEPLOYMENT}" --timeout=120s

log_success "${DEPLOYMENT} 部署完成"
