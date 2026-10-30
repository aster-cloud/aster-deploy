#!/usr/bin/env bash
# retry.sh 离线测试：重试告警不得污染 stdout；API 不可达时状态码必须是 000（issue #31）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
source "${SCRIPT_DIR}/retry.sh"

FAILURES=0
check() { # check <描述> <期望> <实际>
  if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1（期望=[$2] 实际=[$3]）" >&2; FAILURES=$((FAILURES + 1)); fi
}

# 1. 重试告警走 stderr：命令替换捕获到的 stdout 只含命令自己的输出
out="$(retry 3 0 bash -c 'echo 000; exit 1' 2>/dev/null)"
check "retry 的告警不混入 stdout" "000
000
000" "$out"

# 2. API 不可达（假 curl 恒输出 000 并失败）：状态码为 000
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'FAKE'
#!/usr/bin/env bash
if [ -n "${FAKE_CURL_CODE:-}" ]; then printf '%s' "$FAKE_CURL_CODE"; exit 0; fi
printf '000'; exit 7
FAKE
chmod +x "$TMP/bin/curl"

PATH="$TMP/bin:$PATH" retry_http_status 3 0 http://127.0.0.1:1 2>/dev/null
check "API 不可达时状态码为 000" "000" "$HTTP_STATUS"

FAKE_CURL_CODE=400 PATH="$TMP/bin:$PATH" retry_http_status 3 0 http://x 2>/dev/null
check "API 可达时返回真实状态码" "400" "$HTTP_STATUS"

FAKE_CURL_CODE=401 PATH="$TMP/bin:$PATH" retry_http_status 3 0 http://x 2>/dev/null
check "401 也原样返回（不重试）" "401" "$HTTP_STATUS"

[ "$FAILURES" -eq 0 ] || { echo "retry 测试失败: $FAILURES 项" >&2; exit 1; }
echo "✓ retry.sh 全部通过"
