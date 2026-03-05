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
    log_warn "第 ${attempt}/${max_attempts} 次失败，${delay}s 后重试 ..."
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}
