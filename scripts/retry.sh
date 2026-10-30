#!/usr/bin/env bash
# 指数退避重试包装器
# 用法: source retry.sh; retry <max_attempts> <delay_base> <command...>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

retry() {
  local max_attempts="$1"
  local delay_base="$2"
  shift 2

  local attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -eq "$max_attempts" ]; then
      log_error "命令在 ${max_attempts} 次尝试后失败: $*"
      return 1
    fi
    local delay=$(( delay_base * (2 ** (attempt - 1)) ))
    # ★告警写 stderr：调用方常用 $(retry ...) 捕获命令输出，stdout 不能混入日志（issue #31）
    log_warn "第 ${attempt}/${max_attempts} 次失败，${delay}s 后重试 ..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

# 单次探测 HTTP 状态码，写入全局 HTTP_STATUS；连接失败（000）视为失败以触发重试。
_http_status_once() {
  HTTP_STATUS="$(curl -s -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true)"
  [ -n "$HTTP_STATUS" ] && [ "$HTTP_STATUS" != "000" ]
}

# 带重试获取 HTTP 状态码。
# 用法: retry_http_status <max_attempts> <delay_base> <curl 参数...>
# 结果写入全局 HTTP_STATUS（全部失败时为 000），不经命令替换，不会被日志污染。
retry_http_status() {
  local max_attempts="$1" delay_base="$2"
  shift 2
  HTTP_STATUS="000"
  retry "$max_attempts" "$delay_base" _http_status_once "$@" || true
}
