# AI 计费与防盗刷方案 v1.0

> 决策：双轨制 — 平台默认提供 + 用户 BYOK 可选

---

## 决策摘要

| 档位 | AI 来源 | 限额 | 客户体验 |
|---|---|---|---|
| **Free** | 平台 OpenAI 账号 | **20 次 / 月**，每次 ≤ 4k tokens | 开盒即用 |
| **Pro** | 平台 OpenAI 账号 | **500 次 / 席位 / 月** | 不感知 token 成本 |
| **Pro + BYOK** | 用户绑定自己 key | 无限 | 数据/合规需求 |
| **Enterprise** | 默认 BYOK，托管转售可选 | 无限 | 合规优先 |

**Free / Pro 默认走平台账号** = 不让用户去 OpenAI 注册才能体验。
**BYOK 可选** = 给受监管行业 / 大客户 escape hatch。

---

## 为什么不"仅 BYOK"

虽然零成本，但是 **CNL 恐怖谷** 的死亡区：

- 业务专家（合规官 / 风控）99% 不知道什么是 OpenAI key
- 让他们去 platform.openai.com 注册付款 = 流失 80%+ 的目标用户
- 这违反 PM 文档定位"业务专家用母语写规则"

**Cursor 早期教训**：v1.0 仅 BYOK，开发者群体能用但数据科学家流失；v2.0 加平台计费后 DAU 翻 3 倍。

---

## 为什么不"仅平台付"

成本无控 + 法律风险：
- 平台账号被某用户脚本刷爆（GPT-4 一次调用最多 ¥5+，每秒可调 60 次 = 每分钟 ¥18,000 烧）
- 平台付费 = 平台变成 OpenAI 的"白手套"，OpenAI ToS 第 3 条不允许
- 受监管行业（金融/医疗）数据不能进 OpenAI → Enterprise 必须支持 BYOK

---

## 防盗刷三层设计

### Layer 1：配额预算（必备）

每用户 + 每租户 + 全局三级配额：

```
用户级：Free 20 次/月，Pro 500 次/席位/月
租户级：Free tenant 总和 ≤ 50 次/月（防多账号合谋）
全局熔断：所有平台 LLM 调用 > $200/天 → 自动停服 + 告警
```

调用前检查（pre-flight）：

```
POST /api/v1/ai/generate
  ↓
aster-api 调 cloud /api/internal/ai/quota?userId=...
  ↓
cloud 返回 { allowed: true, remainingUSD: 1.20, monthlyLimit: 20 }
  ↓
allowed=false → aster-api 返回 402 + reason="ai_quota_exhausted"
allowed=true  → 继续调 LLM
  ↓
LLM 返回带 usage
  ↓
aster-api 调 cloud /api/internal/ai/usage（POST 实际 token）
  ↓
cloud 写入 aiUsageRecords，下次 quota 计算更新
```

### Layer 2：速率限制（必备）

防"瞬时刷"：

```
每分钟：Free 5 次 / Pro 30 次 / Enterprise 200 次
每小时：Free 20 次 / Pro 200 次 / Enterprise 1000 次
基于 IP + userId 双重 key（防 IP 漂移）
Redis token-bucket（已存在 RateLimitFilter，扩展即可）
```

### Layer 3：异常检测（推荐）

被动检测 → 触发自动封禁 + Slack 告警：

| 信号 | 阈值 | 动作 |
|---|---|---|
| 同一 prompt 重复（hash 比对） | 连续 5 次 | 拒绝 + warning |
| 请求 token 数异常高 | > 8k chars 输入 | 截断 + warning |
| 凌晨/非工作时间突发 | 用户工作时间外 5+ 次/分钟 | 临时禁用 24h |
| 失败率突高（API 错误） | > 80% 失败率（10 次窗口） | 临时禁用，人工审核 |

实现：定时任务（cron 每 5 分钟）扫描 aiUsageRecords，写 user.aiBannedUntil 字段。

---

## BYOK（自带 key）实现

### 用户体验

`/settings/ai-keys`：

```
[ + ] Add OpenAI key
[ + ] Add Anthropic key

OpenAI: sk-...****1234   [测试连接 ✓]   [删除]
默认使用：✓ 优先用我自己的 key（兜底用平台 key）
```

### 安全存储

| 风险 | 对策 |
|---|---|
| DB 泄露 | Postgres pgcrypto 列加密（`pgp_sym_encrypt`），主密钥 Vault |
| 运维 dump | 列级加密 + 字段名混淆（`aiK1` 而非 `openAiKey`）|
| 日志/工单 | API 处理时只解密内存使用，不入日志；`****` 掩码显示 |
| 用户离职 | 不可见纯文本（仅显示后 4 位）|

### 优先级

```
1. 用户 BYOK 已绑定且健康 → 用 BYOK
2. 否则 → 用平台 key（受配额限制）
3. 平台 key 也耗尽 → 402 ai_quota_exhausted（提示 BYOK 或升级）
```

---

## 阶段实施

| 阶段 | 范围 | 工期 |
|---|---|---|
| **F1（本文档）** | 决策落地 | ✅ |
| **F2 配额表** | aiUsageRecords / aiKeyBindings 数据模型 | 1d |
| **F3 配额检查** | pre-flight + post-record 闭环 | 2d |
| **F4 速率限制** | RateLimitFilter 扩展 LLM 路由 | 0.5d |
| **F5 异常检测** | 定时任务 + Slack 告警 | 1d |
| **F6 BYOK UI** | settings 页 + 加密存储 | 2d |

合计 ~6.5d。

---

## 成本预算（PM 一定要看）

按 GPT-4o-mini ($0.15/M prompt, $0.60/M completion)：

| 套餐 | 假设月活 | 月调用数 | 月 token | 月成本 | 单用户月成本 |
|---|---|---|---|---|---|
| Free | 1000 | 20k 次（每次 ≤4k）| 80M | **$48** | $0.05 |
| Pro | 200 席位 | 100k 次 | 400M | **$240** | $1.20 |

Pro 月费 ¥299 ≈ $42，扣去 $1.20 LLM = **$40 毛利**，安全。

按 GPT-4 完整版（成本 × 25）：
- Free 1000 用户 = $1,200/月 → **不可持续**，需要用 mini 默认 + Pro 才解锁完整版
- Pro 200 席位 = $6,000/月 = $30/席位 → 比月费高 → **必须 BYOK 或限制完整版**

**结论**：默认模型必须用便宜的（mini 系列），完整版仅 Enterprise/BYOK 提供。

---

## 平台运营

| 监控指标（已在 Grafana 反指标）| 阈值 |
|---|---|
| `llm_tokens_total{kind="completion"}` 单日总量 | > 100M tokens / 日 → 告警 |
| `llm_cost_per_adopted` | > ¥3.5 / 采纳草稿 → 告警 |
| 单用户日 token | > 1M → 自动封禁 + 人工审核 |
| 平台 LLM 月成本 | > $5,000 → 紧急 |

---

**版本**：v1.0 · 2026-05-10
**关联**：`05-pricing-packaging.md` / `02-north-star-metric.md` 反指标 4
