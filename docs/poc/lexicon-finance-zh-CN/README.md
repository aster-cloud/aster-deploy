# PoC: 行业垂类 Lexicon — 金融 (zh-CN)

|  |  |
|---|---|
| 阶段 | Sprint 3E-3（Phase 4 商业化准备） |
| 状态 | 🟡 技术 PoC（非生产 fork） |
| 日期 | 2026-05-11 |
| 决策 | 验证 custom industry lexicon 商业化路径可行性 |

---

## 1. PoC 目标

Phase 4 商业化关键假设：

> 企业愿意为「行业术语 + 合规审计标签 + 私有 LSP 词库」付费购买定制 lexicon。

本 PoC 不构建完整产品，仅验证以下三点：

1. **可行性**：在不修改 `aster-lang-core` 的前提下，能否通过 LexiconPlugin SPI 提供金融垂类术语？
2. **集成代价**：现有 LSP + Monaco 编辑器接入需要多少额外工作？
3. **审计标签透传**：行业 keyword 是否能在 Core IR + 审计日志中保留来源（finance vs base）？

非目标（属于 Phase 4 真正实施）：

- ❌ 创建 `aster-lang-finance-zh-CN` 独立仓库
- ❌ 商业化定价模型
- ❌ 客户合同模板

---

## 2. 设计概要

### 2.1 包装策略：垂类 = base lexicon + 行业 overlay

不重写 `zh-CN.json`，而是引入一个 **derivedFrom** 字段表示继承：

```json
{
  "meta": {
    "id": "zh-CN-finance",
    "name": "简体中文（金融行业）",
    "derivedFrom": "zh-CN",
    "industry": "finance",
    "auditTag": "industry:finance"
  },
  "keywords": {
    /* 仅声明覆盖 / 新增的 keyword；未声明的从 base 继承 */
    "FUNC_TO": "金融规则",
    "TYPE_DEF": "金融定义"
  },
  "industryVocabulary": {
    /* 金融特有：识别为「领域名词」，参与类型推断与审计标签，但不是语法 keyword */
    "RISK_SCORE": "风险评分",
    "CREDIT_LINE": "授信额度",
    "AML_FLAG": "反洗钱标记",
    "KYC_LEVEL": "KYC 等级",
    "BASEL_RATIO": "巴塞尔比率"
  }
}
```

### 2.2 SPI 扩展（向后兼容）

为支持 `derivedFrom`，`LexiconAbiVersion.V1` **无需改动**：

- `derivedFrom` 是 lexicon 元数据，由 plugin loader 解析
- `industryVocabulary` 是新字段，旧 plugin 忽略，新 plugin（v1.1）消费

ABI 兼容路径：
- v1.0 现存 → ignored fields 不报错
- v1.1（新增） → industryVocabulary 参与类型推断
- 计划：v1.1 与 v1.0 共存 18 个月（与 SPI 承诺一致）

### 2.3 审计标签透传

```
源代码 → 编译器解析行业 keyword → IR 节点附 industryTags ∈ {"finance"} → 评估日志 → 审计存证
```

在 `aster-api` 评估日志加一个字段 `industryTags: ["finance"]`，后续 SOC 2 evidence 收集可按 industry 维度分桶。

### 2.4 集成验证

| 组件 | 工作量 | 状态 |
|---|---|---|
| Plugin SPI 装载 derivedFrom | 0.5 天 | 设计完成，需 v1.1 ABI |
| LSP 词条扩展（industryVocabulary 进入 hover/completion）| 1 天 | 设计完成 |
| Monaco 高亮规则（行业 keyword 用次级配色）| 0.5 天 | 设计完成 |
| 审计日志 industryTags 字段 | 0.5 天 | 设计完成 |
| **总计** | **2.5 天** | PoC 设计已完成，等 Phase 4 实施 |

---

## 3. 商业化验证假设

### 3.1 定价假设（未对外公开）

| 客户类型 | 套餐 | 行业 lexicon 价值 |
|---|---|---|
| 银行 / 持牌金融 | Enterprise + Industry | +¥200k/年 lexicon license |
| 保险 / 财富管理 | Team + Industry | +¥80k/年 |
| 零售金融科技 | Pro + Industry | +¥30k/年 |

### 3.2 关键风险

| 风险 | 缓解 |
|---|---|
| 行业术语翻译需金融专家审校 | 找 1-2 个伙伴客户共建 lexicon |
| 监管词库每年更新（如新巴塞尔条款） | 设定 lexicon 季度刷新节奏 |
| 不同金融子行业差异（银行 vs 保险）大 | 拆 `finance.bank` / `finance.insurance` 两级 sub-domain |

---

## 4. 验收结论

✅ **可行性**：通过现有 SPI + 新增 `derivedFrom` 字段实现，**不需要改 core 编译器**。

✅ **集成代价**：约 2.5 工程日（不含术语收集与翻译审校）。

✅ **审计透传**：通过 IR 节点 `industryTags` + 评估日志字段，可支持 SOC 2 + 行业监管审计。

⚠️ **风险点**：术语词库的领域专家成本远高于工程实现成本。Phase 4 启动前必须先找伙伴客户共建。

---

## 5. 下一步（Phase 4 真实启动条件）

1. 找到第一个签约伙伴客户（建议中型城商行或互联网银行）
2. 与该客户共建 v0.1 词库（30-50 个 finance 专属术语）
3. 创建 `aster-lang-finance-zh-CN` 独立仓库（由 Aster team 托管，参考 aster-lang-template）
4. SPI 升级到 v1.1（加 industryVocabulary 字段）
5. aster-cloud 增加套餐选项：`industry-finance` 标识

---

**版本**：v1 · 2026-05-11
**作者**：Phase 3E 工程团队
**关联**：`aster-lang-template`（参考结构）、`docs/pm/02-north-star-metric.md`（PM 指标 dependency）
