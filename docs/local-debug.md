# 本地调试指南

## 前置条件

- Podman + podman-compose（或 Docker + docker-compose）
- Java 25 (Temurin/Zulu)
- Node.js 24 + pnpm
- IntelliJ IDEA (推荐)

## 快速开始

### 1. 启动基础设施

```bash
task local:infra
```

启动 Postgres (5432) 和 Redis (6379)。

### 2. 调试 aster-api (Quarkus)

**IntelliJ 方式（推荐）**：
1. 打开 `aster-api` 项目
2. 运行 `quarkusDev` Gradle 任务，或在终端执行：
   ```bash
   cd /path/to/aster-api && ./gradlew quarkusDev
   ```
3. Quarkus dev mode 自动连接 `localhost:5432` (Postgres) 和 `localhost:6379` (Redis)
4. 修改 Java 文件 → 自动热重载
5. 调试器默认监听端口 5005

**验证**：
```bash
curl http://localhost:8080/q/health
curl http://localhost:8080/q/swagger-ui
```

### 3. 调试 aster-cloud (Next.js)

```bash
cd /path/to/aster-cloud
NEXT_PUBLIC_API_URL=http://localhost:8080 pnpm run dev
```

访问 http://localhost:3000，Next.js Fast Refresh 提供热重载。

### 4. 调试 aster-lsp

```bash
cd /path/to/aster-cloud
pnpm run dev:lsp
```

LSP 服务监听端口 3001。

### 5. 验证

```bash
task verify:local
```

### 6. 清理

```bash
task local:stop     # 停止容器
task local:clean    # 删除容器和数据卷
```

## Scheme B: API 无认证测试（IDE + curl）

当使用 `task local:infra` + IDE Quarkus dev mode 时，可通过环境变量禁用安全控制，直接用 curl/Postman 测试 API。

### 启动 Quarkus（安全禁用）

```bash
cd /path/to/aster-api
ASTER_SECURITY_SIGNATURE_ENABLED=false \
ASTER_SECURITY_RBAC_ENABLED=false \
ASTER_RATELIMIT_ENABLED=false \
ASTER_PII_ENFORCE=false \
ASTER_TENANT_STRICT_FORMAT=false \
./gradlew quarkusDev
```

### curl 测试示例

```bash
# 健康检查
curl http://localhost:8080/q/health

# 评估策略源码（无需认证）
curl -X POST http://localhost:8080/api/v1/policies/evaluate-source \
  -H "Content-Type: application/json" \
  -H "X-Tenant-Id: test" \
  -d '{"source": "Module Test."}'
```

## Scheme C: 全栈容器化测试

使用 `task local:test` 启动全栈测试环境，自动禁用安全控制并创建测试用户。

```bash
# 启动（首次需要构建）
task local:test

# 验证
task verify:test

# 登录: http://localhost:3000/login
# 邮箱: test@aster.dev  密码: test1234
```

详见 [README.md](../README.md) 中的命令参考。

## 常见问题

### Postgres 端口被占用

```bash
# 查看占用进程
lsof -i :5432
# 修改端口
echo "LOCAL_PG_PORT=5433" >> .env
```

### Quarkus 连不上数据库

确认 `application.properties` 中的默认连接字符串指向 `localhost:5432`。Podman 容器已将端口映射到主机。

### Redis 连接超时

确认 Redis 容器健康：
```bash
podman exec aster-redis redis-cli ping
```
