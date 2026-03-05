#!/usr/bin/env bash
# 解析项目目录路径
# 优先级: ASTER_<NAME>_DIR > ASTER_REPOS_DIR/<name>
# 用法: source resolve-dir.sh; resolve_dir "lang-core"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"

resolve_dir() {
  local project_name="$1"

  # 将 project_name 转为环境变量名: lang-core → LANG_CORE
  local env_name
  env_name="ASTER_$(echo "$project_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_DIR"

  # 优先使用专用环境变量
  local dir="${!env_name:-}"
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    echo "$dir"
    return 0
  fi

  # 回退到 ASTER_REPOS_DIR/aster-<name>
  local repos_dir="${ASTER_REPOS_DIR:-}"
  if [ -z "$repos_dir" ]; then
    log_error "未设置 ASTER_REPOS_DIR 或 ${env_name}"
    return 1
  fi

  dir="${repos_dir}/aster-${project_name}"
  if [ -d "$dir" ]; then
    echo "$dir"
    return 0
  fi

  log_error "项目目录不存在: ${dir}（设置 ${env_name} 或 ASTER_REPOS_DIR）"
  return 1
}
