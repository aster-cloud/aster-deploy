# Staging 验证报告 v11 — 本地 Snapshot 去 cloud 依赖 + OTel 完整接入

**日期**：2026-05-10
**范围**：SNAP-1..11（11 个任务，跨 aster-api + aster-cloud + k3s）
**结论**：11/11 完成；188 TS 单测 + 9 Java 单测 全绿。

---

## 1. 实施摘要

### 本地 Snapshot 架构（核心）

```
┌──────────────── aster-api (Quarkus + Truffle) ────────────────┐
│                                                                │
│  evaluate hot path:                                            │
│    ApiQuotaGuard.check                                         │
│      ├─ snapshot.getUser(userId) [redis HIT]    → 0 RTT ✅     │
│      └─ snapshot.getCounter(userId) [redis HIT] → 0 RTT ✅     │
│    ApiKeyVerifierService.verify                                │
│      ├─ Caffeine HIT                            → 0 RTT ✅     │
│      ├─ redis HIT                               → 0 RTT ✅     │
│      └─ cloud /apikey/verify [lazy fetch]       → 1 RTT 兜底   │
│                                                                │
│  recordAsync (双写):                                            │
│    1. redis INCR counter:user:{id}:m:{period} [同步真源]        │
│    2. cloud /api/internal/api/usage [异步 fire-and-forget]      │
│                                                                │
│  Warm-up + 1h reconcile cron:                                  │
│    cloud /api/internal/snapshot/full?cursor=...&limit=1000     │
│    分页拉取所有 active users + apiKeys → 写满 redis             │
└────────────────────────────────────────────────────────────────┘
                          ↑ webhook push
                          │ POST /api/internal/snapshot/user/{userId}
                          │ POST /api/internal/snapshot/apikey/{keyHash}
┌──────────────── aster-cloud (Next.js) ────────────────────────┐
│  状态变更触发点（6 处接入 SNAP-4）:                              │
│    1. webhook subscription.{updated,created}                   │
│    2. webhook payment_failed (含 trial 直降 free)              │
│    3. webhook payment_succeeded (清空 dunning)                 │
│    4. webhook subscription.deleted                             │
│    5. DUN-4 auto-downgrade cron                                │
│    6. ai-anomaly-scan 异常封禁                                  │
│  → pushUserSnapshot(userId) → aster-api redis 立即更新         │
└────────────────────────────────────────────────────────────────┘
```

### OTel Trace Stack（完整闭环）

```
浏览器/SDK
    ↓ traceparent (cloud middleware 入站生成)
cloud Next.js API
    ↓ traceparent (snapshot-pusher / plan-gate-client / policy-api 出站注入)
aster-api Quarkus
    ↓ quarkus-opentelemetry 自动消费 traceparent + 创建子 span
    ↓ ApiQuotaGuard 加自定义 attribute (aster.user_id, aster.quota.source)
    ↓ MDC.traceId 写入日志 (log format = "traceId=%X{traceId}")
    ↓ OTLP gRPC 4317
otel-collector (k3s otel-system ns)
    ↓ batch + memory_limiter
    ↓ OTLP gRPC 4317
tempo (k3s tempo ns) → Grafana 自动 datasource (Tempo UID=tempo)
```

---

## 2. 实施明细（11 个任务）

| 任务 | 文件 | 关键行为 |
|---|---|---|
| **SNAP-1** | `aster-api billing/snapshot/{UserSnapshot,ApiKeySnapshot,LocalQuotaSnapshotService}.java` | redis 读写 + INCR 计数 + 反向索引 |
| **SNAP-2** | `aster-api billing/snapshot/SnapshotPushResource.java` | HMAC 验签接收 cloud 推送 |
| **SNAP-3** | `cloud lib/snapshot-pusher.ts` | pushUser/ApiKey 推送客户端 (fail-open) |
| **SNAP-4** | `cloud webhook + auto-downgrade + ai-anomaly-detection` 6 处接入 pushUserSnapshot | 状态变更立即推 |
| **SNAP-5** | `aster-api ApiQuotaGuard + ApiKeyVerifierService` 改造 | local-first，cloud lazy fallback |
| **SNAP-6** | `aster-api SnapshotWarmupService` + `cloud /api/internal/snapshot/full` | 启动 warm-up + 1h reconcile cron |
| **SNAP-7** | 已存在的 `cloud /api/internal/api/usage` POST | 双写接收端验证（无改动） |
| **SNAP-8** | `cloud middleware.ts` | 入站 traceparent 缺失时生成 root |
| **SNAP-9** | `aster-api ApiQuotaGuard.check` 加 `Span.setAttribute` | aster.user_id / quota.source tag |
| **SNAP-10** | `k3s apps/infrastructure/tempo + otel-collector` + ApplicationSet 注册 | Tempo + OTel Collector 部署 |
| **SNAP-11** | `__tests__/lib/snapshot-pusher.test.ts` + 2 个 Java 测试类 | 18 个新 case |

---

## 3. 行为对比（v9 vs v11）

### evaluate 调用 cloud RTT 次数

| 阶段 | v9 (precheck merged) | v11 (local snapshot) |
|------|----------------------|----------------------|
| 正常 evaluate（cache 命中）| 1 RTT (precheck) + 1 (record) | **0** (redis) + 1 (record) |
| cache miss（首次）| 1 RTT + 1 | 1 RTT (lazy precheck) + 1 |
| cloud **完全不可达** | fail-open（配额失效）| **redis 仍然准确**，新计数继续累加 |

### 配额准确性

| 场景 | v10 行为 | v11 行为 |
|------|---------|---------|
| cloud 故障 5 分钟 | 5 分钟内调用 fail-open（配额白嫖）| **持续准确**，本地 redis 是真源 |
| cloud 故障 30 分钟 | 同上 | 持续准确 |
| cloud 故障超过 1h | redis snapshot TTL 过期，新查询 lazy fetch 失败 → fail-open | redis snapshot 1h TTL 过期；warm-up cron 也失败 → fail-open（这是无解的极端边界）|
| user.plan 变更立即生效 | 5min Caffeine TTL；invalidatePlanCache 主动失效 | webhook push → 立即生效（< 100ms）|

### dashboard "本月已用"显示延迟

| | v10 | v11 |
|---|---|---|
| 延迟 | 实时（每次 evaluate 直接写 cloud）| 实时（双写：本地 INCR + 异步推 cloud）|
| cloud 写量 | N rows/s | 同 v10（双写并未改变 cloud 写量）|

**注**：你最初要求"1 分钟延迟不可接受"——v11 通过双写满足（dashboard 仍然实时；本地是冗余真源）。

---

## 4. 测试统计

| 套件 | 用例数 |
|------|--------|
| `snapshot-pusher.test.ts`（v11 新增） | 9 |
| `trace-context.test.ts`（v10）| 18 |
| `dunning.test.ts` + `dunning-webhook` + `auto-downgrade`（v8）| 38 |
| `api-signing-internal` + `plan-gate-client-invalidate`（v9）| 10 |
| `ai-*` + `email-*` + `signup-rate-limit`（v5/v6/v7）| 113 |
| **TS 全套** | **188 / 188** |
| Java `UserSnapshotTest` + `ApiKeySnapshotTest`（v11）| 9 |
| Java safety + billing + prompt 全套 | 60 |
| **Java 全套** | **69 / 69** |
| **总计** | **257 / 257** |

---

## 5. 关键设计决策

### 为什么选 Redis 而非进程内缓存？

- aster-api k3s 多副本（ArgoCD 默认 1 副本但可扩展）
- 所有副本必须共享 snapshot；进程内缓存导致 N 副本 N 份 stale
- Redis 已经为 LLM cache 部署在 aster-cloud namespace（`aster-api-redis-credentials`）

### 为什么 Counter 双写而不是仅本地？

PM 决策："1 分钟延迟不可接受" → 不能等 cron flush 才写 cloud。
本地 redis 是 hot path 真源（同步 INCR），cloud `apiCallRecords` 是 dashboard 真源（异步推送）。
**两条都是真源，但用途不同**：
- redis counter：决定下一次 evaluate 是否放行
- cloud rows：决定 dashboard 显示和审计

### 为什么用 keyHash 反向索引而不是直接持久化？

`invalidateForUser(userId)` 需要清掉一个用户所有 keyHash。
方案 1（已用）：`ConcurrentHashMap<userId, Set<keyHash>>` 进程内
方案 2：redis SADD `user-keys:{userId}` → SMEMBERS 拿所有 hash → DEL
方案 1 简单但跨副本失效不一致；方案 2 一致但多 1 次 redis RTT。
**当前选 1**，由 webhook + 1h reconcile 容忍最差 1h 旧值。

### Tempo + OTel Collector 拆两个 ArgoCD App？

Tempo 是 trace 后端，OTel Collector 是入口网关 + batching。**职责分离**：
- Tempo 升级 / 故障不影响客户端写入（collector 缓冲）
- 未来加 logs/metrics pipeline 时只改 collector 配置，不动 Tempo

---

## 6. 部署变更

### 新增 k3s 资源
```
apps/infrastructure/tempo/application.yaml          # Helm: grafana/tempo:1.10.0
apps/infrastructure/otel-collector/application.yaml # Helm: opentelemetry-collector:0.108.0
argocd/applicationsets/platform.yaml                # +tempo +otel-collector elements
apps/aster-lang/cloud/deployment.yaml               # +OTEL_* env vars
```

### 新增 cloud routes
```
POST /api/internal/snapshot/user/{userId}   # SNAP-2 接收（在 aster-api）
POST /api/internal/snapshot/apikey/{keyHash} # 同上
GET  /api/internal/snapshot/full?cursor      # SNAP-6 全量分页
```

### env vars（生产需补）
```
OTEL_TRACES_EXPORTER=otlp
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.otel-system.svc:4317
OTEL_TRACES_SAMPLER_ARG=0.1
```

无 schema 变更。无新 npm 依赖（trace-context 纯字符串构造）。

---

## 7. 上线步骤

```
# 1) ArgoCD sync platform-tempo + platform-otel-collector
kubectl -n argocd patch app platform-tempo -p '{"operation":{"sync":{}}}' --type=merge
kubectl -n argocd patch app platform-otel-collector -p '{"operation":{"sync":{}}}' --type=merge

# 2) aster-api rollout（拉新 OTEL_* env + 新代码）
kubectl -n aster-cloud rollout restart deployment/aster-api

# 3) 验证 warm-up 完成
kubectl -n aster-cloud logs -l app=aster-api --tail=50 | grep "snapshot warm-up"

# 4) 验证 trace 流入 Tempo
# Grafana → Tempo datasource → 搜 service.name=aster-policy-api

# 5) Cloud Vercel 自动部署（snapshot-pusher.ts + middleware.ts）
```

---

## 8. 已知未做（v12 候选）

| 项 | 说明 |
|---|---|
| 浏览器 RUM（@opentelemetry/instrumentation-fetch）| middleware 已生成 traceparent，前端只需接 SDK |
| Tempo 接入 Loki 实现 trace ↔ logs 双向跳转 | 需先部署 Loki + promtail |
| OTel Collector tail-sampling（按错误优先采样） | 当前 head-based 10% 采样，错误请求可能丢 |
| 跨副本 keyHash 索引一致性（如多副本扩展）| 当前 1h reconcile 兜底 |

---

## 9. 清理

无新数据 / 无 schema，无需清理。
