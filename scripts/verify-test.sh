#!/usr/bin/env bash
# 全栈测试环境冒烟测试
# 用法: ./scripts/verify-test.sh
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
  if retry 5 3 curl -sf --max-time 5 "$url" >/dev/null; then
    log_success "${label}"
  else
    log_error "${label}"
    ERRORS=$((ERRORS + 1))
  fi
}

check_tcp() {
  local label="$1" host="$2" port="$3"
  if ! command -v nc >/dev/null 2>&1; then
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

# 检测容器运行时
if command -v podman >/dev/null 2>&1; then
  CONTAINER_RT=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_RT=docker
else
  log_error "未找到 podman 或 docker"
  exit 1
fi

# 通过容器运行时在 postgres 容器内执行 psql
pg_exec() {
  "$CONTAINER_RT" exec aster-postgres psql -U postgres "$@" 2>/dev/null
}

echo "=== 全栈测试环境冒烟测试 ==="

echo ""
echo "--- 基础设施 ---"
check_tcp "PostgreSQL" "localhost" "$PG_PORT"
check_tcp "Redis" "localhost" "$REDIS_PORT"

echo ""
echo "--- 数据库（等待 cloud 初始化完成）---"
# cloud 容器的 entrypoint 需要时间执行 pnpm install + drizzle-kit push + seed SQL
# 简单轮询等待种子用户就绪（最多 120s）
SEED_READY=0
for i in $(seq 1 24); do
  if pg_exec -d aster_cloud -tAc "SELECT 1 FROM \"User\" WHERE email = 'test@aster.dev';" 2>/dev/null | grep -q .; then
    SEED_READY=1
    break
  fi
  log_info "等待 cloud 初始化 ... (${i}/24, 每 5s 重试)"
  sleep 5
done

if [ "$SEED_READY" = "1" ]; then
  log_success "aster_cloud 数据库存在"
  log_success "User 表存在"
  log_success "种子用户 test@aster.dev 存在"
else
  # 逐项检查，方便定位具体问题
  if pg_exec -lqt | cut -d'|' -f1 | grep -qw aster_cloud; then
    log_success "aster_cloud 数据库存在"
  else
    log_error "aster_cloud 数据库不存在"
    ERRORS=$((ERRORS + 1))
  fi

  if pg_exec -d aster_cloud -tAc "SELECT 1 FROM \"User\" LIMIT 1;" 2>/dev/null | grep -q .; then
    log_success "User 表存在"
  else
    log_error "User 表不存在（cloud entrypoint 可能仍在执行 drizzle-kit push）"
    ERRORS=$((ERRORS + 1))
  fi

  if pg_exec -d aster_cloud -tAc "SELECT 1 FROM \"User\" WHERE email = 'test@aster.dev';" 2>/dev/null | grep -q .; then
    log_success "种子用户 test@aster.dev 存在"
  else
    log_error "种子用户 test@aster.dev 不存在"
    ERRORS=$((ERRORS + 1))
  fi
fi

echo ""
echo "--- 应用服务 ---"
check_url "aster-api 健康检查" "http://localhost:${API_PORT}/q/health"

# 验证安全控制已禁用：POST 请求无需 HMAC 签名即可到达业务逻辑层
# 使用 evaluate-source 端点，预期返回 400（参数缺失）而非 401/403（未认证/未授权）
SECURITY_HTTP_CODE=$(retry 3 2 curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  -X POST \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: test" \
  -d '{"source":"Module Test."}' \
  "http://localhost:${API_PORT}/api/v1/policies/evaluate-source" 2>/dev/null || echo "000")
if [ "$SECURITY_HTTP_CODE" = "401" ] || [ "$SECURITY_HTTP_CODE" = "403" ] || [ "$SECURITY_HTTP_CODE" = "000" ]; then
  log_error "API 安全控制未禁用（HTTP ${SECURITY_HTTP_CODE}）"
  ERRORS=$((ERRORS + 1))
else
  log_success "API 安全控制已禁用（HTTP ${SECURITY_HTTP_CODE}）"
fi

check_url "aster-cloud 首页" "http://localhost:${CLOUD_PORT}"

echo ""
if [ "$ERRORS" -gt 0 ]; then
  log_error "测试环境验证失败（${ERRORS} 个错误）"
  exit 1
else
  log_success "全栈测试环境就绪"
  echo ""
  echo "--- 测试凭据 ---"
  echo "  邮箱:   test@aster.dev"
  echo "  密码:   test1234"
  echo "  登录:   http://localhost:${CLOUD_PORT}/login"
  echo ""
  echo "--- API 测试 ---"
  echo "  健康检查: curl http://localhost:${API_PORT}/q/health"
  echo "  评估:     curl -X POST -H 'Content-Type: application/json' -H 'X-Tenant-Id: test' -d '{\"source\":\"Module Test.\"}' http://localhost:${API_PORT}/api/v1/policies/evaluate-source"
fi
