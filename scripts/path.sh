#!/usr/bin/env bash
# 路径辅助（通过 source 使用）。

# 展开开头的 ~ 或 ~/。
# Task 的 dotenv 与 kubectl --kubeconfig 都不会展开波浪号，.env 里写 ~/.kube/xxx
# 会得到一个不存在的字面量路径（issue #25）。
expand_tilde() {
  # shellcheck disable=SC2088  # 这里就是要按字面匹配 ~/
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s' "${HOME}/${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
