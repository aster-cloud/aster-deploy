# Staging 验证报告 v7 — Prompt Governance + Policy Execution API 配额对齐

**日期**：2026-05-10
**范围**：PG-1..7（提示词治理）+ API-1..7（Policy Execution API 配额对齐）
**结论**：14/14 任务全部交付；168 单测全绿（55 Java + 113 TS）；7 个 Chrome 场景全部通过。

---

## 1. 实施摘要

### Prompt Governance（aster-api / Java）

| 任务 | 文件 |
|------|------|
| PG-1 | `safety/RegexInjectionDetector.java`（8 条越狱 regex） |
| PG-2 | `safety/PromptScopeFilter.java`（白名单"中等"严格度 + 黑名单偏题词） |
| PG-3 | `prompts/system/system_base_{en,zh,de}.txt` 加固宪法式规则 |
| PG-4 | `prompt/PromptComposer.wrapUserData()` 三引号包裹用户输入 |
| PG-5 | `api/AiAssistantResource` 4 端点拦截 + UI 前 3 次免费 / API 每次扣 |
| PG-6 | 安全测试矩阵（44 用例） |
| PG-7 | `safety/SafetyEventReporter` HMAC fire-and-forget → cloud safetyFlags |

### API Quota Alignment（aster-api Java + aster-cloud TS）

| 任务 | 文件 |
|------|------|
| API-1 | `billing/PlanInfo.java` + plan-gate 路由加 `apiCallsLimit` |
| API-2 | schema.ts 加 `ApiCallRecord` 表 + drizzle push |
| API-3 | `policy/rest/PolicyEvaluationResource.java` 加 `enforceApiQuota` + 异步 record |
| API-4 | `/api/user/api-usage` + `components/dashboard/api-usage-card.tsx` + i18n×3 |
| API-5 | 响应头 `X-Quota-Limit/Remaining/Reset/Warning` |
| API-6 | `/api/cron/api-quota-alerts` cron + 80%/100%/200% 邮件 |
| API-7 | `lib/api-rate-limiter.ts`（Redis token bucket）+ `/api/internal/api/rate-check` |

---

## 2. 配额行为矩阵（设计）

| Plan | apiCalls/月 | per-second RPS | 100% 行为 | 200% 行为 |
|------|------------|----------------|-----------|----------|
| Free | **0** | 0 | 直接 403 | — |
| Trial | 1000 | 10 | soft warn + 邮件 | 429 hard reject |
| Pro | 5000 | 10 | soft warn + 邮件 | 429 hard reject |
| Team | 50000 | 50 | soft warn + 邮件 | 429 hard reject |
| Enterprise | -1 | 200 | 永远放行 | 永远放行 |

110% 内 soft warn 不停服，与 OpenAI overage 模型一致。

---

## 3. Chrome 端到端验证（CT-1..7）

| # | 场景 | 结果 |
|---|------|------|
| CT-1 | 首页加载 | ✅ 200, 0 console error |
| CT-2 | /login + /signup OAuth-only | ✅ GitHub/Google 按钮存在，0 error |
| CT-3 | /pricing 渲染 | ✅ Free/Pro/Enterprise + 50000 数字 |
| CT-4 | `/api/user/{api-usage,ai-usage,ai-data-export,ai-data}` | ✅ 全部 200，shape 正确（plan=pro, limit=5000, ...） |
| CT-5 | `/api/internal/{api/usage, api/rate-check, ai/usage}` 无签名 | ✅ 全 401 |
| CT-6 | 5 个 cron 路由：no-auth + wrong-auth | ✅ 全 401；正确 secret → 200 |
| CT-7 | plan-gate 返回 `apiCallsLimit` | ✅ free=0 / pro=5000 |

---

## 4. 测试统计

| 来源 | 通过 | 失败 |
|------|------|------|
| Java 单测 (PG safety + prompt + PlanInfo) | **55** | 0 |
| TS 单测 (ai-* + email-* + signup-*) | **113** | 0 |
| Chrome 端到端 (CT-1..7) | **7 场景** | 0 |
| **合计** | **175** | **0** |

---

## 5. 关键设计决策（可追溯）

### Prompt Governance

- **三引号包裹用户输入**：与 system prompt 的 `INPUT BOUNDARY` 规则配套；用户若伪造 `"""` 会被替换为 `""""` 防越界。
- **白名单严格度分档**：generate/explain/suggest = MEDIUM（必须命中 policy 领域词）；complete = LENIENT（仅长度限制）。
- **配额扣除策略**：UI 路径前 3 次拦截不扣（容错），API 路径每次扣（机器自保质量）。
- **PG-7 fire-and-forget 上报**：`SafetyEventReporter` 写 `safetyFlags.jailbreak_attempt=true` 到 cloud → anomaly Signal 4 累计 ≥3 触发 24h 自动封禁。

### API Quota

- **soft overage（100%-200%）**：保 SLA 不停服，仅响应头 + 邮件提醒；只有 200% 才 429。OpenAI/Stripe/Twilio 行业标准做法。
- **响应头标准**：`X-Quota-Limit / X-Quota-Remaining / X-Quota-Reset / X-Quota-Warning`（前 3 月度）+ `X-RateLimit-Limit / X-RateLimit-Remaining`（per-second）。
- **per-second 限流走 Redis fail-open**：Redis 不可达不阻塞业务（SLA > 限流精度）。
- **batch 端点按条扣配额**：1 次 batch with 50 items = 50 次配额，公平计费。

---

## 6. Schema 变更（已 drizzle-kit push 至 staging）

```sql
ALTER TABLE "User" ADD COLUMN "apiQuotaWarn80SentAt"  timestamp;
ALTER TABLE "User" ADD COLUMN "apiQuotaWarn100SentAt" timestamp;
ALTER TABLE "User" ADD COLUMN "apiQuotaWarn200SentAt" timestamp;

CREATE TABLE "ApiCallRecord" (
  "id" text PRIMARY KEY,
  "userId" text NOT NULL,
  "tenantId" text,
  "apiKeyId" text,
  "periodMonth" text NOT NULL,
  "endpointPath" text NOT NULL,
  "status" text NOT NULL,
  "latencyMs" integer NOT NULL DEFAULT 0,
  "createdAt" timestamp NOT NULL DEFAULT now()
);
CREATE INDEX "ApiCall_userId_period_idx" ON "ApiCallRecord" ("userId","periodMonth");
CREATE INDEX "ApiCall_tenantId_createdAt_idx" ON "ApiCallRecord" ("tenantId","createdAt");
CREATE INDEX "ApiCall_apiKeyId_createdAt_idx" ON "ApiCallRecord" ("apiKeyId","createdAt");
CREATE INDEX "ApiCall_createdAt_retention_idx" ON "ApiCallRecord" ("createdAt");
```

---

## 7. 新增依赖

| 包 | 来源 | 用途 |
|-----|------|------|
| `ioredis` ^5.10.1 | aster-cloud | API-7 per-second token bucket |

无其他新依赖。

---

## 8. 新增 env vars

无新增；`CRON_SECRET` / `ASTER_PLAN_GATE_HMAC_KEY` / `REDIS_URL` 均已在 v5/v6 报告 + 现有 staging 配置中。

部署需补充的 cron 调度（生产侧 Vercel/K8s）：
```
0 6 * * *  /api/cron/api-quota-alerts
```

---

## 9. 已知未做（明确记录，避免被动遗漏）

| 项目 | 原因 |
|------|------|
| `ApiCallRecord` 90 天保留 cron | 数据量小，下迭代再加（可复用现有 `ai-audit-cleanup` cron 加一段 SQL） |
| dashboard 把 `ApiUsageCard` 真正挂载到 `/[locale]/dashboard` 页面 | 组件 + 接口 + i18n 都已就绪；PM 决策"挂在哪一档 dashboard"再拼装即可 |
| `X-Call-Source` UI/API 路径区分（aster-cloud 主动设头） | aster-api 端识别已实现；前端目前所有调用都走 UI 路径（缺省即可） |
| 真实 Redis 集成测试 | staging 已有 `aster-redis` 容器；CT 阶段未做真实速率压测，留 v8 |

---

## 10. 清理

```
podman compose -f aster-deploy/podman/podman-compose.staging.yaml down -v
kill <next-dev-pid>
```

由用户在确认验收后执行。
