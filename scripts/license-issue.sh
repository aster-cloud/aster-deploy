#!/usr/bin/env bash
# License v2 签发工具。
#
# 工作流（2 人审批，OSS Vault 兼容）：
#   1. Operator 持 VAULT_TOKEN_OPERATOR 运行（不带 --approve），脚本生成 payload + approval token，
#      写入 secret/audit/license-approvals/<token>。Operator token ACL 禁止 sign。
#   2. Witness 复核 payload，持自己的 VAULT_TOKEN_WITNESS 加上 VAULT_TOKEN_OPERATOR 运行
#      --approve <token>，脚本读取 approval、调用 transit sign（仅 Witness token 有 sign 权）、
#      写入审计、删除 approval。
#
# 用法:
#   VAULT_TOKEN_OPERATOR=... scripts/license-issue.sh \
#     --customer "Acme Corp" --tier enterprise --seats 500 \
#     --term annual --features sso,audit-export --sku standard
#   VAULT_TOKEN_OPERATOR=... VAULT_TOKEN_WITNESS=... scripts/license-issue.sh --approve <token>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log.sh
source "${SCRIPT_DIR}/log.sh"

ALLOWED_FEATURES="sso audit-export custom-domain lsp-cluster byok-keys"
REVOCATION_CHECK_URL="https://license.aster-lang.cloud/revoked.json"
APPROVAL_PATH_PREFIX="secret/audit/license-approvals"
ISSUANCE_PATH_PREFIX="secret/audit/license-issuance"

# 输入白名单 —— codex 审查 Major-4
# keyId 必须严格匹配 ceremony 命名约定
KEY_ID_RE='^license-signing-v2-[0-9]{4}-[0-9]{2}$'
# approval token 必须是 64 hex（sha256 输出）
APPROVAL_TOKEN_RE='^[0-9a-f]{64}$'

CUSTOMER=""
TIER=""
SEATS=""
TERM=""
FEATURES=""
SKU=""
DRY_RUN=0
KEY_ID=""
APPROVE_TOKEN=""

usage() {
  cat <<'EOF'
用法:
  scripts/license-issue.sh \
    --customer "Acme Corp" \
    --tier enterprise|enterprise-plus \
    --seats <int|-1> \
    --term annual|five-year|perpetual \
    --features sso,audit-export,... \
    --sku standard|air-gapped \
    [--key-id <signing-key-id>] \
    [--dry-run]

审批签发:
  VAULT_TOKEN_OPERATOR=... VAULT_TOKEN_WITNESS=... \
    scripts/license-issue.sh --approve <approval-token>

环境变量:
  VAULT_ADDR                 Vault 地址
  VAULT_TOKEN_OPERATOR       Operator token，首次生成 approval 与最终签发均需要
  VAULT_TOKEN_WITNESS        Witness token，仅 --approve 签发时需要
  LICENSES_SLACK_WEBHOOK     可选，签发成功后发送 #licenses-ops 审计消息
EOF
}

die() {
  log_error "$1"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --customer)   CUSTOMER="${2:-}"; shift 2 ;;
    --tier)       TIER="${2:-}"; shift 2 ;;
    --seats)      SEATS="${2:-}"; shift 2 ;;
    --term)       TERM="${2:-}"; shift 2 ;;
    --features)   FEATURES="${2:-}"; shift 2 ;;
    --sku)        SKU="${2:-}"; shift 2 ;;
    --key-id)     KEY_ID="${2:-}"; shift 2 ;;
    --approve)    APPROVE_TOKEN="${2:-}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "未知参数: $1" ;;
  esac
done

require_cmd vault
require_cmd jq
require_cmd openssl
require_cmd node
require_cmd awk
require_cmd curl

[ -n "${VAULT_ADDR:-}" ] || die "必须设置 VAULT_ADDR"
[ -n "${VAULT_TOKEN_OPERATOR:-}" ] || die "必须设置 VAULT_TOKEN_OPERATOR"

# -----------------------------------------------------------------------------
# 编码 / 哈希 helpers
# -----------------------------------------------------------------------------

b64() { openssl base64 -A; }
b64decode() { openssl base64 -d -A; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
sha256_hex() { openssl dgst -sha256 -r | awk '{print $1}'; }

utc_now() {
  node -e 'process.stdout.write(new Date().toISOString().replace(/\.\d{3}Z$/, "Z"))'
}

utc_add() {
  local term="$1"
  node -e '
const term = process.argv[1];
const d = new Date();
if (term === "annual") {
  d.setUTCDate(d.getUTCDate() + 365);
} else if (term === "five-year") {
  d.setUTCFullYear(d.getUTCFullYear() + 5);
} else if (term === "perpetual") {
  d.setUTCFullYear(d.getUTCFullYear() + 100);
} else {
  process.exit(2);
}
process.stdout.write(d.toISOString().replace(/\.\d{3}Z$/, "Z"));
' "$term"
}

generate_ulid() {
  node <<'NODE'
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const crypto = require("crypto");
const bytes = Buffer.alloc(16);
let ts = BigInt(Date.now());
for (let i = 5; i >= 0; i -= 1) {
  bytes[i] = Number(ts & 0xffn);
  ts >>= 8n;
}
crypto.randomBytes(10).copy(bytes, 6);
let value = 0n;
for (const byte of bytes) value = (value << 8n) | BigInt(byte);
let out = "";
for (let i = 0; i < 26; i += 1) {
  out = alphabet[Number(value & 31n)] + out;
  value >>= 5n;
}
process.stdout.write(out);
NODE
}

# -----------------------------------------------------------------------------
# Vault helpers
# -----------------------------------------------------------------------------

operator_identity() {
  VAULT_TOKEN="$VAULT_TOKEN_OPERATOR" vault token lookup -format=json \
    | jq -r '.data.display_name // .data.entity_id // .data.id'
}

witness_identity() {
  VAULT_TOKEN="$VAULT_TOKEN_WITNESS" vault token lookup -format=json \
    | jq -r '.data.display_name // .data.entity_id // .data.id'
}

latest_active_key_id() {
  local active
  active="$(
    VAULT_TOKEN="$VAULT_TOKEN_OPERATOR" vault kv get -field=keyId secret/license/signing/active 2>/dev/null || true
  )"
  if [ -n "$active" ]; then
    printf '%s' "$active"
    return 0
  fi

  VAULT_TOKEN="$VAULT_TOKEN_OPERATOR" vault list -format=json transit/keys 2>/dev/null \
    | jq -r '[.[] | select(test("^license-signing-v2-[0-9]{4}-[0-9]{2}$"))] | sort | last // empty'
}

public_key_b64() {
  local key_id="$1"
  VAULT_TOKEN="$VAULT_TOKEN_OPERATOR" vault read -format=json "transit/keys/${key_id}" \
    | jq -r '[.. | objects | .public_key? // empty][0]'
}

key_fingerprint() {
  local key_id="$1" pubkey
  pubkey="$(public_key_b64 "$key_id")"
  [ -n "$pubkey" ] && [ "$pubkey" != "null" ] || die "无法读取公钥: ${key_id}"
  printf '%s' "$pubkey" | b64decode | sha256_hex
}

# -----------------------------------------------------------------------------
# Payload 构造与校验
# -----------------------------------------------------------------------------

feature_allowed() {
  local feature="$1" allowed
  for allowed in $ALLOWED_FEATURES; do
    [ "$feature" = "$allowed" ] && return 0
  done
  return 1
}

validate_issue_args() {
  [ -n "$CUSTOMER" ] || die "--customer 不能为空"
  case "$TIER" in
    enterprise|enterprise-plus) ;;
    *) die "--tier 必须是 enterprise 或 enterprise-plus" ;;
  esac

  [[ "$SEATS" =~ ^-?[0-9]+$ ]] || die "--seats 必须是整数或 -1"
  if [ "$SEATS" -eq 0 ] || [ "$SEATS" -lt -1 ]; then
    die "--seats 不能为 0，也不能是除 -1 外的负数"
  fi

  case "$TERM" in
    annual|five-year|perpetual) ;;
    *) die "--term 必须是 annual、five-year 或 perpetual" ;;
  esac

  case "$SKU" in
    standard|air-gapped) ;;
    *) die "--sku 必须是 standard 或 air-gapped" ;;
  esac

  if [ "$TERM" = "perpetual" ] && [ "$SKU" != "air-gapped" ]; then
    die "perpetual license 只能用于 --sku air-gapped"
  fi

  if [ -n "$FEATURES" ]; then
    local raw feature
    IFS=',' read -r -a raw <<< "$FEATURES"
    for feature in "${raw[@]}"; do
      feature="$(printf '%s' "$feature" | xargs)"
      [ -n "$feature" ] || die "--features 包含空值"
      feature_allowed "$feature" || die "未知 feature: ${feature}"
    done
  fi
}

features_json() {
  if [ -z "$FEATURES" ]; then
    printf '[]'
    return 0
  fi

  local json="[]" raw feature
  IFS=',' read -r -a raw <<< "$FEATURES"
  for feature in "${raw[@]}"; do
    feature="$(printf '%s' "$feature" | xargs)"
    json="$(printf '%s' "$json" | jq --arg feature "$feature" '. + [$feature]')"
  done
  printf '%s' "$json" | jq -c 'sort'
}

# 关键不变量：build_payload 内 jq -cnS 输出 canonical（按 key 字母排序、紧凑无空格）JSON。
# 签名校验侧（aster-cloud src/lib/license.ts）通过对 *接收到* 的 payload bytes 计算签名，
# 不重新序列化，所以只要签发与传输过程中不改 bytes，verifier 不依赖 sort 一致性。
# 这里仍使用 -cnS 是为了让 audit trail 内的 payload 可被外部工具稳定对比。
build_payload() {
  local license_id="$1" key_id="$2" issued_at="$3" expires_at="$4" not_before="$5" feature_array="$6"

  if [ "$SKU" = "standard" ]; then
    jq -cnS \
      --argjson schemaVersion 2 \
      --arg licenseId "$license_id" \
      --arg keyId "$key_id" \
      --arg customer "$CUSTOMER" \
      --arg issuedAt "$issued_at" \
      --arg expiresAt "$expires_at" \
      --arg notBefore "$not_before" \
      --argjson seatLimit "$SEATS" \
      --arg tier "$TIER" \
      --argjson features "$feature_array" \
      --arg sku "$SKU" \
      --arg licenseTerm "$TERM" \
      --arg revocationCheckUrl "$REVOCATION_CHECK_URL" \
      '{
        schemaVersion: $schemaVersion,
        licenseId: $licenseId,
        keyId: $keyId,
        customer: $customer,
        issuedAt: $issuedAt,
        expiresAt: $expiresAt,
        notBefore: $notBefore,
        seatLimit: $seatLimit,
        tier: $tier,
        features: $features,
        sku: $sku,
        licenseTerm: $licenseTerm,
        deploymentBinding: null,
        revocationCheckUrl: $revocationCheckUrl
      }'
  else
    jq -cnS \
      --argjson schemaVersion 2 \
      --arg licenseId "$license_id" \
      --arg keyId "$key_id" \
      --arg customer "$CUSTOMER" \
      --arg issuedAt "$issued_at" \
      --arg expiresAt "$expires_at" \
      --arg notBefore "$not_before" \
      --argjson seatLimit "$SEATS" \
      --arg tier "$TIER" \
      --argjson features "$feature_array" \
      --arg sku "$SKU" \
      --arg licenseTerm "$TERM" \
      '{
        schemaVersion: $schemaVersion,
        licenseId: $licenseId,
        keyId: $keyId,
        customer: $customer,
        issuedAt: $issuedAt,
        expiresAt: $expiresAt,
        notBefore: $notBefore,
        seatLimit: $seatLimit,
        tier: $tier,
        features: $features,
        sku: $sku,
        licenseTerm: $licenseTerm,
        deploymentBinding: null
      }'
  fi
}

print_payload_preview() {
  local payload="$1"
  echo ""
  echo "=== Payload Preview ==="
  printf '%s\n' "$payload" | jq .
  echo ""
}

# -----------------------------------------------------------------------------
# Approval 状态机
# -----------------------------------------------------------------------------

write_pending_approval() {
  local token="$1" payload="$2" operator="$3" operator_session="$4" key_fingerprint="$5"

  VAULT_TOKEN="$VAULT_TOKEN_OPERATOR" vault kv put "${APPROVAL_PATH_PREFIX}/${token}" \
    payload="$payload" \
    operator="$operator" \
    operatorSession="$operator_session" \
    keyFingerprint="$key_fingerprint" \
    createdAt="$(utc_now)" >/dev/null
}

read_pending_approval() {
  local token="$1"
  VAULT_TOKEN="$VAULT_TOKEN_OPERATOR" vault kv get -format=json "${APPROVAL_PATH_PREFIX}/${token}"
}

delete_pending_approval() {
  local token="$1"
  VAULT_TOKEN="$VAULT_TOKEN_OPERATOR" vault kv delete "${APPROVAL_PATH_PREFIX}/${token}" >/dev/null
}

# -----------------------------------------------------------------------------
# 签名
# -----------------------------------------------------------------------------

sign_payload() {
  local key_id="$1" payload="$2" input_b64 signature vault_sig raw_sig_b64

  input_b64="$(printf '%s' "$payload" | b64)"
  # Ed25519 在 Vault Transit 必须用 raw 路径，不能加 hash_algorithm。
  # `transit/sign/<key>/sha2-512` 触发 Enterprise Ed25519ph 路径（需 prehashed=true），
  # 与 v2 规范的 "raw Ed25519 over payload bytes" 不兼容（codex 审查 Critical-1）。
  #
  # 关键约束：只有 Witness token 有 transit/sign/license-signing-* update 权限。
  # 这是 OSS 部署在缺少 control_group 时的 2 人控制基线 —— 但仍然有 raw transit
  # 旁路风险（见 docs 中的 OSS 限制 + 推荐 signing service）。
  vault_sig="$(
    VAULT_TOKEN="$VAULT_TOKEN_WITNESS" vault write -format=json "transit/sign/${key_id}" input="$input_b64"
  )"
  signature="$(printf '%s' "$vault_sig" | jq -r '.data.signature')"
  [ -n "$signature" ] && [ "$signature" != "null" ] || die "Vault signing 未返回 signature"

  # Vault transit 返回格式: vault:v<n>:<base64-signature>，提取原始 base64 后转 base64url
  raw_sig_b64="${signature##*:}"
  printf '%s' "$raw_sig_b64" | b64decode | b64url
}

write_issuance_audit() {
  # license_key_sha256 而非 license_key 全文（codex Major-5）：license key 是 bearer token，
  # 任何能读 audit 路径的人都能用它授权所有 features。audit 只需 sha256 用于事后比对。
  local license_id="$1" payload="$2" license_key_sha256="$3" operator="$4" witness="$5" key_fingerprint="$6"
  local timestamp customer tier seats sku expires_at

  timestamp="$(utc_now)"
  customer="$(printf '%s' "$payload" | jq -r '.customer')"
  tier="$(printf '%s' "$payload" | jq -r '.tier')"
  seats="$(printf '%s' "$payload" | jq -r '.seatLimit')"
  sku="$(printf '%s' "$payload" | jq -r '.sku')"
  expires_at="$(printf '%s' "$payload" | jq -r '.expiresAt')"

  VAULT_TOKEN="$VAULT_TOKEN_OPERATOR" vault kv put "${ISSUANCE_PATH_PREFIX}/${license_id}" \
    timestamp="$timestamp" \
    customer="$customer" \
    tier="$tier" \
    seats="$seats" \
    sku="$sku" \
    expiresAt="$expires_at" \
    operator="$operator" \
    witness="$witness" \
    licenseId="$license_id" \
    keyFingerprint="$key_fingerprint" \
    payload="$payload" \
    licenseKeySha256="$license_key_sha256" >/dev/null
}

send_slack_audit() {
  local payload="$1" operator="$2" witness="$3" license_id="$4" key_fingerprint="$5"
  local webhook="${LICENSES_SLACK_WEBHOOK:-}"

  [ -n "$webhook" ] || return 0

  local body
  body="$(
    jq -cn \
      --arg timestamp "$(utc_now)" \
      --arg customer "$(printf '%s' "$payload" | jq -r '.customer')" \
      --arg tier "$(printf '%s' "$payload" | jq -r '.tier')" \
      --arg seats "$(printf '%s' "$payload" | jq -r '.seatLimit | tostring')" \
      --arg sku "$(printf '%s' "$payload" | jq -r '.sku')" \
      --arg expiresAt "$(printf '%s' "$payload" | jq -r '.expiresAt')" \
      --arg operator "$operator" \
      --arg witness "$witness" \
      --arg licenseId "$license_id" \
      --arg keyFingerprint "$key_fingerprint" \
      '{
        text: "license issued",
        channel: "#licenses-ops",
        blocks: [
          {
            type: "section",
            text: {
              type: "mrkdwn",
              text: ("*License issued* `" + $licenseId + "`\ncustomer=" + $customer + " tier=" + $tier + " seats=" + $seats + " sku=" + $sku + " expiresAt=" + $expiresAt + "\noperator=" + $operator + " witness=" + $witness + "\nfingerprint=" + $keyFingerprint)
            }
          }
        ],
        metadata: {
          event_type: "license_issuance",
          event_payload: {
            timestamp: $timestamp,
            customer: $customer,
            tier: $tier,
            seats: $seats,
            sku: $sku,
            expiresAt: $expiresAt,
            operator: $operator,
            witness: $witness,
            licenseId: $licenseId,
            keyFingerprint: $keyFingerprint
          }
        }
      }'
  )"

  curl -fsS -X POST -H "Content-Type: application/json" --data "$body" "$webhook" >/dev/null
}

# -----------------------------------------------------------------------------
# 主流程
# -----------------------------------------------------------------------------

if [ -n "$APPROVE_TOKEN" ]; then
  [ "$DRY_RUN" -eq 0 ] || die "--approve 不能与 --dry-run 同时使用"
  [ -n "${VAULT_TOKEN_WITNESS:-}" ] || die "--approve 需要设置 VAULT_TOKEN_WITNESS"

  # codex Major-4: --approve 参数白名单校验，防止 Vault path 拼接注入
  [[ "$APPROVE_TOKEN" =~ $APPROVAL_TOKEN_RE ]] || die "--approve token 格式无效（必须 64 hex）"

  pending="$(read_pending_approval "$APPROVE_TOKEN")"
  payload="$(printf '%s' "$pending" | jq -r '.data.data.payload // .data.payload')"
  operator="$(printf '%s' "$pending" | jq -r '.data.data.operator // .data.operator')"
  operator_session="$(printf '%s' "$pending" | jq -r '.data.data.operatorSession // .data.operatorSession')"
  stored_fingerprint="$(printf '%s' "$pending" | jq -r '.data.data.keyFingerprint // .data.keyFingerprint')"
  [ -n "$payload" ] && [ "$payload" != "null" ] || die "approval token 不存在或已失效"

  # codex Major-3: 防 approval 伪造 —— 重新计算 sha256(payload+session) 必须等于 token
  recomputed_token="$(
    {
      printf '%s' "$payload"
      printf '%s' "$operator_session"
    } | sha256_hex
  )"
  [ "$recomputed_token" = "$APPROVE_TOKEN" ] || die "approval token 与 payload+session hash 不一致（已被篡改或伪造）"

  print_payload_preview "$payload"

  witness="$(witness_identity)"
  [ -n "$witness" ] && [ "$witness" != "null" ] || die "Witness token lookup 失败"
  [ "$witness" != "$operator" ] || die "Witness 不能与 Operator 是同一 Vault identity"

  key_id="$(printf '%s' "$payload" | jq -r '.keyId')"
  license_id="$(printf '%s' "$payload" | jq -r '.licenseId')"

  # codex Major-4: 再次校验 keyId 白名单（防 payload 被中途篡改 keyId）
  [[ "$key_id" =~ $KEY_ID_RE ]] || die "payload keyId 不符合命名规范: ${key_id}"

  current_fingerprint="$(key_fingerprint "$key_id")"
  [ "$current_fingerprint" = "$stored_fingerprint" ] || die "key fingerprint 与 approval 记录不一致"

  payload_b64url="$(printf '%s' "$payload" | b64url)"
  signature_b64url="$(sign_payload "$key_id" "$payload")"
  license_key="aster-ent-v2-${key_id}-${payload_b64url}.${signature_b64url}"

  # 不进入 audit log 全文（codex Major-5）—— 仅存 sha256 + payload，
  # 完整 license key 由 sales 通过加密渠道交付给客户
  license_key_sha256="$(printf '%s' "$license_key" | sha256_hex)"
  write_issuance_audit "$license_id" "$payload" "$license_key_sha256" "$operator" "$witness" "$current_fingerprint"
  send_slack_audit "$payload" "$operator" "$witness" "$license_id" "$current_fingerprint"
  delete_pending_approval "$APPROVE_TOKEN"

  echo ""
  echo "=== License Key（只显示一次，请用加密渠道转交客户）==="
  printf '%s\n' "$license_key"
  echo ""
  echo "audit 仅保留 sha256: ${license_key_sha256}"
  log_success "签发完成: ${license_id}"
  exit 0
fi

validate_issue_args

if [ -z "$KEY_ID" ]; then
  KEY_ID="$(latest_active_key_id)"
  [ -n "$KEY_ID" ] || die "无法从 Vault 找到 active license signing key；请传 --key-id"
fi

# codex Major-4: --key-id 必须严格匹配 ceremony 命名约定，防 Vault path 拼接攻击
[[ "$KEY_ID" =~ $KEY_ID_RE ]] || die "--key-id 不符合命名规范（期望: license-signing-v2-YYYY-MM）: ${KEY_ID}"

issued_at="$(utc_now)"
expires_at="$(utc_add "$TERM")"
not_before="$issued_at"
license_id="$(generate_ulid)"
feature_array="$(features_json)"
payload="$(build_payload "$license_id" "$KEY_ID" "$issued_at" "$expires_at" "$not_before" "$feature_array")"
fingerprint="$(key_fingerprint "$KEY_ID")"
operator="$(operator_identity)"

print_payload_preview "$payload"
echo "Key ID: ${KEY_ID}"
echo "Key fingerprint: ${fingerprint}"
echo "Operator: ${operator}"

if [ "$DRY_RUN" -eq 1 ]; then
  log_info "dry-run: 未写入 Vault approval，未调用 signing endpoint"
  exit 0
fi

operator_session="$(openssl rand -hex 16)"
approval_token="$(
  {
    printf '%s' "$payload"
    printf '%s' "$operator_session"
  } | sha256_hex
)"

write_pending_approval "$approval_token" "$payload" "$operator" "$operator_session" "$fingerprint"

echo ""
echo "=== Approval Token ==="
printf '%s\n' "$approval_token"
echo ""
echo "Witness 复核 payload 后执行:"
echo "  VAULT_TOKEN_OPERATOR=... VAULT_TOKEN_WITNESS=... scripts/license-issue.sh --approve ${approval_token}"
echo ""
log_success "approval 已写入 Vault: ${APPROVAL_PATH_PREFIX}/${approval_token}"
