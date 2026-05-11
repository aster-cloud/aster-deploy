# AI 计费 + 防盗刷运维 SOP

> 配套 `aster-deploy/docs/pm/07-ai-billing.md` 实施。
> 上线前必须按此清单逐项确认。

---

## 1. Vault 密钥写入（一次性）

```bash
# 1.1 BYOK 加密主密钥（AES-256，长度 ≥ 32 字符）
vault kv put secret/apps/aster-cloud-ai \
  ai-key-encryption-secret="$(openssl rand -base64 32)" \
  cron-secret="$(openssl rand -hex 24)" \
  slack-ai-abuse-webhook="https://hooks.slack.com/services/T0XXX/B0XXX/XXX"

# 1.2 PlanGate HMAC 共享密钥（aster-api ↔ aster-cloud 双向验签）
KEY=$(openssl rand -hex 32)
vault kv put secret/apps/aster-api-plan-gate hmac-key="$KEY"
vault kv put secret/apps/aster-cloud-plan-gate hmac-key="$KEY"  # 同一个 key

# 1.3 Mixpanel project token（PM 创建 Mixpanel 项目后）
vault kv put secret/apps/aster-api-mixpanel \
  token="<from Mixpanel project settings>"
```

⚠️ **重要**：`ai-key-encryption-secret` 一旦确定不能变更，否则数据库里所有 BYOK 密文将无法解密。如必须轮换，需迁移脚本：用旧密钥解密 + 新密钥加密 + 双写过渡。

---

## 2. K3S 部署 env

### aster-api (`k3s/apps/aster-lang/cloud/deployment.yaml`)

✅ 已配置（运维不需要再动）：
- `ASTER_MIXPANEL_ENABLED=true` + token (ExternalSecret)
- `ASTER_PLAN_GATE_ENABLED=true` + hmac-key (ExternalSecret)
- `ASTER_STAGING_TELEMETRY_ENABLED=false`
- `ASTER_CLOUD_INTERNAL_URL=http://aster-cloud.aster-cloud.svc.cluster.local:3000`

### aster-cloud (Vercel / Cloudflare Workers)

通过 Vercel CLI 或 Web 控制台配置：

```bash
# Vercel CLI
vercel env add AI_KEY_ENCRYPTION_SECRET production < /tmp/ai-key-secret
vercel env add CRON_SECRET production < /tmp/cron-secret
vercel env add ASTER_PLAN_GATE_HMAC_KEY production < /tmp/hmac-key
vercel env add SLACK_AI_ABUSE_WEBHOOK production < /tmp/slack-webhook
```

**生产必须配齐**（否则 instrumentation.ts 启动时 throw）：
- `DATABASE_URL`
- `AUTH_SECRET`
- `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET`
- `NEXT_PUBLIC_STRIPE_PRO_*_PRICE_ID` × 4
- `NEXT_PUBLIC_MIXPANEL_TOKEN`
- `ASTER_PLAN_GATE_HMAC_KEY`
- `RESEND_API_KEY`
- `NEXT_PUBLIC_APP_URL`

**AI 相关新增**：
- `AI_KEY_ENCRYPTION_SECRET` — BYOK pgcrypto 主密钥（≥32 字符）
- `CRON_SECRET` — 防 cron 路由被外部调用
- `SLACK_AI_ABUSE_WEBHOOK` — AI 滥用告警通道
- `ASTER_API_INTERNAL_URL` — aster-api 内部地址（K3S service DNS）

---

## 3. Cron 配置

### 3.1 异常扫描（5 分钟一次）

**Vercel Cron**（`vercel.json`）：

```json
{
  "crons": [
    {
      "path": "/api/cron/ai-anomaly-scan",
      "schedule": "*/5 * * * *"
    },
    {
      "path": "/api/cron/byok-healthcheck",
      "schedule": "0 3 * * *"
    },
    {
      "path": "/api/cron/trial-day-1-reminder",
      "schedule": "0 9 * * *"
    },
    {
      "path": "/api/cron/cleanup-nonces",
      "schedule": "0 6 * * *"
    }
  ]
}
```

**Cloudflare Workers**（`wrangler.toml`）：

```toml
[triggers]
crons = ["*/5 * * * *", "0 3 * * *", "0 9 * * *", "0 6 * * *"]
```

### 3.2 验证 cron 已注册

```bash
# Vercel
vercel cron list

# Cloudflare
wrangler triggers list
```

---

## 4. AlertManager 路由（K3S）

```yaml
# /Users/rpang/IdeaProjects/k3s/apps/infrastructure/monitoring/alertmanager-config.yaml
route:
  group_by: ["alertname", "team"]
  receiver: "default-null"
  routes:
    # AI 滥用 → 单独频道
    - matchers: ['alertname=~"AsterAi.*"']
      receiver: "slack-ai-abuse"
    # SLO burn rate → 工程 oncall
    - matchers: ['burn_rate="fast"']
      receiver: "pagerduty-oncall"
    - matchers: ['burn_rate="slow"']
      receiver: "slack-eng"
    # PM 反指标 → 产品频道
    - matchers: ['team="product"']
      receiver: "slack-pm-metrics"

receivers:
  - name: "default-null"
  - name: "slack-ai-abuse"
    slack_configs:
      - channel: "#ai-abuse"
        api_url_file: /etc/alertmanager/slack-ai-abuse-url
  - name: "slack-eng"
    slack_configs:
      - channel: "#eng-aster-api"
        api_url_file: /etc/alertmanager/slack-eng-url
  - name: "slack-pm-metrics"
    slack_configs:
      - channel: "#pm-metrics"
        api_url_file: /etc/alertmanager/slack-pm-url
  - name: "pagerduty-oncall"
    pagerduty_configs:
      - service_key_file: /etc/alertmanager/pagerduty-key
```

把 webhook URL 通过 ExternalSecret 挂进 alertmanager pod。

---

## 5. OpenAI / Anthropic 平台层 Hard Cap

**双保险**：除了我们代码里的配额，OpenAI 自己也支持月度 hard cap：

1. https://platform.openai.com/account/billing/limits → Hard limit = $300/月
2. 超出 OpenAI 直接拒绝调用，不会让我们烧成 $3000

PM 设定的全局熔断（aster-cloud 端）应该 **比 OpenAI hard cap 小 10%**，让我们先告警再触发外部硬限。

---

## 6. 上线 day-0 监控 checklist

```bash
# 1. Vault 已写入 5 个 key
vault kv get secret/apps/aster-cloud-ai
vault kv get secret/apps/aster-api-plan-gate
vault kv get secret/apps/aster-api-mixpanel

# 2. ExternalSecret 同步成功
kubectl get externalsecret -n aster-cloud
# 全部 SecretSynced=True

# 3. K3S aster-api pod 起来 + env 注入
kubectl get pod -n aster-cloud -l app=aster-api
kubectl exec -n aster-cloud aster-api-xxx -- env | grep -E "PLAN_GATE|MIXPANEL|STAGING_TEL"
# 应看到 ASTER_STAGING_TELEMETRY_ENABLED=false

# 4. Vercel env 配齐
vercel env ls production | grep -E "AI_KEY|CRON|SLACK_AI|HMAC"

# 5. Cron 注册
vercel cron list
# 应有 4 个 cron

# 6. AI quota internal endpoint 可达（HMAC 签名）
TS=$(date +%s)
SIG=$(echo -n "GET\n/api/internal/ai/quota\n$TS" | openssl dgst -sha256 -hmac "$KEY" | awk '{print $2}')
curl -H "X-Aster-Timestamp: $TS" -H "X-Aster-Signature: $SIG" \
     "https://aster-lang.cloud/api/internal/ai/quota?userId=test"
# 200 + JSON

# 7. Mixpanel 收到事件（让一个真实用户在 SaaS 上点 AI 草稿）
# Mixpanel UI → Live View → 应看到 ai_draft_generated

# 8. Grafana NSM dashboard 有数据
open https://grafana.aster-lang.cloud/d/aster-nsm/

# 9. Prometheus alert rules 加载
curl https://prometheus.aster-lang.cloud/api/v1/rules | jq '.data.groups[] | .name'
```

---

## 7. 应急处理

### 7.1 AI 成本失控

```bash
# 立即关闭所有 Free 用户的 AI（保留 Pro/Enterprise）
psql $DATABASE_URL -c "
  UPDATE \"User\"
  SET \"aiBannedUntil\" = NOW() + INTERVAL '24 hours',
      \"aiBanReason\" = '全局成本熔断（紧急）'
  WHERE plan = 'free';
"

# 或通过管理员 UI（G6 实施后）
curl -X POST https://aster-lang.cloud/api/admin/ai-circuit-breaker \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"action":"open","scope":"free"}'
```

### 7.2 BYOK 加密密钥泄露

```bash
# 1. 立即生成新密钥，标记旧密钥
NEW_KEY=$(openssl rand -base64 32)

# 2. 通过迁移脚本双写（旧 + 新）一段时间
# 3. 用户下次保存 BYOK 时自动切到新密钥
# 4. 全部迁移完成后撤销旧密钥
```

### 7.3 异常扫描误封

```bash
# 解封单个用户
psql $DATABASE_URL -c "
  UPDATE \"User\"
  SET \"aiBannedUntil\" = NULL,
      \"aiBanReason\" = NULL
  WHERE id = '<user-id>';
"
```

---

## 8. 监控指标（Grafana 应展示）

| 面板 | 数据源 | 阈值 |
|---|---|---|
| 月度 AI 调用次数（按 plan） | `count(aiUsageRecords) WHERE periodMonth=now` | — |
| 月度 LLM 成本（USD） | `sum(costCents) / 100` | < $300 |
| 当前被封禁用户数 | `count(users WHERE aiBannedUntil > now)` | < 10 |
| BYOK 启用率 | `count(aiKeyBindings active=true)` | — |
| 平均成本 / 采纳草稿 | `total_cost / WAADR` | < ¥3.5 |

详见 `aster-api/docs/metrics/MetricsCatalog.md` 反指标 4。
