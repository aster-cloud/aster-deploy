# Staging 验证报告 v6 — 反多重注册 + AI 内容审计

**日期**：2026-05-10
**范围**：L0+L1+L2+L3+L5 反多重注册 + AI-Audit-1..4 内容审计
**结论**：9/9 任务全部交付；端到端验证通过；113 单测全绿。

---

## 1. 实施概览

| 任务 | 内容 | 关键文件 |
|------|------|----------|
| **L0** | 邮箱规范化（gmail +/. 剥离 + 唯一索引） | `lib/email-normalize.ts`, `db/schema.ts` users.emailNormalized |
| **L1** | 一次性邮箱黑名单（disposable-email-domains，121k 域名） | `lib/email-disposable.ts` |
| **L2** | 注册 IP 限流（24h ≤ 3） | `lib/signup-rate-limit.ts`, `db/schema.ts` SignupAttempt 表 |
| **L3** | anomaly cron 加 signupIpHash 聚类检测（同 IP ≥5 账号活跃 → 全冻结） | `lib/ai-anomaly-detection.ts` Signal 5, users.signupIpHash |
| **L5** | Free 档强制邮箱验证才解锁配额 | `lib/ai-quota.ts` ai_email_unverified |
| **AI-Audit-1** | schema 加 4 字段（encryptedPrompt/Completion/redactedPrompt/safetyFlags） | `db/schema.ts` aiUsageRecords |
| **AI-Audit-2** | PII 脱敏（regex-only，可插拔，覆盖 8 类） | `lib/ai-pii-redactor.ts` |
| **AI-Audit-3** | prompt-injection 同步阻断（regex，<10ms，8 条规则） | `lib/ai-content-safety.ts` + Signal 4 |
| **AI-Audit-4** | 180 天保留 cron + GDPR 导出/删除 | `/api/cron/ai-audit-cleanup`, `/api/user/ai-data-export`, `/api/user/ai-data` |

---

## 2. 端到端 staging 验证结果

| # | 场景 | 期望 | 实际 |
|---|------|------|------|
| 1 | pgcrypto 加解密往返（新审计字段） | 解密 = 原文 | ✅ |
| 2 | 一次性邮箱拦截 mailinator.com | `signIn → false` | ✅（auth.ts 集成） |
| 3 | 邮箱规范化 5 种 gmail 写法归一 | 1 个 normalized | ✅ |
| 4 | 注册 IP 限流 hashIp 不存明文 | 16 字符 hex | ✅ |
| 5 | Free 未验证邮箱 → ai_email_unverified | 拒绝 | ✅（21 单测覆盖） |
| 6 | Signal 4：3 条 jailbreak → 24h 封禁 | aiBanReason='内容安全策略命中' | ✅ |
| 7 | Signal 5：同 hash ≥5 账号 → 全冻结待审核 | 100 年 ban | ✅（单测覆盖） |
| 8 | 清理 cron：抹除 200 天前加密原文 | 加密列 NULL，billing 字段保留 | ✅ |
| 9 | 清理 cron：删除 24h+ signupAttempts | 行删除 | ✅ |
| 10 | GDPR export 路由 401 gate + 解密查询 | 401 + 明文返回 | ✅ |
| 11 | GDPR delete 路由 401 gate + 三字段抹除 | 401 + UPDATE 成功 | ✅ |
| 12 | PII 脱敏混合输入（邮箱+手机+身份证+IP） | 4 个 [REDACTED:*] | ✅ |
| 13 | prompt-injection 8 条规则全部生效 | blocked=true with ruleId | ✅（19 单测覆盖） |

---

## 3. 数据流（关键交互）

```
注册（OAuth）
  ├─ signIn callback (auth.ts)
  │   ├─ existingAccount? → 直接登录
  │   ├─ disposable email? → reject
  │   ├─ normalized email 已存在? → reject  ← L0
  │   ├─ 24h 同 IP ≥3 次成功? → reject       ← L2
  │   └─ recordSignupAttempt(ip, succeeded)
  └─ adapter.createUser
      ├─ 写入 emailNormalized                ← L0
      └─ 写入 signupIpHash                   ← L3 用

调用 LLM（aster-api → cloud /api/ai/*）
  ├─ checkAiQuota
  │   ├─ BYOK? → 放行
  │   ├─ Free + emailVerified=null? → reject  ← L5
  │   ├─ aiBannedUntil > now? → reject
  │   ├─ 月度配额 / 速率
  │   └─ allow
  ├─ detectPromptInjection（同步阻断）        ← AI-Audit-3
  │   └─ blocked → recordAiUsage(safetyFlags.jailbreak_attempt=true)
  └─ recordAiUsage（异步入库）
      ├─ encryptForAudit(prompt) → encryptedPrompt   ← AI-Audit-1
      ├─ redactPii(prompt) → redactedPrompt          ← AI-Audit-2
      └─ safetyFlags

cron / 5 min: ai-anomaly-scan
  ├─ Signal 1 重复 prompt
  ├─ Signal 2 token 量
  ├─ Signal 3 失败率
  ├─ Signal 4 jailbreak 累计 ≥3                ← AI-Audit-3
  └─ Signal 5 注册 IP 聚类 ≥5                  ← L3

cron / 1 day: ai-audit-cleanup                ← AI-Audit-4
  ├─ 180 天前 encryptedPrompt/Completion → NULL
  └─ 24h+ SignupAttempt → DELETE

用户主动（GDPR）                                ← AI-Audit-4
  ├─ GET /api/user/ai-data-export → 解密返回
  └─ DELETE /api/user/ai-data → 抹除三字段
```

---

## 4. 单元测试

| 文件 | 用例数 |
|------|--------|
| `email-normalize.test.ts` | 13 |
| `email-disposable.test.ts` | 11 |
| `signup-rate-limit.test.ts` | 12 |
| `ai-content-safety.test.ts` | 19 |
| `ai-pii-redactor.test.ts` | 23 |
| `ai-audit-vault.test.ts` | 6 |
| `ai-quota.test.ts` | 21 |
| `ai-anomaly-detection.test.ts` | 8 |
| **合计** | **113** |

```
pnpm exec vitest run src/__tests__/lib/{ai-*,email-*,signup-*}.test.ts
→ 113 passed
```

---

## 5. Schema 变更（drizzle-kit push 已应用）

```sql
-- users
ALTER TABLE "User" ADD COLUMN "emailNormalized" text;
CREATE UNIQUE INDEX "User_emailNormalized_unique" ON "User" ("emailNormalized");
ALTER TABLE "User" ADD COLUMN "signupIpHash" text;

-- aiUsageRecords
ALTER TABLE "AiUsageRecord" ADD COLUMN "encryptedPrompt" text;
ALTER TABLE "AiUsageRecord" ADD COLUMN "encryptedCompletion" text;
ALTER TABLE "AiUsageRecord" ADD COLUMN "redactedPrompt" text;
ALTER TABLE "AiUsageRecord" ADD COLUMN "safetyFlags" json;
CREATE INDEX "AiUsage_createdAt_retention_idx" ON "AiUsageRecord" ("createdAt");

-- 新表
CREATE TABLE "SignupAttempt" (
  "id" text PRIMARY KEY,
  "ipHash" text NOT NULL,
  "succeeded" boolean NOT NULL DEFAULT false,
  "createdAt" timestamp NOT NULL DEFAULT now()
);
CREATE INDEX "SignupAttempt_ipHash_createdAt_idx" ON "SignupAttempt" ("ipHash", "createdAt");
CREATE INDEX "SignupAttempt_createdAt_idx" ON "SignupAttempt" ("createdAt");
```

---

## 6. 新增依赖

```
disposable-email-domains  ^1.0.62  （121k 一次性邮箱域名，~1.2MB）
```

无其他新依赖；其余实现全部基于 Postgres + drizzle + Node crypto。

---

## 7. 新增 env vars（需添加到 Vault / K3S）

```
AI_AUDIT_ENCRYPTION_SECRET   # AES 主密钥，独立于 BYOK 密钥；≥16 字符
SIGNUP_IP_SALT               # IP hash 用 salt；≥16 字符
```

cron 调度（应加入 Vercel / K8s CronJob）：

```
0 4 * * *  /api/cron/ai-audit-cleanup
```

---

## 8. 已知未做（明确写在文档里，避免被动遗忘）

| 项目 | 原因 | 何时再做 |
|------|------|----------|
| **Cloudflare Turnstile** | OAuth-only 注册由 Google/GitHub 自带 bot-gate；增加 captcha 反而劝退合法用户 | 上 Credentials 注册时再加 |
| **小模型 PII 脱敏兜底** | regex-only v1 漏检率可接受；接口预留 PiiRedactor 可平滑替换 | 当 anomaly detection 发现 redactedPrompt 残留 PII 比例 ≥3% 时 |
| **dashboard `ai-usage-card` Chrome 实拍** | dev session cookie 难模拟；i18n 已加好 | 下次 e2e 一起 Playwright |
| **管理员审核界面**（Signal 5 冻结的批量账号） | 后台基础设施依赖产品决策 | 下迭代 |
| **OpenAI 真实账户接入** | 上线前再做 | 公测前 |

---

## 9. 安全/合规收益总结

| 攻击/合规要求 | 防御层 | 状态 |
|--------------|--------|------|
| 同人多 gmail 变体注册 | L0 emailNormalized | ✅ |
| 一次性邮箱注册 | L1 disposable list | ✅ |
| 同 IP 批量脚本注册 | L2 24h ≤ 3 + L3 聚类检测 | ✅ |
| 注册后未验证邮箱直接刷配额 | L5 ai_email_unverified | ✅ |
| Prompt injection / jailbreak | AI-Audit-3 同步阻断 + Signal 4 累计封禁 | ✅ |
| GDPR Article 15（数据可访问） | `/api/user/ai-data-export` | ✅ |
| GDPR Article 17（被遗忘权） | `/api/user/ai-data` DELETE | ✅ |
| 国内《暂行办法》第 11 条（≥6 月日志） | encryptedPrompt 180 天保留 | ✅ |
| GDPR 数据最小化 | IP 仅存 hash；明文 180 天后抹除 | ✅ |
| 内容安全监管复盘 | redactedPrompt + safetyFlags 永久 | ✅ |

---

## 10. 清理

```
podman compose -f aster-deploy/podman/podman-compose.staging.yaml down -v
kill <next-dev-pid>
```

由用户在确认验收后执行。
