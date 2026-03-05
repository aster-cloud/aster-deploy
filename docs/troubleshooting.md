# 故障排除

## 预检失败

### Java 版本不匹配

项目需要 Java 25。安装 Zulu/Temurin JDK 25：
```bash
# macOS
brew install --cask zulu@25
```

### Podman 未安装

```bash
# macOS
brew install podman podman-compose
podman machine init
podman machine start
```

### 项目目录未找到

确认 `.env` 中 `ASTER_REPOS_DIR` 指向包含所有 `aster-*` 目录的父目录。

## 构建失败

### Gradle 依赖解析失败

依赖链要求按序构建：core → packs → runtime → truffle → api。使用 `task dev` 自动处理依赖顺序。

### pnpm install 失败

```bash
# 清除缓存
pnpm store prune
rm -rf node_modules
pnpm install
```

## 容器问题

### 端口被占用（"address already in use"）

Podman gvproxy 可能在旧容器删除后仍持有端口转发。解决方案：

```bash
# 方案 1: 使用其他端口
LOCAL_PG_PORT=5433 task local:infra

# 方案 2: 重启 Podman machine 释放端口
podman machine stop && podman machine start
task local:infra
```

在 `.env` 中设置 `LOCAL_PG_PORT=5433` 可永久避免冲突。注意同时更新 aster-api 的 `application.properties` 中的端口。

### Podman rootless 网络

macOS 上 Podman 运行在 VM 中。容器间通信使用服务名（如 `postgres`），容器到主机使用 `host.containers.internal`。

### 镜像推送失败

```bash
# 登录 Docker Hub
podman login docker.io
# 重试推送
podman push wontlost/aster-api:jvm-latest
```

## 部署问题

### kubectl 连接超时

确认 `KUBECONFIG` 指向正确的 k3s-config 文件：
```bash
kubectl --kubeconfig ~/.kube/k3s-config get nodes
```

### ArgoCD 回滚部署

`task deploy:api` 使用 `rollout restart`（而非 `set image`），与 ArgoCD 兼容。ArgoCD 会保持使用 `jvm-latest` 标签。

### Cloudflare 部署失败

确认 `CLOUDFLARE_API_TOKEN` 有 Workers 部署权限。
