#!/usr/bin/env bash
# Vault 身份提取（通过 source 使用；依赖 jq 与 log.sh）。

# 从 `vault token lookup -format=json` 的输出（stdin）提取稳定的身份标识。
#
# ★只认 entity_id（issue #34）：display_name 由 token 创建者自定，且 `vault token create`
#   不指定 -display-name 时恒为字符串 "token"，用它判「Operator ≠ Witness」会把两个不同的人
#   误判为同一身份，也允许单人造两个不同 display_name 的 token 绕过。
#   无 entity（root / 纯 token auth）时拒绝，要求使用 OIDC / userpass / LDAP 等带 entity 的认证。
vault_identity_from_lookup() {
  local entity
  entity="$(jq -r '.data.entity_id // empty' 2>/dev/null)" || entity=""
  if [ -z "$entity" ]; then
    log_error "Vault token 没有 entity_id：请用 OIDC / userpass / LDAP 等带 entity 的认证方式登录后再签发"
    return 1
  fi
  printf '%s' "$entity"
}
