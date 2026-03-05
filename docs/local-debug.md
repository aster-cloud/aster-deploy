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
