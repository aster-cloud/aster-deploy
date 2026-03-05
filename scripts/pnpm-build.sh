#!/usr/bin/env bash
# pnpm 项目构建脚本
# 用法: ./scripts/pnpm-build.sh <project-name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/resolve-dir.sh"

PROJECT_NAME="$1"
PROJECT_DIR="$(resolve_dir "$PROJECT_NAME")"

log_info "构建 aster-${PROJECT_NAME} (${PROJECT_DIR})"
cd "$PROJECT_DIR"

run_cmd pnpm install --frozen-lockfile
run_cmd pnpm run build

log_success "aster-${PROJECT_NAME} 构建完成"
