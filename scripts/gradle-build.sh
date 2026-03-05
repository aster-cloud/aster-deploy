#!/usr/bin/env bash
# Gradle 项目构建脚本
# 用法: ./scripts/gradle-build.sh <project-name> [--publish-local]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/resolve-dir.sh"

PROJECT_NAME="$1"
PUBLISH_LOCAL=false

shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish-local) PUBLISH_LOCAL=true; shift ;;
    *) log_error "未知参数: $1"; exit 1 ;;
  esac
done

PROJECT_DIR="$(resolve_dir "$PROJECT_NAME")"
log_info "构建 aster-${PROJECT_NAME} (${PROJECT_DIR})"

cd "$PROJECT_DIR"

if [ "$PUBLISH_LOCAL" = true ]; then
  run_cmd ./gradlew build publishToMavenLocal -x test
else
  run_cmd ./gradlew build -x test
fi

log_success "aster-${PROJECT_NAME} 构建完成"
