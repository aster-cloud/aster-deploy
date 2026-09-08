#!/usr/bin/env bash
# deploy-k3s.sh 离线测试：rollout status 超时后必须列出 revision 历史并以非零退出。
#
# ★为什么用假 kubectl 而不是真集群：要测的是「失败分支」，真集群制造超时既慢
#   又会污染生产；用 PATH 前置的假 kubectl 把 rollout status 固定成失败，
#   再断言脚本在失败后确实调用了 rollout history（issue #18）。
#   把本脚本改回不打印 revision 的实现，本测试会变红（已做变异验证）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CALL_LOG="$TMP/kubectl-calls.log"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
# 假 kubectl：记录每次调用，只让 rollout status 失败
echo "$*" >> "$KUBECTL_CALL_LOG"
case "$*" in
  *"config current-context"*) echo default ;;
  *"rollout status"*) echo "error: timed out waiting for the condition" >&2; exit 1 ;;
  *"rollout history"*)
    printf 'REVISION  CHANGE-CAUSE\n3         <none>\n4         <none>\n' ;;
esac
exit 0
FAKE
chmod +x "$TMP/bin/kubectl"
touch "$TMP/kubeconfig"

set +e
KUBECTL_CALL_LOG="$CALL_LOG" PATH="$TMP/bin:$PATH" KUBECONFIG="$TMP/kubeconfig" \
  bash "$SCRIPT_DIR/deploy-k3s.sh" lsp > "$TMP/out.log" 2>&1
STATUS=$?
set -e

fail() { echo "✗ $1" >&2; echo "── 脚本输出 ──" >&2; cat "$TMP/out.log" >&2; exit 1; }

[ "$STATUS" -ne 0 ] || fail "rollout status 失败后脚本应以非零退出，实际 exit=$STATUS"
grep -q "rollout restart deployment/aster-lsp" "$CALL_LOG" || fail "未调用 rollout restart"
grep -q "rollout history deployment/aster-lsp" "$CALL_LOG" || fail "失败分支未调用 rollout history 列出 revision"
grep -q "REVISION" "$TMP/out.log" || fail "输出里没有 revision 历史表"
grep -q "rollout undo deployment/aster-lsp" "$TMP/out.log" || fail "输出里没有可粘贴的 rollout undo 命令"

echo "✓ deploy-k3s.sh 失败分支：列出 revision + 回滚命令，exit=$STATUS"
