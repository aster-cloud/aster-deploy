# Grafana / Prometheus 接入 Authentik SSO

> 详见 K3S manifest：`k3s/apps/infrastructure/monitoring/application.yaml`

---

## 现状（生产 K3S）

| 服务 | URL | 鉴权方式 |
|---|---|---|
| Prometheus | https://prometheus.aster-lang.cloud | Authentik forward-auth (Traefik middleware) |
| Grafana | https://grafana.aster-lang.cloud | Authentik OAuth2 generic (Grafana 内置) + 本地 admin 兜底 |
| Alertmanager | 经 Prometheus 同 host 路由 | 同 Prometheus |

**为什么 Grafana 用 OAuth 而不是 forward-auth**：Grafana 自身有 RBAC（Viewer / Editor / Admin），通过 OAuth `role_attribute_path` 把 Authentik group 映射为 Grafana role，让"是谁"和"能做什么"在 Grafana 内一致。forward-auth 只能做"能不能进"。

---

## Authentik 配置（一次性，需手工）

### 1. 创建 OAuth2 Provider

Authentik admin → Providers → Create → OAuth2/OpenID Provider：

| 字段 | 值 |
|---|---|
| Name | `grafana` |
| Client type | Confidential |
| Client ID | (Authentik 自动生成，复制) |
| Client Secret | (Authentik 自动生成，复制) |
| Redirect URIs | `https://grafana.aster-lang.cloud/login/generic_oauth` |
| Signing Key | authentik Self-signed Certificate |
| Scopes | openid, email, profile, offline_access |

### 2. 创建 Application

Authentik admin → Applications → Create：

| 字段 | 值 |
|---|---|
| Name | Grafana |
| Slug | grafana |
| Provider | grafana（上一步） |
| Launch URL | https://grafana.aster-lang.cloud |

### 3. 写入 Vault

```bash
# 假设 Vault CLI 已配
vault kv put secret/infrastructure/monitoring \
  grafana_oauth_client_id="<step1 client id>" \
  grafana_oauth_client_secret="<step1 client secret>"
```

ExternalSecret 会在 1 小时内同步（手动 `kubectl rollout restart -n monitoring statefulset/prometheus-grafana` 即时生效）。

### 4. 创建 Authentik Group → Grafana Role 映射

| Authentik Group | Grafana Role |
|---|---|
| aster-admins | GrafanaAdmin |
| aster-editors | Editor |
| 其他登录用户 | Viewer（默认） |

映射规则在 `application.yaml` 的 `role_attribute_path` 字段写死，不需要 Authentik 端配置。

---

## Staging 测试

staging 不接 Authentik（避免起庞大的 OIDC 容器）。Grafana 走默认 admin/admin。

如果你想在 staging 也测 SSO 流程，最简方案：

```bash
# 起 keycloak（更轻）
podman run -d --name staging-oidc \
  -e KEYCLOAK_ADMIN=admin -e KEYCLOAK_ADMIN_PASSWORD=admin \
  -p 8180:8080 \
  quay.io/keycloak/keycloak:25.0 start-dev

# 在 Grafana env 里指向 keycloak
GF_AUTH_GENERIC_OAUTH_ENABLED=true
GF_AUTH_GENERIC_OAUTH_AUTH_URL=http://localhost:8180/realms/master/protocol/openid-connect/auth
...
```

---

## 故障排查

| 现象 | 排查 |
|---|---|
| 点 "Sign in with Authentik" 无反应 | 检查 client_id 是否注入：`kubectl get secret -n monitoring grafana-oauth -o yaml` |
| Authentik 返回但 Grafana 报 "User sync error" | 检查 Authentik provider scope 包含 `email`、`profile` |
| 登录后角色总是 Viewer | `role_attribute_path` JMESPath 出错；先看 grafana log `tail` |
| 本地 admin 也登不上 | 本地兜底未禁用；用 `kubectl exec` 进 pod 看 `grafana.ini` 是否生效 |
| Prometheus 跳转到 Authentik 失败 | forwardAuth address 端口 9000 是否能访问：`kubectl exec -n authentik ...` |

---

## 验证

```bash
# 1. 浏览器开 https://grafana.aster-lang.cloud
# 2. 点 "Sign in with Authentik"
# 3. Authentik 登录页 → 用 LDAP / 内置用户登录
# 4. 跳回 Grafana，左下角用户菜单显示 Authentik 邮箱
# 5. 角色根据 group 映射（admin / editor / viewer）

# Prometheus：
# 1. 浏览器开 https://prometheus.aster-lang.cloud
# 2. Traefik forward-auth 拦截 → Authentik 登录页
# 3. 登录后回到 Prometheus，cookie `authentik_proxy=...` 携带 30 天
```
