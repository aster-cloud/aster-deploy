# Performance Benchmarks

> Phase 3B-1 baseline + ongoing regression detection.

## Scripts

| Script | Target | What it measures |
|---|---|---|
| `k6-baseline.js` | aster-cloud / aster-api anonymous endpoints | Cold latency, throughput envelope |
| `k6-policy-evaluation.js` | aster-api `/api/v1/policies/[id]/execute` | 1000 WAADR-equivalent load: 100 teams × 10 QPS sustained |
| `k6-ai-sse.js` (TODO) | aster-api `/api/v1/ai/*` SSE endpoints | Long-connection worker pool isolation |

## Prerequisites

```bash
brew install k6
```

Or use the Docker image:
```bash
docker run --rm -v $(pwd):/scripts grafana/k6 run /scripts/k6-baseline.js
```

## Acceptance gate (PM 02 counter-metric)

- **P99 < 200ms** for policy evaluation under 1000 WAADR-equivalent load
- **5xx error rate < 0.1%** under same load
- **Token bucket rate-limit** holds: API key abuse does not degrade other tenants

## Reporting

Each k6 run outputs JSON via `--summary-export`. Aggregate into `REPORT-v17-performance-baseline.md` (see Phase 3B-1 acceptance).

## Safety rails

- **Always run against `perf-env`**, never staging or production
- `perf-env` is a dedicated postgres + aster-api stack — see `aster-deploy/k3s/perf/values.yaml` (TBD)
- Aborting mid-run: `Ctrl-C` or `k6 stop --pid <pid>`; k6 cools down gracefully
