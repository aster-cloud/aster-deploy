/**
 * Policy evaluation under 1000 WAADR-equivalent load.
 *
 * PM 02 counter-metric: P99 < 200ms under sustained load.
 *
 * Run:
 *   API_KEY=<perf-env-key> k6 run --summary-export=policy-eval.json k6-policy-evaluation.js
 *
 * Setup expected:
 *   - perf-env aster-api stack running, isolated from staging
 *   - 100 pre-seeded policies (POLICY_IDS env var, comma-separated)
 *   - API key with no rate-limit cap for perf testing
 *
 * Profile:
 *   - 100 VUs × 10 RPS each = 1000 QPS sustained for 10 min
 *   - Burst phase: ramp to 2000 QPS for 1 min
 *   - Validates: P99, error rate, latency cliff
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';
import crypto from 'k6/crypto';

// CSPRNG 版 [0,1) 随机数：取 4 字节 crypto.randomBytes → uint32 / 2^32。
// 替代 Math.random()（CodeQL js/insecure-randomness）。此处纯生成负载测试数据，
// 无安全含义，但用 CSPRNG 消除告警且不改变数据分布。
function secureRandom() {
  const b = new Uint8Array(crypto.randomBytes(4));
  const u32 = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
  return (u32 >>> 0) / 4294967296;
}

const API_BASE = __ENV.API_BASE || 'http://localhost:8080';
const API_KEY = __ENV.API_KEY;
if (!API_KEY) {
  throw new Error('Set API_KEY env var (perf-env API key, NOT prod)');
}
const POLICY_IDS = (__ENV.POLICY_IDS || 'demo-policy-1').split(',');

const errorRate = new Rate('eval_errors');
const evalDuration = new Trend('eval_duration', true);
const evalSucceeded = new Counter('eval_succeeded');
const eval5xx = new Counter('eval_5xx');

export const options = {
  scenarios: {
    sustained: {
      executor: 'constant-arrival-rate',
      rate: 1000, // 1000 RPS
      timeUnit: '1s',
      duration: '10m',
      preAllocatedVUs: 100,
      maxVUs: 200,
    },
    burst: {
      executor: 'ramping-arrival-rate',
      startRate: 1000,
      timeUnit: '1s',
      preAllocatedVUs: 200,
      maxVUs: 400,
      stages: [
        { duration: '1m', target: 2000 },
        { duration: '30s', target: 1000 },
      ],
      startTime: '10m', // run AFTER sustained
    },
  },
  thresholds: {
    'eval_duration': ['p(99)<200'],
    'eval_errors': ['rate<0.001'],
    'http_req_failed': ['rate<0.001'],
  },
};

export default function () {
  const policyId = POLICY_IDS[Math.floor(secureRandom() * POLICY_IDS.length)];
  const url = `${API_BASE}/api/v1/policies/${policyId}/execute`;
  const body = JSON.stringify({
    input: {
      // Generic input that satisfies most demo policies
      amount: Math.floor(secureRandom() * 100000),
      age: 25 + Math.floor(secureRandom() * 40),
      credit_score: 600 + Math.floor(secureRandom() * 200),
    },
  });
  const params = {
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${API_KEY}`,
    },
    tags: { name: 'policy_execute' },
  };

  const res = http.post(url, body, params);
  evalDuration.add(res.timings.duration);
  if (res.status >= 500) eval5xx.add(1);

  const ok = check(res, {
    'status 2xx or 4xx (business)': (r) => r.status < 500,
    'response has body': (r) => r.body && r.body.length > 0,
  });
  if (!ok) {
    errorRate.add(true);
  } else {
    errorRate.add(false);
    evalSucceeded.add(1);
  }

  sleep(secureRandom() * 0.1);
}

export function handleSummary(data) {
  const m = data.metrics;
  const p99 = m.eval_duration?.values?.['p(99)'] ?? Infinity;
  const errRate = m.eval_errors?.values?.rate ?? 1;

  const text = `
========================================
Policy Evaluation Load Test
========================================
  total requests:       ${m.http_reqs?.values?.count ?? 0}
  succeeded:            ${m.eval_succeeded?.values?.count ?? 0}
  5xx errors:           ${m.eval_5xx?.values?.count ?? 0}
  error rate:           ${(errRate * 100).toFixed(3)}%

  Latency:
    avg:                ${m.eval_duration?.values?.avg?.toFixed(2) ?? '?'}ms
    P50:                ${m.eval_duration?.values?.med?.toFixed(2) ?? '?'}ms
    P95:                ${m.eval_duration?.values?.['p(95)']?.toFixed(2) ?? '?'}ms
    P99:                ${p99.toFixed(2)}ms

  Acceptance (PM 02 counter-metric):
    P99 < 200ms         ${p99 < 200 ? '✅' : '❌ FAIL'}
    error rate < 0.1%   ${errRate < 0.001 ? '✅' : '❌ FAIL'}
========================================
`;

  return {
    'stdout': text,
    'policy-eval-summary.json': JSON.stringify(data, null, 2),
  };
}
