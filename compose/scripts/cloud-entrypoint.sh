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
apk add --no-cache postgresql16-client >/dev/null 2>&1

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
