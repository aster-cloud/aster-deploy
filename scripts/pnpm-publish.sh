#!/usr/bin/env bash
# npm 发布脚本（带版本冲突检测）
# 用法: ./scripts/pnpm-publish.sh <project-name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/resolve-dir.sh"

PROJECT_NAME="$1"
PROJECT_DIR="$(resolve_dir "$PROJECT_NAME")"

log_info "发布 aster-${PROJECT_NAME} (${PROJECT_DIR})"
cd "$PROJECT_DIR"

# 读取 package.json 中的包名和版本
PKG_NAME="$(node -p "require('./package.json').name")"
PKG_VERSION="$(node -p "require('./package.json').version")"

# 检查版本是否已发布
PUBLISHED_VERSION="$(npm view "${PKG_NAME}" version 2>/dev/null || echo "")"
if [ "$PUBLISHED_VERSION" = "$PKG_VERSION" ]; then
  log_warn "${PKG_NAME}@${PKG_VERSION} 已发布，跳过"
  exit 0
fi

run_cmd pnpm publish --no-git-checks

log_success "${PKG_NAME}@${PKG_VERSION} 发布完成"
