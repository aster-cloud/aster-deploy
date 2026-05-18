# license-signing-api service identity policy
# 只有 service principal 可调用 Transit sign；人类 Operator/Witness token 不应绑定此 policy。
#
# Vault 默认 deny — 不要写 `path "*" { capabilities = ["deny"] }`，那会
# 覆盖前面的 allow 规则导致 service 完全不能 sign（codex 审查 Critical-2）。
# 显式 deny 仅用于高敏 path（export/backup/datakey）作纵深防御。

path "transit/sign/license-signing-*" {
  capabilities = ["update"]
}

path "transit/sign/revocation-signing-*" {
  capabilities = ["update"]
}

path "transit/keys/license-signing-*" {
  capabilities = ["read"]
}

path "transit/keys/revocation-signing-*" {
  capabilities = ["read"]
}

path "secret/data/audit/license-issuance/*" {
  capabilities = ["create", "update"]
}

# 显式 deny 高敏 path —— 即使未来误加 root policy 也无法导出私钥
path "transit/export/*" {
  capabilities = ["deny"]
}

path "transit/backup/*" {
  capabilities = ["deny"]
}

path "transit/datakey/*" {
  capabilities = ["deny"]
}
