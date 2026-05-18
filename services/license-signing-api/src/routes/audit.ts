import { Hono } from 'hono';
import type { AppDeps, AppVariables } from '../index.js';

export function createAuditRoutes(deps: AppDeps): Hono<{ Variables: AppVariables }> {
  const app = new Hono<{ Variables: AppVariables }>();

  app.get('/audit', async (c) => {
    await deps.auth.verifyAdmin(c);
    const limitRaw = c.req.query('limit') ?? '100';
    const limit = Math.min(Math.max(Number.parseInt(limitRaw, 10) || 100, 1), 500);
    const events = await deps.audit.recent(limit);
    return c.json({ events });
  });

  return app;
}
