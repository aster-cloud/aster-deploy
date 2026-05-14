# RFC: Pluggable Language Modules with English as Fallback Backbone

| | |
|---|---|
| Status | Accepted |
| Authors | Aster Lang core team |
| Reviewers | TBD |
| Created | 2026-05-12 |
| Target | aster-lang-core, aster-lang-ts, aster-cloud, aster-lang-{en,zh,de} |
| Phase | Phase 4 — modularization |

---

## 1. Problem

Aster Lang ships in three layers:

| Layer | Distribution | Languages bundled |
|---|---|---|
| Java engine (`aster-lang-core`) | Maven JAR | en + zh + de via SPI plugins |
| TypeScript engine (`aster-lang-ts`) | npm package | en + zh + de **embedded in main bundle** |
| Web UI (`aster-cloud`) | Next.js app | en + zh + de via `messages/*.json` |

Three load-bearing problems with the status quo:

1. **Bundle size pressure on the TS engine.** Every browser consumer downloads zh + de keyword tables and overlays even if the page only renders en text. With future language packs (ja, fr, …) this scales linearly.
2. **No fallback when a language pack drops a keyword.** If `zh-CN.json` is missing `FUNC_GIVEN`, the lexer throws `Unexpected character` instead of degrading to the English keyword `given`. The user experience is "the page doesn't work" rather than "this word looks foreign for a moment".
3. **i18n catalogs drift silently in the UI.** `messages/zh.json` can lose a key relative to `en.json` and we only discover it when a translator opens the page and sees `key.path.literal` rendered as text.

The risk is the same in all three layers: **a non-default language pack is a hard dependency at runtime**. There is no soft-degrade story.

## 2. Goals

1. Make English the **always-present backbone**. Every layer should be guaranteed to render correctly with en alone.
2. Treat zh / de (and any future locale) as **opt-in language packs**. Removing them should reduce bundle size, not break correctness.
3. **Keyword-level fallback**: if pack X is missing `FUNC_GIVEN`, the engine transparently uses en's `given`. No exception thrown.
4. **CI parity check**: `zh.json` / `de.json` extra keys = error; missing keys = warning. Drift is caught before merge.

Non-goals: punctuation/canonicalization-level fallback (those are language-defining and have no meaningful default).

## 3. Design

### 3.1 Java engine (`aster-lang-core`)

- Embed `en-US.json` as a classpath resource (`builtin/en-US.json`), byte-for-byte parity-checked against the canonical copy in `aster-lang-en`.
- `LexiconRegistry` constructor: `loadEmbeddedDefaults()` (always en) → `discoverPlugins()` (SPI; en-US plugin skipped via `containsKey`).
- Introduce `FallbackLexicon(target, fallback)` — a decorator that pre-merges `target.keywords` over `fallback.keywords` at construction time. Punctuation / canonicalization / messages passthrough `target`.
- `LexiconRegistry.get(id)` returns `Optional<FallbackLexicon>` for non-en lexicons, `target` unchanged for en itself, and short-circuits if the wrapper is already in place (defensive).

### 3.2 TypeScript engine (`aster-lang-ts`)

- `initializeDefaultLexicons()` registers **only** en-US. Consumers must explicitly `LexiconRegistry.register(ZH_CN)` to opt in.
- Provide `initializeAllBundledLexicons()` (deprecated bridge) that registers en + zh + de, preserving the old behaviour for existing callers.
- Mark `ZH_CN` / `DE_DE` exports `@deprecated` to surface IDE warnings; long-term these move to `@aster-cloud/aster-lang-ts-{zh,de}` sub-packages.
- Introduce `createFallbackLexicon(target, fallback)` — a factory function returning a frozen object branded with `Symbol.for('aster-lang/fallback-lexicon')`. Type guard `isFallbackLexicon()` replaces `instanceof` (works across realms; satisfies `exactOptionalPropertyTypes`).
- Registry decorates non-en lexicons identically to the Java side.
- **Idempotency fix**: both initializers only call `setDefault('en-US')` on first registration, never clobbering a caller's later `setDefault('zh-CN')`.

### 3.3 UI catalog fallback (`aster-cloud`)

- `src/i18n/request.ts` deep-merges `messages/en.json` (backbone) with the active locale's messages. Missing keys in zh/de transparently render their en value.
- `getMessageFallback({ namespace, key })` returns the dotted key path as a debugging aid for keys missing in **all** locales (i.e. dev error).
- `onError` logs MISSING_MESSAGE in non-production only.

### 3.4 CI parity gates

- **aster-lang-en**: Gradle `verifyLexiconParity` task compares `en-US.json` between `aster-lang-en` and `aster-lang-core/builtin/`. Wired into the `check` chain.
- **aster-cloud**: `scripts/check-locales.ts` walks the message trees:
  - **error**: extra key in zh/de, or type mismatch (string vs object)
  - **warn**: missing key, or empty string (deepMergeMessages tolerates both)
  - `--strict` flag elevates warnings to errors for CI.

## 4. Trade-offs

| | Status quo | This RFC |
|---|---|---|
| TS bundle size (gzip, browser) | All three locales | en backbone only by default |
| Missing keyword in pack | Throws | Falls back to en |
| Missing UI string | Renders `key.path` literal | Renders en value |
| Catalog drift | Discovered in browser at runtime | Caught by `check:locales:strict` in CI |
| Add a new locale | Edit core, ship core | Drop a new plugin / message file |
| Existing consumers | n/a | `initializeAllBundledLexicons()` keeps old behaviour during deprecation window |

## 5. Compatibility

- **Java consumers**: no breakage. `LexiconRegistry.get("zh-CN")` continues to return a usable Lexicon; the only difference is that the returned object is now `FallbackLexicon`-decorated. Punctuation / messages / id / name unchanged.
- **TypeScript consumers**: a one-line migration for callers that relied on `initializeDefaultLexicons()` registering all three locales. They switch to `initializeAllBundledLexicons()` (deprecated) or explicit `LexiconRegistry.register(ZH_CN)`. Existing in-tree test suites and the `lexer.ts` / `canonicalizer.ts` bootstrap paths still function unchanged.
- **`aster-cloud`**: no consumer-visible change. `useTranslations()` continues to work; missing keys now fall through to en instead of throwing.

## 6. Rollout

1. ✅ Java core embeds en-US, ships FallbackLexicon decorator.
2. ✅ aster-lang-en verifies parity in `check`.
3. ✅ TS engine narrows `initializeDefaultLexicons()` to en, exports `createFallbackLexicon` + `isFallbackLexicon`. Tests migrated to `initializeAllBundledLexicons()`.
4. ✅ aster-cloud `request.ts` deep-merges en backbone. `check:locales` script + CI step.
5. Future (next major): publish `@aster-cloud/aster-lang-ts-zh` / `-de` and remove zh/de exports from the main TS bundle.

## 7. Out of scope

- Translating diagnostic *help* text (`diagnosticHelp` overlay). Already supported per-locale; no fallback needed because the en defaults are in `ERROR_METADATA`.
- Punctuation fallback. Languages have language-defining punctuation; falling back from `。` to `.` would produce malformed source for the speaker of the target language.
- LLM-generated translations for missing keys. The check-locales script flags drift; humans translate.

## 8. References

- Plan file: `.claude/plan/pluggable-language-modules.md` (in aster-api repo)
- Java: `aster-lang-core/src/main/java/aster/core/lexicon/{LexiconRegistry,FallbackLexicon}.java`
- TS: `aster-lang-ts/src/config/lexicons/{registry,fallback-lexicon,index}.ts`
- UI: `aster-cloud/src/i18n/request.ts`, `aster-cloud/scripts/check-locales.ts`
