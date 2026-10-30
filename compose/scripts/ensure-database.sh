#!/bin/sh
# 幂等创建数据库。用法: ensure-database.sh <host> <db>
# 连接凭据走 libpq 环境变量（PGPASSWORD / PGUSER，PGUSER 缺省 postgres）。
#
# ★为什么不用 docker-entrypoint-initdb.d：官方镜像只在数据目录为空时执行它，
#   而 local / local:infra / local:test 共用同一个数据卷，先跑过其它模式后
#   initdb.d 不再执行，aster_cloud 永远建不出来（issue #27）。
set -e

host="$1"
db="$2"
user="${PGUSER:-postgres}"

exists="$(psql -h "$host" -U "$user" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'")"
if [ "$exists" = "1" ]; then
  exit 0
fi
psql -h "$host" -U "$user" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$db\""
