#!/usr/bin/env bash
# e2e-lib.sh 离线测试：stage 内中途失败必须判 FAIL（issue #22），
# 子 shell 中登记的后台进程/容器必须能被父 shell 清理（issue #24）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/e2e-lib.sh"

FAILURES=0
check() { # check <描述> <期望> <实际>
  if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1（期望=$2 实际=$3）" >&2; FAILURES=$((FAILURES + 1)); fi
}

# shellcheck disable=SC2034  # 这两个数组由 e2e-lib.sh 读取
SKIP_STAGES=()
ONLY_STAGES=()
# 与 e2e-local.sh 主流程一致：stage 失败不终止父 shell
set +e

# ── #22：多命令 stage 中途失败，后续命令成功也必须判 FAIL ──────────────
stage_fail_midway() { false; echo "后续命令仍被执行"; true; }
stage_ok() { true; echo ok; }
run_stage s1 "中途失败" stage_fail_midway >/dev/null 2>&1
rc_fail=$?
run_stage s2 "全部成功" stage_ok >/dev/null 2>&1
check "中途失败的 stage 状态为 FAIL" "FAIL" "${STAGE_STATUS[0]}"
check "中途失败的 stage 返回码非零" "1" "$([ "$rc_fail" -ne 0 ] && echo 1 || echo 0)"
check "成功的 stage 状态为 PASS" "PASS" "${STAGE_STATUS[1]}"

# shellcheck disable=SC2034
ONLY_STAGES=(other)
run_stage s3 "被过滤" stage_ok >/dev/null 2>&1
check "不在 --only 内的 stage 状态为 SKIP" "SKIP" "${STAGE_STATUS[2]}"
# shellcheck disable=SC2034
ONLY_STAGES=()

# ── #24：子 shell 内登记的资源必须被父 shell 清理 ──────────────────────
FAKE_CLI="$TMP/fake-cli"
cat > "$FAKE_CLI" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_CLI_LOG"
FAKE
chmod +x "$FAKE_CLI"
export FAKE_CLI_LOG="$TMP/cli.log"
export CONTAINER_CLI="$FAKE_CLI"

init_cleanup_registry
stage_register() {
  sleep 300 &
  echo $! > "$TMP/bg.pid"
  register_cleanup "PID:$!"
  register_cleanup "CONTAINER:e2e-fake-pg"
}
run_stage s4 "登记资源" stage_register >/dev/null 2>&1
BG_PID="$(cat "$TMP/bg.pid")"
kill -0 "$BG_PID" 2>/dev/null && alive_before=1 || alive_before=0
cleanup_resources >/dev/null 2>&1
sleep 0.2
kill -0 "$BG_PID" 2>/dev/null && alive_after=1 || alive_after=0
check "清理前后台进程存活" "1" "$alive_before"
check "子 shell 登记的后台进程被清理" "0" "$alive_after"
check "子 shell 登记的容器被停止" "1" "$(grep -c '^stop e2e-fake-pg' "$FAKE_CLI_LOG" 2>/dev/null || echo 0)"
kill -9 "$BG_PID" 2>/dev/null

[ "$FAILURES" -eq 0 ] || { echo "e2e-lib 测试失败: $FAILURES 项" >&2; exit 1; }
echo "✓ e2e-lib.sh 全部通过"
