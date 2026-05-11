# ADR：跨服务 Plan Gate 接口契约

> 版本 v1.0 · 2026-05-10
> 状态：已实施（aster-api B6 / aster-cloud /api/internal/tenant/[id]/plan）
> 关联：05-pricing-packaging.md / 03-telemetry-spec.md

---

## 背景

PM v1.1 决策"保留 Team 数据模型，下线 Team 档位"导致一个新约束：
**aster-api 的审批流 plan gate 必须知道租户当前订阅档位**，但 plan 数据存于 aster-cloud。

aster-api（Java/Quarkus）和 aster-cloud（Next.js）是独立部署的两个服务，不共享数据库（aster-api 用 policy_versions / audit_logs，aster-cloud 用 users / teams / policies）。

## 决策

aster-cloud 暴露内部接口 `GET /api/internal/tenant/{tenantId}/plan`，aster-api 通过 Vert.x WebClient 调用，Caffeine 缓存 5 min。

**优先级**：业务可用性 > plan 强一致性。失败时 fail-open（按 Pro 处理），不阻塞业务。

## 接口契约

### 请求

```http
GET /api/internal/tenant/ut2026w3/plan
Host: aster-cloud:3000
X-Aster-Timestamp: 1715342400
X-Aster-Signature: 7b6f...
```

签名规则（HMAC-SHA256）：

```
message  = "GET\n" + path + "\n" + timestamp
key      = ASTER_PLAN_GATE_HMAC_KEY (env, 共享密钥)
signature = hex(hmac_sha256(key, message))
```

时间戳防重放：5 分钟窗口（`abs(now - timestamp) > 300` 拒绝）。

### 响应

```json
{
  "plan": "pro",
  "legacyTier": "team",
  "allowsApproval": true,
  "maxTeamMembers": -1,
  "evaluationsLimit": 50000
}
```

字段语义：

| 字段 | 类型 | 含义 |
|---|---|---|
| `plan` | enum | 当前 plan：free / trial / pro / team / enterprise |
| `legacyTier` | nullable | 仅 Team grandfather 客户为 "team"，UI 显示 Pro |
| `allowsApproval` | boolean | 是否允许提交审批流（Pro/Enterprise = true） |
| `maxTeamMembers` | int | 团队成员上限，-1 表示无限 |
| `evaluationsLimit` | long | 月评估次数限额，-1 表示无限 |

未识别 tenant 一律返回 free 默认值（`allowsApproval=false`），由调用方按需处理。

## tenantId 解析规则

约定：aster-api 的 `tenantId` = aster-cloud 的 `Team.id` 或 `User.id`：

1. 先匹配 `teams.id`：是团队 tenant，用 team owner 的 plan 表征
2. 否则匹配 `users.id`：是个人 tenant
3. 都找不到：按 free 处理 + 不告警（可能是新租户尚未同步）

## 缓存策略

- aster-api 用 Caffeine `expireAfterWrite = 5 min`
- 目的：让 plan 升级 5 分钟内生效，同时降低 cloud 压力
- 紧急场景：cloud 升级回调可调用 `aster-api://plan-gate/invalidate/{tenantId}`（待实现）让缓存立即失效

## 故障处理（Fail-Open）

| 场景 | 处理 |
|---|---|
| HTTP 超时 / 连接拒绝 | 按 Pro 处理；告警 `mixpanel_events_dropped_total`-style metric |
| HTTP 5xx | 同上 |
| HTTP 401 (签名错误) | **fail-close**：抛 PlanLimitException("plan_lookup_failed")，避免误授权 |
| HTTP 200 但 JSON 解析失败 | 按 Pro 处理；告警 |
| cloud 完全宕机 | 按 Pro 处理；监控告警 |

`failOpen = true` 是默认；运维团队可通过 `aster.plan-gate.fail-open=false` 切换为严格模式（仅在确认审计/合规要求时）。

## 安全考量

- **服务网格内通信**：生产环境 aster-api ↔ aster-cloud 走 K3S 内网，外部不可达
- **HMAC 共享密钥**：通过 ExternalSecret 同时注入到两个服务的 env
- **时间戳防重放**：5 min 窗口
- **Timing-safe compare**：`crypto.timingSafeEqual` 防止时序攻击
- **dev 模式**：缺省 `ASTER_PLAN_GATE_HMAC_KEY` 时不验签（仅本地开发，K3S 部署强制要求）

> 注：CLAUDE.md 全局规则将安全优先级降低，但跨服务调用的最小防护仍保留（HMAC + timestamp）。

## 实现文件

| 仓库 | 文件 |
|---|---|
| aster-api | `src/main/java/io/aster/billing/PlanGateService.java` |
| aster-api | `src/main/java/io/aster/billing/PlanGateConfig.java` |
| aster-api | `src/main/java/io/aster/billing/PlanInfo.java` |
| aster-api | `src/main/java/io/aster/billing/PlanLimitException.java` |
| aster-api | `src/main/java/io/aster/billing/PlanLimitExceptionMapper.java` |
| aster-cloud | `src/app/api/internal/tenant/[id]/plan/route.ts` |

## 业务集成点

`PolicyVersionService.submitForApproval` 入口检查：

```java
if (!planGate.allowsApproval(version.tenantId)) {
    throw new PlanLimitException("reviewer_required");
}
```

ExceptionMapper 转换为 HTTP 402 + JSON：

```json
{
  "upgrade": true,
  "reason": "reviewer_required",
  "recommendedPlan": "pro",
  "message": "upgrade required: reviewer_required"
}
```

前端 UpgradeBlocker 接收此响应弹出升级提示（含 SOX 职责分离文案）。

## 演进路径

| 阶段 | 状态 |
|---|---|
| v1.1：基础 Plan Gate（5 min 缓存 + fail-open） | ✅ 当前 |
| v1.2：cloud → api 主动失效回调 | 待实现 |
| v1.3：传播 author_role 头（X-User-Role），让 WAADR 视图按业务角色过滤 | 待 PM 决策 |
| v2.0：plan 数据下沉到 aster-api（共享 Postgres 或 Kafka 同步） | 视规模决定 |

## 风险与监控

| 风险 | 缓解 | 监控 |
|---|---|---|
| cloud 不可用，业务被 plan 系统拖死 | failOpen=true（默认） | aster-api 端 Caffeine miss rate |
| 5 min 缓存导致升级生效延迟 | 短窗口 + 失效回调（v1.2） | TRIAL_CONVERTED_TO_PAID → 第一次成功 submitForApproval 的延迟 |
| HMAC 密钥泄露 | 通过 K8s Secret + Vault 管理 | 异常登录告警 |
| 未识别 tenant 大量返回 free | tenant 同步差错 | 日志告警「unknown tenant rate > 1%」 |

---

**版本**：v1.0 · 2026-05-10
