import { Hono } from 'hono';
import { metricsContentType, metricsText } from '../metrics.js';

export function createMetricsRoutes(): Hono {
  const app = new Hono();

  app.get('/metrics', async (c) => {
    c.header('content-type', metricsContentType());
    return c.body(await metricsText());
  });

  return app;
}
