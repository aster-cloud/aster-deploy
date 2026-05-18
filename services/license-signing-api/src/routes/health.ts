import { Hono } from 'hono';
import type { AppDeps, AppVariables } from '../index.js';

export function createHealthRoutes(deps: AppDeps): Hono<{ Variables: AppVariables }> {
  const app = new Hono<{ Variables: AppVariables }>();

  app.get('/healthz', (c) => c.json({ ok: true }));

  app.get('/readyz', async (c) => {
    const status = await deps.vault.status();
    if (status.sealed) {
      return c.json({ ok: false, vault: 'sealed' }, 503);
    }
    return c.json({ ok: true, vault: 'ready' });
  });

  return app;
}
