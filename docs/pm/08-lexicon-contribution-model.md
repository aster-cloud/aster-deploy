# Lexicon 贡献模型与多语种生态战略 v1.0

> 把"多语种 lexicon"从一个产品功能，正式升级为 **Aster Lang 的网络效应护城河**。
> 受众：核心团队、社区贡献者、Enterprise 销售、投资人。

---

## 1. 战略定位

**Aster Lang 的真正护城河不是 CNL 编译器，而是 lexicon 生态可扩展性。**

CNL 编译器（aster-lang-core / aster-lang-truffle / aster-lang-ts）是工程能力的体现，可被竞品 12-18 个月内追平。
但 **"母语写规则"作为一等公民 + 社区可扩展** 的产品架构，需要竞品 24-36 个月重写 lexer/parser/canonicalizer 三层才能复制，且**先发优势会持续积累**——已收录的语种越多，新贡献者越倾向于在 Aster 生态下做（不会另立新生态）。

### 1.1 对标参照系

| 平台 | 生态模式 | Aster 类比 |
|---|---|---|
| **VS Code** | Marketplace + 第三方 language extensions | aster-cloud + 第三方 lexicon |
| **Tree-sitter** | 每种语言独立 grammar 仓库（tree-sitter-{python, rust, ...}）| aster-lang-{en, zh, de, ...} |
| **Babel / SWC** | 插件机制 + plugin author 社区 | LexiconPlugin SPI + lexicon author 社区 |
| **JetBrains Plugin Marketplace** | 商业 + 社区双轨 | 官方 lexicon（en/zh/de）+ 社区 lexicon（ja/fr/es/...） |

**核心结论**：lexicon 三个独立 repo **不是工程债**，而是 **product-as-platform** 的物理边界——每个 lexicon 是一个独立 release cadence、独立 reviewer 治理边界、独立 licensable artifact。

---

## 2. 现状盘点（2026-05-11）

### 2.1 技术基础（✅ 已就位）

| 资产 | 位置 | 状态 |
|---|---|---|
| SPI 接口 | `aster-lang-core` `aster.core.lexicon.LexiconPlugin` | ✅ 生产 |
| SPI 注册机制 | `META-INF/services/aster.core.lexicon.LexiconPlugin` | ✅ ServiceLoader 自动发现 |
| Lexicon JSON schema | `keywords` + `markerKeywords` + `punctuation` + `canonicalization` | ✅ 稳定 |
| 词汇表（vocabularies）| 行业术语 JSON（`finance-loan-en-US.json`、`insurance-auto-en-US.json` 等）| ✅ 可扩展 |
| Overlays | `type-inference-rules.json` / `lsp-ui-texts.json` | ✅ 可扩展 |
| Canonicalizer 多语言 | `Canonicalizer + LexiconRegistry.getOrThrow(...)` | ✅ 生产 |
| 官方 lexicon | en-US、zh-CN、de-DE | ✅ 生产 |

### 2.2 生态基础（🔴 完全缺失）

| 资产 | 状态 | 影响 |
|---|---|---|
| **LICENSE 文件** | ❌ aster-lang-{en,zh,de} 三个 repo 均无 LICENSE | 🔴 法律阻碍：贡献者无法判断能否贡献 |
| **CONTRIBUTING.md** | ❌ 无 | 🔴 流程阻碍：新贡献者无入口 |
| **aster-lang-template** repo | ❌ 不存在 | 🔴 启动阻碍：贡献者需 reverse-engineer en/zh/de 才能开始 |
| **Lexicon 校验工具** | ✅ **Phase 1 已交付**：`aster.core.lexicon.tools.LexiconContributorValidator` + `LexiconValidatorCli` 提供结构化报告 + Gradle task 集成 | — |
| **CI 模板** | ❌ 无统一 lexicon-repo CI 模板 | 🟡 工程阻碍：每个 lexicon 重复 CI 配置 |
| **公开 roadmap** | ❌ 无 "Wanted Languages" 看板 | 🟡 awareness 阻碍：社区不知道可以贡献 |
| **贡献者激励** | ❌ 无 credits / steward 标签 / platform credit | 🟡 动机阻碍：纯志愿不可持续 |

**核心矛盾**：技术上**今天**就能接受第三方 lexicon PR；运营/法务上**今天**贡献者还无法启动。

---

## 3. 贡献模型设计

### 3.1 贡献者旅程

```
   发现             准备             贡献              发布
   ─────            ────             ────              ────
   aster-lang.dev → fork template → 翻 keyword YAML → PR + CI 通过
   "Wanted Lang"    aster-lang-     运行 validator    Aster team review
   看板看到 ja        template       (本地 gradle)     合并 → maven central
   想贡献日语                                          → aster-cloud 自动启用
```

### 3.2 三条贡献路径

| 路径 | 控制 | Aster 介入 | 适用场景 |
|---|---|---|---|
| **官方 lexicon** | Aster team 直接维护 | 100% | en/zh/de（核心市场语种） |
| **官方背书 lexicon** | Community PR + Aster team review + merge to aster-cloud/* org | Review + 安全审计 + tag for official distribution | ja/fr/es/pt-BR/ar/ru/ko 等主流语种 |
| **社区维护 lexicon** | Community 自有 GitHub 组织 + 自有 maven coord | 仅文档收录，不背书 | 长尾语种（hi/sw/tl/...）或行业 dialect lexicon |

### 3.3 LexiconPlugin SPI 契约（不变量）

> 贡献者**必须**遵守的稳定接口（更改将作为 breaking change 提前 6 个月废弃通告）

```java
public interface LexiconPlugin {
    Lexicon createLexicon();
    default Map<String, Supplier<SyntaxTransformer>> getTransformers() { return Map.of(); }
    default List<String> getOverlayResources() { return List.of(); }
}
```

**Lexicon JSON 必填字段**：
- `meta.id`（IETF BCP 47，如 `ja-JP`）
- `meta.name`（语种自身的名字，如 `日本語`）
- `meta.direction`（`LTR` 或 `RTL`）
- `keywords.*`（**完整** keyword token set，与 en-US.json 一一对应）
- `markerKeywords.*`（如适用）
- `punctuation`（语种约定的标点）

**Lexicon 可选字段**：
- `vocabularies/*.json`（行业术语，如 finance-loan-ja-JP.json）
- `overlays/type-inference-rules.json`
- `overlays/lsp-ui-texts.json`（LSP UI 翻译）
- `overlays/diagnostic-messages.json`（错误诊断翻译）

### 3.4 lexicon 完整性校验（机器可执行）

新贡献者运行 `./gradlew :validateLexicon` 应通过以下检查：

| 检查项 | 规则 | 失败动作 |
|---|---|---|
| keyword 集合完整 | 与 `aster-lang-en` 的 keywords 集合 1:1 对应（不允许少 key） | FAIL |
| keyword 唯一性 | 同一 lexicon 内不同 key 不得映射到同一字符串 | FAIL |
| reserved chars 不冲突 | keyword 不得包含 `[](),.;` 等 Aster 语法保留字符 | FAIL |
| 与 en lexicon 语义等价 | 同样的黄金测试 policy 在新 lexicon 下解析为相同的 Core IR JSON | FAIL |
| punctuation 合理 | 必须显式声明 list/range/decimal 分隔符 | FAIL |
| meta.id 合法 | IETF BCP 47 格式 | FAIL |
| direction 合法 | LTR / RTL 二选一 | FAIL |
| vocabulary IDs 不冲突 | 同名 vocabulary 在不同语种间 ID 可相同（语种内唯一）| FAIL |
| overlay JSON schema | 通过 aster-lang-validation 的 JSON schema 校验 | FAIL |

校验工具放入 **aster-lang-core** 模块 `aster.core.lexicon.tools` 子包（不放 `aster-lang-validation`，因为该模块语义是业务策略校验 `io.aster.validation`，与 lang lexicon 校验语义冲突）。

**实际类名**（Phase 1 实施完成 2026-05-11）：
- `aster.core.lexicon.tools.LexiconContributorValidator` — 面向贡献者的结构化校验（ERROR/WARNING/INFO + suggestion）
- `aster.core.lexicon.tools.LexiconValidationReport` — 校验报告 record
- `aster.core.lexicon.tools.LexiconValidatorCli` — CLI 入口（贡献者通过 `./gradlew validateLexicon` 调用）

与既有的 `aster.core.lexicon.LexiconValidator`（内部静态工具类）并存且互补——后者面向 core 自检，前者面向社区贡献者。

---

## 4. 实施路线图

### Phase 1：法务 + 模板（0-4 周，P0）

| # | 任务 | 负责 | 验收 |
|---|---|---|---|
| 1.1 | aster-lang-{en,zh,de,core,truffle,ts,runtime,validation} **加 Apache 2.0 LICENSE 文件** | 法务 / Eng | 8 个 repo 均含 LICENSE + README 链接 |
| 1.2 | 创建 `aster-lang-template` repo | Eng | repo 含：build.gradle.kts、SPI manifest 占位、JSON 模板、CI 模板、CONTRIBUTING.md、README |
| 1.3 | 为 aster-lang-en 写 **CONTRIBUTING.md**（reference） | Eng + PM | 含：fork → translate → validate → PR 四步 + lexicon JSON 字段说明 |
| 1.4 | `LexiconValidator` CLI + Gradle task | Eng | `./gradlew validateLexicon` 在 en/zh/de 全通过；故意破坏后报错明确 |
| 1.5 | aster-lang-template README 含 **"从零写新 lexicon"15 分钟教程**（含视频/截图）| PM + Eng | 链接到 aster-lang.dev |

### Phase 2：roadmap + awareness（4-8 周，P0）

| # | 任务 | 负责 | 验收 |
|---|---|---|---|
| 2.1 | aster-lang.dev 新增 `/community/lexicons` 页面 | 增长 + Eng | 含：已收录 lexicon 列表（状态徽章）+ Wanted Languages 看板 |
| 2.2 | "Wanted Languages" 投票机制 | 增长 | GitHub Discussions + 票数排序，初始候选：ja/fr/es/pt-BR/ar/ru/ko |
| 2.3 | 每个 lexicon repo README 顶部加状态徽章 | Eng | `[![official]] [![ci]] [![lexicon-coverage]]` |
| 2.4 | 官方博客发布 `Introducing Aster Lexicon Contribution Model` | PM + 增长 | 博客 + LinkedIn / Hacker News / Reddit /r/programming 推广 |
| 2.5 | docs 站翻译指南（中文 + 英文双语，便于多语种贡献者）| PM | 仅文档贡献流程，先英文 + 中文 |

### Phase 3：激励 + 第一例（8-24 周，P1）

| # | 任务 | 负责 | 验收 |
|---|---|---|---|
| 3.1 | 招募 2 名 **paid lexicon authors**（如 ja/fr，每语 ¥8,000-¥15,000 一次性 + ¥3,000/年维护）| BD | ja + fr lexicon 6 个月内进 staging |
| 3.2 | "Aster Language Steward" 计划：合并 2+ lexicon 或维护 1 lexicon 12+ 月 → 标签 + ¥200/年 platform credit | PM + 增长 | 至少 3 人获标签 |
| 3.3 | 第一个**纯社区贡献**的 lexicon 进 staging | 社区 | 来自非 Aster 团队成员的 PR 被合并 |
| 3.4 | 案例分享：第一个 lexicon 贡献者博客采访 | PM | 1 篇深度 case study |

### Phase 4：Enterprise 化（24-52 周，P2）

| # | 任务 | 负责 | 验收 |
|---|---|---|---|
| 4.1 | **Custom Industry Lexicon** 商业化（医疗 / 航司 / 油气 / 政企）| BD + PM | 报价：¥10 万/语种 一次性 + ¥3 万/年维护（写入 PM 05） |
| 4.2 | 至少 1 家 Enterprise 客户签下 custom lexicon 项目 | BD | 合同金额 + 案例 |
| 4.3 | lexicon SPI ABI 版本化（`@SinceLexiconAbi("1.0")`） | Eng | core 启动时校验 ABI 兼容性，旧 lexicon 自动隔离 |
| 4.4 | community-maintained lexicon 数量达到总数 30% | 增长 | dashboard 追踪 |

---

## 5. 商业模式集成

### 5.1 PM 文档 05 v1.2 更新建议

**Enterprise 档新增卖点**：
```diff
| 自定义 lexicon（行业垂类术语） | ✅ |
+ | Custom industry lexicon（医疗/航司/油气/政企）| ✅（¥10 万 一次性 + ¥3 万/年） |
+ | 母语 lexicon 委托翻译（小语种）| ✅（¥5 万 一次性 + ¥2 万/年） |
```

**Add-on 表新增**：
```diff
+ | 自定义 lexicon 设计 | Enterprise | ¥10 万 / 个 | 行业术语包：医疗 / 航司 / 油气 / 政企 |
+ | 私有 lexicon 翻译 | Enterprise | ¥5 万 / 个 | 客户内部术语 lexicon + 维护 |
```

### 5.2 销售故事（30 秒电梯版）

> "你们的合规规则要不要用日语写？要不要用阿拉伯语 RTL？要不要用医疗专业术语而非通用词汇？
>
> Aster 的 lexicon 是**插件**：英中德开箱即用，社区还在贡献日法西葡，Enterprise 客户可以委托我们定制行业 lexicon——
> 你的精算师、临床医师、风控官，用**自己的母语 + 行业术语**写规则。
>
> 这是别人 24 个月追不上的差异化。"

### 5.3 防御措施（避免护城河被挖）

| 威胁 | 防御 |
|---|---|
| 竞品 fork Aster + 自己社区运营 | Apache 2.0 允许 fork，但**官方背书 + maven central 正版**形成 trust signal；fork 难以建立同等社区信任 |
| 竞品自建多语种 | 重写 lexer/parser/canonicalizer 三层是 12-18 人月起；Aster 已生产；时间差不可逆 |
| Lexicon 贡献者被挖走 | Apache 2.0 允许，但 Aster 提供 maven 发布渠道 + 平台 credit + steward 身份；纯志愿不可持续，竞品也难复制激励 |
| Custom lexicon 商业模型被绕过 | 客户可以自写 lexicon，但**vocabulary 调优 + 黄金测试 + LSP 集成**是工程量；¥10 万 一次性低于客户自做的人天成本 |

---

## 6. KPI 与北极星指标关联

### 6.1 Lexicon 生态健康指标

| 指标 | Q2 2026 | Q3 | Q4 | Y2 |
|---|---|---|---|---|
| 官方 lexicon 数 | 3（en/zh/de） | 3 | 5（+ja/fr） | 8 |
| 社区贡献 lexicon 数 | 0 | 1 | 3 | 10 |
| Enterprise custom lexicon 数 | 0 | 1 | 2 | 8 |
| 月度 lexicon contribution PR | 0 | 2 | 5 | 15 |
| Lexicon Stewards 数（活跃） | 0 | 1 | 3 | 10 |
| Lexicon contribution ARR | ¥0 | ¥10 万 | ¥30 万 | ¥150 万 |

### 6.2 与 NSM (WAADR) 的关联

- **每新增一个 lexicon → 解锁一个语种市场** → WAADR 子指标 "Prompt → 草稿转化率" 在该语种市场起步
- **Custom industry lexicon → 解锁一个行业垂类** → 行业内 WAADR 增长更快（术语已贴近场景）
- **Steward 计划 → 把核心贡献者变成布道者** → "Awareness" 漏斗指标改善

---

## 7. 风险与缓解

| 风险 | 严重度 | 缓解 |
|---|---|---|
| 社区贡献的 lexicon 质量不一致 | 🔴 高 | LexiconValidator 强制 CI；review checklist；24 小时 reviewer SLA |
| Apache 2.0 允许 fork，担心生态分裂 | 🟡 中 | 通过"官方背书 + maven central + 商业支持"建立 trust signal；接受小规模 fork 作为生态生命力证明 |
| 贡献者长期维护流失 | 🟡 中 | Steward 平台 credit + community 文档归档 + 至少 1 名 Aster team 副 maintainer 兜底 |
| custom lexicon 报价过低 / 过高 | 🟡 中 | Phase 4 启动前先做 3 家客户访谈摸底报价；锁定后通过 add-on 标准化 |
| SPI ABI 不稳定导致 lexicon 大面积坏 | 🔴 高 | Phase 4.3 ABI 版本化；breaking change 提前 6 个月废弃通告；ABI v1 至少保证 18 个月不变更 |
| 法律风险：lexicon 中含他方版权术语 | 🟡 中 | CONTRIBUTING.md 明确 DCO + 行业术语来源声明；高敏术语（如制药商标）由 Aster team 法务 review |

---

## 8. 决策记录

| 决策 | 状态 | 决策者 | 理由 |
|---|---|---|---|
| Lexicon 保持三个独立 repo | ✅ 确认（2026-05-11） | 创始团队 | 可插拔 + 社区贡献边界 + release 独立 |
| 不合并到 monorepo | ✅ 确认（2026-05-11） | 创始团队 | 推翻 BA 早期"省 30% 工程效率"建议 |
| Lexicon 采用 Apache 2.0 license | ⏳ 待定 | 创始团队 + 法务 | 建议 Apache 2.0（与 Tree-sitter/Babel 对齐） |
| Custom industry lexicon 价格 ¥10 万/语种 | ⏳ 待定 | BD + PM | 需 3 家客户访谈验证 |
| 启动 Phase 1（法务 + 模板） | ⏳ 待批准 | 创始团队 | 4 周工程量 |

---

## 9. 关联文档

- `01-one-pager.md` — 公司一页纸（建议 v1.1 加入 lexicon 生态作为核心差异化）
- `05-pricing-packaging.md` — Pricing v1.1（Phase 4 升 v1.2 增加 custom lexicon 加购项）
- `aster-lang-core` / `LexiconPlugin.java` — SPI 接口源
- `aster-lang-template`（待建） — 贡献者模板 repo

---

**版本**：v1.0 · 2026-05-11（定稿）
**作者**：Claude（基于创始团队"lexicon 是社区扩展的可插拔架构"决策起草）
**状态**：已定稿。Phase 1 已完成法务 LICENSE + template repo + LexiconContributorValidator + 三语 CONTRIBUTING + aster-lang.dev community 板块骨架。
**Phase 1 关联实施**：见 `aster-api/.claude/plan/ba-ta-remediation-phase1.md`。

**修正记录**：
- §2.2「Lexicon 校验工具」状态由"🟡 部分"更新为"✅ Phase 1 已交付"
- §3.4 校验工具位置由"aster-lang-validation"修正为"aster-lang-core 的 lexicon.tools 子包"（理由：避免与 io.aster.validation 业务校验语义冲突）
