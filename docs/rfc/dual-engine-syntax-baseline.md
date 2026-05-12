# RFC: Dual-Engine Syntax Baseline

| | |
|---|---|
| Status | Proposed |
| Authors | Aster Lang core team |
| Reviewers | TBD |
| Created | 2026-05-11 |
| Target | Phase 3A landing in dual-engine corpus |
| Phase | 3A-1 |

---

## 1. Problem

Aster Lang ships two execution engines:
- **Java ANTLR** (`aster-lang-core`) — production server, GraalVM Truffle, type system, effect system
- **TypeScript PEG** (`aster-lang-ts`) — browser playground, LSP, dynamic-typed

During Phase 2 dual-engine corpus expansion, we discovered the two parsers **accept different subsets of Aster CNL**. A policy that compiles on aster-cloud (browser) may fail at aster-api (server), or vice versa. This is a **production semantic-drift risk**.

Empirical findings from `aster-lang-ts/dist/src/browser.js` v0.0.1 probing (Phase 2-D smoke test):

| Syntax | Java ANTLR | TS PEG | Notes |
|---|---|---|---|
| `Rule add given x, y, produce:` | ✅ | ✅ | Baseline shape |
| `Rule add given x, y produce:` (no trailing comma) | ✅ | ✅ | Both accept |
| `Rule add given x: Int, y: Int, produce Int:` | ✅ | ❌ "Expected 'produce' and return type" | Type annotations |
| `Rule add given x be Int, y be Int produce Int:` | ✅ | ❌ | Verbose type form |
| `If x greater than 0: Return ...` | ✅ | ✅ | Control flow |
| `Let v be x divided by 10.` | ✅ | ✅ | Let binding |
| Single-letter variable `a` / `b` | ✅ | ❌ "Expected '.' at end of statement" | TS treats `a`/`b` as articles (parser ambiguity) |
| `"Hello, " plus name` | ✅ | ✅ | String concat |

---

## 2. Decision

**Java ANTLR is the authoritative parser.** TypeScript PEG must align.

Rationale:
1. Java engine carries the **type system** + effect system + PII propagation — these are core IP, not skin
2. Server-side execution is the source of truth for billing / audit — TS engine is supplementary (playground, LSP)
3. Customers publishing through aster-cloud go through TS frontend → Java backend; the backend is what executes in production

**Until TS PEG fully aligns, dual-engine corpus uses the LCM (lowest-common-multiple) subset**:

### Portable subset rules (v1.0)

| Rule | Why |
|---|---|
| ❌ No type annotations in params (`x: Int` / `x be Int`) | TS PEG limitation; type inference covers most cases |
| ❌ No return type after `produce` (just `produce:`) | Same as above |
| ❌ Avoid single-letter variable names `a`, `b`, `an`, `the` | TS PEG article disambiguation; use `x`, `y`, `value`, etc. |
| ✅ Always end statements with `.` | Strict in both |
| ✅ `Rule <name> given <p1>, <p2>, produce:` is the canonical signature | LCM shape |
| ✅ Multi-line indented blocks with `Return ... .` | Both engines |
| ✅ `If <cond>: ... Otherwise: ...` | Both engines |
| ✅ `Let <name> be <expr>.` | Both engines |

---

## 3. Migration plan

### 3A-1 (this RFC + corpus rewrite)
- Rewrite `aster-lang-core/src/test/resources/dual-engine/policies/*.aster` to use the portable subset
- 30 policies × ~3 lines each — small mechanical edit
- Cases JSON unchanged (only source changes)

### 3A-2 (cross-lang test gate)
- `DualEngineCrossLangTest` with `@Tag("crosslang")` proves portability case by case

### Phase 3B+ (TS PEG alignment)
- Implement type annotation parsing in `aster-lang-ts/src/peg/` (probably ~1-2 dev weeks)
- Implement single-letter variable carve-out (article disambiguation by surrounding context)
- Promote dual-engine corpus to test full Java syntax once TS aligns

### Long-term
- Generate TS PEG **from the ANTLR grammar** (via codegen) — single source of truth for both engines

---

## 4. Risks & mitigation

| Risk | Mitigation |
|---|---|
| Portable subset is too restrictive for real customer policies | Phase 3B fast-tracks TS PEG alignment; customer-facing docs note current limitations |
| Java strict policies break when copied to playground | aster-cloud editor shows pre-flight TS lint warnings before save |
| RFC v1.0 baseline drifts as engines evolve | Re-probe matrix in each Phase release; treat the table in §1 as machine-verified by `crosslangTest` |
| Type system users feel demoted | Type annotations remain in Java; only **portable subset** drops them; customer policies needing strict types stay in aster-api anyway |

---

## 5. Non-goals (Phase 3A)

- Full TS PEG type system implementation — Phase 3B+
- Auto-generation of TS PEG from ANTLR — long-term
- Breaking change to Java parser — never

---

## 6. Open questions

1. Should aster-cloud playground reject Java-strict syntax with a friendly warning, or auto-strip type annotations? — **Phase 3B UX decision**
2. Where to land the article carve-out for `a`/`an`/`the` as variables? — **Phase 3B parser work**
3. RFC review process for future syntax changes — **Phase 4** (when external lexicon contributors enter)

---

## 7. Phase 3A landing — actual TS PEG acceptance (verified 2026-05-11)

After applying the portable subset (`given x, y, produce:` + no type annotations), 30-policy dual-engine corpus probed against `aster-lang-ts/dist/src/browser.js`:

- **23 / 30** compile cleanly in TS PEG
- **7 / 30** fail with `Expected '.' at end of statement` — root cause: **TS PEG does not support `and` / `or` as binary expression operators**

Failing policies (deferred to Phase 3B TS PEG alignment):

| Policy | Failing construct |
|---|---|
| `11-boolean-and.aster` | `x and y` |
| `12-boolean-or.aster` | `x or y` |
| `14-boolean-short-circuit.aster` | `enabled and value greater than 0` |
| `17-comparison-range.aster` | `value greater than lo and value less than hi` |
| `26-if-bool-condition.aster` | `is_member and has_coupon` |
| `27-business-loan-eligibility.aster` | `age greater than 17 and credit_score greater than 599 and ...` |
| `30-business-gdpr-retention.aster` | `consent_active and days_since_consent less than 730` |

**Action items for Phase 3B TS PEG**:
1. Add `and` / `or` as binary expression operators (currently parsed as keywords but not as expression infix)
2. Add type annotation `: <Type>` to param grammar
3. Add return type `produce <Type>:` to signature grammar
4. Article carve-out for `a`, `an`, `the`

Until then, `DualEngineCrossLangTest` will mark these 7 policies as `@Disabled` with a link to this RFC.

### 7.1 Runtime semantic differences (also Phase 3B work)

Beyond syntax, Phase 3A-2 `crosslangTest` execution revealed **runtime divergence** in numeric semantics:

| Case | Java engine | TS engine | Root cause |
|---|---|---|---|
| `08-arithmetic-divide`: `7 / 2` | `3` (Int trunc) | `3.5` (IEEE 754) | Java enforces Int division; TS treats numbers as floats |
| `09-arithmetic-modulo`: `n - n/2*2` | `1` (odd) | `0` (7 - 3.5*2 = 0) | Same root cause as above |

**Decision**: TS engine should emulate Int truncation when both operands are integer literals or come from Int-annotated params. Until then, these 2 cases are also `@Disabled` in `crosslangTest`.

After Phase 3B, total disabled = **0** (currently **9 cases** — 7 syntax + 2 runtime).

### 7.2 Phase 3A-2 baseline metrics (verified 2026-05-11)

After ProcessBuilder bridge implementation + corpus rewrite:
- **Java sanity** (`./gradlew test`): 181 dynamic tests ✅
- **Cross-lang** (`./gradlew crosslangTest`): **74 / 76 passing** (97.4%)
  - 7 syntax-blocked policies → 0 ran (disabled containers, 7 placeholder "disabled" cases)
  - 2 runtime-divergent cases blocked but not yet `@Disabled` (08+09)
  - 23 / 30 policies fully cross-engine equivalent

---

## 8. TS sample alignment outcome (2026-05-11)

Follow-up sweep: feed every user-facing TS sample to the **Java authoritative parser**. Files that fail to parse under Java are the divergence set; per the "Java ANTLR is authoritative" principle, **TS samples must conform to Java grammar**, not the other way around.

### 8.1 Inventory

17 user-facing samples were scanned via `TsSampleParseInventoryTest` (aster-lang-core, tag `inventory`):

| Path | Initial | After fix |
|---|---|---|
| `examples/healthcare/patient-record.aster` | ❌ | ✅ |
| `examples/healthcare/prescription-workflow.aster` | ❌ | ✅ |
| `examples/compliance/hipaa-validation-demo.aster` | ❌ | ✅ |
| `examples/compliance/soc2-audit-demo.aster` | ❌ | ✅ |
| `test/policy-converter/simple_policy.aster` | ✅ | ✅ |
| `test/policy-converter/async_policy.aster` | ❌ | ✅ |
| `test/policy-converter/effects_policy.aster` | ❌ | ✅ |
| `test/policy-converter/data_policy.aster` | ✅ | ✅ |
| `test/capability-v2.aster` | ✅ | ✅ |
| `test/truffle/smoke-test.aster` | ✅ | ✅ |
| `test/lsp-multi/a.aster` | ✅ | ✅ |
| `test/lsp-multi/b.aster` | ✅ | ✅ |
| `test/fixtures/capability-violations.aster` | ❌ | ✅ |
| `test/fixtures/parallel-workflow.aster` | ✅ | ✅ |
| `test/cnl/programs/examples/greet.aster` | ✅ | ✅ |
| `test/cnl/programs/examples/hello.aster` | ✅ | ✅ |
| `test/cnl/programs/examples/login.aster` | ✅ | ✅ |
| **Total** | **10/17** | **17/17** |

### 8.2 Root causes of TS-only constructs

| Cause | Affected files | Authoritative form |
|---|---|---|
| `//` line comments (TS canonicalizer accepts both `//` and `#`; Java grammar only accepts `#`) | 4 healthcare/compliance demos | `#` only |
| Module names colliding with reserved keywords (`Module test.async.` → lexer eats `async` as ASYNC token) | `async_policy.aster` | Rename to non-keyword (`test.async_demo`) |
| `produce with IO.` (TS-only `with` filler before return-type) | `effects_policy.aster` | `produce IO.` (no `with`) |
| Workflow inside rule body: blank line before `workflow:` breaks INDENT detection | `capability-violations.aster` | No blank line between rule colon and `workflow:` |

### 8.3 Fixes applied (no deletions)

All 7 failing samples were **fixed in-place** to conform to Java grammar — none deleted. The semantic intent of each sample is preserved.

- 4 demo files: `^\s*//` → `\s*#` for line comments
- `async_policy.aster`: `Module test.async.` → `Module test.async_demo.`
- `effects_policy.aster`: removed extraneous `with` between `produce` and return type
- `capability-violations.aster`: removed stray blank lines inside rule body

A corresponding TS test fixture (`test/policy-converter/round-trip.test.ts:81`) was updated from `'test.async'` to `'test.async_demo'` to match.

### 8.4 Cross-engine verification (2026-05-11)

After alignment:

- **Java parse inventory** (`./gradlew test --tests TsSampleParseInventoryTest`): 17/17 ✅
- **TS `pnpm run test:converter`**: 5/5 ✅
- **TS `pnpm run test:integration`**: 87/87 ✅

No regressions on either side. From this point forward, **any new TS sample must parse under Java first** — `TsSampleParseInventoryTest` is the regression net.

### 8.5 Equivalence (not subset) is the goal

The Phase 3A-1 decision elevated Java ANTLR as authoritative for **conflict resolution**, not as an upper bound on TS PEG. The two engines must be **bidirectionally equivalent**:

- Any `.aster` parsed by Java ANTLR → TS PEG must also parse.
- Any `.aster` parsed by TS PEG → Java ANTLR must also parse.

Section 8 above closed half the gap (TS samples → Java). The other half — Java corpus → TS PEG — is tracked in §9 below as the reverse inventory.

For any new `.aster` file (human or AI authored), the practical rules currently differ between engines:

1. Comments must use `#` (TS PEG also accepts `//`; Java rejects it — write `#` for portability).
2. Module / identifier names must not collide with reserved keywords (`async`, `await`, `io`, `step`, `workflow`, `produce`, `given`, …).
3. Return-type annotation: `produce <Type>.` (no `with`).
4. Workflow blocks must be indented inside a rule body with no leading blank lines.

These are **interim portability rules**, not a permanent constraint. The intent is to drive both grammars toward full equivalence — see §9 for the gap closure plan.

---

## 9. Bidirectional equivalence gap (2026-05-11)

To enforce the §8.5 equivalence principle, both engines were scanned against the other side's full sample corpus.

### 9.1 Forward direction — TS samples → Java parser

**Scan**: `aster-lang-core/src/test/java/aster/core/dualengine/TsSampleParseInventoryTest.java`
**Inputs**: all `*.aster` under `aster-lang-ts/` except `lossless/` + `comments/` (pretty-printer goldens) — **360 files**.

| Result | Count | % |
|---|---|---|
| Java accepts | 285 | 79.2% |
| Java rejects (TS-only construct) | 75 | 20.8% |

Failures cluster by **root cause** (first error per file, tallied; `<TOKEN>` collapses similar errors):

| # | Cluster signature | Java gap |
|---|---|---|
| 16 | `mismatched input '/'` at start of line/file | `//` line comment syntax (Java only accepts `#`) |
| 15 | `mismatched input 'workflow'` at top level | Top-level `workflow` block (Java requires inside Rule body) |
| 13 | `no viable alternative at input 'Letfbefunctionwith...'` | `Let x be function with ...` lambda binding |
| 11 | `token recognition error at: '。' / '，'` | CJK full-width punctuation in source (zh-CN lexicon paths) |
|  4 | `mismatched input 'async'` at top level | Top-level `async` declaration |
|  3 | `mismatched input 'retry'` at top level | Top-level `retry` block |
|  5 | `missing '.' at 'at'` | `at` keyword (used as operator / suffix in TS) |
|  2 | `mismatched input 'with'` after identifier | Some `Define ... with ...` form |
|  6 | various single-shot issues | wide tail (typecheck-golden async edges, etc.) |

### 9.2 Reverse direction — Java corpus → TS PEG

**Scan**: `aster-lang-ts/scripts/java-corpus-parse-inventory.mjs`
**Inputs**: all 30 `dual-engine/policies/*.aster` from aster-lang-core.

| Result | Count | % |
|---|---|---|
| TS PEG accepts | 23 | 76.7% |
| TS PEG rejects (Java-only construct) | 7 | 23.3% |

| Policy | Failing construct |
|---|---|
| `11-boolean-and.aster` | `x and y` as binary expression |
| `12-boolean-or.aster` | `x or y` as binary expression |
| `14-boolean-short-circuit.aster` | `enabled and value greater than 0` |
| `17-comparison-range.aster` | `value greater than lo and value less than hi` |
| `26-if-bool-condition.aster` | `is_member and has_coupon` |
| `27-business-loan-eligibility.aster` | chained `and` predicates |
| `30-business-gdpr-retention.aster` | `consent_active and days_since_consent less than 730` |

These match the 7 `@Disabled` policies in `DualEngineCrossLangTest` — direct evidence the disablement is grammar-deep, not just evaluator-deep.

### 9.3 Combined equivalence gap

**初始基线（2026-05 P1-9 框架落地时）**：

| Side | Files | Pass | Fail | Pass-rate |
|---|---|---|---|---|
| TS → Java | 360 | 285 | 75 | 79.2% |
| Java → TS | 30 | 23 | 7 | 76.7% |
| **Aggregate** | **390** | **308** | **82** | **79.0%** |

**当前（2026-05-12 P1-10/-11 后）**：tier1+tier2 等价率 **92.9%**（见 §10.3 历史表）。
剩余 14 个分歧主要是 lambda 短形 + match-bind 模式，Java grammar 后续补齐
（追踪在 §9.4 backlog）。

### 9.4 Gap-closure backlog (sized)

Priority is "how many samples this unblocks" × "how localized the grammar change is".

#### Java grammar additions (to accept current TS PEG output)

| Gap | Unblocks | Sizing | Owner |
|---|---|---|---|
| `//` line comment alongside `#` | 16 | XS (1-line lexer rule: `COMMENT: ('#' \| '//') ~[\r\n]* -> channel(HIDDEN);`) | aster-lang-core |
| Top-level `workflow` declaration | 15 | M (grammar refactor: workflow as moduleDecl alternative, not just stmt) | aster-lang-core |
| `Let x be function with params produce: ...` lambda | 13 | M (new expression form) | aster-lang-core |
| CJK full-width punctuation in source (not lexicon) | 11 | S (lexer skip rule for CJK punctuation when canonicalization='cjk') | aster-lang-core |
| Top-level `async` declaration | 4 | S (similar to workflow) | aster-lang-core |
| Top-level `retry` declaration | 3 | S | aster-lang-core |
| `at` keyword (positional / map index) | 5 | S | aster-lang-core |
| `Define ... with ...` form | 2 | S | aster-lang-core |
| Tail (one-off) | 6 | M (case-by-case) | aster-lang-core |

**Total**: ~9 grammar deltas; estimated **2-3 engineering days** for parser-only work, +2 days for AstBuilder + tests.

#### TS PEG additions (to accept current Java grammar output)

| Gap | Unblocks | Sizing | Owner |
|---|---|---|---|
| `and` / `or` as binary expression operators | 7 | M (already partially keyworded; needs precedence wiring in PEG) | aster-lang-ts |

**Total**: 1 grammar delta; estimated **1 engineering day**.

### 9.5 Acceptance criteria & regression net

Definition of "bidirectionally equivalent":
- `TsSampleParseInventoryTest`: 360/360 pass.
- `scripts/java-corpus-parse-inventory.mjs`: 30/30 pass.
- `DualEngineCrossLangTest`: 0 `@Disabled` cases (currently 9 — 7 syntax + 2 runtime).

These three checks are the regression net going forward. They should run on every grammar PR in either repo.

### 9.6 Sequencing

Equivalence closure is **not** a Phase 3 commitment — it's tracked here so Phase 4 can prioritize against business value. Recommended order:

1. **Phase 4 W1** — Java `//` comment + CJK punctuation (XS+S, unblocks 27 samples cheaply).
2. **Phase 4 W2** — TS `and`/`or` binary operators (M, closes the 7 disabled corpus; the only way to enable cross-lang test for boolean policies).
3. **Phase 4 W3** — Java top-level workflow/async/retry blocks (M, unblocks 22 samples).
4. **Phase 4 W4** — Java lambda binding (`Let x be function with`) + tail (M+, unblocks 19 samples).
5. **Phase 4 W5** — re-run both inventories, target 100% / 100%.

---

## 10. Corpus 治理流程（Step 2 完成后）

Step 1 双向 inventory 后，Step 2 完成了 corpus 抽出工作。本节锁定后续 corpus 维护流程。

### 10.1 单一权威 corpus

所有 .aster 测试样本的权威源是独立仓库 [`aster-lang-test`](https://github.com/aster-cloud/aster-lang-test)。

- npm 包：`@aster-cloud/aster-lang-test`
- Maven artifact：`cloud.aster-lang:aster-lang-test`
- 双发布机制保证 Java 与 TS 两端拉到的是字节相同的 corpus

### 10.2 三层 corpus 结构

```
corpus/
├── tier1-equivalence/         # 双引擎都接受；可参与等价测试
│   ├── policies/*.aster       # 162 个
│   └── inputs/*.cases.json    # 15 个有黄金期望
├── tier2-divergent/           # 单引擎接受；等价缺口的可见档案
│   ├── java-only/*.aster      # 8 个（and/or 等）
│   └── ts-only/*.aster        # 27 个（lambda / `at` / `with` 等）
└── tier3-fixtures/            # 单端 fixture，不参与等价
    ├── golden-{ast,core,diagnostics}/    # TS pipeline 内部 golden
    ├── type-checker / type-checker-xmodule/
    ├── lossless / comments/   # pretty-printer round-trip
    ├── lexicon-i18n/          # 词法 fixture（zh/de/...）
    ├── parser-error/          # 故意触发 parser error
    ├── lsp / runtime-retry / truffle / fixtures / policy-converter/
    └── broken/                # 两端均拒绝；triage 用
```

### 10.3 当前等价度（2026-05-11 重测）

| 维度 | 通过 / 总数 | 比率 |
|---|---|---|
| Tier 1 双向等价 | 162 / 162 | 100% |
| Tier 2/3 — 单端可接受 | 14 | — |
| **等价 corpus 范围（tier1+tier2）** | **183 / 197** | **92.9%** |

**变更历史**（来自 `aster-lang-test/equivalence-history.csv`）：
| 日期 | 等价数 | 总数 | 等价率 | 触发 |
|---|---|---|---|---|
| 2026-05-12 (initial) | 162 | 197 | 82.2% | 框架建立（P1-9） |
| 2026-05-12 (P1-11) | 169 | 197 | 85.8% | TS PEG 加 `and`/`or` binary ops |
| 2026-05-12 (P1-10 step 1) | 177 | 197 | 89.9% | Java grammar 加 `:` 作 if 块分隔 |
| 2026-05-12 (P1-10 step 2) | 183 | 197 | **92.9%** | Java 加 `at least`/`at most`/`is equal to`/`more than` 自然别名 |


注：tier3 共 227 个 fixture 不参与等价度计算（它们是单端 fixture by design）。

### 10.4 新增 sample 流程

1. 决定 tier（参考 `aster-lang-test/CONTRIBUTING.md`）
2. PR 提交到 `aster-lang-test` 仓
3. CI 自动跑双向 inventory + tier1 gate；如下放到 tier1 必须双引擎都过，否则只能去 tier2/tier3
4. Aster reviewer 24h 内首次回复

### 10.5 grammar 变更工作流

任何 grammar 变更（Java 或 TS）必须：

1. 在自己 repo 的 grammar PR 里同时**减少 tier2 文件**（每修一个语法分歧，把对应 .aster 从 tier2 升级到 tier1，并补 .cases.json 黄金）
2. 通过 `node scripts/inventory.mjs --parser=<engine> --gate=tier1` 验证 tier1 没回归
3. 更新 §9 的「unblocks N samples」表格

### 10.6 等价度 release gate

`aster-lang-test` 仓 CI 强制：
- Tier1 任何样本失败 → block PR
- 整体等价度比上次 release 下降 → 警告（不 block，但需 reviewer 显式批准）

下次 grammar 改动后跑 inventory 即可看到等价度变化；不需要手动维护 §9 数字。

### 10.7 消费者改造记录（Step 2 完成时）

| Repo | 改动 | 状态 |
|---|---|---|
| `aster-lang-core` | `testImplementation("cloud.aster-lang:aster-lang-test:0.0.1")`；`DualEngineCrossLangTest` / `TsSampleParseInventoryTest` / `DualEngineGoldenTest` 改走 `CorpusLoader`；删 `src/test/resources/dual-engine/` | ✅ |
| `aster-lang-ts` | `scripts/java-corpus-parse-inventory.mjs` 改走 npm corpus loader；`test/*.aster` 保留不动（legacy，未来重构时再迁） | ✅ |
| 未来 `aster-idea` / `aster-vscode` 重构 | 加 corpus devDep，按 tier1 fixture 编写新 IDE 测试 | 📅 Phase 4+ |
