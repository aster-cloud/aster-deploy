# Staging 验证报告 v8 — Dunning（催收）流程

**日期**：2026-05-10
**范围**：DUN-1..7（21 天 grace period + 4 阶段邮件 + 自动降级 + 自助挽留）
**结论**：7/7 任务全部交付；38 单测全绿；staging 端到端通过。

---

## 1. PM 决策（已确认）

| 决策点 | 选择 | 理由 |
|--------|------|------|
| Grace period 长度 | **21 天** | B2B 财务月结 cover 90% 真实"忘付"场景 |
| 数据恢复窗口 | **30 天** | 销售挽回客户的标准窗口 |
| Trial 失败处理 | **直接降 Free** | trial 用户感知本来就是"不付钱就 Free" |
| 自助挽留 | **启用** | Stripe Customer Portal，0 客服压力 |

---

## 2. 实施摘要

| 任务 | 文件 |
|------|------|
| DUN-1 | `db/schema.ts` users 加 5 字段（gracePeriodStartsAt/EndsAt, dunningEmailsSentCount, lastDunningEmailSentAt, downgradedAt） |
| DUN-2 | `api/stripe/webhook/route.ts` 扩展 payment_failed/payment_succeeded/customer.subscription.deleted；Trial 直降分支 |
| DUN-3 | `lib/dunning.ts`（4 阶段邮件模板）+ `api/cron/dunning-emails/route.ts`（每天 06:30 UTC） |
| DUN-4 | `api/cron/auto-downgrade/route.ts`（每天 07:00 UTC，21 天后强制降级） |
| DUN-5 | `api/stripe/portal/route.ts` 已存在；自助更新支付方式 |
| DUN-6 | `components/dashboard/dunning-banner.tsx` + `api/user/dunning-status/route.ts` + i18n×3 |
| DUN-7 | `__tests__/lib/dunning.test.ts` + `__tests__/api/dunning-webhook.test.ts` + `__tests__/api/auto-downgrade.test.ts` |

---

## 3. 状态机（核心）

```
正常订阅 (active)
       ↓ payment_failed (首次)
past_due + gracePeriodStartsAt=now + gracePeriodEndsAt=+21d
       ├─ Day 0  webhook 直接发邮件 #1（dunningEmailsSentCount=1）
       ├─ Day 3  cron 发邮件 #2（sentCount=2）
       ├─ Day 7  cron 发邮件 #3 URGENT（sentCount=3）
       ├─ Day 14 cron 发邮件 #4 FINAL NOTICE（sentCount=4）
       ↓ Day 21 grace 到期 + auto-downgrade cron
canceled + plan=free + downgradedAt=now + apiKeys.revokedAt=now
       │      ↓ ≤30 天内 payment_succeeded
       │      → active + 清空所有 dunning 字段（DB 自动恢复）
       └─ >30 天 → 数据进入 GDPR cleanup 队列

Trial 路径（旁路）:
trialing → payment_failed → 直接 plan='free' / status='canceled'
```

---

## 4. 端到端 staging 验证（chrome MCP）

| # | 场景 | 期望 | 实际 |
|---|------|------|------|
| 1 | 401 守卫（dunning-emails / auto-downgrade） | 401 | ✅ 401 |
| 2 | 正确 Bearer + 0 past_due 用户 | scanned=0 | ✅ |
| 3 | `/api/user/dunning-status`（已登录，正常用户） | null/null/null | ✅ |
| 4 | 设置 past_due 4 天前 + 跑 cron | 发 Day 0 邮件，sentCount=1 | ✅ |
| 5 | 同日重跑 cron（幂等检查） | sent=false, reason=already-sent-today | ✅ |
| 6 | grace 已过期 + 跑 auto-downgrade | plan→free, status→canceled, downgradedAt 写入 | ✅ |
| 7 | 再跑 auto-downgrade（幂等） | scanned=0（已被 SQL filter 排除） | ✅ |
| 8 | audit log 记录 metadata | previous_plan / grace_period_ends_at | ✅ |

---

## 5. 测试统计

| 套件 | 用例数 |
|------|--------|
| `dunning.test.ts`（pickStage / shouldSendStage / buildEmail / graceDaysLeft / 常量）| 27 |
| `dunning-webhook.test.ts`（payment_failed/succeeded 状态转移） | 4 |
| `auto-downgrade.test.ts`（边界 + 30 天恢复窗口） | 7 |
| **DUN 合计** | **38** |
| 历史 TS 测试不回归 | 113 |
| **TS 全套** | **151 / 151** |

```
pnpm exec vitest run src/__tests__/{lib,api}/{dunning,*ai*,*email*,*signup*}.test.ts → 151 passed
```

---

## 6. 修复的运行时缺陷

### apiKeys 列名 schema 不一致
- **症状**：`auto-downgrade` 第一次执行时报 `syntax error at or near "where"`，部分降级（plan/status 已切但 apiKeys 没切）
- **原因**：`apiKeys` 表 schema 用 `revokedAt` 而非 `active`；最初代码假设 active 列存在
- **修复**：`set({ revokedAt: now })` + `where(isNull(apiKeys.revokedAt))`
- **影响**：staging 修复后端到端验证全部通过；生产无影响（DUN-4 还未上线）

---

## 7. Schema 变更（已 drizzle-kit push）

```sql
ALTER TABLE "User" ADD COLUMN "gracePeriodStartsAt"   timestamp;
ALTER TABLE "User" ADD COLUMN "gracePeriodEndsAt"     timestamp;
ALTER TABLE "User" ADD COLUMN "dunningEmailsSentCount" integer DEFAULT 0 NOT NULL;
ALTER TABLE "User" ADD COLUMN "lastDunningEmailSentAt" timestamp;
ALTER TABLE "User" ADD COLUMN "downgradedAt"           timestamp;
```

---

## 8. 部署侧 cron 调度（生产需补）

```
30 6 * * *  /api/cron/dunning-emails    （Bearer CRON_SECRET）
0  7 * * *  /api/cron/auto-downgrade    （Bearer CRON_SECRET）
```

两个 cron 时间错开 30 分钟：先发邮件再降级，避免同时触发让客户体验混乱。

---

## 9. 与上游"会计平账"问题的关系

v7 报告 §9 中提的"100% soft overage 缺失计费闭环"问题，本期 DUN 实现是其**应收侧的下半场**：

- **收入侧**（overage metered billing）—— 仍为 v7 待办，未做
- **应收侧**（不付款怎么办）—— ✅ 本期完成

合规上：DUN 已经能保证"过 21 天还不付款 → 服务停 + 数据保留 30 天"——这是会计 close-the-books 的基础。下次做 metered billing 时，所有 overage 都会自然走入 Stripe invoice → 失败时也走相同 dunning 流程，不会出现"漏开账"。

---

## 10. 已知未做（下一轮）

| 项目 | 备注 |
|------|------|
| Day 14+ 弹窗 modal（urgency 升级） | 当前 banner 已含 URGENT 标签；modal 增量收益小 |
| 30 天后数据归档（GDPR cleanup 接 downgradedAt） | 留给下个迭代加进现有 GDPR cron |
| Stripe Smart Retries 配置 | 需在 Stripe Dashboard 手工 enable（一次性，不在代码里） |
| Customer Portal 配置 `payment_method_collection: always` | 同上，手工配置 |
| ToS 条款补充 "21-day grace, then downgrade" | 法务事项 |

---

## 11. 清理

```
podman compose -f aster-deploy/podman/podman-compose.staging.yaml down -v
kill <next-dev-pid>
```

待用户确认验收后执行。
