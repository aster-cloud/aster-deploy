#!/usr/bin/env bash
# e2e-local.sh 的 stage 调度与资源清理（通过 source 使用，便于离线测试）。
#
# 调用方约定：
#   - 已 source log.sh
#   - 定义 SKIP_STAGES / ONLY_STAGES 数组
#   - 在需要收集全部失败时自行 `set +e`（run_stage 不依赖父 shell 的 errexit）

# ─── 全局计数 ──────────────────────────────────────────────────────────
declare -a STAGE_NAMES=()
declare -a STAGE_STATUS=()  # PASS / FAIL / SKIP
declare -a STAGE_TIME=()

should_run_stage() {
  local stage="$1" s
  if [ ${#ONLY_STAGES[@]} -gt 0 ]; then
    for s in "${ONLY_STAGES[@]}"; do
      [ "$s" = "$stage" ] && return 0
    done
    return 1
  fi
  for s in "${SKIP_STAGES[@]}"; do
    [ "$s" = "$stage" ] && return 1
  done
  return 0
}

# 执行一个 stage，记录 PASS/FAIL/SKIP。
# ★stage 必须在「显式开启 errexit 的子 shell」里作为独立命令运行，再取 $?。
#   若写成 `if ( stage ); then`，bash 会把整个子 shell 视为条件上下文并忽略 -e，
#   stage 里只有最后一条命令的退出码生效，测试失败会被后续成功命令掩盖（issue #22）。
run_stage() {
  local stage="$1" name="$2"
  shift 2

  if ! should_run_stage "$stage"; then
    STAGE_NAMES+=("$name")
    STAGE_STATUS+=("SKIP")
    STAGE_TIME+=("0")
    log_warn "跳过 stage: $stage"
    return 0
  fi

  echo ""
  log_info "═══ ${name} ═══"
  local start_ts rc end_ts duration
  start_ts=$(date +%s)

  ( set -e; "$@" )
  rc=$?

  end_ts=$(date +%s)
  duration=$((end_ts - start_ts))
  STAGE_NAMES+=("$name")
  STAGE_TIME+=("$duration")
  if [ "$rc" -eq 0 ]; then
    STAGE_STATUS+=("PASS")
    log_success "${name} 通过 (${duration}s)"
    return 0
  fi
  STAGE_STATUS+=("FAIL")
  log_error "${name} 失败（exit=${rc}, ${duration}s）"
  return "$rc"
}

# ─── 资源清理登记 ──────────────────────────────────────────────────────
# stage 在子 shell 中运行，对数组的修改回不到父 shell（issue #24），
# 所以登记表落在文件里：每行 `PID:<pid>` 或 `CONTAINER:<name>`。
CLEANUP_FILE=""

init_cleanup_registry() {
  CLEANUP_FILE="$(mktemp)"
}

register_cleanup() {
  echo "$1" >> "$CLEANUP_FILE"
}

# 优雅停止后台进程：SIGTERM，最多等 15 秒，仍在则 SIGKILL
stop_pid() {
  local pid="$1"
  kill -0 "$pid" 2>/dev/null || return 0
  log_info "停止 PID ${pid}"
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 15); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null || true
}

cleanup_resources() {
  [ -n "$CLEANUP_FILE" ] && [ -f "$CLEANUP_FILE" ] || return 0
  local entry
  while IFS= read -r entry; do
    case "$entry" in
      PID:*)
        stop_pid "${entry#PID:}"
        ;;
      CONTAINER:*)
        [ -n "${CONTAINER_CLI:-}" ] || continue
        log_info "停止容器 ${entry#CONTAINER:}"
        "$CONTAINER_CLI" stop "${entry#CONTAINER:}" >/dev/null 2>&1 || true
        ;;
    esac
  done < "$CLEANUP_FILE"
  rm -f "$CLEANUP_FILE"
}
