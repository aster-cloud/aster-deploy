# Staging 验证报告 v5 — AI 计费 / 反盗刷

**日期**：2026-05-09 / 2026-05-10
**范围**：07-ai-billing 全栈（数据 + API + cron + admin）
**结论**：8/8 场景通过；3 处运行时缺陷在过程中发现并修复。

---

## 1. 验证范围

按 `docs/pm/07-ai-billing.md` 的三层防御 + 运维 backlog 全量验证：

| # | 模块 | 文件 |
|---|------|------|
| L1 | 配额（月度+档位） | `aster-cloud/src/lib/ai-quota.ts` |
| L2 | 限流（每分钟+每小时） | `aster-cloud/src/lib/ai-quota.ts` |
| L3 | 异常检测（5min cron） | `aster-cloud/src/lib/ai-anomaly-detection.ts` |
| ops | BYOK 健康检查 cron | `aster-cloud/src/lib/ai-byok-healthcheck.ts` |
| ops | dashboard 用量进度条 | `aster-cloud/src/components/dashboard/ai-usage-card.tsx` |
| ops | 全局成本熔断 cron | `aster-cloud/src/lib/ai-circuit-breaker.ts` |
| ops | 管理员 admin 解锁 | `aster-cloud/src/app/api/admin/ai-circuit-breaker/route.ts` |

---

## 2. 测试基础设施

```
Postgres 16  : podman aster-postgres:5432  (含 pgcrypto)
Redis 7      : podman aster-redis:6379
mock-llm     : podman aster-mock-llm
Prometheus   : podman aster-prometheus:9090
Grafana      : podman aster-grafana:3000
aster-cloud  : pnpm dev (3001)，env-staging
aster-api    : 未启（本期不涉及后端 LLM 调用）
```

测试用户：
- `test-free-user` (free) — 配额/封禁/BYOK/熔断验证主体
- `test-abuser` (free) — 异常检测验证
- `test-user-…0001` (trial) — 熔断作用域验证

---

## 3. 场景结果

| # | 场景 | 期望 | 实际 | 结果 |
|---|------|------|------|------|
| 1 | Free 当月用满 20 → 拒绝 | `ai_quota_exhausted` | 同期望 | ✅ |
| 2 | 同用户绑定 BYOK → 直接放行 | `allowed:true, usedByok:true` | 同期望 | ✅ |
| 3 | pgcrypto 加解密往返 | 解密 = 原 key | `sk-fake-byok-key-1234567890` | ✅ |
| 4 | 异常检测 24h 自动封 | `aiBannedUntil` 24h | `test-abuser` 被封 | ✅ |
| 5 | 全局熔断 \$200 → 停 free | free 用户 `aiBanReason='全局成本熔断（free_stopped）'` | `affected:1` | ✅ |
| 6 | 管理员 release 清空熔断 | `aiBannedUntil/Reason=NULL` | SQL 验证 + 401 gate 通过 | ✅ |
| 7 | `/api/user/ai-usage` 数据形状 | 含 monthly/cost/byok/banned | 数据 21 次/21020 cents/byok 可用 | ✅ |
| 8 | BYOK 健康检查失败 → 24h 内再失败自动停用 | `active=false` | 第 2 次 cron 命中 deactivate | ✅ |

---

## 4. 过程中发现并修复的缺陷

### 4.1 异常检测 cron 500 — Date 对象传给原始 SQL

**症状**：调用 `/api/cron/ai-anomaly-check` 返回 500，日志 `TypeError: The "string" argument must be of type string ... Received an instance of Date`。

**原因**：`postgres-js` 将 `${date}` 模板插值视为字符串绑定。

**修复**：`ai-anomaly-detection.ts` line 63
```ts
// before
WHERE "createdAt" >= ${since}

// after
const sinceIso = since.toISOString();
WHERE "createdAt" >= ${sinceIso}::timestamp
```

### 4.2 熔断器 cron 500 — 同一根因（Date + 类型 + 数组）

熔断器 `ai-circuit-breaker.ts` 触及三个独立但互锁的缺陷：

1. `${today}` / `${endOfDay}` 都是 Date 对象 → 同 4.1 修复
2. `WHERE "plan" = ANY(...)` 中 `plan` 是 `pgEnum('Plan', ...)`，与 `text[]` 没有运算符 → 加 `::text` 显式转换
3. JS 数组 `['free']` 经 `${}` 绑定后被序列化为 `'free'` 字符串，触发 `malformed array literal` → 改用 `sql.join(...)` 构造 `IN (...)` 列表
4. `db.execute(UPDATE ...)` 不返回 `rowCount`，需 `RETURNING id` 才能正确报告 `affected`

修复后：
```ts
WHERE "plan"::text IN (${plansList})
  AND ("aiBannedUntil" IS NULL OR "aiBannedUntil" < ${endOfDayIso}::timestamp)
RETURNING id
```

### 4.3 BYOK pgcrypto 解密 `Wrong key or corrupt data`

**原因**：staging DB 的 BYOK 行是上一会话用未知 secret 加密的，与当前 `.env.staging` 的 `AI_KEY_ENCRYPTION_SECRET` 不一致。

**处理**：把 staging 测试数据 `byok-1` 用当前 secret 重新加密，避免污染下一轮。**生产路径不存在此问题**（同一个 secret 自始至终来自 Vault）。

---

## 5. 运维侧补充

| 补充项 | 文件 |
|--------|------|
| Vault 路径 / Cron 调度 / AlertManager 路由 / 应急流程 | `aster-deploy/observability/AI-OPERATIONS.md` |
| K3S ExternalSecret `aster-cloud-ai-secrets`（3 keys） | `k3s/apps/aster-lang/cloud/external-secrets.yaml` |

---

## 6. 单元测试

| 套件 | 用例数 | 结果 |
|------|--------|------|
| `ai-quota.test.ts` | 17 | ✅ |
| `ai-anomaly-detection.test.ts` | 6 | ✅ |
| 其他既有 AI 相关用例 | — | 未回归 |

```
pnpm exec vitest run src/__tests__/lib/ai-quota.test.ts src/__tests__/lib/ai-anomaly-detection.test.ts
→ 23 passed
```

---

## 7. 待办（不阻塞当前迭代）

- 真实 OpenAI/Anthropic key 接入后，把 BYOK 健康检查从"401 即视为失败"扩展为"区分 401（key 失效）/ 429（限流）/ 500（上游故障）"，对后两者不计入失效次数。
- admin 解锁路由当前以 `plan='enterprise'` 等价 admin。生产前需引入 `users.role` 字段或独立 ACL 表。
- dashboard `ai-usage-card` 通过 Chrome 实拍尚未做（dev server session cookie 未模拟）；下次和 e2e 一起跑 Playwright。

---

## 8. 清理

```
podman compose -f aster-deploy/podman/podman-compose.staging.yaml down -v
kill <next-dev-pid>
```

清理由用户在确认验收后执行。
