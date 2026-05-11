# Staging 验证报告 v9 — API Key 认证 + RTT 优化

**日期**：2026-05-10
**范围**：AKA-1..9（9 个任务，跨 aster-api + aster-cloud）
**结论**：9/9 任务全部交付；163 单测全绿（2 Java + 161 TS）；5 chrome E2E 全过。

---

## 1. 设计动机

v8 完成 dunning 后发现：
- aster-api 公开 `policy.aster-lang.dev` 但**没有真正的 API key 校验**
- DUN-4 把 `apiKeys.revokedAt` 写库后，aster-api 端没人查这个字段
- `/evaluate-source` 接受请求体源码 → 公开后客户可绕过审核流提交未批准代码
- `ApiQuotaGuard.check()` 每次 evaluate 调 cloud 2 次（plan-gate + usage 查询）

本期解决以上 4 个问题。

---

## 2. 实施摘要

| 任务 | 文件 | 作用 |
|------|------|------|
| AKA-1 | `cloud /api/internal/apikey/verify/route.ts` | HMAC 内部接口，单 SQL JOIN 验证 keyHash |
| AKA-2 | `cloud lib/plan-gate-client.ts` 加 `invalidateApiKeyCache` | 出站客户端，通知 aster-api 失效缓存 |
| AKA-3 | `aster-api security/apikey/ApiKeyVerifierService.java` | 5min Caffeine 缓存 + userId→hashes 反向索引 |
| AKA-4 | `aster-api security/apikey/ApiKeyAuthFilter.java` | `@ServerRequestFilter`，仅守 `/evaluate{,-json,/batch}` |
| AKA-5 | `aster-api security/apikey/ApiKeyCacheResource.java` | DELETE `/api/internal/apikey-cache/{userId}`（HMAC） |
| AKA-6 | `cloud auto-downgrade/route.ts` + webhook `subscription.deleted` | DUN-4 + Stripe 删除时调 invalidateApiKeyCache |
| AKA-7 | `__tests__/lib/api-signing-internal.test.ts` + `plan-gate-client-invalidate.test.ts` + Java `ApiKeyVerifyResultTest` | 12 用例 |
| AKA-8 | `cloud /api/internal/api/precheck/route.ts` + `aster-api ApiQuotaGuard.fetchPrecheck()` | 合并 plan + usage 查询为单 RTT |
| AKA-9 | `aster-api security/apikey/InternalCallerFilter.java` + `cloud lib/api-signing.ts signInternalCallerHeaders` | `/evaluate-source` 仅 cloud BFF 可调 |

---

## 3. 数据流（关键路径）

### 客户调 `/api/v1/policies/evaluate`（生产路径）

```
SDK 请求 → Authorization: Bearer ak_xxx
   ↓
RequestSignatureFilter（HMAC 防篡改 — 已存在）
   ↓
InternalCallerFilter（跳过非 evaluate-source 路径）
   ↓
ApiKeyAuthFilter（AKA-4）
   ├─ SHA-256(plaintext) → 64 char hex
   ├─ ApiKeyVerifierService.verify
   │   ├─ Caffeine cache 命中？→ 直接返回
   │   └─ miss → cloud /api/internal/apikey/verify
   │       ├─ revokedAt != null → invalid
   │       └─ valid → cache + 写 userId→hashes 反向索引
   └─ 写 routingContext.apikey.userId/tenantId/apiKeyId
   ↓
PolicyEvaluationResource.evaluate
   ├─ enforceApiQuota → ApiQuotaGuard.check
   │   └─ AKA-8: 一次 GET /api/internal/api/precheck
   │       返回 {plan, apiCallsLimit, monthlyUsed, banned}
   ├─ 数据库读 published version（你的"防中间人"设计）
   ├─ Truffle 执行
   └─ recordApiCall 异步写 cloud apiCallRecords
```

**RTT 改进**：每次 evaluate 从 2 次 cloud 调用降为 1 次（精确度未损失）。

### 客户调 `/api/v1/policies/evaluate-source`（被屏蔽）

```
SDK 请求 → InternalCallerFilter (AKA-9)
   ├─ 没有 X-Internal-Caller / 签名 → 403 evaluate_source_internal_only
   └─ 仅当 cloud BFF 走 signInternalCallerHeaders 才能通过
```

### DUN-4 auto-downgrade 时的失效链

```
Day 21 cron 跑 auto-downgrade
   ↓
DB: plan='free', apiKeys.revokedAt=now
   ↓
invalidatePlanCache(userId)    → aster-api 5min plan 缓存失效
invalidateApiKeyCache(userId)  → aster-api 失效该用户所有 key 缓存（AKA-6）
   ↓
下一次 SDK 请求带旧 key 调 evaluate
   ├─ ApiKeyAuthFilter cache miss
   ├─ → cloud /apikey/verify 返回 {valid:false, reason:"revoked"}
   └─ 401 unauthorized
```

---

## 4. 测试结果

### 单元测试

| 套件 | 用例数 |
|------|--------|
| `api-signing-internal.test.ts`（5 cases） | 5 |
| `plan-gate-client-invalidate.test.ts`（fail-open / 签名 / 路径） | 5 |
| Java `ApiKeyVerifyResultTest`（factory / 字段映射） | 2 |
| **AKA 合计** | **12** |
| 历史 TS 测试不回归（含 dunning） | 151 |
| **TS 全套** | **161 / 161** |
| **Java safety+billing 全套** | **57 / 57** |

### Chrome E2E（5 场景）

| # | 场景 | 期望 | 实际 |
|---|------|------|------|
| 1 | `/api/internal/apikey/verify` 无签名 | 401 | ✅ |
| 2 | `/api/internal/apikey-cache/{id}` 无签名（cloud 没此入站路由） | 404（设计如此） | ✅ |
| 3 | `/api/internal/api/precheck` 无签名 | 401 | ✅ |
| 4 | 带 HMAC + 不存在的 keyHash | `{valid: false, reason: "not_found"}` | ✅ |
| 5 | 带 HMAC + free 用户 precheck | `{plan: "free", apiCallsLimit: 0, monthlyUsed: 0}` | ✅ |

---

## 5. 关键设计决策

### 缓存 fail-open 的非对称策略

| 状态 | aster-api 的行为 |
|------|----------|
| cloud 可达 + 验证通过 | 缓存 + 放行 |
| cloud 可达 + 验证失败（revoked / not_found） | 不缓存 + 拒绝 |
| **cloud 不可达 + cache 命中** | **用缓存（放行）** |
| **cloud 不可达 + cache miss** | **拒绝**（防伪造新 key 蒙混） |

权衡："已被 revoke 的 key 在 cache 过期前还能用 5 分钟"是可接受窗口；
"伪造的 key 因 cloud 故障而蒙混"是不可接受。

### 反向索引（userId → keyHashes）

`ApiKeyVerifierService` 维护一个 `ConcurrentHashMap<userId, Set<keyHash>>`，
用于 `invalidateForUser(userId)` 一次性清掉一个用户所有 key 缓存。
这是 DUN-4 auto-downgrade 时最关键的一步——
否则要扫整个 cache 找匹配，O(n) 不可接受。

### `/evaluate-source` 的两层守卫

1. **InternalCallerFilter**（AKA-9）：要求 `X-Internal-Caller=cloud-bff` + HMAC
2. **生产建议**：再加 ingress 路径分级，把 `policy.aster-lang.dev/api/v1/policies/evaluate-source` 在 traefik 层 404（防 filter 配错）

第 2 步是 ops 改造，未在本期实施。

---

## 6. 端到端 RTT 改进数据

| 场景 | v8（旧）cloud 调用次数 | v9（新）|
|------|---------|--------|
| 正常 evaluate（cache 命中）| plan-gate(命中) + usage(必查) + record = **2** | precheck(必查) + record = **1** |
| 正常 evaluate（cache miss） | plan-gate(查) + usage(查) + record = **3** | precheck(查) + record = **1** |
| 带 API key 的 evaluate | + apikey/verify(cache) = **2-3** | + apikey/verify(命中)/precheck/record = **1-2** |
| `policy.aster-lang.dev` 跨大洋时 | 2 × 60-200ms = +120-400ms | 1 × 60-200ms = +60-200ms |

**实际生产**：每次 evaluate 给 SDK 客户**少一次 60-200ms 的 RTT**。

---

## 7. 已知未做（v10 候选）

| 项目 | 备注 |
|------|------|
| ingress 层路径分级（traefik 屏蔽 `/evaluate-source` 公开路径） | 0.5 天 ops，零代码 |
| API key 创建 / 撤销时主动失效（用户在 dashboard 操作） | 复用 `invalidateApiKeyCache` 即可 |
| 跨服务 trace ID 透传（OTel） | v8 报告就提了，仍未做 |
| AKA-3 缓存预热（启动时拉所有 active key）| 优化项，不阻塞 |

---

## 8. 部署变更

### 配置项（生产需补）
```
aster.security.apikey.enabled=true       # ApiKeyAuthFilter 总开关（默认 true）
aster.security.evaluate-source.public=false  # 生产必须 false（默认 false）
ASTER_PLAN_GATE_HMAC_KEY=<≥32 字符>      # InternalCallerFilter / Apikey 路径共用
```

### Cloud 路由
新增 3 条：
- `POST /api/internal/apikey/verify`
- `GET /api/internal/api/precheck`
- （`DELETE /api/internal/apikey-cache/{userId}` 在 aster-api 侧）

### aster-api Filter 优先级
```
RequestSignatureFilter   = AUTHENTICATION (1000)
InternalCallerFilter     = AUTHENTICATION + 50 (1050)
ApiKeyAuthFilter         = AUTHENTICATION + 100 (1100)
TenantFilter / RoleEnforcement = 后续
```

---

## 9. 与 v7/v8 报告中"已知未做"的关系

| v7/v8 待办 | v9 是否解决？|
|-----------|-----------|
| API key 不被真正校验 | ✅ AKA-1..7 解决 |
| evaluate 路径每次 2 次 cloud RTT | ✅ AKA-8 降为 1 次 |
| evaluate-source 公开漏洞 | ✅ AKA-9 解决 |
| cloud 不可达时 fail-open 让配额失效 | ⚠️ 仍存在（中长期方案 A：本地配额 snapshot） |
| 观测性割裂（无 trace ID） | ❌ 未做 |
| Stripe metered overage billing | ❌ 未做（PM 说 50 客户后再做） |

---

## 10. 清理

```
podman compose -f aster-deploy/podman/podman-compose.staging.yaml down -v
kill <next-dev-pid>
```

由用户确认验收后执行。
