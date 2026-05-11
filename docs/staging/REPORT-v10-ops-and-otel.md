# Staging 验证报告 v10 — Ingress 屏蔽 + 跨服务 OTel Trace

**日期**：2026-05-10
**范围**：OPS-1 + OTEL-1..3（4 个任务，跨 k3s + aster-cloud + aster-api）
**结论**：4/4 完成；179 单测全绿；2 chrome 烟测通过；0 console error。

---

## 1. 实施摘要

### OPS-1：ingress 层屏蔽 `/evaluate-source`

文件：`k3s/apps/aster-lang/cloud/ingress-deny-evaluate-source.yaml`

```yaml
Middleware: block-evaluate-source        # replacePathRegex 改写到不存在的路径 → 404
IngressRoute: aster-api-deny-evaluate-source  # 仅匹配精确路径 evaluate-source
```

**作用**：traefik 层 404 兜底防御。即使 `InternalCallerFilter`（AKA-9）配错，
`policy.aster-lang.dev/api/v1/policies/evaluate-source` 也直接 404。

**cloud BFF 怎么调？** Cloud 通过 `ASTER_POLICY_API_INTERNAL_URL` 走集群内 service DNS
（`http://aster-api.aster-cloud.svc:80`），**绕过 ingress** 直连 service，
不受此 middleware 影响。两层防御正交。

### OTEL-1：cloud 出站 fetch 注入 traceparent

新文件：`aster-cloud/src/lib/trace-context.ts`（W3C Trace Context 实现，无 SDK 依赖）
- `parseTraceparent(header)` — 解析入站
- `newTraceContext()` — 新建 root（traceId 32 hex + spanId 16 hex + flags=01）
- `childSpan(parent)` — fan-out 时复用 traceId 但换 spanId
- `ensureTraceContext(req)` — 入站缺失/非法 → 自动新建

接入点：
- `lib/plan-gate-client.ts` (invalidate{Plan,ApiKey}Cache)
- `services/policy/policy-api.ts.request()` (所有 cloud → aster-api 调用)

每次 fetch header 加 `traceparent: 00-<traceId>-<spanId>-01`。

### OTEL-2：aster-api 日志加 traceId

`application.properties`:
```properties
quarkus.log.console.format=%d{HH:mm:ss} %-5p [%c{2.}] (%t) traceId=%X{traceId} %s%e%n
```

quarkus-opentelemetry 已自动把 traceId 写入 MDC，配置生效后所有日志行都带 `traceId=<32hex>`。
配合 cloud 端日志（`console.warn(...)` 含 traceparent）可在 ELK / Loki 跨服务串起来。

### OTEL-3：trace-context 单测（18 cases）

`__tests__/lib/trace-context.test.ts`

- parseTraceparent：合法 / null / 错版本 / 错长度 / 非 hex / 空白处理（7）
- newTraceContext：长度 / flags / 一致性 / 随机性（5）
- childSpan：traceId 继承 + spanId 不同（3）
- ensureTraceContext：合法透传 / 缺失新建 / 非法忽略（3）

---

## 2. 数据流

### 跨服务 trace 建立链

```
浏览器 → cloud /api/v1/policies/[id]/execute
   ├─ ensureTraceContext(req) 拿或建 traceparent
   │  「场景 A：入站已有 traceparent → 透传」
   │  「场景 B：浏览器没传 → cloud 新建 root」
   │
   ├─ executePolicyUnified 本地 TS 跑（不需要 traceparent，单进程）
   │
   └─ 出站 fetch 到 aster-api（如 invalidatePlanCache）
      Headers: traceparent: 00-<traceId>-<spanId-A>-01
      ↓
aster-api 收到请求
   ├─ quarkus-opentelemetry 自动消费 traceparent
   │  → MDC.traceId = <traceId>
   │  → 创建 child span（spanId-B，同 traceId）
   ├─ 日志: "traceId=<traceId> Evaluating policy: ..."
   └─ 异常: GlobalExceptionMapper 已读 SpanContext.traceId
      → 错误响应里带同一个 traceId 给客户端排查
```

### 排查实战示例

客户报"调用失败 traceId=abc123def456..."
- 在 cloud 日志：`grep abc123def456 cloud.log` → 找到 fetch 出站时的 traceparent
- 在 aster-api 日志：`grep abc123def456 aster-api.log` → 看到处理过程
- 一条 grep 串起两端

---

## 3. 测试结果

| 套件 | 用例 | 状态 |
|------|------|------|
| `trace-context.test.ts`（v10 新增） | 18 | ✅ |
| 历史 TS 测试不回归 | 161 | ✅ |
| **TS 全套** | **179 / 179** | ✅ |
| `ApiKeyVerifyResultTest`（v9） | 2 | ✅ |
| Java safety + billing 全套 | 57 | ✅ |
| Chrome 烟测（/api/auth/session, /api/user/dunning-status） | 2 | ✅ |
| 控制台 error | 0 | ✅ |

---

## 4. 未做（v11 候选）

| 项 | 说明 |
|---|---|
| 浏览器侧入站 traceparent | 大部分浏览器请求由 next-auth / next.js 内部触发，没主动传；如需 RUM 跨服务 trace 要接 `@opentelemetry/instrumentation-fetch` |
| OTel Collector / Tempo / Jaeger | aster-api 已配 OTLP exporter，需运维侧把 endpoint 指向真实 collector（生产已有 Prometheus，trace 后端待定） |
| Span 名 / 自定义 attribute | 当前 OTel 自动为每个 HTTP 端点生成 span；未给 evaluate / dunning 等关键路径手动加 span name + tag |
| ingress 单测（curl `/evaluate-source` 验证 404） | k3s 环境下需要 staging cluster；本期只 kustomize 校验渲染 OK |

---

## 5. 部署变更清单

| 资源 | 变更 |
|------|------|
| k3s `aster-cloud/ingress-deny-evaluate-source.yaml` | **新增**（Middleware + IngressRoute） |
| k3s `aster-cloud/kustomization.yaml` | 加一行引用 |
| aster-api `application.properties` | log.console.format 改 |
| aster-cloud `lib/trace-context.ts` | **新文件** |
| aster-cloud `lib/plan-gate-client.ts` | 加 traceparent 头 |
| aster-cloud `services/policy/policy-api.ts` | 加 traceparent 头 |

无新依赖。无 schema 变更。无 env vars 变更。

---

## 6. 上线步骤

```
# 1) ArgoCD 自动 sync k3s/apps/aster-lang/cloud（含新 ingress + middleware）
# 2) aster-api 滚动重启拿新 log format
kubectl -n aster-cloud rollout restart deployment/aster-api

# 3) cloud 由 Vercel 自动部署
# 4) 验证：
curl -s -o /dev/null -w '%{http_code}\n' https://policy.aster-lang.dev/api/v1/policies/evaluate-source
# 期望 404
```

---

## 7. 清理

无新数据 / 无 schema，无需清理。
