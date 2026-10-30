#!/usr/bin/env bash
# compose/scripts/ensure-database.sh 集成测试（issue #27）：
# 数据卷已被初始化（initdb.d 不会再跑）时，脚本仍须幂等地建出 aster_cloud。
#
# 起一个一次性 Postgres 容器（sweep- 前缀、端口 55800–55899），测完删除。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENSURE="${SCRIPT_DIR}/../compose/scripts/ensure-database.sh"
CLI="${CONTAINER_CLI:-$(command -v podman || command -v docker)}"
NAME="${ENSURE_DB_TEST_CONTAINER:-sweep-ensure-db-$$}"

cleanup() { "$CLI" rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 容器内不映射端口：脚本经 exec 在容器里以 localhost 连接
"$CLI" run -d --name "$NAME" -e POSTGRES_PASSWORD=pw -e POSTGRES_DB=aster_policy \
  docker.io/postgres:16-alpine >/dev/null
for _ in $(seq 1 60); do
  "$CLI" exec "$NAME" pg_isready -U postgres -h localhost >/dev/null 2>&1 && break
  sleep 1
done
# 官方镜像初始化阶段会先重启一次，再确认一次稳定
sleep 2
"$CLI" exec "$NAME" pg_isready -U postgres -h localhost >/dev/null

run_ensure() {
  "$CLI" exec -i -e PGPASSWORD=pw "$NAME" sh -s -- localhost aster_cloud < "$ENSURE"
}
db_exists() {
  "$CLI" exec -e PGPASSWORD=pw "$NAME" psql -h localhost -U postgres -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='aster_cloud'"
}

[ -z "$(db_exists)" ] || { echo "✗ 前置条件：aster_cloud 不应已存在" >&2; exit 1; }
run_ensure || { echo "✗ 首次执行失败" >&2; exit 1; }
[ "$(db_exists)" = "1" ] || { echo "✗ 执行后 aster_cloud 仍不存在" >&2; exit 1; }
run_ensure || { echo "✗ 重复执行不幂等（数据库已存在时失败）" >&2; exit 1; }
echo "✓ ensure-database.sh：已初始化的卷上建库成功且幂等"
