#!/bin/sh
# aster-cloud 测试环境启动脚本
# 1. 安装 psql（用于执行种子 SQL）
# 2. 安装依赖
# 3. 等待 Postgres 就绪
# 4. 同步 Drizzle schema
# 5. 插入种子用户
# 6. 启动 Next.js dev server
set -e

echo "[cloud-entrypoint] 安装 postgresql-client ..."
# ★不要把 stderr 一起吞掉（issue #13）。此前是 `>/dev/null 2>&1`：
#   apk 失败（镜像源不可达 / 包名在新版 alpine 改名 / 网络受限）时 `set -e`
#   直接退出，日志里只有上面那行 echo，没有任何线索——排查得靠猜。
#   现在只静默 stdout（正常安装的进度噪音），保留 stderr，并在失败时
#   打印明确错误后退出。
#
#   ★包名里的 16 必须与 compose 的 postgres 大版本一致（见 podman-compose.yml）。
#   psql 客户端连更高版本服务端会警告、更低版本可能不兼容新 wire 特性。
if ! apk add --no-cache postgresql16-client >/dev/null; then
  echo "[cloud-entrypoint] ✗ 安装 postgresql16-client 失败（错误详情见上方 apk 输出）" >&2
  echo "[cloud-entrypoint]   常见原因：alpine 镜像源不可达、或该 alpine 版本里包名已变更" >&2
  exit 1
fi

echo "[cloud-entrypoint] 启用 corepack + 安装依赖 ..."
corepack enable
pnpm install

echo "[cloud-entrypoint] 等待 Postgres 就绪 ..."
until pg_isready -h postgres -p 5432 -U postgres >/dev/null 2>&1; do
  sleep 1
done

echo "[cloud-entrypoint] 同步 Drizzle schema（drizzle-kit push）..."
npx drizzle-kit push --force

echo "[cloud-entrypoint] 插入种子用户 ..."
PGPASSWORD=postgres psql -h postgres -p 5432 -U postgres -d aster_cloud -f /seed/seed-cloud-user.sql

echo "[cloud-entrypoint] 启动 Next.js dev server ..."
exec pnpm run dev
