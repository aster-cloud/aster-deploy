#!/usr/bin/env bash
# Whole-stack 本地端到端集成测试
#
# 目的：在开发机器上重放 aster-* 各仓库的 GitHub Actions CI 关键步骤，
# 跑通 api + cloud + langs 的整体集成链路，作为推送前自检关。
#
# 默认行为：完全按照 CI 配置跑 —— 远程拉取、推镜像、Slack 通知等等。
# 添加 --local 后：跳过仅 CI 才有意义的副作用（docker push、ArgoCD
# sync、Slack notify、codecov 上传、artifact 上传），并优先使用本机
# sibling checkout / mavenLocal / npm registry localhost，加速且避免
# 远程依赖（airplane mode 也能跑）。
#
# 用法:
#   ./scripts/e2e-local.sh              # 等价于 CI（需要 secrets）
#   ./scripts/e2e-local.sh --local      # 推荐：本地开发自检
#   ./scripts/e2e-local.sh --local --skip cloud  # 跳过某 stage
#   ./scripts/e2e-local.sh --local --only api    # 仅跑某 stage
#
# 前置：
#   - ASTER_REPOS_DIR 指向各 aster-* repo 的父目录（默认 ${HOME}/IdeaProjects）
#   - 或为每个项目单独设 ASTER_<NAME>_DIR
#   - --local 模式还需要本机 Docker 守护进程（testcontainers / Postgres / Redis）
#
# 退出码:
#   0  全部 stage 通过
#   1+ 失败的 stage 数

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/resolve-dir.sh"

# 默认 ASTER_REPOS_DIR：脚本所在 repo 的父目录
ASTER_REPOS_DIR="${ASTER_REPOS_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
export ASTER_REPOS_DIR

# ─── 参数解析 ───────────────────────────────────────────────────────────
LOCAL_MODE=0
SKIP_STAGES=()
ONLY_STAGES=()

usage() {
  sed -n '2,30p' "$0"
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local)
      LOCAL_MODE=1
      shift
      ;;
    --skip)
      SKIP_STAGES+=("$2")
      shift 2
      ;;
    --only)
      ONLY_STAGES+=("$2")
      shift 2
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      log_error "未知参数: $1"
      usage 1
      ;;
  esac
done

# ─── stage 调度辅助 ─────────────────────────────────────────────────────
should_run_stage() {
  local stage="$1"
  if [ ${#ONLY_STAGES[@]} -gt 0 ]; then
    local s
    for s in "${ONLY_STAGES[@]}"; do
      [ "$s" = "$stage" ] && return 0
    done
    return 1
  fi
  local s
  for s in "${SKIP_STAGES[@]}"; do
    [ "$s" = "$stage" ] && return 1
  done
  return 0
}

# ─── 全局计数 ──────────────────────────────────────────────────────────
declare -a STAGE_NAMES=()
declare -a STAGE_STATUS=()  # PASS / FAIL / SKIP
declare -a STAGE_TIME=()

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
  local start_ts
  start_ts=$(date +%s)

  # subshell 隔离 cd / set -e 行为
  if ( "$@" ); then
    local end_ts duration
    end_ts=$(date +%s)
    duration=$((end_ts - start_ts))
    STAGE_NAMES+=("$name")
    STAGE_STATUS+=("PASS")
    STAGE_TIME+=("$duration")
    log_success "${name} 通过 (${duration}s)"
    return 0
  else
    local rc=$?
    local end_ts duration
    end_ts=$(date +%s)
    duration=$((end_ts - start_ts))
    STAGE_NAMES+=("$name")
    STAGE_STATUS+=("FAIL")
    STAGE_TIME+=("$duration")
    log_error "${name} 失败（exit=${rc}, ${duration}s）"
    return "$rc"
  fi
}

# ─── 通用工具 ──────────────────────────────────────────────────────────
ensure_cmd() {
  local cmd="$1" hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "缺少依赖: ${cmd}${hint:+ ($hint)}"
    return 1
  fi
}

ensure_dir() {
  local label="$1" dir="$2"
  if [ ! -d "$dir" ]; then
    log_error "${label} 目录不存在: ${dir}（设置 ASTER_REPOS_DIR 或对应的 ASTER_*_DIR）"
    return 1
  fi
}

wait_http() {
  local url="$1" timeout="${2:-60}" label="${3:-$url}"
  local i
  for i in $(seq 1 "$timeout"); do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      log_success "${label} 就绪（${i}s）"
      return 0
    fi
    sleep 1
  done
  log_error "${label} 等待超时（${timeout}s）"
  return 1
}

# 后台进程登记 + 退出清理
declare -a CLEANUP_PIDS=()
register_pid() {
  CLEANUP_PIDS+=("$1")
}

cleanup() {
  local pid
  for pid in "${CLEANUP_PIDS[@]:-}"; do
    [ -z "$pid" ] && continue
    if kill -0 "$pid" 2>/dev/null; then
      log_info "停止 PID ${pid}"
      kill "$pid" 2>/dev/null || true
      # 给 15 秒优雅关闭
      local i
      for i in $(seq 1 15); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT INT TERM

# 各 stage 的工作目录解析（带缓存）
declare -A REPO_DIR_CACHE=()
repo_dir() {
  local name="$1"
  if [ -n "${REPO_DIR_CACHE[$name]:-}" ]; then
    echo "${REPO_DIR_CACHE[$name]}"
    return 0
  fi
  local d
  d=$(resolve_dir "$name") || return 1
  REPO_DIR_CACHE[$name]="$d"
  echo "$d"
}

# ═══ stages ════════════════════════════════════════════════════════════

stage_preflight() {
  ensure_cmd git
  ensure_cmd curl
  ensure_cmd java   "JDK 24+ 必需（aster-api / aster-lang-core 构建）"
  ensure_cmd node   "Node 24+ 必需（aster-lang-ts / aster-cloud / aster-lang-dev）"
  ensure_cmd pnpm   "pnpm 10+ 必需（所有 TS workspace）"

  if [ "$LOCAL_MODE" = "1" ]; then
    # 本地模式额外需要 docker（testcontainers）
    ensure_cmd docker "用于 testcontainers / 本地 Postgres+Redis"
    if ! docker info >/dev/null 2>&1; then
      log_error "docker daemon 未运行"
      return 1
    fi
  fi

  ensure_dir "aster-api"          "$(repo_dir api)"
  ensure_dir "aster-cloud"        "$(repo_dir cloud)"
  ensure_dir "aster-lang-ts"      "$(repo_dir lang-ts)"
  ensure_dir "aster-lang-core"    "$(repo_dir lang-core)"
  ensure_dir "aster-lang-runtime" "$(repo_dir lang-runtime)"
  ensure_dir "aster-lang-test"    "$(repo_dir lang-test)"

  log_success "前置检查通过（mode=$([ $LOCAL_MODE = 1 ] && echo local || echo ci-parity)）"
}

stage_lang_core() {
  # 镜像 aster-lang-core/.github/workflows/ci.yml：编译 + 测试 +
  # publishToMavenLocal（aster-api 依赖它）
  local d
  d=$(repo_dir lang-core)
  cd "$d"

  log_info "aster-lang-core: gradlew test"
  ./gradlew test --no-daemon

  log_info "aster-lang-core: publishToMavenLocal"
  ./gradlew publishToMavenLocal -x test --no-daemon
}

stage_lang_runtime() {
  # 镜像 aster-lang-runtime/.github/workflows/ci.yml：单元测试 +
  # publishToMavenLocal
  local d
  d=$(repo_dir lang-runtime)
  cd "$d"

  log_info "aster-lang-runtime: gradlew test"
  ./gradlew test --no-daemon

  log_info "aster-lang-runtime: publishToMavenLocal"
  ./gradlew publishToMavenLocal -x test --no-daemon
}

stage_lang_test() {
  # aster-lang-test/packages/js：跑测试，准备 npm link 用于 aster-lang-ts
  local d
  d=$(repo_dir lang-test)/packages/js
  cd "$d"

  log_info "aster-lang-test/packages/js: 构建"
  pnpm install --frozen-lockfile=false
  pnpm build
  pnpm test
}

stage_lang_ts() {
  # 镜像 aster-lang-ts/.github/workflows/ci.yml：typecheck + lint + tests
  # + golden + property
  local d
  d=$(repo_dir lang-ts)
  cd "$d"

  pnpm install --frozen-lockfile=false
  pnpm run typecheck
  pnpm run lint
  pnpm run build
  pnpm run test
}

stage_api_build() {
  # 镜像 aster-api/.github/workflows/ci.yml：assemble + unit test
  # （integrationTest 留给 stage_api_e2e）
  local d
  d=$(repo_dir api)
  cd "$d"

  log_info "aster-api: gradlew test（不含 IT）"
  ./gradlew test --no-daemon

  log_info "aster-api: quarkusBuild"
  ./gradlew quarkusBuild -x test --no-daemon
}

stage_api_e2e() {
  # 启动 aster-api jar，跑健康检查 + evaluate-source 冒烟
  local d
  d=$(repo_dir api)
  cd "$d"

  if [ "$LOCAL_MODE" != "1" ]; then
    # CI parity 模式：integration tests 依赖 testcontainers，正常 CI 也跑
    log_info "aster-api: gradlew integrationTest（testcontainers）"
    ./gradlew integrationTest --no-daemon
    return 0
  fi

  # --local 模式：起一个轻量 Postgres+Redis 跑端到端冒烟
  log_info "启动本地 Postgres + Redis（docker run）"
  local pg_name="aster-e2e-pg-$$" redis_name="aster-e2e-redis-$$"
  docker run -d --rm --name "$pg_name" \
    -e POSTGRES_DB=aster_e2e -e POSTGRES_USER=aster -e POSTGRES_PASSWORD=aster \
    -p 15432:5432 postgres:17-alpine >/dev/null
  docker run -d --rm --name "$redis_name" \
    -p 16379:6379 redis:7-alpine >/dev/null

  # 注册清理（trap 会调用）
  CLEANUP_PIDS+=("DOCKER:$pg_name" "DOCKER:$redis_name")

  # 等 Postgres
  local i
  for i in $(seq 1 30); do
    docker exec "$pg_name" pg_isready -U aster >/dev/null 2>&1 && break
    sleep 1
  done

  # 后台启 aster-api
  log_info "启动 aster-api jar（后台）"
  : > "${d}/e2e-aster-api.log"
  (
    cd "$d"
    QUARKUS_DATASOURCE_JDBC_URL=jdbc:postgresql://localhost:15432/aster_e2e \
    QUARKUS_DATASOURCE_REACTIVE_URL=postgresql://localhost:15432/aster_e2e \
    QUARKUS_DATASOURCE_USERNAME=aster \
    QUARKUS_DATASOURCE_PASSWORD=aster \
    QUARKUS_REDIS_HOSTS=redis://localhost:16379 \
    QUARKUS_HTTP_PORT=18080 \
    ASTER_SECURITY_SIGNATURE_ENABLED=false \
    ASTER_SECURITY_RBAC_ENABLED=false \
    ASTER_SECURITY_EVALUATE_SOURCE_PUBLIC=true \
    ASTER_RATELIMIT_ENABLED=false \
    OTEL_TRACES_EXPORTER=none \
    nohup java -jar build/quarkus-app/quarkus-run.jar \
      > e2e-aster-api.log 2>&1 &
    echo $! > e2e-aster-api.pid
  )
  local api_pid
  api_pid=$(cat "${d}/e2e-aster-api.pid")
  register_pid "$api_pid"

  if ! wait_http "http://localhost:18080/q/health" 90 "aster-api /q/health"; then
    log_error "aster-api 启动失败，日志末 80 行："
    tail -80 "${d}/e2e-aster-api.log" >&2 || true
    return 1
  fi

  log_info "POST /api/v1/policies/evaluate-source 冒烟"
  local resp
  resp=$(curl -fsS -X POST http://localhost:18080/api/v1/policies/evaluate-source \
    -H 'Content-Type: application/json' \
    -H 'X-Tenant-Id: e2e-tenant' \
    -d '{
      "source": "Module e2e.smoke. Rule evaluate given amount: amount > 100.",
      "context": { "amount": 150 },
      "locale": "en-US",
      "functionName": "evaluate"
    }')
  echo "$resp" | head -1
  echo "$resp" | grep -q '"result"' || { log_error "evaluate-source 响应缺少 result 字段"; return 1; }
  log_success "evaluate-source 冒烟通过"
}

stage_cloud() {
  # 镜像 aster-cloud/.github/workflows/ci.yml：lint + typecheck + tests + build
  local d
  d=$(repo_dir cloud)
  cd "$d"

  pnpm install --frozen-lockfile=false
  pnpm lint
  pnpm exec tsc --noEmit
  pnpm run check:locales:strict

  # glossary 检查：CI 中 stage 1 是 report-only。--local 模式保持一致行为。
  pnpm run check:glossary || log_warn "check:glossary 有发现（stage 1 report-only，不阻塞）"

  # 测试：SaaS + on-prem 两个 vitest project
  pnpm test:run

  # build：next build。--local 模式跳过 opennext + cloudflare 部分（不需要部署）
  if [ "$LOCAL_MODE" = "1" ]; then
    log_info "--local: 仅跑 next build:next（跳过 opennext Cloudflare 包装）"
    pnpm run build:next
  else
    pnpm run build
  fi
}

# CI-only：副作用步骤（docker push / ArgoCD / Slack / codecov / artifact）。
# --local 模式下统一跳过；CI parity 模式下也跳过（因为本脚本不是真 CI），
# 但打印一条提示让用户知道哪些步骤需要单独跑。
stage_ci_only_notice() {
  if [ "$LOCAL_MODE" = "1" ]; then
    log_info "--local 模式：跳过 CI-only 副作用（docker push / ArgoCD / Slack / codecov / artifact）"
  else
    log_warn "本脚本不替代真实 CI：以下步骤未执行 ——"
    log_warn "  · docker build & push (aster-api/.github/workflows/deploy.yml)"
    log_warn "  · ArgoCD sync 触发（aster-cloud/.github/workflows/ci.yml build-migrate-image）"
    log_warn "  · Codecov / artifact upload"
    log_warn "  · Slack notify"
    log_warn "  · npm publish（aster-lang-ts / aster-lang-test / aster-cloud/glossary）"
    log_warn "推送 main 后由 GitHub Actions 自动跑这些。"
  fi
}

# ═══ docker container 清理（运行 stage_api_e2e 时启动的） ═══════════════
cleanup_docker_containers() {
  local entry
  for entry in "${CLEANUP_PIDS[@]:-}"; do
    case "$entry" in
      DOCKER:*)
        local cname="${entry#DOCKER:}"
        if docker ps --format '{{.Names}}' | grep -qx "$cname"; then
          log_info "停止容器 ${cname}"
          docker stop "$cname" >/dev/null 2>&1 || true
        fi
        ;;
    esac
  done
}
trap 'cleanup_docker_containers; cleanup' EXIT INT TERM

# ═══ 主流程 ════════════════════════════════════════════════════════════
GLOBAL_START=$(date +%s)
echo ""
log_info "Aster 端到端集成测试（mode=$([ $LOCAL_MODE = 1 ] && echo local || echo ci-parity)）"
log_info "ASTER_REPOS_DIR=${ASTER_REPOS_DIR}"
[ ${#SKIP_STAGES[@]} -gt 0 ] && log_info "skip: ${SKIP_STAGES[*]}"
[ ${#ONLY_STAGES[@]} -gt 0 ] && log_info "only: ${ONLY_STAGES[*]}"

# stage 失败不立即退出 —— 收集后统一汇总，便于一次跑完看全貌。
# 单 stage 内部仍用 set -e 行为（subshell + run_stage 检查 exit code）
set +e

run_stage preflight     "preflight: 工具链 + 仓库目录" stage_preflight

# lang 链路：core → runtime → test → ts
run_stage lang-core     "aster-lang-core: test + publishToMavenLocal" stage_lang_core
run_stage lang-runtime  "aster-lang-runtime: test + publishToMavenLocal" stage_lang_runtime
run_stage lang-test     "aster-lang-test/js: build + test" stage_lang_test
run_stage lang-ts       "aster-lang-ts: typecheck + lint + test + build" stage_lang_ts

# 后端 api
run_stage api-build     "aster-api: test + quarkusBuild" stage_api_build
run_stage api-e2e       "aster-api: e2e（启动 + evaluate-source 冒烟 / IT）" stage_api_e2e

# 前端 cloud
run_stage cloud         "aster-cloud: lint + typecheck + test + build" stage_cloud

# CI-only 步骤提示
stage_ci_only_notice

set -e

# ─── 汇总 ──────────────────────────────────────────────────────────────
GLOBAL_END=$(date +%s)
TOTAL=$((GLOBAL_END - GLOBAL_START))

echo ""
echo "═══ 测试汇总 ═══"
PASSED=0
FAILED=0
SKIPPED=0
for i in "${!STAGE_NAMES[@]}"; do
  local_name="${STAGE_NAMES[$i]}"
  local_status="${STAGE_STATUS[$i]}"
  local_time="${STAGE_TIME[$i]}"
  case "$local_status" in
    PASS)
      printf "${COLOR_SUCCESS}  ✓ %-58s${COLOR_RESET} %ss\n" "$local_name" "$local_time"
      PASSED=$((PASSED + 1))
      ;;
    FAIL)
      printf "${COLOR_ERROR}  ✗ %-58s${COLOR_RESET} %ss\n" "$local_name" "$local_time"
      FAILED=$((FAILED + 1))
      ;;
    SKIP)
      printf "${COLOR_DIM}  - %-58s${COLOR_RESET} skipped\n" "$local_name"
      SKIPPED=$((SKIPPED + 1))
      ;;
  esac
done

echo ""
summary "$PASSED" "$FAILED" "$TOTAL"
[ "$SKIPPED" -gt 0 ] && log_info "${SKIPPED} 个 stage 被跳过"

exit "$FAILED"
