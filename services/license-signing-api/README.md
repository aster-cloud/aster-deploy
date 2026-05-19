# License Signing API

> **目标**：在 Vault OSS 环境下强制 2 人审批，避免 Witness 或 Operator 直接调用 Vault Transit 签发 license。
> **原则**：只有本 service 的 Vault token 拥有 `transit/sign/*` 权限；人类身份只通过短 TTL JWT 调用本 service。

---

## 架构

```
Operator JWT ── POST /v1/approve ─┐
                                  │ pending approval (10 min TTL)
Witness JWT  ── POST /v1/sign  ───┤
                                  ▼
                         license-signing-api
                                  │ service Vault token
                                  ▼
                      Vault Transit raw Ed25519 sign
                                  │
                                  ▼
                         base64url(signature)
```

`scripts/license-issue.sh` 后续应改为调用本 service，不再直接调用 Vault Transit。

---

## 本地启动

```bash
cd services/license-signing-api
cp .env.example .env
pnpm install
pnpm dev
```

也可以使用本目录的 compose 文件启动本地 Vault dev server：

```bash
cd services/license-signing-api
docker compose up --build
```

项目根目录 Taskfile：

```bash
task signing-api:dev
task signing-api:test
task signing-api:build
task signing-api:image
```

---

## 测试

```bash
# 单元 + zod / canonical-json 测试（默认 mock vault，无依赖）
pnpm test

# 集成测试：起一个真 Vault Transit 容器，跑 approve → sign → verify ed25519 全链路
# 自动探测 docker 或 podman；如果都没有 → describe 整体 skip 并打印原因。
# 显式 skip：SKIP_VAULT_INTEGRATION=1 pnpm test:integration
# 强制指定 runtime：VAULT_CONTAINER_CMD=podman pnpm test:integration
pnpm test:integration
```

集成测试当前覆盖 12 个场景：happy-path Ed25519 round-trip、replay、过期 JWT、
crossed keyId、缺/坏 deploymentBinding、operator==witness、未签发的
approvalToken、payload tamper、approval TTL 过期、revocation purpose 不要求
binding、approve 限速、Vault 不可达 502+audit。

---

## Vault Policy

本 service 的 Vault token 必须只允许 Transit sign，不允许 export、backup、key management。

```hcl
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

path "transit/export/*" {
  capabilities = ["deny"]
}

path "transit/backup/*" {
  capabilities = ["deny"]
}
```

Operator、Witness、Admin 的人类 Vault token 不应拥有 `transit/sign/*` 权限。

---

## IdP / JWKS

任意 OIDC IdP 均可使用，例如 Authentik、Keycloak、Okta。

JWT 必须满足：
- `iss` 等于 `JWT_ISSUER`
- `aud` 等于 `JWT_AUDIENCE`
- `role` 为 `license-operator`、`license-witness` 或 `license-admin`
- `exp - iat <= 300` 秒
- `nbf` 由 `jose` 自动校验
- Operator 与 Witness 的 `sub` 必须不同

JWKS 使用：

```ts
createRemoteJWKSet(new URL(JWT_JWKS_URL))
```

这样 IdP 轮换 signing key 时，service 不需要重启。

---

## API

### POST /v1/approve

Headers:

```
X-Operator-JWT: <short-lived jwt>
Content-Type: application/json
```

Body:

```json
{
  "purpose": "license",
  "keyId": "license-signing-v2-2026-01",
  "payload": {
    "schemaVersion": 2,
    "licenseId": "01J...",
    "customer": "Acme Corp"
  }
}
```

返回：

```json
{ "approvalToken": "<sha256 hex>", "expiresAt": "2026-05-18T00:00:00Z" }
```

### POST /v1/sign

Headers:

```
X-Operator-JWT: <same operator identity>
X-Witness-JWT: <short-lived witness jwt>
Content-Type: application/json
```

Body:

```json
{
  "purpose": "license",
  "keyId": "license-signing-v2-2026-01",
  "payload": { "schemaVersion": 2 },
  "approvalToken": "<from /v1/approve>"
}
```

返回：

```json
{
  "signature": "<base64url raw Ed25519 signature>",
  "keyVersion": "1",
  "canonicalPayload": "<base64url canonical JSON bytes>"
}
```

最终 license key 由调用方组装：

```
aster-ent-v2-<keyId>-<base64url(payload)>.<base64url(sig)>
```

---

## 部署

生产部署建议：
- service 只监听内部网络。
- TLS/mTLS 在 Envoy、Caddy 或 Traefik sidecar 终止。
- service container 不挂载 Docker socket，不运行 root。
- `VAULT_TOKEN` 使用 Vault Agent 注入短 TTL renewable token。
- `/var/log/license-signing-api/audit.jsonl` 挂载到持久卷，并由日志管道归档。

Kubernetes 示例：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: license-signing-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: license-signing-api
  template:
    metadata:
      labels:
        app: license-signing-api
    spec:
      containers:
        - name: api
          image: aster-license-signing-api:prod
          ports:
            - containerPort: 8443
          envFrom:
            - secretRef:
                name: license-signing-api-env
          volumeMounts:
            - name: audit
              mountPath: /var/log/license-signing-api
      volumes:
        - name: audit
          persistentVolumeClaim:
            claimName: license-signing-api-audit
```

---

## Disaster Recovery

如果 service 不可用，签发暂停。这是刻意设计：宁可暂停签发，也不要回退到离线私钥或人类 Vault token 直签。

恢复顺序：
1. 检查 `/readyz` 与 Vault seal 状态。
2. 检查 sidecar mTLS 与 IdP JWKS 可达性。
3. 检查 audit volume 是否可写。
4. 重启 service；pending approval 可丢失，Operator 重新发起审批。

---

## 安全模型

本 service 解决 Vault OSS 没有 `control_group` 的问题。直接把 `transit/sign/*` 发给 Witness token 会导致 Witness 绕过审批。这里把 raw Transit sign 权限收敛到 service identity，所有人类操作只走 JWT + approval 状态机 + audit。
