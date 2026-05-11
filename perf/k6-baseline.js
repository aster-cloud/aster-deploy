/**
 * Baseline performance probe — public/anonymous endpoints only.
 *
 * Run:
 *   k6 run --summary-export=baseline.json k6-baseline.js
 *
 * Targets:
 *   - aster-cloud /pricing  → SSR render latency
 *   - aster-cloud /api/health → liveness
 *   - aster-lang.dev / → SEO landing
 *
 * Acceptance:
 *   - P99 < 1000ms (anonymous SSR pages are heavier than API)
 *   - Failures < 0.1%
 *
 * This is the warmup before k6-policy-evaluation.js which exercises the real
 * production hot path under WAADR-equivalent load.
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const BASE_CLOUD = __ENV.CLOUD_URL || 'http://localhost:3001';
const BASE_DEV = __ENV.DEV_URL || 'http://localhost:5173';

const errorRate = new Rate('errors');
const pricingDuration = new Trend('pricing_duration');
const devLandingDuration = new Trend('dev_landing_duration');

export const options = {
  stages: [
    { duration: '30s', target: 10 }, // ramp up
    { duration: '2m', target: 50 },  // sustained
    { duration: '30s', target: 0 },  // ramp down
  ],
  thresholds: {
    'http_req_duration{group:pricing}': ['p(99)<1000'],
    'http_req_failed': ['rate<0.001'],
    'errors': ['rate<0.001'],
  },
};

export default function () {
  // aster-cloud /pricing — SSR
  {
    const res = http.get(`${BASE_CLOUD}/pricing`, { tags: { group: 'pricing' } });
    pricingDuration.add(res.timings.duration);
    const ok = check(res, {
      'pricing 200': (r) => r.status === 200,
      'pricing has Pro tier': (r) => typeof r.body === 'string' && r.body.includes('Pro'),
    });
    errorRate.add(!ok);
  }

  sleep(0.5);

  // aster-cloud /api/health (if exists)
  {
    const res = http.get(`${BASE_CLOUD}/api/health`, { tags: { group: 'health' } });
    // 200 or 404 (if endpoint doesn't exist yet) both OK; only fail on 5xx
    errorRate.add(res.status >= 500);
  }

  sleep(0.5);

  // aster-lang-dev / — SEO landing
  {
    const res = http.get(`${BASE_DEV}/`, { tags: { group: 'dev_landing' } });
    devLandingDuration.add(res.timings.duration);
    errorRate.add(res.status !== 200);
  }

  sleep(1);
}

export function handleSummary(data) {
  return {
    'stdout': textSummary(data),
    'baseline-summary.json': JSON.stringify(data, null, 2),
  };
}

function textSummary(data) {
  const m = data.metrics;
  return `
========================================
k6 baseline summary
========================================
  iterations:           ${m.iterations?.values?.count ?? 0}
  http_reqs:            ${m.http_reqs?.values?.count ?? 0}
  failed rate:          ${(m.http_req_failed?.values?.rate ?? 0) * 100}%
  pricing P99:          ${m.pricing_duration?.values?.['p(99)']?.toFixed(2) ?? '?'}ms
  dev_landing P99:      ${m.dev_landing_duration?.values?.['p(99)']?.toFixed(2) ?? '?'}ms

  Acceptance:
    P99 < 1000ms        ${(m.pricing_duration?.values?.['p(99)'] ?? Infinity) < 1000 ? '✅' : '❌'}
    failures < 0.1%     ${(m.http_req_failed?.values?.rate ?? 1) < 0.001 ? '✅' : '❌'}
========================================
`;
}
