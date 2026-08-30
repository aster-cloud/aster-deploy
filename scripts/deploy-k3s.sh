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
# ★rollout status 超时不能直接死掉（issue #11）。
#
#   此前 `set -e` 会让脚本在超时处静默退出：Deployment 卡在半滚状态
#   （新 ReplicaSet 起不来、旧的已被缩容），而操作者手上没有任何恢复指引，
#   得自己回想 `kubectl rollout undo` 的语法和 namespace。
#
#   ★这里**不自动 undo**：自动回滚会掩盖真实故障（镜像拉不动、探针失败、
#   配额不足都会走到这），且在多人同时操作时可能回滚掉别人刚发的版本。
#   合规决策系统上，"让人看着办但把信息给全" 比 "替人做决定" 更安全。
#   故：打印诊断 + 现成可粘贴的回滚命令，然后以非零退出。
if ! run_cmd "${KUBECTL[@]}" rollout status "deployment/${DEPLOYMENT}" --timeout=120s; then
  log_error "${DEPLOYMENT} 滚动更新未在 120s 内完成——Deployment 可能停在半滚状态"

  echo "" >&2
  echo "── 当前状态 ─────────────────────────────────" >&2
  "${KUBECTL[@]}" get "deployment/${DEPLOYMENT}" -o wide 2>&1 | sed 's/^/  /' >&2 || true
  echo "" >&2
  echo "── Pod 状态（看 READY 列，0/1 即未就绪）──────────" >&2
  # ★不要用 `--field-selector=status.phase!=Running` 过滤（交叉审查实证）。
  #   `status.phase` 与「就绪」是两个概念，readiness 不参与 phase 计算：
  #     ImagePullBackOff / 排不下  → phase=Pending   ✅ 会被显示
  #     CrashLoopBackOff           → phase=**Running** ❌ 被滤掉
  #     readinessProbe 失败(0/1)   → phase=**Running** ❌ 被滤掉
  #   而 rollout status 超时最常见的原因恰恰是后两者——新 Pod 起来了但没 ready。
  #   加过滤会让这一段在真正需要它时打印「No resources found」，
  #   标题却写着「最可能的原因在这里」，把排查方向引开。
  #   实测（假 kubectl 模拟 CrashLoopBackOff）：加过滤 → 空表；去掉 → 正常列出。
  #   列全部 Pod 即可，READY 列自己会显示 0/1。
  "${KUBECTL[@]}" get pods -l "app=${DEPLOYMENT}" -o wide 2>&1 | sed 's/^/  /' >&2 || true
  echo "" >&2
  echo "── 最近事件 ─────────────────────────────────" >&2
  "${KUBECTL[@]}" get events --sort-by=.lastTimestamp 2>&1 | tail -15 | sed 's/^/  /' >&2 || true

  echo "" >&2
  echo "── 恢复操作（按需选一条，均可直接粘贴）──────────" >&2
  echo "  # 看某个 Pod 为什么起不来：" >&2
  echo "  kubectl --kubeconfig ${KUBECONFIG_PATH} -n ${NAMESPACE} describe pod -l app=${DEPLOYMENT}" >&2
  echo "  kubectl --kubeconfig ${KUBECONFIG_PATH} -n ${NAMESPACE} logs -l app=${DEPLOYMENT} --tail=100" >&2
  echo "" >&2
  echo "  # 回滚到上一个 revision：" >&2
  echo "  kubectl --kubeconfig ${KUBECONFIG_PATH} -n ${NAMESPACE} rollout undo deployment/${DEPLOYMENT}" >&2
  echo "" >&2
  echo "  # 查看历史 revision（回滚到指定版本用 --to-revision=N）：" >&2
  echo "  kubectl --kubeconfig ${KUBECONFIG_PATH} -n ${NAMESPACE} rollout history deployment/${DEPLOYMENT}" >&2
  echo "" >&2

  exit 1
fi

log_success "${DEPLOYMENT} 部署完成"
