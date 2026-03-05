#!/usr/bin/env bash
# 环境预检脚本
# 用法: ./scripts/preflight.sh <mode>  (mode: infra|local|dev|release)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/resolve-dir.sh"

MODE="${1:-dev}"
ERRORS=0

check_cmd() {
  local cmd="$1" min_version="${2:-}" label="${3:-$1}"
  if command -v "$cmd" >/dev/null 2>&1; then
    local version
    version="$("$cmd" -version 2>&1 | head -1 | grep -oE '[0-9]+[.0-9]*' | head -1 || true)"
    [ -z "$version" ] && version="$("$cmd" --version 2>&1 | head -1 | grep -oE '[0-9]+[.0-9]*' | head -1 || echo "unknown")"
    log_success "${label} ${version}"
  else
    log_error "${label} 未找到"
    ERRORS=$((ERRORS + 1))
  fi
}

check_env() {
  local var="$1" label="${2:-$1}"
  if [ -n "${!var:-}" ]; then
    log_success "${label} 已设置"
  else
    log_error "${label} (${var}) 未设置"
    ERRORS=$((ERRORS + 1))
  fi
}

check_dir() {
  local project="$1"
  local dir
  if dir="$(resolve_dir "$project" 2>/dev/null)"; then
    log_success "aster-${project} → ${dir}"
  else
    log_error "aster-${project} 目录未找到"
    ERRORS=$((ERRORS + 1))
  fi
}

check_container_runtime() {
  if command -v podman >/dev/null 2>&1; then
    log_success "Podman $(podman --version 2>&1 | grep -oE '[0-9]+[.0-9]*' | head -1)"
  elif command -v docker >/dev/null 2>&1; then
    log_success "Docker $(docker --version 2>&1 | grep -oE '[0-9]+[.0-9]*' | head -1)"
  else
    log_error "容器运行时未找到（需要 podman 或 docker）"
    ERRORS=$((ERRORS + 1))
  fi
}

check_compose() {
  if command -v podman-compose >/dev/null 2>&1; then
    log_success "podman-compose $(podman-compose --version 2>&1 | grep -oE '[0-9]+[.0-9]*' | head -1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    log_success "docker-compose $(docker-compose --version 2>&1 | grep -oE '[0-9]+[.0-9]*' | head -1)"
  elif podman compose version >/dev/null 2>&1; then
    log_success "podman compose (内置)"
  elif docker compose version >/dev/null 2>&1; then
    log_success "docker compose (内置)"
  else
    log_error "compose 工具未找到（需要 podman-compose 或 docker-compose）"
    ERRORS=$((ERRORS + 1))
  fi
}

echo "=== 环境预检 (mode=${MODE}) ==="
echo ""

# infra 模式：仅检查容器运行时和 compose
if [ "$MODE" = "infra" ]; then
  echo "--- 容器运行时 ---"
  check_container_runtime
  check_compose
  echo ""
  if [ "$ERRORS" -gt 0 ]; then
    log_error "预检失败：${ERRORS} 个问题"
    exit 1
  else
    log_success "预检通过"
  fi
  exit 0
fi

# 基础工具（local/dev/release）
echo "--- 工具链 ---"
check_cmd java "" "Java"
check_cmd node "" "Node.js"
check_cmd pnpm "" "pnpm"

# 容器运行时（local + release）
if [ "$MODE" = "local" ] || [ "$MODE" = "release" ]; then
  check_container_runtime
fi

# Compose 工具（仅 local）
if [ "$MODE" = "local" ]; then
  check_compose
fi

# 发布工具（仅 release）
if [ "$MODE" = "release" ]; then
  check_cmd kubectl "" "kubectl"
  check_cmd wrangler "" "wrangler"
fi

echo ""
echo "--- 项目目录 ---"
for project in lang-core lang-en lang-zh lang-de lang-runtime lang-truffle api lang-ts cloud; do
  check_dir "$project"
done

# 发布凭证（仅 release）
if [ "$MODE" = "release" ]; then
  echo ""
  echo "--- 凭证 ---"
  check_env GITHUB_TOKEN "GitHub Token"
  check_env NPM_TOKEN "NPM Token"
  check_env DOCKERHUB_USERNAME "Docker Hub Username"
  check_env DOCKERHUB_TOKEN "Docker Hub Token"
  check_env CLOUDFLARE_API_TOKEN "Cloudflare API Token"
  check_env KUBECONFIG "KUBECONFIG"
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
  log_error "预检失败：${ERRORS} 个问题"
  exit 1
else
  log_success "预检通过"
fi
