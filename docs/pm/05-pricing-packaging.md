# 定价与部署矩阵 v1.0（草案）

> 把 K3S 自托管从"技术债"包装成"Enterprise Edition 商品"
> 用一张矩阵让销售、客户、工程对齐"谁该买什么"

---

## 1. 战略原则

1. **三轨并行，不互相蚕食**：Free 服务个人 + 评估，Pro 服务团队 + 中小企业，Enterprise 服务受监管行业。
2. **K3S = Enterprise 必选**：自托管是 Enterprise 的差异化卖点，不是降级。
3. **AI 用量不绑死定价**：AI 是用量计费（usage-based add-on），避免固定定价被 Token 成本拖累。
4. **不要 Freemium 的隐形成本陷阱**：Free 版必须有明确"够用上限"，超出就强制升级。
5. **多语种全档可用**：lexicon 包不分档，是产品力不是付费墙。

---

## 2. 套餐三档

### 🟢 Free（Developer / 个人 / 评估）

| 项 | 限额 |
|---|---|
| 用户席位 | 1 |
| 项目数 | 1 |
| 已发布规则数 | 5 |
| 月评估调用数 | 1,000 |
| AI 草稿生成 / 月 | 20 次（gpt-4o-mini） |
| 审计保留期 | 7 天 |
| 多语种 lexicon | ✅ 全部（en/zh/de） |
| Playground / LSP / REST API | ✅ |
| 团队协作 / SSO / RBAC | ❌ |
| 支持 | 社区 / GitHub Issue |

**目的**：让个人开发者、风控同行评估方案，最大化 PLG 漏斗顶端。

---

### 🔵 Pro（中小团队 SaaS）—— ¥299 / 席位 / 月

| 项 | 限额 |
|---|---|
| 用户席位 | **1 起步**（按需邀请，每邀请一人 +¥299/月） |
| 项目数 | 无限 |
| 已发布规则数 | 100 / 项目 |
| 月评估调用数 | 50,000 / 工作区，超出 ¥0.005 / 次 |
| AI 草稿生成 | 包含 500 / 席位 / 月（gpt-5.2），超出 ¥0.30 / 次 |
| 审计保留期 | 90 天 |
| 团队协作（评论 / 评审） | ✅ |
| RBAC | ✅（业务专家 / 审批人 / 工程师 三角色） |
| 审批流（Reviewer ≠ Author） | ✅ **≥ 2 席强制启用 SOX 职责分离** |
| Stripe 计费 | ✅ 月付 / 年付（年付 8 折），seat 增减按比例 prorate |
| Webhook / 集成 | ✅（Slack / 飞书 / Teams） |
| SSO | ❌（Enterprise 专属） |
| SLA | 99.5%（无补偿） |
| 支持 | 工单（48h） |

**目的**：跑通 SaaS 商业模式；客户成功团队可直接转化。

#### Pro 多人协作模型（v1.1 新增）

> **关键设计**：Pro = 1 席位起步。每个被邀请的协作者（reviewer / 工程师）占用一个 seat，按 ¥299/月计费。

**席位计费规则**：

| 场景 | 行为 | 计费 |
|---|---|---|
| 单人 Pro 用户 | 自动建 personal team workspace（owner = 自己） | ¥299/月 × 1 = ¥299/月 |
| 邀请 1 位 reviewer | accept 邀请后立即同步 Stripe `subscriptionItems.update({ quantity: 2 })` | ¥299/月 × 2 = ¥598/月（按比例 prorate） |
| 邀请 N 位协作者 | seat = team members 总数 | ¥299/月 × (N+1) |

**审批流强制规则（SOX 职责分离）**：

| Owner 团队 seats | 审批行为 | API 响应 |
|---|---|---|
| 1（仅自己） | 提交人 = 审批人 → 引导邀请 reviewer | `403 invite_reviewer_required` + cta `/teams/{id}/invite` |
| ≥ 2 | 提交人 ≠ 审批人 | `200 approved`（正常审批通过） |
| ≥ 2 但仍自审 | 自己审自己 | `403 segregation_of_duties`（SOX 违规拒绝） |

**升级触发器**：单人 Pro 客户首次点击 "Approve" 自己的策略时，UI 弹出引导 modal："Invite a teammate to enable Reviewer ≠ author"。这是 expansion 漏斗的关键转化点（1 seat → 2 seat 的自然驱动）。

**销售话术**（针对单人买家询问"我自己审自己"）：
> "Pro 默认就是 1 席 ¥299/月，您可以单人使用所有 AI 草稿、API、审计功能。但要启用合规级审批流（满足 SOX、等保、内审要求），需要邀请至少一位同事担任 reviewer，多一席 ¥299——业内合规审计一次的人天费用就远超这个数。"

---

### 🟣 Enterprise（自托管 / 受监管）—— 合同制，起价 ¥30 万 / 年

| 项 | 限额 |
|---|---|
| 用户席位 | 无限 |
| 评估调用 | 无限（自有算力） |
| AI 草稿 | BYOK（客户自己 OpenAI/Azure 账号）或托管转售 |
| 审计保留 | 无限（基于客户存储） |
| **部署模式** | **K3S + ArgoCD 私有化** / **客户自管 Kubernetes** / **VPC 单租户托管** |
| SSO | ✅ SAML 2.0 / OIDC / Authentik / 企业 LDAP |
| 数据驻留 | ✅ 中国 / 欧盟 / 美国 / 客户自定义 |
| GDPR / PII 合规报告 | ✅ |
| 审计：哈希链 + 数字签名 | ✅ |
| 自定义 lexicon（行业垂类术语） | ✅ |
| 24×7 SLA 99.9% + 故障补偿 | ✅ |
| 专属客户成功 | ✅（Slack Connect + 月度 QBR） |
| 源码托管 / Escrow | ⚙️ 可议 |
| 法务定制（DPA / MSA） | ✅ |

**目的**：金融、医疗、政企、保险、政府客户；签合同，做项目，年单为主。

---

## 3. 套餐对比矩阵

| 能力 | Free | Pro | Enterprise |
|---|---|---|---|
| 多语种 CNL（en/zh/de） | ✅ | ✅ | ✅ |
| Playground / LSP | ✅ | ✅ | ✅ |
| REST / GraphQL / WS API | ✅（限速） | ✅ | ✅ |
| AI 草稿 / 解释 / 修复 | 20/月 | 500/席位/月 | BYOK / 托管 |
| 团队协作 + RBAC | — | ✅（1 席起步，按需扩） | ✅ + 自定义角色 |
| **审批流（Reviewer ≠ Author）** | — | ✅（≥ 2 席启用） | ✅ 多级 |
| SSO（SAML / OIDC） | — | — | ✅ |
| 数据驻留选择 | — | EU / US（默认） | 全部 + 客户自定义 |
| 审计哈希链 | 7 天 | 90 天 | ∞ + 数字签名 |
| 自定义 lexicon / overlay | — | — | ✅ |
| 部署 | aster-cloud SaaS | aster-cloud SaaS | **K3S 私有化 / VPC** |
| SLA | — | 99.5% | 99.9% + 补偿 |
| 支持 | 社区 | 工单 48h | 24×7 + CSM |
| 价格 | ¥0 | **¥299 / 席位 / 月**（1 席起） | 起 ¥30 万 / 年 |

---

## 4. 加购项（Add-ons，跨档可买）

| Add-on | 适用 | 价格 | 说明 |
|---|---|---|---|
| 额外 AI 草稿包 | Pro / Enterprise | ¥1,500 / 1,000 次 | 跑量大客户预付 |
| 额外评估调用包 | Pro | ¥800 / 100,000 次 | 替代超出按量计费的便宜选项 |
| 自定义行业 lexicon 设计 | Enterprise | ¥10 万 / 个（一次性）+ ¥3 万 / 年维护 | 行业术语包：医疗 / 航司 / 油气 / 政企 |
| 私有母语 lexicon 翻译 | Enterprise | ¥5 万 / 个（一次性）+ ¥2 万 / 年维护 | 小语种 / 内部术语 lexicon；Aster team 委托翻译 + 维护 |
| 培训与认证 | Pro / Enterprise | ¥2 万 / 期（10 人） | 业务专家 CNL 培训营 |
| 专业服务（PoC / 迁移） | Enterprise | T&M ¥5,000 / 人 / 日 | 专家上门、PoC 共建 |

---

## 5. 部署矩阵（产品 vs 客户能力）

```
                   客户运维能力强 →
              ┌─────────────────────────────────────┐
              │                                     │
   数据敏感   │     Enterprise                      │
   度高       │     K3S 自托管（客户机房）          │
       ↑      │     + ArgoCD GitOps                 │
       │      │     + 客户自有 Vault / SSO          │
              │                                     │
              ├─────────────────────────────────────┤
              │                                     │
              │     Enterprise                      │
              │     VPC 单租户托管                  │
              │     （我们运维 / 客户 VPC）         │
              │                                     │
   数据敏感   ├─────────────────────────────────────┤
   度低       │                                     │
              │     Pro / Free                      │
              │     aster-cloud 多租户 SaaS         │
              │                                     │
              └─────────────────────────────────────┘
                   ← 客户运维能力弱
```

| 部署模式 | 适用客户 | 我方责任 | 客户责任 | 上线周期 |
|---|---|---|---|---|
| **多租户 SaaS** | Free + Pro | 全部基础设施 | 仅订阅 + 用 | 即时 |
| **VPC 单租户托管** | Enterprise（数据驻留要求） | 应用 + 基础设施运维 | 提供 VPC + DNS + 计费 | 2–4 周 |
| **K3S 完全私有化** | Enterprise（强合规） | 安装 + 升级 + 答疑 | 集群 + 网络 + 运维 7×24 | 4–8 周 |
| **客户自管 K8s** | Enterprise（已有 K8s） | Helm Chart + 答疑 | 集群 + 部署 + 运维 | 1–3 周 |

---

## 6. 价格锚点对比（外部参考，非承诺）

| 竞品 | 大致价格档 | Aster 对应 |
|---|---|---|
| IBM ODM | $5万/年 + 实施 | Enterprise |
| Drools 商业版 (Red Hat) | $3万–10万/年 | Enterprise |
| Kogito Enterprise | $2万–8万/年 | Enterprise |
| Camunda DMN Enterprise | €1.5万起 / 年 | Enterprise |
| n8n Cloud | $20–500/月 | Pro |
| Retool | $10/席位/月 起 | Pro |

定价心锚：**Pro 比 Retool 略贵**（业务专家工具，价值更高），**Enterprise 比 ODM 略便宜**（年轻品牌，建立信任期）。

---

## 7. 升级路径（Expansion 故事）

```
   Free（个人评估，20 AI 草稿/月，5 规则上限）
       ↓ 触达上限 / 需要 API / 需要 90 天审计
   Pro 1 席（¥299/月，单人 SaaS）
       ↓ 需要审批流（点 Approve 自己 → modal 引导邀请）
   Pro N 席（¥299 × N/月，启用 SOX 职责分离）
       ↓ 月评估 > 50万 / 数据合规要求 / SSO 需求
   Enterprise VPC 托管
       ↓ 数据完全不出域 / 监管审计要求
   Enterprise K3S 私有化
       ↓ 行业垂类规模化
   Enterprise + 自定义 lexicon
```

每一步升级都有清晰的"硬触发器"（席位 / 用量 / 合规），便于销售识别和客户成功催化。

**v1.1 关键转化点**：Pro 1 席 → Pro 2 席的转化由 SOX 守护强制驱动——单人 Pro 用户每次尝试 self-approve 都会被 modal 引导，这是 ARPA 翻倍的天然机会（¥299 → ¥598/月）。

---

## 8. 反陷阱清单

| 常见陷阱 | 我们的对策 |
|---|---|
| 把 K3S 自托管当"降级版" | 反过来：它是 **Enterprise 唯一拥有**的最高档能力 |
| Free 没有上限 → 永远不付费 | 5 条已发布规则、1,000 次评估、7 天审计 是硬上限 |
| AI 用量打爆毛利 | 用量计费 + BYOK 选项，毛利转嫁 |
| Pro 单人客户不付钱审批流 | **SOX 守护强制**：自审 → 403 引导邀请；不邀请就不能 publish |
| Pro 客户用集体账号绕过席位 | RBAC + 审计强制每用户登录；invitation accept 自动同步 Stripe seat |
| Enterprise 一单一议，无法 SCALE | 起价 ¥30 万锚定，自定义部分走 Add-on 标准化报价 |
| 私有化客户后续断联 | 内置 telemetry 上报（可关闭）+ 季度 QBR + 升级激励 |

---

## 9. 销售脚本（30 秒电梯版）

> "您团队现在的业务规则在哪？
> ——埋在代码里？合规读不懂。
> ——在 Excel 里？永远过期。
> ——在低代码里？别人家的运行时。
>
> Aster 让您的合规官和风控专员**用中文写规则**，AI 帮他们起草，
> 然后我们的引擎执行——审计完整，可重放，可私有化。
>
> 中小团队 ¥299 一席，企业版数据完全不出您的机房。
> 5 分钟在 aster-lang.dev 试一个 demo。"

---

## 10. 后续行动项

| # | 行动 | 负责 | 截止 |
|---|---|---|---|
| 1 | aster-cloud Pricing 页面上线（含套餐对比表） | 增长 | 2026-06-15 |
| 2 | Stripe 三档产品配置 + 试用流 | 工程 | 2026-06-20 |
| 3 | Enterprise 报价单 / SoW 模板 | 销售 + 法务 | 2026-06-30 |
| 4 | K3S 私有化部署 SOP（用 aster-deploy 现有任务） | DevOps | 2026-07-15 |
| 5 | 与第一批 3 个 PoC 客户验证定价 | 销售 + 产品 | 2026-08-01 |

---

**版本**：v1.2 · 2026-05-11
**v1.2 变更**：
- 自定义行业 lexicon 设计：补充 ¥3 万 / 年维护费（与 PM 08 商业化条款一致）
- 新增"私有母语 lexicon 翻译"add-on（¥5 万一次性 + ¥2 万 / 年），针对小语种 / 内部术语
- 与 PM 08 lexicon contribution model 完整协同

**v1.1 变更**（保留历史）：
- Pro 起步从"≥ 3 席"改为 **"1 席起步，按需邀请扩容"**（v1.0 老 Team 档已下线，归并入 Pro）
- 新增 §2 Pro 多人协作模型 + 席位计费规则 + SOX 守护规则表
- 新增 v1.1 关键转化点说明（1 → 2 席的 SOX 驱动）
- 关联实施：`aster-cloud` Sprint A-E（plans.ts、SOX 守护、Pro 协作流），见 `aster-deploy/docs/staging/REPORT-v16-pm-alignment-fix.md`

**状态**：内部草案，需与 CEO / CFO / 销售总监评审后定稿
**关联**：`01-one-pager.md` / `02-north-star-metric.md` / `08-lexicon-contribution-model.md`
