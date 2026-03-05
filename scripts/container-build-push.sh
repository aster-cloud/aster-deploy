#!/usr/bin/env bash
# 容器镜像构建与推送（Podman 优先，Docker 回退）
# 用法: ./scripts/container-build-push.sh <project-name> <image> <tag> [--dockerfile <path>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/resolve-dir.sh"
source "${SCRIPT_DIR}/retry.sh"

PROJECT_NAME="$1"
IMAGE="$2"
TAG="$3"
shift 3

DOCKERFILE="Dockerfile.jvm"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dockerfile) DOCKERFILE="$2"; shift 2 ;;
    *) log_error "未知参数: $1"; exit 1 ;;
  esac
done

PROJECT_DIR="$(resolve_dir "$PROJECT_NAME")"
FULL_IMAGE="${IMAGE}:${TAG}"

# 自动检测容器运行时
detect_runtime() {
  if command -v podman >/dev/null 2>&1; then
    echo "podman"
  elif command -v docker >/dev/null 2>&1; then
    echo "docker"
  else
    log_error "未找到 podman 或 docker"
    exit 1
  fi
}

# 自动检测目标平台
detect_platform() {
  case "$(uname -m)" in
    arm64|aarch64) echo "linux/arm64" ;;
    x86_64|amd64)  echo "linux/amd64" ;;
    *)             echo "linux/amd64" ;;
  esac
}

RUNTIME="${CONTAINER_RUNTIME:-$(detect_runtime)}"
PLATFORM="${CONTAINER_PLATFORM:-$(detect_platform)}"
log_info "使用 ${RUNTIME} 构建 ${FULL_IMAGE} (${PLATFORM})"

cd "$PROJECT_DIR"
run_cmd "$RUNTIME" build --platform "$PLATFORM" -f "$DOCKERFILE" -t "$FULL_IMAGE" .
log_success "镜像构建完成: ${FULL_IMAGE}"

log_info "推送 ${FULL_IMAGE}"
retry 3 5 run_cmd "$RUNTIME" push "$FULL_IMAGE"
log_success "镜像推送完成: ${FULL_IMAGE}"
