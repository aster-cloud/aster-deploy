import type { ContentfulStatusCode } from 'hono/utils/http-status';

export class AppError extends Error {
  constructor(
    public readonly status: ContentfulStatusCode,
    public readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

export function errorReason(err: unknown): string {
  if (err instanceof AppError) return err.code;
  if (err instanceof Error) return err.message;
  return 'unknown-error';
}

export function publicStatus(err: unknown): ContentfulStatusCode {
  if (err instanceof AppError) return err.status;
  return 500;
}
