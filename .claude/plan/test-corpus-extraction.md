# Plan: 抽出 `aster-lang-test` 共享测试 Corpus 模块

|  |  |
|---|---|
| 计划编号 | step2-test-corpus-extraction |
| 创建日期 | 2026-05-11 |
| 起源 | 双向 inventory 揭示 TS / Java 测试 corpus 平行漂移；用户决议「未来 aster-idea / aster-vscode 重构后也从 aster-lang-test 取测试」|
| 状态 | 草案 — 待用户回 "Y" 后由 `/ccg:execute` 启动 |
| 任务类型 | 全栈（Java + TypeScript + 跨 repo 工程治理） |

---

## 1. 目标（Objective）

把当前散落在 `aster-lang-core/src/test/resources/dual-engine/` 与 `aster-lang-ts/{test,examples}/` 的 .aster 测试样本集中到一个**独立 git 仓库 `aster-lang-test`**，作为：

1. **双引擎等价测试的单一权威 corpus**（Java ANTLR 与 TS PEG 共用）
2. **未来重构的 aster-idea / aster-vscode 的测试源**
3. **community lexicon 贡献者验证 lexicon 时的标准 corpus**（通过 npm + Maven 双发布）

完成定义：任何对语法 / 解析器 / lexicon 的改动 PR，CI 必须用 `aster-lang-test` 当前 release 跑过两端 parser。

---

## 2. 范围（Scope）

### 2.1 In-scope

- 创建 `/Users/rpang/IdeaProjects/aster-lang-test` 新 repo（与现有 aster-lang-* 同级）
- 迁移 390 个 .aster 文件 + 30 个 `.cases.json`（dual-engine inputs）
- 设计 corpus 目录分层 + 元数据 frontmatter（每个 .aster 头注释或同名 .meta.json，标注：tier / engines / capabilities / lexicon）
- 双发布构建：
  - npm package `@aster-cloud/aster-lang-test` (含 corpus + TS loader API)
  - Maven artifact `cloud.aster-lang:aster-lang-test` (含 corpus + Java loader API)
- 改造 `aster-lang-core` 与 `aster-lang-ts` 让它们消费新 artifact
- 改造现有 4 个测试入口（`DualEngineCrossLangTest`、`TsSampleParseInventoryTest`、`policy-converter/round-trip.test.ts`、`java-corpus-parse-inventory.mjs`）
- 在 `aster-lang-test` 仓内置双向 inventory script（可独立运行，不依赖 core/ts 完整构建）
- 更新 RFC §9 与 §10，把 corpus 治理流程文档化

### 2.2 Out-of-scope

- 不动 legacy `aster-lang/` monorepo 的 587 文件（用户已明确不理会）
- 不修复任何当前已识别的等价缺口（那是 Phase 4 的工作）
- 不重构 aster-idea / aster-vscode（用户决议未来重构时再接入）
- 不引入新 sample —— 本计划只做「迁移 + 治理」，新增 sample 走另一 PR

### 2.3 关键边界判断

- **Corpus repo 不含运行引擎**。它只是数据 + 极薄 loader。Java 端 loader 几行 ClassLoader.getResource，TS 端几行 path.join + fs。不能把 parser 依赖反向引入。
- **现有 30 个 dual-engine inputs (.cases.json) 保留 expected output**。这是黄金合约，不动。
- **TS 端 `lossless/` + `comments/` (29 个 pretty-printer goldens) 不迁** —— 这是 TS pretty-printer 的内部 round-trip 数据，不属于双引擎 corpus。留在 aster-lang-ts/test/。

---

## 3. 交付物（Deliverables）

### 3.1 新 repo: `aster-lang-test`

```
aster-lang-test/
├── LICENSE                          # Apache 2.0
├── README.md                        # 使用方式（Java + TS）
├── CONTRIBUTING.md                  # 如何加 sample（必须双引擎都过）
├── corpus/
│   ├── tier1-equivalence/           # 双引擎必须等价的核心集（当前 308 个全通过的子集）
│   │   ├── policies/*.aster
│   │   └── inputs/*.cases.json
│   ├── tier2-divergent/             # 仅一边能解析的；标注哪边能、为什么
│   │   ├── java-only/*.aster        # 7 个（and/or 等）
│   │   └── ts-only/*.aster          # 75 个（//, workflow, lambda 等）
│   └── tier3-fixtures/              # 单端 fixture：parser error / lossless / typecheck-golden
│       └── ...
├── packages/
│   ├── js/                          # @aster-cloud/aster-lang-test (npm)
│   │   ├── package.json
│   │   ├── src/loader.ts            # listSamples() / readSample() / listTier()
│   │   └── src/inventory.ts         # 双向 inventory CLI (调用方注入 parser)
│   └── jvm/                         # cloud.aster-lang:aster-lang-test (Maven)
│       ├── build.gradle.kts
│       └── src/main/java/cloud/aster/test/CorpusLoader.java
├── .github/workflows/
│   ├── release-npm.yml
│   └── release-maven.yml
└── scripts/
    └── classify-existing.mjs        # 一次性脚本：把现有 390 个文件按 inventory 结果分到 tier1/2/3
```

### 3.2 改造现有 repo

| Repo | 改动 |
|---|---|
| `aster-lang-core` | `build.gradle.kts` 加 `testImplementation("cloud.aster-lang:aster-lang-test:0.0.1")`；`DualEngineCrossLangTest` + `TsSampleParseInventoryTest` 从 classpath 取 corpus；删 `src/test/resources/dual-engine/` |
| `aster-lang-ts` | `package.json` 加 `"@aster-cloud/aster-lang-test": "^0.0.1"` 到 devDependencies；`scripts/java-corpus-parse-inventory.mjs` + `test/policy-converter/round-trip.test.ts` 改路径；保留 `test/{lossless,comments}/`（pretty-printer 自有）；迁移 `test/{cnl,e2e,fixtures,policy-converter,lsp-multi,runtime,type-checker}` + `examples/` 到 aster-lang-test |
| `aster-deploy` | 更新 RFC §9 数据来源（指向 aster-lang-test release）；新增 §10 治理流程 |

### 3.3 双向 inventory 升级为 release gate

- aster-lang-test 仓 CI：每次 PR 都跑 `npm test`（拉 aster-lang-ts 最新 release 跑 TS parser）+ `./gradlew test`（拉 aster-lang-core 最新 release 跑 Java parser）
- 如果新 sample 进 tier1 但任一端跑不过 → block PR
- Release tag 触发 npm publish + Maven publish

---

## 4. 关键文件 / 关键改动

| 文件 | 操作 | 说明 |
|---|---|---|
| `aster-lang-test/corpus/tier*/` | 新建 | 390 个 .aster + 30 个 .cases.json 按 tier 重新组织 |
| `aster-lang-test/packages/js/src/loader.ts` | 新建 | Node + browser 都能用的 corpus loader（path glob + fs.readFileSync）|
| `aster-lang-test/packages/jvm/src/main/java/cloud/aster/test/CorpusLoader.java` | 新建 | ClassLoader.getResource 读 jar 内嵌 corpus/* |
| `aster-lang-test/scripts/classify-existing.mjs` | 新建 | 跑过一次后删 —— 把 390 个文件按 §9 inventory 结果落到 tier1/2/3 |
| `aster-lang-core/src/test/java/aster/core/dualengine/DualEngineCrossLangTest.java` | 改 | `resolveResource("dual-engine/inputs")` → `CorpusLoader.listTier("tier1-equivalence").inputs()` |
| `aster-lang-core/src/test/java/aster/core/dualengine/TsSampleParseInventoryTest.java` | 改 | 自动发现 TS 路径换成 `CorpusLoader.listAll().filter(s -> s.engines.contains("ts"))` |
| `aster-lang-ts/scripts/java-corpus-parse-inventory.mjs` | 改 | 从 `@aster-cloud/aster-lang-test` import loader |
| `aster-lang-ts/test/policy-converter/round-trip.test.ts` | 改 | corpus 路径切换 |
| `aster-deploy/docs/rfc/dual-engine-syntax-baseline.md` | 改 | §9 数据来源更新；新增 §10 治理流程 |

---

## 5. 实施步骤（Step-by-step）

### Phase A — 准备（0.5 人日）

1. 创建 GitHub repo `aster-cloud/aster-lang-test`（Apache 2.0，与其他 aster-lang-* 一致）
2. 本地 clone 到 `/Users/rpang/IdeaProjects/aster-lang-test`
3. 初始化 monorepo 结构：根目录 + `corpus/` + `packages/js` + `packages/jvm`
4. 配置 GitHub Actions（CI matrix：Node 22 + JDK 25）

### Phase B — Corpus 分层迁移（1 人日）

1. 写 `scripts/classify-existing.mjs`：
   - 读 RFC §9 inventory 数据（或重跑两个 inventory 脚本）
   - 把 308 个双端都过的 → `tier1-equivalence/`
   - 把 7 个 Java-only + 75 个 TS-only → `tier2-divergent/`
   - 把单端 fixture（parser-error 测试、type-checker golden 等）→ `tier3-fixtures/`
2. 跑脚本，git mv 文件到新位置
3. 每个文件**附 .meta.json** 同名文件（首版只填 tier / source-engine / known-gaps）
4. 把 30 个 .cases.json 拷到 `tier1-equivalence/inputs/`，更新 policy 路径引用

### Phase C — 双发布包（1.5 人日）

1. **npm package** `@aster-cloud/aster-lang-test`：
   - `package.json` 用 pnpm workspace 在根目录维护
   - `src/loader.ts` 暴露：`listSamples(tier?)`、`readSample(rel)`、`readCases(rel)`、`listTier(name)`
   - 发布配置：`"files": ["corpus/**/*", "dist/**/*"]`
2. **Maven artifact** `cloud.aster-lang:aster-lang-test`：
   - `build.gradle.kts` 把 `corpus/` 当 resources 打进 jar
   - `CorpusLoader.java` 同样的 API 形态
3. 两端各写 5 个单测验证 loader 工作正常
4. 本地 `npm pack` + `./gradlew publishToMavenLocal` 验证

### Phase D — 现有 repo 改造（1 人日）

1. **aster-lang-core**：
   - `build.gradle.kts` 加 `testImplementation("cloud.aster-lang:aster-lang-test:0.0.1")` （先 `mavenLocal()` 跑通，发布后再切公开仓库）
   - 改 `DualEngineCrossLangTest` 与 `TsSampleParseInventoryTest` 走 `CorpusLoader`
   - `git rm -r src/test/resources/dual-engine/`
   - `./gradlew test` 验证 181 个 dynamic test 全过；`./gradlew crosslangTest` 仍 74/76（保 disabled list 不变）
2. **aster-lang-ts**：
   - `pnpm add -D @aster-cloud/aster-lang-test`（先 `link:` 本地，发布后切版本号）
   - 改 `scripts/java-corpus-parse-inventory.mjs` + `test/policy-converter/round-trip.test.ts`
   - `git rm -r test/cnl test/e2e test/fixtures test/policy-converter test/lsp-multi test/runtime test/type-checker test/capability-v2.aster test/truffle examples/`
   - **保留** `test/lossless/` + `test/comments/`（pretty-printer 内部）
   - `pnpm test` 全过

### Phase E — 双向 inventory 升级为 release gate（0.5 人日）

1. 把两个 inventory 脚本搬到 `aster-lang-test/scripts/`，依赖注入解析器：
   - `inventory.mjs --parser=ts` 调用 `@aster-cloud/aster-lang-ts` 当前 release
   - `inventory.mjs --parser=java` shell out 到 `./gradlew -Pcorpus=... runInventory`
2. aster-lang-test CI 跑 inventory，更新 README 顶部 badge：`Equivalence: 79.0% (308/390)`
3. 任何 PR 让等价度下降 → block

### Phase F — 发布 + 收尾（0.5 人日）

1. tag `aster-lang-test@0.0.1`
2. 触发 npm + Maven publish workflow
3. aster-lang-core / aster-lang-ts 把 dependency 切到正式 release
4. 更新 RFC §9 数据来源 + 新增 §10「Corpus 治理流程」
5. 写 release notes：迁移背景、消费者改造步骤、对比旧版

### 总工作量：**4-5 人日**

---

## 6. 风险与缓解

| 风险 | 严重度 | 缓解 |
|---|---|---|
| Maven artifact 首次发布配置错（GPG / Sonatype / 仓库地址）导致 aster-lang-core 取不到 | 🟡 中 | 先用 `publishToMavenLocal` 跑通整条链路；公网发布走 GitHub Packages（与 aster-lang-en/zh/de 现有发布通道一致）|
| 现有 30 个 .cases.json 里硬编码了 .aster 文件名（如 `"policy": "01-arithmetic-add.aster"`）—— 路径变了 cases 找不到 policy | 🔴 高 | classify-existing 脚本同步 rewrite `.cases.json` 里的 policy 字段，加 tier 前缀 |
| `pnpm add -D @aster-cloud/aster-lang-test` 在 aster-lang-ts 引入循环依赖（test 依赖发布物，发布物又得用 ts parser 测自己）| 🟡 中 | 双发布顺序：先发 aster-lang-test 0.0.1（不验证）→ aster-lang-ts 取它 → 下一版 aster-lang-test 用 aster-lang-ts release 当 dep 跑 inventory |
| `DualEngineCrossLangTest` 当前用 `Files.list` 遍历 inputs 目录 — 切到 classpath jar 后 Files.list 不能直接列 jar | 🟡 中 | `CorpusLoader.listTier()` 内部用 ClassLoader.getResources 枚举；Java 端 loader 一次性把所有 entry path 列出来再 forEach |
| Legacy aster-lang/ 已死但被某些 build script 引用 | 🟢 低 | 不动它；如果有 build 引用，留 dangling reference 不阻塞本计划 |
| 用户未来重构 aster-idea / aster-vscode 时发现 corpus 还差关键 sample | 🟢 低 | 那时候新增 sample 走正常 PR 流程；本计划只做迁移不预判未来需求 |
| 当前 75 个 TS-only failures 里有些其实是 sample 本身有 bug（不是 Java 缺特性）| 🟡 中 | tier2 的 .meta.json 必须填 `divergence-type: "grammar-gap" \| "sample-bug" \| "intentional"`；首版可以全标 grammar-gap，Phase 4 实施 grammar fix 时再分类 |
| 79% 等价度变成 README badge 后给外部观感差 | 🟢 低 | README 同时显示 tier1 通过率（100% / 308 个）—— 那个才是「健康双引擎 corpus」的真实度量 |

---

## 7. 验收清单

- [ ] `aster-lang-test` repo 已创建，CI 绿
- [ ] 390 个 .aster + 30 个 .cases.json 全部迁入，按 tier1/2/3 分层
- [ ] `@aster-cloud/aster-lang-test@0.0.1` 已发 npm
- [ ] `cloud.aster-lang:aster-lang-test:0.0.1` 已发 Maven（或 GitHub Packages）
- [ ] `aster-lang-core` 改造完成：`./gradlew test` + `./gradlew crosslangTest` 数字与迁移前一致
- [ ] `aster-lang-ts` 改造完成：`pnpm test` + `pnpm test:converter` 全过
- [ ] 双向 inventory 在 aster-lang-test CI 自动跑，等价度 ≥ 当前基线 79.0%
- [ ] RFC §9 数据来源指向 aster-lang-test；新增 §10 治理流程
- [ ] release notes 已发 GitHub

---

## 8. 后续（Phase 4 衔接点）

本计划完成后：

- **Phase 4 W1-W5 缺口实施**（RFC §9.6）每次 grammar 改动 PR 都跑 aster-lang-test inventory，逼出回归
- **aster-idea / aster-vscode 重构**时 `add devDependency: @aster-cloud/aster-lang-test`，按 tier1 fixture 写新 IDE 测试
- **行业 lexicon PoC**（Phase 3E-3 留的）扩展 corpus 时加 `tier4-industry/finance/` 等子目录
- **Community lexicon 贡献者**（aster-lang-template README）用 aster-lang-test 当 "is your lexicon compatible" 的标准

---

## 9. SESSION_ID

本计划没有调用过外部模型（codex/codex）—— Step 1 完整在主对话内完成。`/ccg:execute` 启动时如需要 codex 协助拆 Phase B 的 classify 脚本细节，可创建新 session。

- CODEX_SESSION: （未创建）
- GEMINI_SESSION: （未创建）

---

## 10. 待用户确认的决策点

执行前请确认以下几点（这些会影响 plan 的细节而非整体方向）：

1. **repo 命名**：`aster-lang-test` ✅ / 还是 `aster-lang-corpus` / `aster-lang-test-corpus`？
2. **发布渠道**：Maven artifact 走 GitHub Packages（与 aster-lang-en/zh/de 一致）✅ / 还是 Sonatype Maven Central？
3. **monorepo 还是双 repo**：一个 repo 用 packages/js + packages/jvm 子目录 ✅ / 还是拆 aster-lang-test-js + aster-lang-test-jvm 两个 repo？
4. **是否保留 tier3-fixtures**：parser-error / typecheck-golden 这些单端 fixture 是搬过来 ✅ / 还是留在 aster-lang-ts 不动？
5. **`.meta.json` 还是头注释 frontmatter**：每个 .aster 同名 `.meta.json` ✅ / 还是把元数据写进 .aster 头部 `#---\n# tier: 1\n#---`？

打 ✅ 是我建议的默认值。

---

**📋 计划已生成并保存至 `aster-deploy/.claude/plan/test-corpus-extraction.md`**

**请审查上述计划，您可以：**
- 🔧 **修改计划**：告诉我需要调整的部分（含 §10 的决策点），我会更新计划
- ▶️ **执行计划**：复制以下命令到新会话执行

```
/ccg:execute aster-deploy/.claude/plan/test-corpus-extraction.md
```
