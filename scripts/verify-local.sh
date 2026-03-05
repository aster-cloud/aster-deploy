#!/usr/bin/env bash
# 本地环境冒烟测试
# 用法: ./scripts/verify-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/retry.sh"

API_PORT="${LOCAL_API_PORT:-8080}"
CLOUD_PORT="${LOCAL_CLOUD_PORT:-3000}"
PG_PORT="${LOCAL_PG_PORT:-5432}"
REDIS_PORT="${LOCAL_REDIS_PORT:-6379}"
ERRORS=0

check_url() {
  local label="$1" url="$2"
  if retry 3 2 curl -sf --max-time 5 "$url" >/dev/null; then
    log_success "${label}"
  else
    log_warn "${label} — 未运行（可能尚未启动）"
    ERRORS=$((ERRORS + 1))
  fi
}

check_tcp() {
  local label="$1" host="$2" port="$3"
  if ! command -v nc >/dev/null 2>&1; then
    # nc 不可用时回退到 bash /dev/tcp
    if (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; then
      log_success "${label} (${host}:${port})"
    else
      log_error "${label} (${host}:${port})"
      ERRORS=$((ERRORS + 1))
    fi
    return
  fi
  if nc -z "$host" "$port" 2>/dev/null; then
    log_success "${label} (${host}:${port})"
  else
    log_error "${label} (${host}:${port})"
    ERRORS=$((ERRORS + 1))
  fi
}

echo "=== 本地环境冒烟测试 ==="

echo ""
echo "--- 基础设施 ---"
check_tcp "PostgreSQL" "localhost" "$PG_PORT"
check_tcp "Redis" "localhost" "$REDIS_PORT"

echo ""
echo "--- 应用服务（可选） ---"
check_url "aster-api 健康检查" "http://localhost:${API_PORT}/q/health"
check_url "aster-cloud 首页" "http://localhost:${CLOUD_PORT}"

echo ""
if [ "$ERRORS" -gt 0 ]; then
  log_warn "部分服务未运行（${ERRORS} 个），基础设施已就绪即可开始开发"
else
  log_success "所有本地服务正常"
fi
