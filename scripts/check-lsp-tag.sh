#!/usr/bin/env bash
# 校验 LSP_IMAGE_TAG 是否可用于发布。用法: check-lsp-tag.sh <tag>
# 供 container:lsp 与 release 的预检共用，保证两处判定一致（issue #29）。
set -euo pipefail

TAG="${1:-}"

# ★同时拒绝「空」与「历史可变 tag 0.0.9」。
#   只判空是不够的：仓库 .env（gitignored）里长期写着 LSP_IMAGE_TAG=0.0.9，
#   守卫会被存量本地配置**静默绕过**。
if [ -z "$TAG" ] || [ "$TAG" = "0.0.9" ]; then
  cat >&2 <<'MSG'
✗ 必须显式指定 LSP_IMAGE_TAG，且必须是不可变 tag（不能是 0.0.9）。

  为什么：往同一 tag 重复推镜像时，有缓存的节点会**静默继续跑旧版本**，
  rollout restart 也换不掉（issue #9）。且生产 lsp 现已按 digest 固定
  （k3s apps/aster-lang/lsp/kustomization.yaml），推 tag 本身不会触发部署，
  正式发布走 aster-cloud CI 的 build-lsp-image job + k3s image-pin（issue #16）。

  用法：task release LSP_IMAGE_TAG=$(git -C ../aster-cloud rev-parse HEAD)
        task container:lsp LSP_IMAGE_TAG=$(git -C ../aster-cloud rev-parse HEAD)
  （必须用 task 的 var 语法传；仓库有 dotenv: [.env]，前置环境变量会被 .env 覆盖）

  若你的本地 .env 里有 `LSP_IMAGE_TAG=0.0.9`，请删掉那一行。
MSG
  exit 1
fi
