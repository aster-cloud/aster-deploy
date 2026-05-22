import pino from 'pino';

const service = 'license-signing-api';
const version = process.env.npm_package_version ?? '0.1.0';
const level = process.env.LOG_LEVEL ?? 'info';
const isProd = process.env.NODE_ENV === 'production';

// exactOptionalPropertyTypes: pino's `transport` option does not accept
// `undefined`; omit the key entirely in production instead.
const baseOptions = {
  level,
  base: {
    service,
    version,
  },
  timestamp: pino.stdTimeFunctions.isoTime,
};

export const logger = pino(
  isProd
    ? baseOptions
    : {
        ...baseOptions,
        transport: {
          target: 'pino-pretty',
          options: {
            colorize: true,
            singleLine: true,
            translateTime: 'SYS:standard',
          },
        },
      },
);

export type RequestLogger = ReturnType<typeof withRequestId>;

export function withRequestId(requestId: string) {
  return logger.child({ requestId });
}

export async function flushLogs(): Promise<void> {
  await new Promise<void>((resolve) => {
    const maybeFlush = logger.flush;
    if (typeof maybeFlush === 'function') {
      maybeFlush.call(logger);
    }
    setImmediate(resolve);
  });
}
