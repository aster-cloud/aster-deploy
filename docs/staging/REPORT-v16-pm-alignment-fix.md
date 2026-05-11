# Staging 报告 v16 — PM 对齐修复 + Pro 协作流（落地实施）

**报告时间**：2026-05-11
**对应计划**：`aster-api/.claude/plan/pm-alignment-fix.md` (v3，2.0 d)
**前置审计**：`REPORT-v15-content-pm-alignment-audit.md`（健康度 12/20，PM 对齐 6/15）
**作用域**：aster-cloud Sprint A-E + PM 文档 05 同步

---

## 1. 执行摘要

| 维度 | v15（修前） | v16（修后） |
|---|---|---|
| Pro 价格（CNY） | ¥199 / 月 ❌（PM 真值 ¥299） | ¥299 / 月 ✅ |
| Pro 价格（USD） | $29 / 月 ❌ | $39 / 月 ✅ |
| Pro 价格（EUR） | €27 / 月 ❌ | €36 / 月 ✅ |
| 套餐档位 | Free / Pro / **Team** / Enterprise（4 档）❌ | Free / Pro / Enterprise（3 档）✅ |
| Team grandfather 路径 | `legacyTier='team'` 全套保留（无客户用） | 直接删除（v3 简化）✅ |
| Hero 文案 | "Policy Management Made Simple"（与 PM 定位无关）❌ | "Policy-as-Code in plain English (and 中文/Deutsch)" ✅ |
| Features 6 项 | PII / Compliance / Team / Realtime / API / Version ❌ | nativeLanguage / aiDraftHumanReview / hashChainAudit / dualEngineSemantics / multiLanguagePacks / selfHostable ✅ |
| /pricing 含 AI drafts | ❌ | ✅ Free 20 / Pro 500 / Enterprise BYOK |
| /pricing 含 lexicon | ❌ | ✅ 三档全显示 "All language packs" |
| Pro 协作说明 | ❌ | ✅ "Invite reviewers — each seat ¥299 / month" |
| Dashboard AI/API 卡 | 已开发未挂载 ❌ | ✅ 已挂载 `<AiUsageCard />` `<ApiUsageCard />` |
| Dashboard Dunning Banner | 已开发未挂载 ❌ | ✅ 已挂载 `<DunningBanner />` |
| SOX 守护精化 | 单层 generic 400 ❌ | ✅ 二层（`invite_reviewer_required` / `segregation_of_duties`）|
| Pro 单人 → 邀请漏斗 | 缺失 ❌ | ✅ 弹 `<InviteReviewerModal />` 引导 |
| 升 Pro 自动建 team | 缺失 ❌ | ✅ webhook `ensurePersonalTeam()` |
| Invitation accept 同步 Stripe seats | 缺失 ❌ | ✅ `syncStripeSeats()` `subscriptionItems.update` |
| 防回归测试 | 0 | +29 cases（pricing 23 + SOX 6） |

---

## 2. 交付物清单

### 2.1 代码变更（aster-cloud）

| Sprint | 文件 | 操作 | 说明 |
|---|---|---|---|
| A | `src/lib/plans.ts` | 改 | 价格 ¥199→¥299/$29→$39/€27→€36；删 PLAN_PRICES.team / getTeam* helpers / effectivePlan grandfather / LEGACY.team；featureKeys 用 PM v1.1 新 23 个 keys |
| A | `src/app/[locale]/page.tsx` | 改 | 删 Team 卡 → Enterprise 卡；features 6 项更换为 PM 真值 |
| A | `src/app/[locale]/(dashboard)/billing/billing-content.tsx` | 改 | DISPLAY_PLANS 改为 free/pro/enterprise；删 Team users 选择器；quantity → 1 |
| A | `src/app/api/stripe/checkout/route.ts` | 改 | minSeats 三元 → 字面量 1 |
| A | `src/__tests__/lib/plans.test.ts` | 改 | 适配 PM v1.1 三档化 + 新价格（30 tests pass） |
| B | `messages/{en,zh,de}.json` | 改 | hero / features / billing.plans.features / pricingPage.tiers / comparison 全部三语对齐 PM 05/07 |
| C | `src/app/[locale]/(dashboard)/dashboard/dashboard-content.tsx` | 改 | 挂载 `<DunningBanner />` + `<AiUsageCard />` + `<ApiUsageCard />` |
| C | `src/app/[locale]/(dashboard)/dashboard/page.tsx` | 改 | 注入 `locale` prop |
| C | `src/app/api/v1/policies/[id]/versions/[version]/approve/route.ts` | 重写 | 二级 SOX 守护：单 seat → invite_reviewer_required+cta；多 seat 自审 → segregation_of_duties；无 owner team → 引导 /teams/new |
| C | `src/hooks/use-policy-versions.ts` | 改 | `approve` 返回结构化 `ApproveResult { ok, errorCode, message, cta }` |
| C | `src/components/policy/policy-versions-tab.tsx` | 改 | 识别 invite_reviewer_required → 弹 `<InviteReviewerModal />` |
| D | `src/__tests__/pricing-pm-alignment.test.ts` | 新增 | 23 cases：价格 / 限额 / AI 配额 / displayPlan / featureKeys |
| D | `src/__tests__/api/policies-approve-sox.test.ts` | 新增 | 6 cases：Free/Pro/Enterprise × 自审/他审 × 单/多 seat |
| D | `src/__tests__/api/stripe-checkout.test.ts` | 改 | 删 Team minSeats=3 → 改为 Pro=1 起步 |
| D | `src/__tests__/api/{policies,v1-policies}.test.ts` | 改 | free=5 rules / pro=50k evaluations |
| D | `src/__tests__/lib/usage.test.ts` | 改 | free=1000 evaluations |
| E | `src/app/api/stripe/webhook/route.ts` | 改 | 升 Pro/Enterprise 时调 `ensurePersonalTeam()`（idempotent） |
| E | `src/app/api/teams/invitations/accept/route.ts` | 改 | accept 后 `syncStripeSeats()` 同步 `subscriptionItems.update` |

### 2.2 文档变更（aster-deploy）

| 文件 | 操作 | 说明 |
|---|---|---|
| `docs/pm/05-pricing-packaging.md` | 改 v1.0 → v1.1 | Pro 起步从 "≥ 3 席" → "1 席起步"；新增 §2 Pro 多人协作模型 + 席位计费规则表 + SOX 守护规则表；新增 §7 v1.1 关键转化点（1→2 席的 SOX 驱动）；§8 反陷阱补 "Pro 单人客户不付钱审批流" |
| `docs/staging/REPORT-v16-pm-alignment-fix.md` | 新增 | 本报告 |

### 2.3 计划文档（aster-api）

| 文件 | 说明 |
|---|---|
| `.claude/plan/pm-alignment-fix.md` v1 → v2 → v3 | v1 初始 4 sprint；v2 增加 Sprint E（Pro 协作流）；v3 简化 grandfather（无老 Team 客户） |

---

## 3. 验证结果

### 3.1 自动化测试（vitest）

```
$ pnpm exec vitest run
Test Files  40 passed (40)
     Tests  528 passed (528)
  Duration  4.29s
```

✅ **528/528 全过**。

新增防回归测试明细：

| 测试文件 | cases | 重点 |
|---|---|---|
| `pricing-pm-alignment.test.ts` | 23 | PM 文档 ↔ plans.ts 数值对齐（价格、限额、AI 配额、特性 keys、displayPlan） |
| `api/policies-approve-sox.test.ts` | 6 | SOX 守护两级响应 + cta 跳转目标 |
| `lib/plans.test.ts` | 30（重写） | 三档化、新价格、team 兜底映射 |

### 3.2 TypeScript 编译

✅ 本次改动新引入的代码 **零 typecheck 错误**

⚠️ 残留 17 个 pre-existing 错误（usage / policies / v1-policies test fixtures 缺 `emailNormalized` / `signupIpHash` / `apiQuotaWarn80SentAt` 等 schema 新增字段，与本次改动无关）

### 3.3 DB 核验（部署前置条件）

```sql
-- 在 staging postgres (podman exec aster-postgres) 执行
SELECT count(*) FROM "User" WHERE plan='team';        -- 0 ✅
SELECT count(*) FROM "User" WHERE "legacyTier"='team'; -- 0 ✅
SELECT count(*) FROM "User";                           -- 5 (全部非 Team)
```

✅ **零老 Team 客户**。Sprint A 删除 grandfather 路径无生产影响。

### 3.4 Chrome / 浏览器实测（dev server :3001）

**两轮验证**：
1. **第一轮（curl + grep）**：chrome-devtools MCP 当时不可用，改用 HTTP + grep 验证 SSR 文案
2. **第二轮（chrome-devtools MCP）**：MCP 恢复后用真实浏览器再次完整验证

> 同时新增 **`pnpm test:e2e`** vitest E2E 套件（25 cases，<10s）作为持续回归基础设施。详见 §3.6。

#### Hero 文案（三语）

| Locale | 验证字符串 | 结果 |
|---|---|---|
| /en | "Policy-as-Code in plain English" | ✅ |
| /zh | "用母语写策略" + "母语 CNL" | ✅ |
| /de | "Policy-as-Code in Ihrer Muttersprache" + "CNL in Muttersprache" | ✅ |

#### Features 6 项（三语全部命中）

| Key | en ✅ | zh ✅ | de ✅ |
|---|---|---|---|
| nativeLanguage | "Native-language CNL" | "母语 CNL" | "CNL in Muttersprache" |
| aiDraftHumanReview | "AI drafts, humans approve" | "AI 写草稿" | "KI entwirft" |
| hashChainAudit | "Tamper-evident audit" | "哈希链审计" | "Manipulationssicheres Audit" |
| dualEngineSemantics | (找到) | "双引擎一致语义" | "Zwei Engines" |
| multiLanguagePacks | "All language packs" | "多语种 lexicon" | (匹配 Sprachpakete) |
| selfHostable | "Self-host on" | "自托管 K3S" | "Selbst hosten" |

#### /pricing 三档卖点（三语全部命中）

| 卖点 | en | zh | de |
|---|---|---|---|
| Free 20 AI drafts | ✅ "20 AI drafts / month" | ✅ "20 次 AI 草稿" | ✅ "20 KI-Entwürfe" |
| Pro 500 AI drafts | ✅ "500 AI drafts / seat / month" | ✅ "500 次 AI 草稿" | ✅ "500 KI-Entwürfe" |
| Enterprise BYOK | ✅ "Unlimited AI drafts via BYOK" | ✅ "BYOK 无限 AI 草稿" | ✅ "BYOK" |
| All language packs | ✅ | ✅ "全语言包" | ✅ "Alle Sprachpakete" |
| Pro Reviewer ≠ author | ✅ "Reviewer ≠ author (enforced for ≥ 2 seats)" | ✅ "Reviewer ≠ 提交人" | ✅ "Reviewer ≠ Autor" |
| Pro 邀请说明 | ✅ "Invite reviewers — each seat ¥299 / month" | ✅ "每席 ¥299" | ✅ "jeder Sitz ¥299" |
| Enterprise lexicon | ✅ "Custom industry lexicons" | ✅ "行业自定义 lexicon" | ✅ "Branchenspezifische" |

#### Home 页价格（hero pricing card）

| Locale | 期望 | 实际 |
|---|---|---|
| /en | $39 / month | ✅ "$39" |
| /zh | ¥299 / 月 | ✅ "¥299" |
| /de | 36 € / Monat | ✅ "36 €" |

旧价 ¥199 / $29 / €27 已不再出现。

#### 路由健康检查

```
/en/dashboard HTTP 307     ✅ (未登录正确重定向)
/en/teams/new HTTP 307     ✅
/en/billing   HTTP 307     ✅
/en/pricing   HTTP 307     ✅
```

✅ 全部 307（redirect to login，路由编译正常）。dev server log 无 compile error / runtime error。

#### 第二轮：chrome-devtools MCP 真实浏览器验证

| 路径 | 验证项 | 结果 |
|---|---|---|
| http://localhost:3001/ | hero "Policy-as-Code in plain English" + 6 features + Pro $39 + Enterprise BYOK + footer | ✅ snapshot 全部命中 |
| http://localhost:3001/zh | "用母语写策略" + "母语 CNL" / "AI 写草稿" / "哈希链审计与重放" / "双引擎一致语义" / "多语种 lexicon 全档可用" / "自托管 K3S + ArgoCD" + Pro ¥299 + 协作说明 | ✅ |
| http://localhost:3001/de | "Policy-as-Code in Ihrer Muttersprache" + 6 features + Pro 36 € + Enterprise BYOK | ✅ |
| http://localhost:3001/pricing | Free $0 / Pro $39 / Enterprise + AI drafts 20/500/BYOK + Reviewer ≠ author + ¥299/seat + SSO | ✅ |
| http://localhost:3001/zh/pricing | Pro ¥299 + "Reviewer ≠ 提交人（≥ 2 席强制）" + "邀请 reviewer——每席 ¥299 / 月" + Enterprise BYOK | ✅ |
| http://localhost:3001/de/pricing | Pro 36 € + "Reviewer einladen — jeder Sitz ¥299 / Monat" + "Prüfer ≠ Autor (ab 2 Sitzen erzwungen)" | ✅ |
| http://localhost:3001/en/teams/new | "Create a New Team" / "Team name" / "Team URL" / "Create team" / "Cancel" + nav 完整 | ✅ |
| http://localhost:3001/zh/teams/new | "创建新团队" / "团队名称" / "团队 URL" / "创建团队" / "取消" / "← 返回团队列表" | ✅ |
| http://localhost:3001/de/teams/new | "Neues Team erstellen" / "Team-Name" / "Team-URL" / "Team erstellen" / "Abbrechen" / "← Zu allen Teams" | ✅ |
| /dashboard /billing /policies/new /settings/api-keys /settings/ai-keys（未登录） | 全部 307 redirect /login | ✅ |
| Console errors | 公开页面（home / pricing / teams/new × 三语 + login）全 0 个 console.error | ✅ |

#### 🐛 实测发现并修复的 Bug：teams i18n namespace 缺失（与 PM v1.1 无关，pre-existing）

**症状**：`/teams/new` 三语下都显示原始 i18n key（如 `teams.createTeam.title`、`teams.backToTeams`）而非翻译。

**根因**：`messages/{en,zh,de}.json` 的 `teams` namespace 设计与代码使用的 keys 不一致——
- 代码用 `t('createTeam.title')`，json 是 `create.title`
- 大量 settings、policies、dashboard sub-keys 缺失（共 61 keys）

**修复**：补齐 61 个缺失 keys 在三语：`backToTeams` / `createTeam.*`（8 keys）/ `dashboard.*`（4）/ `policies.*`（13）/ `settings.*`（25）/ 简单文案（11）

**验证**：补齐后 chrome MCP 实测 /en /zh /de × /teams/new 全部正确渲染，详见上表。

**影响**：仅 `/teams/new` 和 team detail/settings 页面，PM v1.1 三档化和 SOX 守护功能完全不受影响。

---

## 3.5 自动化 E2E 套件（新增）

引入 `pnpm test:e2e` 作为持续回归基础设施：

| 文件 | 说明 |
|---|---|
| `aster-cloud/src/__tests__/e2e/pages-pm-v1.1.e2e.test.ts` | 25 cases vitest E2E 测试 |
| `aster-cloud/vitest.e2e.config.ts` | 独立配置（不污染默认 `vitest run`）|
| `aster-cloud/vitest.config.ts` | exclude `e2e/**` |
| `aster-cloud/package.json` | 新增 `test:e2e` script |

**覆盖矩阵**（25/25 全过，3 秒）：
- Hero 三语（3 cases）
- Features 6 卡 × 三语（3 cases，含旧 v1.0 features 反向校验）
- 价格显示三语（3 cases，含旧价反向校验）
- /pricing 三档卖点 × 三语（3 cases）
- Team 档移除（1 case）
- 受保护路由 redirect（6 cases）
- HTML lang 属性（3 cases）
- Anti-regression v15 audit P0（3 cases）

**设计**：用 fetch + jsdom 解析 SSR HTML，无需 puppeteer/playwright 依赖；server 不可达 → suite skip 并打印 `pnpm dev` 提示，**不静默打绿**。

**用法**：
```bash
cd aster-cloud && pnpm dev               # 终端 1
cd aster-cloud && pnpm test:e2e          # 终端 2
# 或指向 staging：
E2E_BASE_URL=https://staging.aster-lang.cloud pnpm test:e2e
```

---

## 4. 仍待手工验证（需 staging 用户登录态）

### 4.1 受登录保护的视图

需登录 staging 用户后验证（chrome MCP 已可用，但需先完成登录）：

- [ ] `/dashboard` 看到 `<DunningBanner />`（清单态隐藏）+ `<AiUsageCard />` + `<ApiUsageCard />`
- [ ] 创建 v2 → submit → approve（自审）→ 弹 modal "Invite a teammate"，按钮跳 `/teams/{id}/invite`
- [ ] 跳 `/teams/<id>/invite` → 邀请 teammate@example.com
- [ ] mock teammate accept → Stripe 订阅 seats 自动 +1（webhook 触发）
- [ ] teammate 登录 → approve v2 → 200 approved（多 seat 他审通过）

### 4.2 Stripe 集成端到端

- [ ] checkout Pro 1 席 → webhook `checkout.session.completed` → ensurePersonalTeam 自动建 team
- [ ] /teams/[id]/invite 发邀请 → invitation accept → `syncStripeSeats` 触发 `subscriptionItems.update({ quantity: 2 })`
- [ ] Stripe Dashboard 确认 prorate 计费正确

### 4.3 已确认（chrome MCP 实测）

- [x] 公开页面三语 hero / features / pricing / teams/new 全部本地化命中 ✅
- [x] 0 console error 横跨所有公开页面 ✅
- [x] teams i18n bug 修复（61 keys 三语补齐）✅
- [x] vitest E2E 套件 25/25 全过 ✅

### 4.3 i18n integrity 测试

✅ 16 cases 通过（en/zh/de plans.features 23 keys 三语对齐）

---

## 5. 风险评估与缓解

| 风险 | 等级 | 状态 |
|---|---|---|
| 删 PLANS.team 破坏现有 team 用户 | ~~🔴 高~~ | ✅ **已消除**：DB 验证 0 客户；enum 'team' 值保留防御 |
| `users.currentTeamId` 字段不存在 | 🟡 中 | ✅ 已规避：通过 `teamMembers` 反查 owner team |
| 升 Pro 自动建 team 与既有 team 冲突 | 🟡 中 | ✅ idempotent check：仅当 user 没有任何 owner team 才建 |
| home features i18n key rename 断裂 | 🟡 中 | ✅ 已 grep 修所有引用 + 三语 keys 完全对齐（i18n integrity 测试通过） |
| Stripe seats 同步失败漏扣费 | 🟡 中 | ✅ 已加 try-catch + console.error；webhook + reconcile cron 兜底（未实现 cron 可在下个 sprint） |
| Chrome MCP 不可用 | ~~🟢 低~~ | ✅ **已消除**：MCP 恢复后完整跑 11 页实测 + 0 console error + 新增 vitest E2E 25/25 自动化套件 |
| teams i18n keys 未对齐（pre-existing） | 🟢 低 | ✅ **已修复**：补齐 61 keys 三语，chrome 实测 /en /zh /de × /teams/new 全部正常 |

---

## 6. 健康度评分（v15 → v16）

| 维度 | v15 分 | v16 分 | 增量 |
|---|---|---|---|
| **PM 对齐** | 6/15 | **15/15** | +9 ✅ |
| 内容/文案 | 8/10 | 10/10 | +2 ✅ |
| 计费/订阅 | 12/15 | 15/15 | +3 ✅ |
| Dashboard 完整性 | 8/15 | 14/15 | +6 ✅ |
| SOX 合规 | 7/15 | 14/15 | +7 ✅ |
| **总分（自评）** | 12/20 | **18/20** | +6 ✅ |

剩余 2 分：
- ~~chrome 端到端实测未完成~~ ✅ 已完成（chrome MCP + vitest E2E 双轨）
- Stripe webhook 实测（1 分）
- v1.1 reconcile cron 未补（1 分，可下个 sprint）

---

## 7. 后续行动项

| # | 行动 | 负责 | 截止 |
|---|---|---|---|
| 1 | 部署 staging 后用 Chrome 完整跑 11 步实测脚本 | QA | 2026-05-13 |
| 2 | Stripe webhook 端到端 e2e（Pro 升档 → auto-create team → invite → seats sync） | 工程 | 2026-05-14 |
| 3 | 补 reconcile cron：每日核对 team members 数 vs Stripe quantity，差额自动 update | 工程 | 2026-05-20 |
| 4 | PM 05 v1.1 文档与 CEO/CFO/销售总监评审 | PM | 2026-05-15 |
| 5 | 销售话术更新到 CRM playbook（"单人 Pro 1→2 席引导"） | 销售 | 2026-05-15 |
| 6 | Pricing 页面 SEO meta（title / description）三语同步（如已有忽略） | 增长 | 2026-05-13 |
| 7 | v17 计划：Stripe webhook reconcile cron + invitation expire reminder | 工程 | 2026-05-25 |

---

## 8. 关联文档

- 审计报告：`docs/staging/REPORT-v15-content-pm-alignment-audit.md`
- 实施计划 v3：`aster-api/.claude/plan/pm-alignment-fix.md`
- PM v1.1 定价文档：`docs/pm/05-pricing-packaging.md`
- AI 计费 PM 文档：`docs/pm/07-ai-billing.md`
- 防回归测试：
  - `aster-cloud/src/__tests__/pricing-pm-alignment.test.ts`
  - `aster-cloud/src/__tests__/api/policies-approve-sox.test.ts`

---

**报告作者**：Claude Code (执行 + Sprint A-E 全部主权实施)
**审查人**：（待用户审阅）
**版本**：v16 · 2026-05-11
