# Aster Lang 产品文档（PM 索引）

> 产品视角的"事实来源"。工程文档在 `aster-deploy/docs/`，本目录是产品 / 增长 / 商业化的工作底稿。

---

## 文档导航

| # | 文档 | 用途 | 受众 |
|---|---|---|---|
| 01 | [One Pager](./01-one-pager.md) | 一页讲清 Aster 是什么 | 全员、投资人、销售 |
| 02 | [北极星指标](./02-north-star-metric.md) | 定义 NSM、指标树、目标线 | 产品、增长、工程 |
| 03 | [埋点规格](./03-telemetry-spec.md) | 4 事件 + source_kind 实现规格 | 工程、产品、数据 |
| 04 | [可用性测试方案](./04-usability-test-plan.md) | 5 人业务专家测试 SOP | 产品、设计、用研 |
| 05 | [定价与部署矩阵](./05-pricing-packaging.md) | Free / Pro / Enterprise 三档 | 销售、商业化、CFO |

招募 / 测试执行包：

| 文档 | 用途 |
|---|---|
| [recruiting/W1-recruiting-kit.md](./recruiting/W1-recruiting-kit.md) | 招募邮件、问卷、排期、主持人脚本 |
| [recruiting/staging-checklist.md](./recruiting/staging-checklist.md) | 测试环境准备 9 节 checklist |
| [recruiting/consent-form.md](./recruiting/consent-form.md) | 录屏知情同意书模板 |

---

## 优先级与依赖

```
P0  01-one-pager  ←──────────────┐
                                 │ (统一叙事)
P0  02-north-star-metric  ←──────┤
                                 │
P1  03-dev-portal-readme         │ (在 aster-lang-dev 仓库)
                                 │
P1  04-usability-test-plan  ←────┤
                                 │
P2  05-pricing-packaging  ←──────┘
```

01 + 02 是其他文档的基础叙事/数据来源；03 已落地到 aster-lang-dev README + 落地页；04 + 05 依赖 01/02 的语境。

---

## 维护规则

1. **每季度复盘一次**：02 的目标线、05 的价格锚点至少季度更新。
2. **重大产品发布前回看 01**：避免 One Pager 与产品现状脱节。
3. **可用性测试报告**：04 执行完成后产出 `04-usability-test-report.md`（同目录）。
4. **指标变更需评审**：02 的 NSM 一年内不应变化，子指标可随产品演进调整。

---

**最后更新**：2026-05-10
