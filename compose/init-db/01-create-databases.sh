#!/bin/bash
# Postgres docker-entrypoint-initdb.d 脚本
# 在首次初始化时创建 aster_cloud 数据库（aster_policy 由 POSTGRES_DB 自动创建）
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE aster_cloud'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'aster_cloud')\gexec
EOSQL
