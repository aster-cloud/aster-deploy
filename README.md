# aster-deploy

Aster 生态统一编排工具。基于 [Taskfile](https://taskfile.dev/) 提供三种模式：

- **`local`** — Podman Compose 全栈本地运行
- **`dev`** — 构建全部项目到本地（mavenLocal + pnpm build）
- **`release`** — 完整发布 + 部署流水线

## 依赖关系

```
aster-lang-core
  ├── aster-lang-en  ─┐
  ├── aster-lang-zh  ─┤
  ├── aster-lang-de  ─┼── aster-lang-truffle → aster-api → K3S
  └── aster-lang-runtime ┘

aster-lang-ts → aster-cloud → Cloudflare Workers + K3S (LSP)
```

## 快速开始

```bash
# 1. 配置环境
cp .env.example .env
vim .env  # 填写 ASTER_REPOS_DIR

# 2. 预检
task preflight

# 3. 选择模式
task local:infra   # 调试（最常用）
task dev           # 构建
task release       # 发布 + 部署
```

## 本地调试（最常用工作流）

```bash
# 启动基础设施（Postgres + Redis）
task local:infra

# 然后：
#   IntelliJ → 运行 aster-api（Quarkus dev mode, 端口 8080, 热重载 + 调试器）
#   终端 → cd aster-cloud && pnpm run dev（端口 3000, 热重载）

# 检查服务状态
task verify:local

# 完成后停止
task local:stop
```

详见 [docs/local-debug.md](docs/local-debug.md)。

## 全栈容器化

```bash
# 所有服务在 Podman 中运行（API + Cloud + LSP + Postgres + Redis）
task local

# 查看日志
task local:logs

# 停止
task local:stop

# 清理（含数据卷）
task local:clean
```

## 命令参考

| 命令 | 说明 |
|------|------|
| `task local` | 全栈容器化本地环境 |
| `task local:infra` | 仅基础设施（IDE 调试用） |
| `task local:stop` | 停止本地容器 |
| `task local:logs` | 查看容器日志 |
| `task local:clean` | 删除容器和数据卷 |
| `task dev` | 构建全部项目 |
| `task release` | 完整发布流水线 |
| `task build:core` | 构建 aster-lang-core |
| `task build:packs` | 构建语言包（并行） |
| `task build:ts` | 构建 aster-lang-ts |
| `task build:api` | 构建 aster-api |
| `task build:cloud` | 构建 aster-cloud |
| `task publish:jvm` | 发布 JVM 构件 |
| `task publish:npm` | 发布 npm 包 |
| `task container:api` | 构建推送 API 镜像 |
| `task deploy:api` | 部署 API 到 K3S |
| `task deploy:cloud` | 部署 Cloud 到 Cloudflare |
| `task verify` | 生产冒烟测试 |
| `task verify:local` | 本地冒烟测试 |
| `task preflight` | 环境预检 |
| `task doctor` | 详细环境诊断 |

## 常见场景

| 场景 | 命令 |
|------|------|
| 修改了 aster-lang-core 语法 | `task dev` |
| 本地调试 aster-api | `task local:infra` + IntelliJ |
| 仅部署 API | `task build:api && task container:api && task deploy:api` |
| 完整发布 | `task release` |

## 环境配置

详见 [.env.example](.env.example)。

## 故障排除

详见 [docs/troubleshooting.md](docs/troubleshooting.md)。
