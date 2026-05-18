// license-signing-api 主入口（生产化版本）。
//
// 设计意图：
//   - structured logging (pino) — JSON 日志便于 K8s log aggregation
//   - Prometheus metrics — 请求延迟、签名结果计数等关键指标
//   - graceful shutdown — SIGTERM 优雅退出，最长等 25s 让 in-flight 请求完成
//   - request-id 中间件 — 每请求 ULID + child logger

import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { createJwtAuth, type AuthService } from './auth.js';
import { loadConfig, type Config } from './config.js';
import { JsonlAuditLogger, type AuditLogger } from './audit-log.js';
import {
  InMemoryApprovalStore,
  ReplayCache,
  FixedWindowRateLimiter,
  type ApprovalStore,
} from './approval-store.js';
import { errorReason, publicStatus } from './errors.js';
import { ulid } from './canonical-json.js';
import { createHealthRoutes } from './routes/health.js';
import { createSignRoutes } from './routes/sign.js';
import { createAuditRoutes } from './routes/audit.js';
import { createMetricsRoutes } from './routes/metrics.js';
import { VaultTransitClient, type VaultClient } from './vault.js';
import {
  logger,
  flushLogs,
  withRequestId,
  type RequestLogger,
} from './logger.js';
import {
  requestDurationSeconds,
  setPendingApprovalsProvider,
} from './metrics.js';
// metrics.ts 也暴露 metricsText/metricsContentType 给 routes/metrics.ts

export interface AppDeps {
  config: Config;
  auth: AuthService;
  audit: AuditLogger;
  vault: VaultClient;
  approvals: ApprovalStore;
  replay: ReplayCache;
  approvalLimiter: FixedWindowRateLimiter;
  signLimiter: FixedWindowRateLimiter;
}

export type AppVariables = {
  requestId: string;
  logger: RequestLogger;
};

export function createApp(
  overrides: Partial<AppDeps> = {},
): Hono<{ Variables: AppVariables }> {
  const config = overrides.config ?? loadConfig();
  const deps: AppDeps = {
    config,
    auth: overrides.auth ?? createJwtAuth(config),
    audit:
      overrides.audit ??
      new JsonlAuditLogger(
        config.AUDIT_LOG_PATH,
        config.LICENSES_SLACK_WEBHOOK || undefined,
      ),
    vault: overrides.vault ?? new VaultTransitClient(config),
    approvals: overrides.approvals ?? new InMemoryApprovalStore(),
    replay: overrides.replay ?? new ReplayCache(),
    approvalLimiter:
      overrides.approvalLimiter ?? new FixedWindowRateLimiter(5, 60_000),
    signLimiter:
      overrides.signLimiter ?? new FixedWindowRateLimiter(10, 60 * 60_000),
  };

  const app = new Hono<{ Variables: AppVariables }>();

  // metrics: pending approvals gauge 通过 provider 回调拉取当前 size
  setPendingApprovalsProvider(() => deps.approvals.size());

  app.use('*', async (c, next) => {
    const requestId = ulid();
    const requestLogger = withRequestId(requestId);
    c.set('requestId', requestId);
    c.set('logger', requestLogger);
    c.header('x-request-id', requestId);
    c.header('strict-transport-security', 'max-age=31536000; includeSubDomains');
    c.header('x-content-type-options', 'nosniff');
    c.header('referrer-policy', 'no-referrer');

    const timeout = new Promise<never>((_, reject) => {
      setTimeout(() => reject(new Error('request-timeout')), 10_000);
    });
    const started = process.hrtime.bigint();
    try {
      await Promise.race([next(), timeout]);
    } finally {
      const duration =
        Number(process.hrtime.bigint() - started) / 1_000_000_000;
      const status = String(c.res.status || 200);
      requestDurationSeconds.labels(c.req.path, status).observe(duration);
      requestLogger.info(
        { method: c.req.method, path: c.req.path, status, duration },
        'request completed',
      );
      c.res.headers.delete('server');
    }
  });

  app.use(
    '*',
    bodyLimit({
      maxSize: 1024 * 1024,
      onError: (c) =>
        c.json({ error: 'request-failed', requestId: c.get('requestId') }, 413),
    }),
  );

  app.route('/', createHealthRoutes(deps));
  app.route('/v1', createSignRoutes(deps));
  app.route('/v1', createAuditRoutes(deps));
  app.route('/', createMetricsRoutes());

  app.notFound((c) =>
    c.json({ error: 'request-failed', requestId: c.get('requestId') }, 404),
  );

  app.onError(async (err, c) => {
    const requestId = c.get('requestId') ?? ulid();
    await deps.audit
      .append({
        requestId,
        event: 'sign-denied',
        errorReason: errorReason(err),
      })
      .catch(() => undefined);
    c.var.logger.error(
      { err, errorReason: errorReason(err) },
      'request failed',
    );
    return c.json({ error: 'request-failed', requestId }, publicStatus(err));
  });

  return app;
}

/**
 * 等待 in-flight 请求归零（用于 graceful shutdown）。
 * 超时后强制返回，避免无限等待。
 */
function waitForInflight(
  getInflight: () => number,
  timeoutMs: number,
): Promise<void> {
  const started = Date.now();
  return new Promise((resolve) => {
    const tick = () => {
      if (getInflight() === 0 || Date.now() - started >= timeoutMs) {
        resolve();
        return;
      }
      setTimeout(tick, 100);
    };
    tick();
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const config = loadConfig();
  const audit = new JsonlAuditLogger(
    config.AUDIT_LOG_PATH,
    config.LICENSES_SLACK_WEBHOOK || undefined,
  );
  let inflight = 0;
  const app = createApp({ config, audit });
  app.use('*', async (_c, next) => {
    inflight += 1;
    try {
      await next();
    } finally {
      inflight -= 1;
    }
  });
  const server = serve({
    fetch: app.fetch,
    hostname: '0.0.0.0',
    port: config.PORT,
  });
  logger.info({ port: config.PORT }, 'license-signing-api started');

  const shutdown = async (signal: NodeJS.Signals) => {
    logger.info({ signal }, 'shutdown requested');
    server.close(async () => {
      await waitForInflight(() => inflight, 25_000);
      if (typeof audit.close === 'function') {
        await audit.close();
      }
      await flushLogs();
      process.exit(0);
    });
    setTimeout(() => {
      logger.error({ signal }, 'forced shutdown after grace period');
      process.exit(1);
    }, 28_000).unref();
  };

  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
}
