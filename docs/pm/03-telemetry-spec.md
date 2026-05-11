# 北极星指标埋点规格 v1.0

> 与 `02-north-star-metric.md` 配套的实现规格。
> 4 个事件 + 后端 source_kind 列，构成 WAADR 的最小数据闭环。

---

## 数据流总览

```
   用户在 aster-cloud 编辑器内操作
                │
                ↓
   ┌──────────────────────────┐
   │  Mixpanel (前端事件)     │  ← ai_draft_generated
   │                          │  ← draft_edited
   │                          │  ← draft_published
   └──────────────────────────┘
                │
                │  保存请求时附带 metadata.source_kind
                ↓
   ┌──────────────────────────┐
   │  aster-api PolicyVersion │
   │  source_kind 列（V6.7.0） │
   └──────────────────────────┘
                │
                │  rule_rolled_back 由后端审计日志映射
                ↓
   ┌──────────────────────────┐
   │  Mixpanel (后端事件)     │  ← rule_rolled_back
   └──────────────────────────┘
                │
                ↓
   pm_weekly_waadr 物化视图（每周一刷新） → Slack #pm-metrics
```

---

## 事件契约

### 1. `ai_draft_generated`

**触发点**：`aster-cloud/src/components/policy/ai-assistant-panel.tsx`，SSE 流接收到 `final` 事件且 `validated === true` 时。

**属性**：
| key | type | 必填 | 说明 |
|---|---|---|---|
| `prompt_id` | string | ✓ | 用 nanoid 在生成开始时分配 |
| `lang` | `'en' \| 'zh' \| 'de'` | ✓ | 当前编辑器 lexicon |
| `model` | string | ✓ | LLM 后端 model id（gpt-5.2 等） |
| `latency_ms` | number | ✓ | 从 user 提交到 final 事件的时间 |
| `char_count` | number | ✓ | 草稿文本长度 |
| `validated` | boolean | ✓ | 是否通过编译校验 |
| `auto_applied` | boolean | ✓ | 是否触发了 auto-apply |

---

### 2. `draft_edited`

**触发点**：`edit-policy-content.tsx` 保存按钮处。**仅当本次保存的内容是基于 AI 草稿修改而来**时才触发。

**判定逻辑**：
- 进入编辑会话时，若编辑器初始内容与最近一次 `ai_draft_generated` 的 `prompt_id` 关联（同 session 内），标记为 AI-derived。
- 保存时若 `editor.getValue() !== aiDraftSnapshot`，触发本事件。

**属性**：
| key | type | 必填 | 说明 |
|---|---|---|---|
| `draft_id` | string | ✓ | policy id |
| `prompt_id` | string | ✓ | 关联的 AI 草稿 id |
| `edit_distance` | number | ✓ | Levenshtein(aiDraft, finalContent) |
| `edit_ratio` | number | ✓ | edit_distance / max(len_a, len_b) |
| `time_spent_sec` | number | ✓ | 从 ai_draft_generated 到 save 的秒数 |
| `repair_count` | number | ✓ | 期间触发 AI Repair 的次数 |

**保存请求扩展**：调用后端保存接口时附带 `{ ...payload, metadata: { source_kind: 'ai_draft_edited' } }`，后端入库到 `policy_versions.source_kind`。

---

### 3. `draft_published`

**触发点**：状态从 `DRAFT` / `SUBMITTED` 转到 `APPROVED`/`active=true` 时。

**实现**：
- 前端：编辑页 publish 操作成功回调中触发。
- 后端：`PolicyVersionService.activateVersion` 同时写一条 audit log（已存在），可由后端服务上报到 Mixpanel server-side（推荐，避免依赖前端可达）。

**属性**：
| key | type | 必填 | 说明 |
|---|---|---|---|
| `draft_id` | string | ✓ | policy id |
| `version` | number | ✓ | timestamp 版本号 |
| `source_kind` | enum | ✓ | manual / ai_draft / ai_draft_edited / imported |
| `reviewer_id` | string | – | 审批人 |
| `tenant_id` | string | ✓ | 租户 |
| `author_role` | enum | ✓ | business_expert / compliance_officer / risk_analyst / engineer / admin |

---

### 4. `rule_rolled_back`

**触发点**：`PolicyEvaluationResource#rollback`（已存在 endpoint）调用后。

**属性**：
| key | type | 必填 | 说明 |
|---|---|---|---|
| `rule_id` | string | ✓ | policy id |
| `from_version` | number | ✓ | 回滚前版本 |
| `to_version` | number | ✓ | 回滚目标版本 |
| `days_after_publish` | number | ✓ | from_version 上线到回滚的天数 |
| `reason` | string | – | RollbackRequest.reason |

**实现位置**：`PolicyEvaluationResource.java:570-618`，rollback 成功后调用 `mixpanelTracker.track("rule_rolled_back", ...)`。

---

## 后端字段

### `policy_versions.source_kind`（已通过 V6.7.0 添加）

| 取值 | 含义 | NSM 计入 |
|---|---|---|
| `manual` | 人工从零撰写 | ❌ |
| `ai_draft` | AI 生成后未经修改保存 | ❌ |
| `ai_draft_edited` | AI 生成后被人工修改保存 | ✅ |
| `imported` | 外部导入 | ❌ |

### Mixpanel server-side 上报（建议）

在 aster-api 内集成 Mixpanel Java SDK 的最薄一层：仅 `track(distinctId, event, props)`，由 `PolicyVersionService.activateVersion` 与 `PolicyEvaluationResource#rollback` 调用。

> 一致性原则：**草稿事件靠前端**（粒度细、噪声大），**上线/回滚事件靠后端**（强一致、不能丢）。

---

## 工程交付清单

| # | 任务 | 仓库 | 已完成 |
|---|---|---|---|
| T1 | Flyway 迁移 V6.7.0 | aster-api | ✅ |
| T2 | PolicyVersion 实体加 sourceKind | aster-api | ✅ |
| T3 | PolicyVersionService.createVersion 重载 | aster-api | ✅ |
| T4 | 前端 4 事件埋点 | aster-cloud | 见下文 |
| T5 | 物化视图 pm_weekly_waadr + cron | aster-api | 见下文 |
| T6 | Mixpanel 看板 | Mixpanel | 待配置 |

---

**关联**：`02-north-star-metric.md` / `04-usability-test-plan.md`
