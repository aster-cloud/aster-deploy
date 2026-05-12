# Disaster Recovery Drill Runbook

> P0-6 of phase4-p0-production-hardening.md

## 现状

- **Cluster**: cloudnative-pg `shared-postgres` (1 instance, 20Gi local-path PVC)
- **Backup**: cnpg `ScheduledBackup` daily @ 02:00 UTC，barmanObjectStore → OCI
  Object Storage `bucket-backup/shared-postgres/`
- **Retention**: 30 天
- **Latest**: `kubectl -n data-services get backup --sort-by=.metadata.creationTimestamp | tail`

## RTO / RPO 目标

- **RTO**（Recovery Time Objective）：< 30 分钟（首次演练目标）
- **RPO**（Recovery Point Objective）：< 24h（依赖 nightly backup；WAL 归档启用后可降到 < 5 分钟）

## 演练频率

每季度一次。演练日志写入 `docs/dr-drills/<YYYY-Qx>.md`。

---

## 演练步骤

### 准备

```bash
# 1. 选定一个最近成功的 backup
KUBECONFIG=~/.kube/k3s-config kubectl -n data-services get backup \
  --sort-by=.metadata.creationTimestamp | tail -3

# 2. 记下名字，例如 shared-postgres-daily-backup-20260512020200
BACKUP_NAME=shared-postgres-daily-backup-20260512020200

# 3. 检查 backup 状态
kubectl -n data-services get backup $BACKUP_NAME -o yaml | grep -E "phase:|completed:|method:"
# phase 必须是 completed
```

### Step 1：从备份建恢复 Cluster（不动生产）

```bash
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: dr-drill-pg
  namespace: data-services
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4

  bootstrap:
    recovery:
      source: shared-postgres
      # backup: 不指定 → 用 latest；或者指定 backup 名字 → 该时点

  externalClusters:
    - name: shared-postgres
      barmanObjectStore:
        destinationPath: s3://bucket-backup/shared-postgres/
        endpointURL: https://axuwdowxwpud.compat.objectstorage.ap-melbourne-1.oraclecloud.com
        s3Credentials:
          accessKeyId:
            name: postgres-backup-credentials
            key: ACCESS_KEY_ID
          secretAccessKey:
            name: postgres-backup-credentials
            key: SECRET_ACCESS_KEY
        wal:
          compression: gzip

  storage:
    size: 5Gi
    storageClass: local-path

  resources:
    requests: { memory: 256Mi, cpu: 100m }
    limits:   { memory: 512Mi, cpu: 300m }
EOF
```

### Step 2：等待 Cluster Ready（计时开始）

```bash
START=$(date +%s)
kubectl -n data-services wait --for=condition=Ready cluster/dr-drill-pg --timeout=20m
END=$(date +%s)
echo "Recovery duration: $(( (END - START) / 60 )) minutes"
```

### Step 3：验证数据完整性

```bash
# 列举 databases
kubectl -n data-services exec dr-drill-pg-1 -- psql -U postgres -c '\l'
# 必须看到 aster_api, authentik, grafana, aster_cloud（如有）

# 抽样查表（User 表）
kubectl -n data-services exec dr-drill-pg-1 -- \
  psql -U postgres -d aster_cloud -c \
  'SELECT count(*) FROM "User"; SELECT max("emailNormalized") FROM "User";'

# 与生产对比（不应有大偏差，因为 backup 最多 < 24h 旧）
kubectl -n data-services exec shared-postgres-1 -- \
  psql -U postgres -d aster_cloud -c 'SELECT count(*) FROM "User";'
```

### Step 4：清理

```bash
kubectl -n data-services delete cluster dr-drill-pg
# PVC 默认自动清理，确认：
kubectl -n data-services get pvc | grep dr-drill-pg
# 如还在：kubectl -n data-services delete pvc -l cnpg.io/cluster=dr-drill-pg
```

### Step 5：记录演练

写入 `docs/dr-drills/YYYY-Qx.md`：

```markdown
# DR Drill <YYYY-Qx>

- **Date**: YYYY-MM-DD
- **Operator**: Ryan
- **Source backup**: shared-postgres-daily-backup-YYYYMMDD020200
- **Recovery duration**: N minutes (RTO)
- **Data age at recovery**: N hours (RPO)
- **Data integrity**: row count delta = X (acceptable: < 1% of prod)

## Findings

- ...

## Action items

- [ ] ...
```

---

## 紧急恢复（真实事故，非演练）

### 场景 A：shared-postgres pod corrupt 但 PVC 完好

```bash
# cnpg 通常自动恢复。先观察：
kubectl -n data-services get cluster shared-postgres -o yaml | grep -A 5 conditions:
# 如 cnpg 无法自动恢复：
kubectl -n data-services rollout restart statefulset/shared-postgres
```

### 场景 B：PVC 丢失或 corrupt

```bash
# 1. 暂停 cnpg 对该 cluster 的 reconcile
kubectl -n data-services annotate cluster shared-postgres \
  cnpg.io/reconciliationLoop=disabled --overwrite

# 2. 用 Step 1 的方法新建恢复 cluster，但命名为 shared-postgres-restored
# 3. 切换所有 aster-api / aster-cloud / authentik / grafana 的连接到 shared-postgres-restored
#    （改 ExternalSecret 中的 host）
# 4. 验证业务通过
# 5. 删除损坏的 shared-postgres + PVC
# 6. 重命名 shared-postgres-restored → shared-postgres（停机时间）
```

### 场景 C：整个 K3S 集群崩溃

```bash
# 1. 重建 K3S 集群（manual k3s install + ArgoCD bootstrap）
#    见 argocd/bootstrap/root-app.yaml
# 2. ArgoCD 重建所有 application
# 3. shared-postgres 启动时 cnpg 会从 barmanObjectStore 自动恢复（因为
#    spec.bootstrap.recovery 已配置）
#    ⚠️ 实际：当前 cluster.yaml 用 spec.bootstrap.initdb 而非 recovery，
#    重建时需要先改 cluster.yaml 切到 recovery，待恢复完再改回
```

---

## 演练历史

| 季度 | 日期 | RTO | RPO | 备注 |
|------|------|-----|-----|------|
| 2026-Q2 | 待执行 | — | — | 首次演练（创建本 runbook） |
