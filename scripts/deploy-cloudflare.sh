#!/usr/bin/env bash
# Cloudflare Workers 部署脚本
# 用法: ./scripts/deploy-cloudflare.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/resolve-dir.sh"

CLOUD_DIR="$(resolve_dir "cloud")"

log_info "部署 aster-cloud 到 Cloudflare Workers"
cd "$CLOUD_DIR"
run_cmd pnpm run deploy

log_success "aster-cloud 部署完成"
