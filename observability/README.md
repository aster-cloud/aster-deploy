# Aster Observability

PM 北极星指标与反指标的可观测性部署文件。

## 文件清单

| 文件 | 用途 |
|---|---|
| `prometheus/aster-alerts.yaml` | Prometheus 告警规则（NSM / 反指标，7 个 alert） |
| `prometheus/aster-phase3-alerts.yaml` | Phase 3E 增量告警（dunning / quota / audit / AHA / Stripe reconcile / AI 熔断） |
| `grafana/aster-nsm-dashboard.json` | NSM 仪表盘（7 个面板） |
| `grafana/aster-phase3-dashboard.json` | Phase 3 Ops & Billing 仪表盘（7 个面板） |

## 部署到 K3S（ArgoCD GitOps）

### Prometheus 告警

```bash
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: aster-nsm-rules
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
    role: alert-rules
spec: $(cat prometheus/aster-alerts.yaml | yq -o=json)
EOF
```

### Grafana 仪表盘

通过 Grafana ConfigMap provisioning：

```bash
kubectl create configmap aster-nsm-dashboard \
  --from-file=grafana/aster-nsm-dashboard.json \
  -n monitoring \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label configmap aster-nsm-dashboard \
  grafana_dashboard=1 -n monitoring
```

## 必需的 Grafana Datasource

| UID | 类型 | 用途 |
|---|---|---|
| `DS_PROMETHEUS` | Prometheus | 反指标 / Mixpanel 健康 / SLA / LLM token |
| `DS_POSTGRES` | PostgreSQL | WAADR 物化视图查询（连到 aster-api 用的 Postgres） |

WAADR Postgres datasource 需要只读账号，仅授权 `pm_weekly_waadr` 视图。

## 告警接收方

建议通过 AlertManager 路由到 Slack：

```yaml
route:
  group_by: ["alertname", "team"]
  routes:
    - matchers: ["team=product"]
      receiver: "slack-pm-metrics"
    - matchers: ["team=backend"]
      receiver: "slack-eng"
    - matchers: ["team=infra"]
      receiver: "slack-oncall"
```

频道建议（与 PM 文档对齐）：

- `#pm-metrics`：WAADR 趋势、反指标越界
- `#eng-aster-api`：后端故障
- `#oncall`：SLA 击穿等需要立即响应的

## 反指标对照表

| 反指标 | 数据源 | 阈值 | 告警 |
|---|---|---|---|
| 7 日回滚率 | Prometheus rule_rolled_back_total / draft_published_total | > 0.15 | `AsterHighRollbackRate` |
| P99 评估延迟 | Prometheus policy_evaluation_duration_seconds | > 0.2 s | `AsterHighEvaluationLatency` |
| LLM 成本/采纳 | Prometheus llm_tokens_total + draft_published_total | > ¥3.5 | `AsterHighLlmCostPerWaadr` |
| Mixpanel 丢失率 | Prometheus mixpanel_events_dropped_total | > 1% | `AsterMixpanelDeliveryDegraded` |
| 平台 SLA | Prometheus up | < 99.5% | `AsterApiSlaBreach` |
| PlanGate 失败 | Prometheus http_client_requests_seconds | > 0.1 req/s | `AsterPlanGateLookupFailing` |

## 相关 PM 文档

- [02-north-star-metric.md](../docs/pm/02-north-star-metric.md) — NSM 与反指标定义
- [03-telemetry-spec.md](../docs/pm/03-telemetry-spec.md) — 4 事件契约
- [06-cross-service-plan-gate.md](../docs/pm/06-cross-service-plan-gate.md) — PlanGate ADR

aster-api 端度量目录详见 `aster-api/docs/metrics/MetricsCatalog.md`。
