# 凭证轮换 Runbook (P0-1)

> **目标**：把所有在对话/截图/日志里暴露过的凭证全部失效，替换为新值。
> **执行人**：创始人（涉及上游账号操作 + Vault 写入）。
> **预估时长**：3-4 小时（单次完整轮换）。
> **频率**：每季度一次，或发现泄露后立即执行。

---

## 凭证清单与 Vault 映射

| # | 凭证 | 上游 | Vault 路径 | 消费方 |
|---|------|------|-----------|--------|
| 1 | Cloudflare API Token | dash.cloudflare.com → My Profile → API Tokens | `infrastructure/cloudflare` | external-secrets (k3s)、`wrangler` 本地、GH Actions |
| 2 | Vault Root Token | `vault operator init` 或现 root 重新生成 | N/A（root 本身） | 人类管理员 |
| 3 | LLM API Key（rightcode） | right.codes 后台 | `apps/aster-api-llm` → `api-key` | aster-api |
| 4 | Mixpanel Project Token | mixpanel.com 项目设置 | `apps/aster-api-mixpanel` → `token` | aster-api（事件埋点） |
| 5 | Slack Incoming Webhook | api.slack.com/apps → Incoming Webhooks | `apps/aster-api-plan-gate` → `slack-webhook` | aster-api 告警 + AlertManager |
| 6 | HMAC Signing Key | 自生成（256-bit） | `apps/aster-api-plan-gate` → `hmac-key` | aster-api 请求签名 |
| 7 | Cron Secret | 自生成（256-bit） | `apps/aster-api-plan-gate` → `cron-secret` | aster-api `/cron/*` 端点 |
| 8 | AI Key Encryption Secret | 自生成（256-bit） | `apps/aster-cloud-ai` → `key-encryption-secret` | aster-cloud（用户 BYOK 加密） |
| 9 | KUBECONFIG (k3s admin) | k3s server 上 `/etc/rancher/k3s/k3s.yaml` | N/A | 本地 `~/.kube/k3s-config`、GH Secret `KUBECONFIG_B64` |
| 10 | GitHub PAT (repository_dispatch) | github.com/settings/tokens | N/A | GH Actions secret `CROSS_REPO_TOKEN` |

---

## 通用步骤模板

每项凭证按以下五步走：

```
1. 在上游创建新凭证（名字带 _v2 / _2026-05 后缀，便于区分）
2. 写入 Vault 新值（不删旧值）
3. 让消费方重新加载（ExternalSecret refresh 或 Pod restart）
4. 验证生产功能（具体见每项的"验证"）
5. 撤销旧凭证（上游 revoke + Vault 删除）
```

**回滚原则**：第 3 步失败时，立刻把 Vault 值改回旧的 + 重启消费方，旧凭证还未撤销，可恢复。

---

## 1. Cloudflare API Token

### 当前用途
- ArgoCD external-secrets 拉取 Cloudflare Tunnel credentials
- `wrangler` 本地部署 aster-lang.cloud
- GitHub Actions（如有 CF deploy step）

### 轮换步骤
```bash
# Step 1: 在 dash.cloudflare.com 创建新 Token
#   Profile → API Tokens → Create Token → 复制现有 Token 的权限模板
#   命名：aster-deploy-2026-05
#   权限：Zone:Read, Zone:DNS:Edit, Account:Workers:Edit, Account:Pages:Edit
#   范围限定：Specific account = wontlost; Specific zone = aster-lang.cloud
#   过期：90 天

# Step 2: 写入 Vault
export VAULT_ADDR=https://vault.aster-lang.cloud
vault login
vault kv get secret/infrastructure/cloudflare  # 备份当前值
vault kv put secret/infrastructure/cloudflare \
  api-token="<new-token>" \
  account-id="<existing-account-id>" \
  zone-id="<existing-zone-id>"

# Step 3: 触发 ExternalSecret refresh
kubectl annotate externalsecret cloudflare-tunnel-credentials \
  -n cloudflare-tunnel \
  force-sync=$(date +%s) --overwrite

# 等待 ESO refresh（默认 1h，强制触发后 < 1 分钟）
kubectl get externalsecret -A | grep cloudflare

# Step 4: 验证
#   a) cloudflare-tunnel pod 应自动重启拉新 credentials
kubectl rollout status -n cloudflare-tunnel deployment/cloudflared
#   b) 用新 Token 调 API 验证
curl -s -H "Authorization: Bearer <new-token>" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq .result.status
# 期望: "active"

# Step 5: 撤销旧 Token
#   dashboard → API Tokens → 旧 Token → Delete
#   验证旧 Token 失效
curl -s -H "Authorization: Bearer <old-token>" \
  https://api.cloudflare.com/client/v4/user/tokens/verify
# 期望: HTTP 401
```

### 回滚
```bash
# 旧 Token 未撤销前，写回旧值
vault kv put secret/infrastructure/cloudflare api-token="<old-token>" ...
kubectl annotate externalsecret cloudflare-tunnel-credentials \
  -n cloudflare-tunnel force-sync=$(date +%s) --overwrite
```

---

## 2. Vault Root Token

### 警告
Root token 极少使用。日常运维应该用 AppRole 或 short-TTL token，不要长期持有 root。

### 轮换步骤
```bash
# Step 1: 用现 root 创建新 root（操作员 token）
vault login <current-root>
NEW_ROOT=$(vault token create -policy=root -ttl=8760h -format=json | jq -r .auth.client_token)
echo "$NEW_ROOT" > ~/.vault-token-new  # 暂存

# Step 2: 验证新 root 可用
VAULT_TOKEN=$NEW_ROOT vault token lookup

# Step 3: 撤销旧 root
vault token revoke <old-root-token>

# Step 4: 替换本地 vault token
mv ~/.vault-token-new ~/.vault-token

# Step 5: 验证旧 root 失效
VAULT_TOKEN=<old-root> vault token lookup  # 期望: permission denied
```

### 备用方案：unseal keys
如果丢失所有 root，用 unseal keys 重建：
```bash
vault operator generate-root -init
# 按提示用 3 个 unseal keys 解锁
```

---

## 3. LLM API Key (rightcode)

```bash
# Step 1: right.codes 后台生成新 key
#   命名: aster-api-2026-05

# Step 2: 写 Vault
vault kv patch secret/apps/aster-api-llm api-key="<new-key>"

# Step 3: 触发 ESO + Pod restart
kubectl annotate externalsecret aster-api-llm-credentials \
  -n aster-cloud force-sync=$(date +%s) --overwrite
sleep 30
kubectl rollout restart -n aster-cloud deployment/aster-api

# Step 4: 验证 AI 功能
curl -X POST https://policy.aster-lang.dev/api/v1/ai/complete \
  -H "Content-Type: application/json" \
  -d '{"prompt":"hello","maxTokens":10}'
# 期望: 200 OK + 文本响应

# Step 5: 撤销旧 key（right.codes 后台）
```

---

## 4. Mixpanel Project Token

```bash
# Step 1: mixpanel.com → Project Settings → Service Accounts → New
#   或：重置 Project Token（注意：会清空历史归因数据，慎用）
#   推荐：用 Service Account API Secret 替代 project token

# Step 2: 写 Vault
vault kv patch secret/apps/aster-api-mixpanel token="<new-token>"

# Step 3: 重启
kubectl annotate externalsecret aster-api-mixpanel-credentials \
  -n aster-cloud force-sync=$(date +%s) --overwrite
kubectl rollout restart -n aster-cloud deployment/aster-api

# Step 4: 验证
#   触发一次 policy evaluation, 然后在 Mixpanel Live View 看是否有事件

# Step 5: 撤销旧 token (Mixpanel UI)
```

---

## 5. Slack Incoming Webhook

```bash
# Step 1: api.slack.com → Your Apps → aster-alerts → Incoming Webhooks
#   Add New Webhook to Workspace → 选择 channel #aster-alerts
#   复制新 webhook URL

# Step 2: 写 Vault
vault kv patch secret/apps/aster-api-plan-gate slack-webhook="<new-url>"

# Step 3: 重启 (aster-api + AlertManager)
kubectl annotate externalsecret aster-api-plan-gate-credentials \
  -n aster-cloud force-sync=$(date +%s) --overwrite
kubectl rollout restart -n aster-cloud deployment/aster-api
# AlertManager 用 ExternalSecret 注入，也要 refresh
kubectl annotate externalsecret alertmanager-slack \
  -n aster-observability force-sync=$(date +%s) --overwrite 2>/dev/null || true

# Step 4: 验证
curl -X POST "<new-webhook>" \
  -H "Content-Type: application/json" \
  -d '{"text":"rotation test from runbook"}'
# 期望: 200 OK, Slack 收到消息

# Step 5: 撤销旧 webhook (Slack App 设置中删除)
```

---

## 6. HMAC Signing Key（自生成）

```bash
# Step 1: 生成新 key
NEW_HMAC=$(openssl rand -base64 32)

# Step 2: 写 Vault（保留旧 key 为 prev-hmac-key 用于 grace period）
OLD_HMAC=$(vault kv get -field=hmac-key secret/apps/aster-api-plan-gate)
vault kv patch secret/apps/aster-api-plan-gate \
  hmac-key="$NEW_HMAC" \
  prev-hmac-key="$OLD_HMAC"

# Step 3: aster-api 代码需支持 dual-key 验证（接受 hmac-key OR prev-hmac-key）
#   ⚠️ 这是代码改造前置条件。如未支持，本步骤会导致正在传输中的请求验签失败。
#   检查代码：grep -r "hmac" src/main/java/io/aster/policy/security/RequestSignatureFilter.java

# Step 4: 重启
kubectl rollout restart -n aster-cloud deployment/aster-api

# Step 5: 等待 24h grace period（让所有客户端切到新签名）
#   然后删除 prev-hmac-key
vault kv patch secret/apps/aster-api-plan-gate prev-hmac-key=""
kubectl rollout restart -n aster-cloud deployment/aster-api
```

**前置改造**：若 `RequestSignatureFilter` 不支持 dual-key，先做改造再轮换。

---

## 7. Cron Secret（自生成）

```bash
NEW_CRON=$(openssl rand -hex 32)
vault kv patch secret/apps/aster-api-plan-gate cron-secret="$NEW_CRON"
kubectl rollout restart -n aster-cloud deployment/aster-api

# 验证
curl -X POST https://policy.aster-lang.dev/cron/dunning-check \
  -H "X-Cron-Secret: $NEW_CRON"
# 期望: 200 OK; 用旧 secret 应返回 401
```

---

## 8. AI Key Encryption Secret（自生成，aster-cloud）

```bash
# ⚠️ 这把 key 加密了用户存储的 BYOK API keys
# 轮换需要 re-encrypt 数据库中所有 encrypted_api_keys 列

# Step 1: 生成新 key
NEW_AES=$(openssl rand -base64 32)

# Step 2: 双 key 阶段（代码需支持 KEY_CURRENT + KEY_PREVIOUS）
OLD_AES=$(vault kv get -field=key-encryption-secret secret/apps/aster-cloud-ai)
vault kv patch secret/apps/aster-cloud-ai \
  key-encryption-secret="$NEW_AES" \
  prev-key-encryption-secret="$OLD_AES"

# Step 3: 跑 re-encryption migration
cd ~/IdeaProjects/aster-cloud
pnpm tsx scripts/rotate-ai-key-encryption.ts
# 该脚本应：
#   1) 用 OLD 解密所有 encrypted_api_keys
#   2) 用 NEW 重新加密并写回
#   3) verification: 抽样 5 条解密验证

# Step 4: Cloudflare Pages 环境变量同步更新（aster-cloud 跑在 CF Workers）
#   wrangler secret put KEY_ENCRYPTION_SECRET --env production < (echo $NEW_AES)
#   wrangler deployments tail 看是否生效

# Step 5: 删除 prev key
vault kv patch secret/apps/aster-cloud-ai prev-key-encryption-secret=""
wrangler secret delete PREV_KEY_ENCRYPTION_SECRET --env production
```

**前置改造**：`aster-cloud/src/lib/byok-encryption.ts` 需支持 dual-key 解密。

---

## 9. KUBECONFIG (k3s admin)

```bash
# Step 1: SSH 到 k3s server，重新签发 client cert
ssh k3s-server-1
sudo /usr/local/bin/k3s certificate rotate-ca  # 这会重签所有 cert，包括 client
# 或仅 client cert:
sudo k3s kubectl certificate approve <CSR>

# Step 2: 拷贝新 kubeconfig 到本地
scp k3s-server-1:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-config-new
# 改 server URL 从 127.0.0.1 → 真实 IP
sed -i '' "s|127.0.0.1|<k3s-server-public-ip>|" ~/.kube/k3s-config-new

# Step 3: 验证
KUBECONFIG=~/.kube/k3s-config-new kubectl get nodes

# Step 4: 替换本地
mv ~/.kube/k3s-config-new ~/.kube/k3s-config

# Step 5: 更新 GitHub Secret（base64 编码避免多行换行问题）
base64 -i ~/.kube/k3s-config | pbcopy
# 粘贴到 https://github.com/wontlost/aster-api/settings/secrets/actions
# Secret 名: KUBECONFIG_B64

# Step 6: 触发 deploy workflow 验证
gh workflow run deploy.yml -R wontlost/aster-api
gh run watch -R wontlost/aster-api
```

**注意**：k3s 默认 client cert 有效期 1 年。在 `aster-deploy/docs/dr-drills/` 加日历提醒。

---

## 10. GitHub PAT (repository_dispatch)

```bash
# Step 1: github.com/settings/tokens → Generate new token (classic)
#   命名: aster-cross-repo-2026-05
#   权限: repo (full), workflow
#   过期: 90 天

# Step 2: 更新所有需要这个 PAT 的仓库 secret
for repo in aster-lang-test aster-lang-ts aster-lang-core; do
  gh secret set CROSS_REPO_TOKEN \
    --body "<new-pat>" \
    --repo wontlost/$repo
done

# Step 3: 验证 repository_dispatch
gh api repos/wontlost/aster-lang-ts/dispatches \
  -X POST \
  -H "Authorization: token <new-pat>" \
  -f event_type=corpus-changed

gh run list --repo wontlost/aster-lang-ts | head -3

# Step 4: 撤销旧 PAT (github.com/settings/tokens)
```

---

## 轮换后检查清单

执行完所有 10 项后跑一遍：

```bash
# ✅ k3s 健康
kubectl get pods -A | grep -v Running | grep -v Completed
# 期望: 仅 0/x Init 之类瞬时状态

# ✅ ExternalSecret 全部 Synced
kubectl get externalsecret -A | grep -v SecretSynced
# 期望: 输出为空（除了 header）

# ✅ aster-api 健康
curl -fsS https://policy.aster-lang.dev/q/health | jq .status
# 期望: "UP"

# ✅ aster-cloud 登录
# 浏览器访问 https://aster-lang.cloud/login → SSO 走通

# ✅ Slack 收到测试消息
# (P0-1 Step 5 的验证)

# ✅ AI Explain 可用
# 浏览器 aster-lang.cloud → 创建规则 → 点 AI Explain

# ✅ AlertManager 路由
# kubectl exec 进入 alertmanager pod
amtool config routes test severity=critical
```

---

## 备忘

- **不要**把任何凭证粘贴进 git commit、issue、PR 描述
- **不要**在对话中传递活跃凭证。如必须传递，先在上游撤销并立即生成新值
- 季度复盘时核对：所有凭证创建日期 < 90 天？
- 离职/外包结束时立即跑一次全量轮换

---

## 历史轮换记录

| 日期 | 触发原因 | 执行人 | 备注 |
|------|---------|--------|------|
| 2026-05-12 | 初次建立 runbook (P0-1) | Ryan | 凭证在前序对话中暴露过 |
