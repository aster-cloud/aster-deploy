# License Key Ceremony Runbook

> **目标**：生成两组生产 Ed25519 keypair：`license-signing` 与 `revocation-signing`。两组密钥必须分离，降低单一用途泄露后的 blast radius。
> **执行人**：Operator + Witness 两人在场。Operator 执行命令，Witness 逐项核对并签字确认。
> **预估时长**：2-3 小时（含录屏、纸质备份、ACL 验证与 smoke test）。
> **频率**：每 12 个月轮换一次 signing key；发生密钥疑似泄露、Vault 审计异常、人员离职或合规要求时立即执行。

---

## 凭证清单与 Vault 映射

| # | 凭证 / 密钥 | 用途 | Vault 路径 | 私钥导出策略 | 消费方 |
|---|-------------|------|------------|--------------|--------|
| 1 | License Signing Key | 生产 license v2 签发 | `transit/keys/license-signing-v2-2026-01` | `exportable=false`, `allow_plaintext_backup=false` | `scripts/license-issue.sh`、Vault Transit sign |
| 2 | Revocation Signing Key | revocation manifest 签名 | `transit/keys/revocation-signing-v2-2026-01` | `exportable=false`, `allow_plaintext_backup=false` | revocation publisher |
| 3 | License Public Key | on-prem trust bundle 验签 | `transit/keys/license-signing-v2-2026-01` read output | 仅公钥 | aster-cloud `src/lib/license-trust-bundle.ts` |
| 4 | Revocation Public Key | revoked.json 验签 | `transit/keys/revocation-signing-v2-2026-01` read output | 仅公钥 | on-prem revocation verifier |
| 5 | Public Key Fingerprints | 人工核验与发布审计 | `secret/license/metadata/v2-2026-01` | SHA-256(pubkey bytes) | release checklist、纸质备份 |
| 6 | Backup License Key | 主 Vault 失效时恢复签发 | 独立 air-gapped Vault Transit | 私钥不离开 backup Vault | break-glass ceremony |
| 7 | Backup Revocation Key | 主 revocation key 失效时恢复 | 独立 air-gapped Vault Transit | 私钥不离开 backup Vault | break-glass ceremony |

---

## 通用步骤模板

每次 key ceremony 必须按以下顺序执行：

```
1. Operator 和 Witness 同时到场，确认录屏、纸质记录、Vault root token envelope 完整
2. 使用干净的气隙环境准备 ceremony 终端，不挂载个人磁盘
3. 在 Vault Transit 里生成不可导出的 Ed25519 密钥
4. 只读取 public key，计算 SHA-256 fingerprint
5. 写入 Vault metadata，并由两人签署纸质备份
6. 配置最小权限 ACL 和 2-person control group / quorum policy
7. 执行 signing + verify smoke test
8. 更新 on-prem trust bundle 发布流程
9. 归档录屏、命令 transcript、Vault audit log digest、纸质备份编号
10. 封存 root token envelope 和 backup Vault Shamir keys
```

**回滚原则**：新 key 未进入 trust bundle 前，可以废弃本次 ceremony 并重新生成；新 public key 一旦发布到 on-prem build，必须按 rotation policy 进入 overlap，不允许无审计删除。

---

## 前置条件

### 人员与环境
- Operator 与 Witness 两人全程在场，任何一方离席即暂停。
- 使用 air-gapped laptop；网络只在连接目标 Vault 的受控窗口打开。
- 使用 fresh Tails USB 或等效一次性干净系统；启动后校验系统镜像 hash。
- Vault root token 保存在实体信封内；开封、使用、重新封存均要录屏并写入纸质记录。
- 全程 screen recording，用于 SOC2 / 合规审计；录屏文件 ceremony 后写入受控归档。
- 纸质记录包含时间、地点、两人姓名、Vault 地址、key id、public key fingerprint、录屏文件 hash、签名。

### 工具检查
```bash
set -euo pipefail

command -v vault
command -v jq
command -v openssl

export VAULT_ADDR=https://vault.aster-lang.cloud
vault status
vault audit list
```

### 安全约束
- 不运行 `vault read transit/export/...`，也不启用 export。
- 不把 private key、seed、backup 明文写入磁盘、剪贴板、聊天工具、ticket、日志。
- Terminal scrollback、shell history、录屏文件视为敏感材料处理。
- `license-signing` 与 `revocation-signing` 必须是两把独立 key，不允许复用。

### Zeroization 与 audit 保留
Ceremony 开始前在终端执行：

```bash
export HISTFILE=/dev/null
export LESSHISTFILE=/dev/null
set +o history
```

Ceremony 结束后：

```bash
unset VAULT_TOKEN VAULT_TOKEN_OPERATOR VAULT_TOKEN_WITNESS
unset LICENSE_PUBKEY_B64 REVOCATION_PUBKEY_B64
unset LICENSE_FINGERPRINT REVOCATION_FINGERPRINT
history -c                                # 清除内存 history
shred -u ~/.lesshst ~/.bash_history 2>/dev/null || true
```

录屏与 audit 保留：
- 录屏 SHA-256 + 文件大小写入 Vault metadata；原始录屏保存到受控对象存储
  （生命周期 = 7 年；季度审计）
- Vault audit log 启用 file backend，保留 ≥ 90 天（合规需要可延长到 7 年）
- 纸质备份扫描件归档到法务保险柜；编号记录在 Vault metadata
- ceremony transcript（命令 + 输出）SHA-256 写入 Vault metadata，原文件单独归档

---

## 1. 启用 Vault Transit Engine

### 执行步骤
```bash
vault login

# 如果 transit 已存在，该命令会返回 path already in use；记录现状后继续。
vault secrets enable -path=transit transit

vault secrets list | grep '^transit/'
```

### 验证
```bash
vault secrets list -format=json | jq -e 'has("transit/")'
```

期望：返回 `true`，Vault audit log 里出现 `sys/mounts/transit` 或已存在记录。

---

## 2. 生成 License Signing Key

### 执行步骤
```bash
vault write -f transit/keys/license-signing-v2-2026-01 \
  type=ed25519 \
  exportable=false \
  allow_plaintext_backup=false
```

### 验证
```bash
vault read -format=json transit/keys/license-signing-v2-2026-01 \
  | jq '{name: .data.name, type: .data.type, exportable: .data.exportable, allow_plaintext_backup: .data.allow_plaintext_backup}'
```

期望：
- `type` 为 `ed25519`
- `exportable` 为 `false`
- `allow_plaintext_backup` 为 `false`

---

## 3. 生成 Revocation Signing Key

### 执行步骤
```bash
vault write -f transit/keys/revocation-signing-v2-2026-01 \
  type=ed25519 \
  exportable=false \
  allow_plaintext_backup=false
```

### 验证
```bash
vault read -format=json transit/keys/revocation-signing-v2-2026-01 \
  | jq '{name: .data.name, type: .data.type, exportable: .data.exportable, allow_plaintext_backup: .data.allow_plaintext_backup}'
```

期望与 license signing key 相同，但 key name 必须是 `revocation-signing-v2-2026-01`。

---

## 4. 提取 Public Key 并计算 Fingerprint

### 执行步骤
```bash
LICENSE_PUBKEY_B64="$(
  vault read -format=json transit/keys/license-signing-v2-2026-01 \
    | jq -r '[.. | objects | .public_key? // empty][0]'
)"

REVOCATION_PUBKEY_B64="$(
  vault read -format=json transit/keys/revocation-signing-v2-2026-01 \
    | jq -r '[.. | objects | .public_key? // empty][0]'
)"

LICENSE_FINGERPRINT="$(
  printf '%s' "$LICENSE_PUBKEY_B64" \
    | openssl base64 -d -A \
    | openssl dgst -sha256 -r \
    | awk '{print $1}'
)"

REVOCATION_FINGERPRINT="$(
  printf '%s' "$REVOCATION_PUBKEY_B64" \
    | openssl base64 -d -A \
    | openssl dgst -sha256 -r \
    | awk '{print $1}'
)"

printf 'license-signing-v2-2026-01 %s\n' "$LICENSE_FINGERPRINT"
printf 'revocation-signing-v2-2026-01 %s\n' "$REVOCATION_FINGERPRINT"
```

### 写入 metadata
```bash
vault kv put secret/license/metadata/v2-2026-01 \
  licenseKeyId="license-signing-v2-2026-01" \
  licensePublicKeyB64="$LICENSE_PUBKEY_B64" \
  licenseFingerprintSha256="$LICENSE_FINGERPRINT" \
  revocationKeyId="revocation-signing-v2-2026-01" \
  revocationPublicKeyB64="$REVOCATION_PUBKEY_B64" \
  revocationFingerprintSha256="$REVOCATION_FINGERPRINT" \
  ceremonyDate="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  operator="$(vault token lookup -format=json | jq -r '.data.display_name')" \
  witness="<recorded-on-paper>"
```

### 纸质备份
纸质记录只写 public key fingerprint、公钥 base64、key id、Vault path、录屏文件 SHA-256。Operator 与 Witness 双签。纸质备份编号写入 Vault metadata。

---

## 5. 生成独立 Backup Keypair

### 执行步骤
在独立物理 Vault instance 上重复第 1-4 步，使用独立 root token、独立 unseal keys、独立审计归档。

```bash
export VAULT_ADDR=https://backup-vault.airgap.aster-lang.internal
vault status

vault secrets enable -path=transit transit

vault write -f transit/keys/license-signing-backup-v2-2026-01 \
  type=ed25519 \
  exportable=false \
  allow_plaintext_backup=false

vault write -f transit/keys/revocation-signing-backup-v2-2026-01 \
  type=ed25519 \
  exportable=false \
  allow_plaintext_backup=false
```

### Shamir key 封存
- Backup Vault master Shamir keys 分给不同保管人，不与 root token 同处一地。
- 每份 Shamir key 单独装入防篡改信封，放入防火保险柜。
- 纸质恢复流程记录 quorum 人数、保管人名单、保险柜位置、访问审批人。
- 每 6 个月演练一次 recovery drill，只验证 unseal 与 signing smoke test，不导出任何私钥。

---

## 6. Smoke Test

> **重要**：Vault Transit 的 `transit/sign/<key>/sha2-512` 路径只在 Vault Enterprise
> 的 Ed25519ph（prehashed）模式下有效。v2 license 格式规定"signature 为 raw Ed25519
> over payload bytes"，所以必须使用 `transit/sign/<key>`（无 hash_algorithm 后缀）。

### 签名
```bash
DUMMY_PAYLOAD='{"schemaVersion":2,"licenseId":"ceremony-smoke-test","customer":"Aster Internal"}'
DUMMY_INPUT_B64="$(printf '%s' "$DUMMY_PAYLOAD" | openssl base64 -A)"

SIGN_RESPONSE="$(
  vault write -format=json transit/sign/license-signing-v2-2026-01 \
    input="$DUMMY_INPUT_B64"
)"

SIGNATURE="$(printf '%s' "$SIGN_RESPONSE" | jq -r '.data.signature')"
test -n "$SIGNATURE"
```

### 验证
```bash
vault write -format=json transit/verify/license-signing-v2-2026-01 \
  input="$DUMMY_INPUT_B64" \
  signature="$SIGNATURE" \
  | jq -e '.data.valid == true'
```

期望：返回 `true`，Vault audit log 里出现 `transit/sign/license-signing-v2-2026-01` 与 `transit/verify/license-signing-v2-2026-01`。

---

## 7. ACL Policy 与 2 人审批

### Policy 目标
- 只有 `aster-license-issuer` role 可以调用 `transit/sign/license-signing-*`。
- 只有 `aster-revocation-publisher` role 可以调用 `transit/sign/revocation-signing-*`。
- 两个 role 都只能读取对应 key 的 metadata / public key。
- 禁止任何非 root principal 访问 `transit/export/*`、`transit/backup/*`。
- 生产 signing endpoint 必须启用 2 人审批：Operator token 发起请求，Witness token 审批后才允许完成。

> **Vault Enterprise vs OSS**：control_group 是 Vault Enterprise 特性。OSS 部署必须通过 `services/license-signing-api/` 实现 2 人审批；该 service 是唯一拥有 `transit/sign/license-signing-*` 与 `transit/sign/revocation-signing-*` 权限的 principal。Operator/Witness 人类 token 不允许直接调用 Vault Transit sign。

### License issuer policy（Enterprise control_group 版）
```hcl
path "transit/sign/license-signing-*" {
  capabilities = ["update"]
  control_group = {
    factor "witness" {
      identity {
        group_names = ["aster-license-witnesses"]
        approvals = 1
      }
    }
  }
}

path "transit/keys/license-signing-*" {
  capabilities = ["read"]
}

path "secret/data/audit/license-issuance/*" {
  capabilities = ["create", "update", "read"]
}

path "secret/data/audit/license-approvals/*" {
  capabilities = ["create", "update", "read", "delete"]
}
```

### Revocation publisher policy
```hcl
path "transit/sign/revocation-signing-*" {
  capabilities = ["update"]
  control_group = {
    factor "witness" {
      identity {
        group_names = ["aster-revocation-witnesses"]
        approvals = 1
      }
    }
  }
}

path "transit/keys/revocation-signing-*" {
  capabilities = ["read"]
}
```

### OSS 替代方案（无 control_group）

Vault OSS 部署：
1. `services/license-signing-api/` 使用 service Vault token，这是 **唯一** 可调用 `transit/sign/*` 的 token
2. Operator 与 Witness 使用短 TTL OIDC/JWT 登录 signing API，**不持有** Vault Transit sign 权限
3. Operator 调用 `POST /v1/approve` 创建 10 分钟 TTL approval
4. Witness 调用 `POST /v1/sign`，service 校验 Operator JWT + Witness JWT + approval token + purpose/keyId 绑定 + 防 replay 后才调用 Vault Transit
5. signing API 审计写入 append-only JSONL，并可同步 Slack 摘要

**禁止配置**：不要给 Witness 或 Operator 人类 Vault token 直接授予 `transit/sign/license-signing-*` 或 `transit/sign/revocation-signing-*`，否则可绕过 2 人审批。

### Cross-key deny 验证
```bash
VAULT_TOKEN="$ASTER_LICENSE_ISSUER_TOKEN" \
  vault write transit/sign/revocation-signing-v2-2026-01 input="$DUMMY_INPUT_B64"
# 期望: permission denied

VAULT_TOKEN="$ASTER_REVOCATION_PUBLISHER_TOKEN" \
  vault write transit/sign/license-signing-v2-2026-01 input="$DUMMY_INPUT_B64"
# 期望: permission denied
```

---

## 8. Verification Checklist

- [ ] Operator 与 Witness 两人全程在场，纸质记录双签。
- [ ] Ceremony 使用 fresh Tails USB 或等效干净系统，录屏已开启并归档。
- [ ] Vault root token envelope 开封、使用、封存均有录屏和纸质记录。
- [ ] `license-signing-v2-2026-01` 与 `revocation-signing-v2-2026-01` 是两把独立 Ed25519 key。
- [ ] 两把 key 均为 `exportable=false` 且 `allow_plaintext_backup=false`。
- [ ] 没有 private key、seed、明文 backup 出现在磁盘、shell history、剪贴板、ticket、聊天工具或日志。
- [ ] Vault audit log 显示 key generation、public key read、sign、verify、metadata write。
- [ ] Public key fingerprint 是 SHA-256(pubkey bytes)，已写入 Vault metadata 与纸质备份。
- [ ] ACL 阻止 license issuer 签 revocation key，也阻止 revocation publisher 签 license key。
- [ ] Backup keypair recovery drill 已完成，Shamir keys 已分离封存到防火保险柜。

---

## 9. Rotation Policy

### 时间线
- Active period：每把 production signing key 最多 active 12 个月。
- Overlap period：新 key 发布后，新旧 key 至少重叠 6 个月。
- Verify-only：旧 key 在 overlap 结束后标记为 verify-only，停止签发，但保留在 trust bundle 用于历史 license 验签。
- Retirement：所有由旧 key 签发且仍可能合法存在的 license 过期后，才能从 trust bundle 删除旧 public key。

### Trust bundle bump
1. 从 Vault metadata 读取新 public key 与 fingerprint。
2. 在 aster-cloud 更新 `src/lib/license-trust-bundle.ts`，加入新 `keyId`、public key、fingerprint、`activatedAt`。
3. 保留旧 key，根据 overlap 期决定标记为 `active`（可签新 license）或 `verify-only`（只验签旧 license）。
4. 发布 on-prem build 前，用新旧 license 各做一次验签回归。
5. 发布说明中记录 trust bundle version、key id、fingerprint、ceremony 记录编号。

### 轮换命名
后续 key id 使用同一格式：

```
license-signing-v2-YYYY-MM
revocation-signing-v2-YYYY-MM
```

月份使用 active ceremony 月份，不使用计划月份。

---

## 10. Compromise / Break-glass

> 触发：密钥泄露、Vault audit 异常、人员被胁迫报警、审计发现未授权签名。
> 目标：在 4 小时内停止泄露 key 签发新 license，48 小时内通知所有 active 客户。

### 即时遏制（前 30 分钟）
```bash
# 1. 撤销被怀疑泄露的 signing key 的 ACL（最快）
vault delete sys/policies/acl/aster-license-issuer-v2-2026-01

# 2. 在 Vault 中标记 key 为 deletion_allowed=true 后 delete
vault write transit/keys/license-signing-v2-2026-01/config deletion_allowed=true
vault delete transit/keys/license-signing-v2-2026-01

# 3. 告警 oncall + 创建 incident ticket（P0）
```

### 客户端响应（4 小时内）
- 立即在 aster-cloud `src/lib/license-trust-bundle.ts` 把被泄露 key 状态改为
  `'retired'` + 设置 `retiredAt` = 泄露发现时间
- 触发 emergency release pipeline（绕过常规 deploy gate）
- 验证 on-prem 客户拉取新 trust bundle 后，由该 key 签发的所有 license 立即变为
  `trustStatus='signature-untrusted-key'`

### Revocation 批量发布（24 小时内）
- 用 revocation-signing key（独立未泄露）签发包含被泄露 key 所有 license id 的
  revocation manifest
- 提升 manifest version + 写入 `secret/audit/revocation-emergencies/`
- 监控 24h 后 ≥ 95% 客户已拉取到新 manifest

### 客户通知（48 小时内）
- 法务起草通知信，列出被影响 license id（不列客户身份）
- 销售 / CSM 一对一联系所有受影响客户解释续签流程
- 内部 retro：4 周内复盘根因 + ACL / 流程改进

### 证据保全
- 立即对涉事 Vault 实例做 snapshot（DB + audit log + config）
- 受影响 ceremony 录屏与 transcript 冻结，不允许覆盖
- 调用法务和外部 IR 团队（如 incident 涉及刑事）

### 启用 Backup Keypair
若主 Vault 整体失陷：
1. 两名独立保管人持 Shamir keys 到 backup Vault 物理位置
2. Unseal backup Vault（最少 quorum 人数）
3. 用 backup key 走第 7 节 ACL 流程发布新 trust bundle
4. 主 Vault 取证完成后才允许重建
