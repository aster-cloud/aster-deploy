#!/usr/bin/env bash
# Gradle 发布到 GitHub Packages
# 用法: ./scripts/gradle-publish.sh <project-name> [<project-name>...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/resolve-dir.sh"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  log_error "GITHUB_TOKEN 未设置"
  exit 1
fi

for project in "$@"; do
  PROJECT_DIR="$(resolve_dir "$project")"
  log_info "发布 aster-${project} (${PROJECT_DIR})"
  cd "$PROJECT_DIR"
  run_cmd ./gradlew publish
  log_success "aster-${project} 发布完成"
done
