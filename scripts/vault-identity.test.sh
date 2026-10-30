#!/usr/bin/env bash
# vault-identity.sh 离线测试：身份取 entity_id，不得被默认 display_name=token 误判（issue #34）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/log.sh"
source "${SCRIPT_DIR}/vault-identity.sh"

FAILURES=0
check() { # check <描述> <期望> <实际>
  if [ "$2" = "$3" ]; then echo "✓ $1"; else echo "✗ $1（期望=[$2] 实际=[$3]）" >&2; FAILURES=$((FAILURES + 1)); fi
}

# 两个不同人的普通 token：display_name 同为 "token"，entity_id 不同
alice='{"data":{"display_name":"token","entity_id":"ent-alice","id":"hvs.a"}}'
bob='{"data":{"display_name":"token","entity_id":"ent-bob","id":"hvs.b"}}'
check "取 entity_id 而非 display_name" "ent-alice" "$(printf '%s' "$alice" | vault_identity_from_lookup 2>/dev/null)"
check "不同人得到不同身份" "1" "$([ "$(printf '%s' "$alice" | vault_identity_from_lookup 2>/dev/null)" != "$(printf '%s' "$bob" | vault_identity_from_lookup 2>/dev/null)" ] && echo 1 || echo 0)"

# 无 entity 的 token（root / 纯 token auth）：必须拒绝，不能回退到 display_name 或 id
for body in \
  '{"data":{"display_name":"token","entity_id":"","id":"hvs.x"}}' \
  '{"data":{"display_name":"token","entity_id":null,"id":"hvs.x"}}' \
  '{"data":{"display_name":"token","id":"hvs.x"}}' \
  'not-json'; do
  out="$(printf '%s' "$body" | vault_identity_from_lookup 2>/dev/null)"; rc=$?
  check "无 entity_id 时拒绝并无输出: ${body:0:40}" "1|" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)|$out"
done

# 升级前遗留的在途 approval：operator 是 display_name，不是 entity_id UUID
check "UUID 形式的 entity_id 通过" "0" "$(is_entity_id 3f2a9c1d-0b7e-4c55-9a1e-6d2b8f4e7a10; echo $?)"
check "display_name（token）被拒绝" "1" "$(is_entity_id token; echo $?)"
check "空串被拒绝" "1" "$(is_entity_id ''; echo $?)"
check "null 被拒绝" "1" "$(is_entity_id null; echo $?)"

[ "$FAILURES" -eq 0 ] || { echo "vault-identity 测试失败: $FAILURES 项" >&2; exit 1; }
echo "✓ vault-identity.sh 全部通过"
