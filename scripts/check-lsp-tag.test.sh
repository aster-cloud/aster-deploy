#!/usr/bin/env bash
# LSP_IMAGE_TAG 前置校验测试（issue #29）：release 必须在任何不可逆发布动作之前失败。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FAILURES=0
check() { if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1（期望=[$2] 实际=[$3]）" >&2; FAILURES=$((FAILURES + 1)); fi; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

# 1. 校验脚本本身
check "空 tag 被拒绝" "1" "$(rc_of "$SCRIPT_DIR/check-lsp-tag.sh" "")"
check "可变 tag 0.0.9 被拒绝" "1" "$(rc_of "$SCRIPT_DIR/check-lsp-tag.sh" "0.0.9")"
check "git sha 通过" "0" "$(rc_of "$SCRIPT_DIR/check-lsp-tag.sh" "3f2a9c1d")"

# 2. Taskfile 接线：release 的预检在 publish 之前就拦下缺失的 tag
if ! command -v task >/dev/null 2>&1; then
  echo "✗ 缺少 task 命令，无法验证 Taskfile 接线（https://taskfile.dev/installation/）" >&2
  exit 1
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# 隔离：不读仓库根目录的 .env，避免本机配置影响结果
cp -R "$ROOT/Taskfile.yml" "$ROOT/scripts" "$TMP/"
out_missing="$(cd "$TMP" && task preflight MODE=release 2>&1 || true)"
out_given="$(cd "$TMP" && task preflight MODE=release LSP_IMAGE_TAG=3f2a9c1d 2>&1 || true)"
check "release 预检在未给 LSP_IMAGE_TAG 时报错" "1" "$(printf '%s' "$out_missing" | grep -q '必须显式指定 LSP_IMAGE_TAG' && echo 1 || echo 0)"
check "release 预检给了 tag 后通过该项" "1" "$(printf '%s' "$out_given" | grep -q 'LSP_IMAGE_TAG 已设置' && echo 1 || echo 0)"

[ "$FAILURES" -eq 0 ] || { echo "check-lsp-tag 测试失败: $FAILURES 项" >&2; exit 1; }
echo "✓ check-lsp-tag 全部通过"
