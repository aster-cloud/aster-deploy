#!/usr/bin/env bash
# 共享日志函数，所有脚本通过 source 使用

COLOR_INFO="\033[1;34m"
COLOR_WARN="\033[1;33m"
COLOR_ERROR="\033[1;31m"
COLOR_SUCCESS="\033[1;32m"
COLOR_DIM="\033[0;90m"
COLOR_RESET="\033[0m"

DRY_RUN="${DRY_RUN:-0}"

log_info()    { printf "${COLOR_INFO}[INFO]${COLOR_RESET} %s\n" "$1"; }
log_warn()    { printf "${COLOR_WARN}[WARN]${COLOR_RESET} %s\n" "$1"; }
log_error()   { printf "${COLOR_ERROR}[ERROR]${COLOR_RESET} %s\n" "$1" >&2; }
log_success() { printf "${COLOR_SUCCESS}[OK]${COLOR_RESET} %s\n" "$1"; }

step_start() {
  local n="$1" total="$2" name="$3"
  printf "${COLOR_INFO}[%s/%s]${COLOR_RESET} %s …\n" "$n" "$total" "$name"
}

step_done() {
  local n="$1" total="$2" name="$3" duration="${4:-}"
  local suffix=""
  [ -n "$duration" ] && suffix=" (${duration}s)"
  printf "${COLOR_SUCCESS}[%s/%s] ✓${COLOR_RESET} %s%s\n" "$n" "$total" "$name" "$suffix"
}

step_fail() {
  local n="$1" total="$2" name="$3" duration="${4:-}"
  local suffix=""
  [ -n "$duration" ] && suffix=" (${duration}s)"
  printf "${COLOR_ERROR}[%s/%s] ✗${COLOR_RESET} %s%s\n" "$n" "$total" "$name" "$suffix" >&2
}

summary() {
  local passed="$1" failed="$2" total_time="$3"
  echo ""
  if [ "$failed" -eq 0 ]; then
    log_success "全部完成：${passed} 个任务通过（${total_time}s）"
  else
    log_error "完成：${passed} 通过 / ${failed} 失败（${total_time}s）"
  fi
}

# DRY_RUN 支持：包装命令执行
run_cmd() {
  if [ "$DRY_RUN" = "1" ]; then
    log_info "DRY-RUN: $*"
    return 0
  fi
  "$@"
}
