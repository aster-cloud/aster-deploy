# Deep equivalence (eval-time) — design note

> P1-9.5 of phase4-p1-dual-engine-equivalence.md
> Status: **Designed, not implemented**（占位，等待优先级）
> Owner: TBD

## Why this is a separate task

P1-9 落地的 `equivalence-nightly.mjs` 只测**parse-equivalence**：两个引擎都能解析 .aster 源代码即视为等价。它**不验证 evaluate 结果一致**。

举个例子：两个引擎都能 parse `x and y`，但如果一个返回 `x AND y` 短路求值、另一个返回 `x BITWISE AND y`，parse-equivalence 仍说"等价"，**实际语义已分歧**。

deep-equivalence 关闭这个口子。

## Current corpus state

`aster-lang-test/corpus/tier1-equivalence/inputs/*.cases.json` 已为大部分
tier1 样本提供了 input + expectedOutput pair（见 `packages/js/src/loader.ts`
里的 `CasesGolden` 类型），但**当前没人消费**。两个引擎都没接入。

## Architecture proposal

```
                   ┌───────────────────────────┐
                   │  corpus/.cases.json       │
                   │  { policy, entry, cases } │
                   └────────────┬──────────────┘
                                │
              ┌─────────────────┴─────────────────┐
              │                                   │
   ┌──────────▼────────────┐         ┌────────────▼──────────────┐
   │ aster-lang-ts CI:     │         │ aster-lang-core CI:       │
   │   eval-golden.test.ts │         │   EvalGoldenTest.java     │
   │   foreach case →      │         │   foreach case →          │
   │     parse + interpret │         │     parse + lower +       │
   │     assert == expected│         │     Truffle Polyglot.eval │
   │                       │         │     assert == expected    │
   └──────────┬────────────┘         └────────────┬──────────────┘
              │ writes per-engine                 │
              │ eval-report.json                  │
              └────────────────┬──────────────────┘
                               │
                  ┌────────────▼─────────────┐
                  │ aster-lang-test:         │
                  │ equivalence-nightly.mjs  │
                  │ already fetches both →   │
                  │ extend to compare eval   │
                  │ outcomes by sample id    │
                  └──────────────────────────┘
```

## Why split this from P1-9

P1-9 是"框架建立"——把骨架立起来产出 baseline。P1-9.5 是"语义保真"——
工时更大（两侧引擎各自需要 evaluator 入口 + 一致的 result JSON serialization）。

混在一起会让 P1-9 出不来。

## Sized work breakdown

| 子任务 | 工时 | 依赖 |
|---|---|---|
| aster-lang-ts: `scripts/eval-corpus.mjs`，读 .cases.json + 调 `evaluate()` + 输出 `eval-report-ts.json` | 4h | 现有 `evaluate` + `parse` |
| aster-lang-core: gradle task 或 truffle cli，输入样本路径 + 输出 `eval-report-java.json` | 6-8h | 需要确定 Polyglot Source 是 .aster 源还是 Core IR JSON |
| aster-lang-test: 扩展 `equivalence-nightly.mjs`，并行调两个 engine，按 case 名 join 比较 | 3h | P1-9 已落地 |
| 统一 result JSON shape：number / string / boolean / null / 嵌套结构的 canonical 表示 | 2h | 决定 inf/nan/小数比较容差 |
| nightly workflow 加 eval-equivalence step + 阈值 alert | 1h | P1-9 workflow |

**总计 16-20h**（创始人约 1-2 周兼职工时）。

## Edge cases to handle

1. **浮点比较**：两个引擎 IEEE 754 默认行为基本一致，但 `pow`/`sqrt` 等可能有 1-ulp 差异 → 容差比较
2. **map/dict key 顺序**：JSON 序列化时排序键，避免假阳性
3. **错误等价**：两个引擎都抛错算"equivalent"？还是要求错误信息也匹配？建议前者
4. **lambda 闭包对比**：返回 function 时如何比较？建议：function-returning cases 不进 tier1
5. **运行时性能**：跑 162 样本 × N case 大约 < 1 min（如果引擎 startup 是单次）

## Decision now

不实施。原因：
- P1-12 90% 目标已通过 P1-10/-11 达成（92.9%）
- parse-equivalence baseline 已经能 catch 大部分回归（grammar 改动会让 parse 失败 → divergent）
- 实际生产用户 < 5，eval 分歧的现实风险目前低
- 等到要做 P2 金融垂直 PoC 时，eval-equivalence 会变成"必须做"——届时一起做

## Trigger to start

满足任一即重启：
1. P1-9 nightly 报警出现 eval-time 分歧但 parse 等价（用户/dogfooding 发现）
2. 进入 P2 PoC 阶段
3. 准备外部审计（SOC2 或行业认证）

## Real-world events triggering this design

### 2026-05-13: user-function shadowing builtin（calculator bug）

**症状**：用户在 dashboard 写 `Rule add given request: Let v be (request.leftAmount plus request.rightAmount). Return CalcResult with resultAmount set to v ...`，调用方 `calculate` 里 `Return add(request)` —— TS 引擎返回 `{resultAmount: 2000, ...}`，Java 引擎返回 `Integer(0)`。

**根因**：aster-lang-truffle Loader.buildExpr 见到 `Call(Name("add"), [...])` 时检查 `Builtins.has("add") == true`（算术 `add(a,b)`），直接走 BuiltinCallNode；1 个 Map 参数 + 期待 2 个 Int → arity 失配在 DSL specialization 重写时被吞，静默返回 0。

**修复**：aster-lang-truffle commit `51c0afe` — Loader 维护 `userFunctionNames` 集合，buildExpr 在分发 Call 时先查该集合，用户定义函数屏蔽同名 builtin。

**parse-equivalence 没捕到**：两个引擎都能 parse 这段代码（rate 仍 92.9%）；分歧只在 eval。**正是本 RFC 预言的 case**。

**启示**：这件事的发现需要用户实测；nightly 无法替代真实使用。但**有 `.cases.json` + eval-equivalence**就能 catch。把"实施 deep-equivalence"的优先级从 "P2 阶段做" 提到 "下个空闲 sprint 做"。
