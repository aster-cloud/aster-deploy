#!/usr/bin/env bash
# path.sh 离线测试：Task dotenv 不展开 ~，脚本必须自己展开（issue #25）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/path.sh"

FAILURES=0
check() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1（期望=[$2] 实际=[$3]）" >&2; FAILURES=$((FAILURES + 1)); fi; }

HOME=/home/tester
# shellcheck disable=SC2088  # 传入字面量 ~ 是测试目的
check "~/x 展开为 \$HOME/x" "/home/tester/.kube/k3s-config" "$(expand_tilde '~/.kube/k3s-config')"
# shellcheck disable=SC2088
check "单独的 ~ 展开为 \$HOME" "/home/tester" "$(expand_tilde '~')"
check "绝对路径原样返回" "/etc/kube/config" "$(expand_tilde '/etc/kube/config')"
check "相对路径原样返回" "conf/kube" "$(expand_tilde 'conf/kube')"
check "中间的 ~ 不展开" "/a/~/b" "$(expand_tilde '/a/~/b')"
check "空串原样返回" "" "$(expand_tilde '')"

[ "$FAILURES" -eq 0 ] || { echo "path 测试失败: $FAILURES 项" >&2; exit 1; }
echo "✓ path.sh 全部通过"
