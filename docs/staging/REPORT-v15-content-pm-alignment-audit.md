# Staging 验证报告 v15 — 页面内容 vs PM 定义对齐审计

**日期**：2026-05-10
**范围**：home / pricing / dashboard / policy 工作流，对照 PM 文档 01-one-pager / 05-pricing / 07-ai-billing 校准
**结论**：**Acceptable / 12-13 分**——核心功能与 PM 一致（policy 工作流、AI 链路、限额）；但**核心定位漂移 + 价格差错**两个 P0 问题需立即处理。

---

## 1. 审计健康分

| # | 维度 | 分 (0-4) | 关键发现 |
|---|------|---------|----------|
| 1 | 产品定位呈现 | **1** | Hero 完全没提 CNL / 多语种，丢失最核心差异化 |
| 2 | 价格准确性 | **2** | Pro CNY ¥199 vs PM ¥299；Team 档位 PM 没定义 |
| 3 | 限额一致性 | **4** | 5/100/-1 published rules、1k/50k/-1 evals、20/500 AI — 全部对 PM v2 |
| 4 | 工作流完整度 | **3** | 草稿→审批→批准→执行 全跑通；缺审批人≠提交人强制 |
| 5 | Dashboard 卖点暴露 | **2** | 3 大用量卡（AI/API/Dunning）已开发但未挂载 |
| **总分** | | **12 / 20** | **Acceptable（significant work needed）** |

---

## 2. Anti-Patterns Verdict

不是"AI slop"问题。是**产品定位与 UI 文案脱节**问题。Hero 看起来像通用 SaaS（"Made Simple, PII protection, compliance monitoring"），任何"policy management"工具都能这么写。**Aster 的"CNL + 多语种 + 双引擎语义不漂移"完全没体现。**

---

## 3. Detailed Findings by Severity

### 🔴 P0 阻塞级（必须立即修）

#### [P0-1] Hero 文案与 PM 一句话定位完全脱节

**Location**: `messages/{en,zh,de}.json` `hero.title` / `hero.description` / `features.*`
**Category**: 产品定位（Anti-pattern: generic positioning）
**Impact**: 用户/投资人/招聘候选人**第一眼看不出 Aster 是 CNL 平台**。竞争对手再多一个"policy management with PII"——Drools / IBM ODM / n8n / Retool 都能这么宣传。
**PM 标准（01-one-pager §一句话定位 + 五行价值主张）**:
- "面向业务规则可治理的**多语种受控自然语言（CNL）平台**——把传统埋在代码里的策略提取成 **Policy-as-Code**"
- 价值 1: "**业务专家用母语写规则**：英文/中文/德语开箱即用"
- 价值 4: "**一份语义、双引擎实现**"
**Recommendation**:
- Hero title 改为 "**Policy-as-Code in plain English (and 中文 / Deutsch)**"（pricing SEO 描述就有这句，hero 居然没用）
- features 区扩 1 条："**Multi-language CNL: Write rules in your native business language**"
- features 区加 1 条："**AI writes the draft, humans approve & ship**"——直接对应 PM 价值 3
**Suggested command**: `/clarify`

#### [P0-2] Pro 价格代码 vs PM 文档不一致

**Location**: `aster-cloud/src/lib/plans.ts:25` `PLAN_PRICES.pro.CNY = { monthly: 199 }`
**Category**: 定价准确性（PM 文档对齐）
**Impact**: 销售页可能展示 ¥199，PM 计划销售故事按 ¥299；客户看到一个数字、销售用另一个，**信任崩**。
**PM 标准（05-pricing-packaging.md §2 Pro）**:
- "**¥299 / 席位 / 月**"
**Recommendation**:
- 三选一：(a) PM 文档改成 ¥199；(b) 代码改成 199 → 299；(c) 写一份 v1.2 文档解释为什么调整
- **必须先与 PM 对齐再改代码**——这是商务决策不是工程决策
**Suggested command**: 用户决策后 `/clarify`

#### [P0-3] PM 文档缺 "Team" 档位定义

**Location**: PM 05 vs `aster-cloud/src/lib/plans.ts` PLANS / LEGACY_PLAN_LIMITS
**Category**: 文档与代码偏离
**Impact**: 代码里有 4 档（Free/Pro/Team/Enterprise + Trial），PM 文档只有 3 档（Free/Pro/Enterprise）。**Team 档位文案 / Stripe price ID / UI 都已部分实现**，但**销售故事不存在**。
**Recommendation**: PM 决策——保留 Team 档（写进 v1.2 文档），或者代码删掉（merge 到 Pro）
**Suggested command**: 用户决策

---

### 🟡 P1 主要级（发版前修）

#### [P1-1] /pricing 完全没提 AI 草稿配额

**Location**: `messages/en.json` line 1044-1085 `pricingPage.tiers.{free,pro,enterprise}.features`
**Category**: 卖点缺失
**Impact**: PM 05 + 07 都明确把 AI 草稿放在三档对比矩阵里（Free 20/月、Pro 500/seat/月、Enterprise BYOK），**销售关键差异化**。pricing 页一字不提，转化率低。
**Recommendation**: 三档 features 各加一条：
- Free: "20 AI drafts / month (gpt-4o-mini)"
- Pro: "500 AI drafts / seat / month (gpt-5.2)"
- Enterprise: "Unlimited via BYOK (your OpenAI/Anthropic key)"
**Suggested command**: `/distill`

#### [P1-2] dashboard 缺 AI / API / Dunning 用量卡（v6/v7/v8 实现但未挂载）

**Location**: `app/[locale]/(dashboard)/dashboard/page.tsx`
**Category**: 卖点暴露度
**Impact**: 这 3 张卡是 v6/v7/v8 重头戏（10+ 工作日），代码完整、API ready、i18n keys 完整——**只差挂载**。用户上 dashboard 看不到自己用了多少 AI/API、不知道 dunning grace period——降低续费 / 升级转化。
**Existing components ready**:
- `components/dashboard/ai-usage-card.tsx`
- `components/dashboard/api-usage-card.tsx`
- `components/dashboard/dunning-banner.tsx`
**Recommendation**: 在 `dashboard-content.tsx` 顶部加 `<DunningBanner />`，stats grid 旁加 `<AiUsageCard />` + `<ApiUsageCard />`，3 行 import + 3 行 JSX
**Suggested command**: `/extract`（提到 dashboard）

#### [P1-3] 审批人 ≠ 提交人 强制未实现

**Location**: cloud `policies/[id]/versions/[version]/approve/route.ts`
**Category**: 工作流准确性
**Impact**: PM 05 §2 Pro 档明确："**Reviewer ≠ author (enforced)**" + "**Meets SOX Segregation of Duties**"。staging 测试中 staging-real-user 自审了自己的 v1——SOX 合规失败。
**PM 标准**:
- pricingPage.tiers.pro.features[4]: "Reviewer ≠ author (enforced)"
**Recommendation**:
- approve route 加 check：if `version.submitterId === session.user.id` → 403 "审批人不能是提交人"
- 仅对 plan ∈ {pro, team, enterprise} 强制；free/trial 跳过
**Suggested command**: `/harden`（增 SOX 合规守护）

---

### 🟢 P2 次要（下次迭代）

#### [P2-1] pricing 页 Free 独占 "All language packs"，Pro/Enterprise 没列

**Location**: `messages/en.json` pricingPage.tiers
**Category**: 卖点漏写
**Impact**: PM 1-pager 第 1 条价值主张「多语种全档可用，是产品力不是付费墙」；Pro/Enterprise 页没列 → 用户**误以为 Pro 不含多语种**。
**Recommendation**: Pro / Enterprise 也加 "All language packs (en / zh / de)"
**Suggested command**: `/distill`

#### [P2-2] Pricing comparison 表 Pro 行 SSO 显示模糊

**Location**: `pricingPage.comparison`
**Category**: 卖点对比清晰度
**Impact**: PM 明确 Pro 不含 SSO，Enterprise 才有；UI 只在 Enterprise 列了 SSO，Pro 行没明确"—"或"❌"
**Recommendation**: Pro 行 SSO 字段显示 "—" 或 "Enterprise only"
**Suggested command**: `/distill`

#### [P2-3] Hero CTA "Start your 14-day free trial" 与 Free 文案矛盾

**Location**: `messages/en.json` hero.description
**Impact**: Free 是永久免费；Hero 说 "14-day free trial"——读者以为是 trial-then-paid。PM 文档：Free 是永久档位，Trial 是 Pro 的试用通道。
**Recommendation**: Hero CTA 改成 "Start free, no credit card" 或 "Try Pro free for 14 days"（明确指 trial 是 Pro 通道）
**Suggested command**: `/clarify`

#### [P2-4] features 区缺 "Audit hash chain / Replay"

**Location**: home features 6 项里没有审计哈希链
**Impact**: PM 1-pager 价值 2 + Enterprise 卖点都强调"哈希链 + 数字签名 + 重放"。home features 只说了 "Version History"，没强调审计完整性。
**Recommendation**: features 加一项 "Tamper-evident audit: SHA-256 hash chain + deterministic replay"
**Suggested command**: `/distill`

---

### 🔵 P3 抛光（有空再做）

- **[P3-1]** SEO description 只 en 写了 "Policy-as-Code in plain English (and 中文 / Deutsch)"，zh/de 应本地化
- **[P3-2]** Hero 没出现 "GraalVM" 或"高吞吐"——技术决策者卖点
- **[P3-3]** 对 PM 提到的 K3S / ArgoCD / 私有化部署，pricing Enterprise 里有提，但 home/features 没暴露
- **[P3-4]** features.realTimeExecution: "Test and execute policies instantly" — 没明显与 PM 强调的"业务专家可读"挂钩

---

## 4. Patterns & Systemic Issues

### 系统性问题 1: i18n 文案与 PM 定位不同步
**症状**: home / pricing / nav / dashboard 各自有一套文案，PM 文档每次更新没同步到 messages/*.json。
**根因**: 缺少 PM → 文案 的同步流程；i18n keys 由工程师按"组件需要什么"写，没经过 PM/marketing review。
**建议**:
- PM 文档每次大改 → 必须有一个 PR 同步 messages/{en,zh,de}.json
- v1.2 文档发布时把 hero.title / pricingPage / features 一起更

### 系统性问题 2: 已建成功能未挂载
**症状**: AI usage card / API usage card / Dunning banner / `/settings/ai-keys`（v13 已修）都遇到过相同问题——后端 + i18n + 组件都做完了，**就差挂载到页面**。
**根因**: 多次迭代都跳过"集成到主流程"步骤，原因是赶 schema/路由/逻辑。
**建议**: 每次 PM 文档改完，**Definition of Done 必须包含"用户在哪一页能看到这个功能"**——dashboard 默认入口必挂。

### 系统性问题 3: 价格 / 档位 PM ↔ 代码偏离
**症状**: ¥299 vs ¥199；PM 三档 vs 代码四档（含 Team）；trial 在 PM 没单独档位但代码有。
**根因**: 这些细节代码 commit 时没拉 PM review。
**建议**: 加一个 `__tests__/pricing-pm-alignment.test.ts`，用代码层面对照 PM 文档的硬编码值（类似新加的 i18n integrity 测试），任何一方先改都失败。

---

## 5. Positive Findings

✅ **Policy 工作流完整且严谨** — 草稿/待审批/已批准 状态机正确，与 PM "AI 写草稿，人审上线" 一致
✅ **AI 拦截链路完美** — PG-1 (regex) + PG-2 (scope) 实战拦截，与 PM 1-pager "审计 / 重放" 价值兼容
✅ **限额数字与 PM v2 一致** — 5/100/∞ rules、1k/50k/∞ evals、20/500/∞ AI drafts 全部对齐
✅ **多语种基础架构存在** — i18n 三语切换工作，pricing/policies 标题本地化（PM 价值 1 的技术基础有了）
✅ **Enterprise feature 列表完整** — pricing.tiers.enterprise 5 条 features 与 PM 05 §Enterprise 表对应

---

## 6. Recommended Actions（优先级序）

1. **[P0] `/clarify`** — 重写 home hero + features 区，强调 CNL + 多语种 + AI-draft + audit-hash-chain
2. **[P0] 商务决策** — Pro 价格 ¥199 vs ¥299 选哪个；Team 档保留还是合并到 Pro（决策后再 `/clarify`）
3. **[P1] `/distill`** — pricing 三档 features 各加 "AI 草稿配额"行
4. **[P1] `/extract`** — 把 AiUsageCard / ApiUsageCard / DunningBanner 挂载到 dashboard
5. **[P1] `/harden`** — approve route 加"审批人 ≠ 提交人"强制（plan ∈ {pro, team, enterprise}）
6. **[P2] `/distill`** — Pro/Enterprise pricing 加 "All language packs" 行；comparison 表补 SSO=—
7. **[P2] `/clarify`** — Hero CTA 文案修矛盾
8. **[P2] `/distill`** — home features 加 "audit hash chain"
9. **[P3] `/polish`** — 收尾各种 SEO / 技术决策者卖点
10. **后置**：加 `__tests__/pricing-pm-alignment.test.ts` 防偏离

---

## 7. 你可以让我

> 一个一个跑、一次性全跑、或按你想要的顺序跑。
> 修完后重新跑 `/audit` 看分数提升。

**注意**: P0-1 + P0-2 + P0-3 是**商务决策**而非工程问题——技术上完全可改，但 marketing message + 价格档位需要产品/销售确认。
