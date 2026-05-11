# Aster Lang — 北极星指标与指标树

> 一份让产品 / 工程 / 销售 / 增长团队对齐的"什么算成功"。

---

## 北极星指标（North Star Metric, NSM）

> **每周被业务专家采纳的 AI 草稿规则数（Weekly Adopted AI-Drafted Rules, WAADR）**

### 为什么是它

候选我们权衡过两个：

| 候选指标 | 反映的是 | 缺点 |
|---|---|---|
| 月活策略评估次数（Monthly Policy Evaluations） | **用量** —— 平台已有用户用得多吗 | 容易被一个大客户拉爆，掩盖产品力问题；且评估调用可被脚本/合成流量污染 |
| **每周被业务专家采纳的 AI 草稿规则数（WAADR）** ✅ | **PMF** —— 业务专家是否真的能用我们的 CNL 写规则 | 需要埋点 + 定义"采纳"；前期数字小、噪声大 |

我们选 **WAADR**，因为：

1. **它直接打 CNL 恐怖谷**——只有当业务专家能（且愿意）把 AI 草稿改成可上线规则时，PMF 才存在。
2. **它强迫产品 / AI / 教学三个方向都要发力**：草稿质量差则采纳率低，UX 难用则采纳数低，业务专家不会用则草稿数低。
3. **它天然抗刷量**：评估次数可以伪造，"被人审过、改过、上线"很难伪造。
4. **数字小但敏感**：50 → 100 → 300 的增长曲线，团队感受得到、能讲故事。

### 精确定义

```
WAADR = COUNT(rule_versions) WHERE
        rule_versions.created_at IN [Mon 00:00, Sun 23:59]
    AND rule_versions.source_kind = 'ai_draft_edited'
    AND rule_versions.status = 'published'
    AND rule_versions.author.role IN ('business_expert', 'compliance_officer', 'risk_analyst')
```

- **`source_kind = 'ai_draft_edited'`**：必须是 AI 生成后被人工修改并保存的版本（纯 AI 直接保存不算，避免"用 AI 刷量"）。
- **`status = 'published'`**：必须从 draft 进入 published（即真的会被引擎评估），避免"写着玩"污染数据。
- **`role IN (业务角色)`**：开发者写的不算，必须是业务专家。

---

## 指标树（NSM 拆解）

```
                    WAADR
                       │
          ┌────────────┼────────────────────────┐
          │            │                        │
     A. 草稿数        B. 编辑率               C. 上线率
   (AI 生成的         (草稿被改过的           (改过的草稿
    草稿总量)          比例)                  上线的比例)
          │            │                        │
   ↑驱动子指标↑   ↑驱动子指标↑              ↑驱动子指标↑
   ─────────    ─────────                ──────────
   • DAU/WAU    • 草稿质量评分           • 团队评审 SLA
   • Prompt    • 编辑距离中位数         • 失败评估率
     转化率    • AI 修复使用次数         • 回滚率
   • 模板复用   • 自然语言改动率         • 协作活跃度
```

### A. 草稿数（输入侧 — 用户愿意试）

| 子指标 | 健康线 | 含义 |
|---|---|---|
| 周活业务专家数 (WAU_BE) | ≥ 团队席位的 60% | 业务专家是否真的进系统 |
| Prompt → 草稿转化率 | ≥ 70% | AI 是否能稳定生成可读草稿 |
| 模板使用率 | ≥ 30% | 我们的模板/示例库是否有效 |

### B. 编辑率（中间层 — AI 草稿够好）

| 子指标 | 健康线 | 含义 |
|---|---|---|
| 草稿编辑距离中位数 | 10–40% | 太低=AI 太弱用户全自己写；太高=AI 太烂全推倒重来 |
| AI Repair 使用次数 / 草稿数 | ≤ 2 次 | 修复流的可用性 |
| 草稿编辑后的解析成功率 | ≥ 95% | 业务专家手改后还能编译通过 |

### C. 上线率（输出侧 — 真的解决问题）

| 子指标 | 健康线 | 含义 |
|---|---|---|
| 草稿 → 已上线 转化率 | ≥ 35% | 产品全闭环健康度 |
| 上线后 7 天回滚率 | ≤ 10% | 规则质量 |
| 上线规则的月评估调用数 | 持续增长 | "用得起"的规则才有商业价值 |

---

## 增长漏斗 × 指标对应

```
   Awareness                                         Activation
   ─────────                                         ──────────
   aster-lang.dev   →   Playground   →   注册   →   首条草稿   →   首条上线   →   团队采纳
   月独立访客 (UV)       Playground 试用率   注册转化率   AHA 触达率    NSM (WAADR)    Net Retention

   增长团队负责    →    产品 + AI 团队负责    →    商业团队负责    →    客户成功负责
```

| 漏斗阶段 | 关键指标 | 健康线 |
|---|---|---|
| Awareness | aster-lang.dev 月 UV | 6 个月内 ≥ 5,000 |
| Activation | Playground → 注册 | ≥ 8% |
| AHA Moment | 注册 → 首条草稿（24h 内） | ≥ 50% |
| **NSM** | **WAADR** | **目标见下** |
| Retention | 团队 30 日活跃留存 | ≥ 70% |
| Revenue | 团队订阅转化 | ≥ 15% |

---

## 目标线（OKR 草案）

| 时间 | WAADR 目标 | 同步驱动 |
|---|---|---|
| **Q1 / 2026 末（已过）** | Baseline 50 / week | 埋点上线、Mixpanel 看板 |
| **Q2 / 2026 末** | 150 / week | 完成 5 人可用性测试，AI 模型升 gpt-5.2 |
| **Q3 / 2026 末** | 400 / week | 公开 3 个客户案例，aster-lang.dev SEO 上线 |
| **Q4 / 2026 末** | 1,000 / week | Enterprise 包装上线，2 家私有化客户 |

---

## 反指标（Counter Metrics）

不要为了拉 NSM 让这些恶化：

| 反指标 | 阈值 |
|---|---|
| 上线 7 天回滚率 | 不得 > 15%（否则 NSM 是"数量假繁荣"） |
| 评估 P99 延迟 | 不得 > 200ms |
| 平台月故障 SLA | 不得低于 99.5% |
| AI Token 成本 / 采纳草稿 | 不得高于 $0.50（成本失控） |

---

## 数据采集落地

### 已有埋点（aster-cloud / aster-api）

- Mixpanel：用户行为事件（已接入）
- aster-api 审计表 `audit_logs`：每次评估带 SHA-256
- LLM repair_start / validated 事件（已上线）

### 需补充埋点（P0，跟可用性测试同周期）

| 事件名 | 触发点 | 关键属性 |
|---|---|---|
| `ai_draft_generated` | LLM 生成草稿 | prompt_id, lang, model, latency_ms, char_count |
| `draft_edited` | 草稿被人工修改保存 | draft_id, edit_distance, time_spent_sec |
| `draft_published` | 草稿进入 published 状态 | draft_id, source_kind, reviewer_id |
| `rule_rolled_back` | 规则被回滚 | rule_id, days_after_publish, reason |

### 计算视图（建议在 aster-api Postgres 建物化视图）

```sql
CREATE MATERIALIZED VIEW pm_weekly_waadr AS
SELECT
    date_trunc('week', published_at) AS week,
    tenant_id,
    COUNT(*) AS waadr
FROM rule_versions rv
JOIN users u ON u.id = rv.author_id
WHERE rv.source_kind = 'ai_draft_edited'
  AND rv.status = 'published'
  AND u.role IN ('business_expert', 'compliance_officer', 'risk_analyst')
GROUP BY 1, 2;
```

每周一 00:30 通过 ArgoCD CronJob 刷新；推送到 Mixpanel + Slack #pm-metrics。

---

## 关键决策原则

1. **NSM 一年内不变**：避免每季度换指标导致团队没北极星。
2. **任何新功能上线必须能解释"对 NSM 哪个子指标有贡献"**——否则 deprioritize。
3. **季度复盘看 NSM + 反指标**：单看 NSM 容易得意忘形。

---

**版本**：v1.0 · 2026-05-10
**关联文档**：`01-one-pager.md` / `04-usability-test-plan.md`
