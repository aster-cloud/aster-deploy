import { collectDefaultMetrics, Counter, Gauge, Histogram, register } from 'prom-client';

collectDefaultMetrics({
  prefix: 'license_signing_api_',
});

export const approvalsTotal = new Counter({
  name: 'signing_approvals_total',
  help: 'Total approval requests',
  labelNames: ['purpose', 'outcome'] as const,
});

export const signingRequestsTotal = new Counter({
  name: 'signing_requests_total',
  help: 'Total signing requests',
  labelNames: ['purpose', 'outcome'] as const,
});

export const vaultCallsTotal = new Counter({
  name: 'signing_vault_calls_total',
  help: 'Total Vault Transit calls',
  labelNames: ['outcome'] as const,
});

export const replayAttemptsTotal = new Counter({
  name: 'signing_replay_attempts_total',
  help: 'Total replay attempts',
});

export const rateLimitedTotal = new Counter({
  name: 'signing_rate_limited_total',
  help: 'Total rate limited requests',
  labelNames: ['actor'] as const,
});

export const requestDurationSeconds = new Histogram({
  name: 'signing_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['route', 'status'] as const,
  buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10],
});

export const vaultLatencySeconds = new Histogram({
  name: 'signing_vault_latency_seconds',
  help: 'Vault Transit latency in seconds',
  labelNames: ['outcome'] as const,
  buckets: [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5],
});

let pendingApprovalsProvider = () => 0;

export function setPendingApprovalsProvider(provider: () => number): void {
  pendingApprovalsProvider = provider;
}

new Gauge({
  name: 'signing_pending_approvals',
  help: 'Current pending approval count',
  collect() {
    this.set(pendingApprovalsProvider());
  },
});

export async function metricsText(): Promise<string> {
  return register.metrics();
}

export function metricsContentType(): string {
  return register.contentType;
}
