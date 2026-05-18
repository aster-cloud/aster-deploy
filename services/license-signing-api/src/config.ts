import { readFileSync, statSync } from 'node:fs';
import { config as loadDotenv } from 'dotenv';
import { z } from 'zod';

loadDotenv();

const ConfigSchema = z.object({
  PORT: z.coerce.number().int().min(1).max(65535).default(8443),
  VAULT_ADDR: z.string().url(),
  // codex 审查 Critical-1：Vault Agent Injector 把 token 写到 /vault/secrets/vault-token
  // 文件而不是 env。允许 env 或 file，至少二选一非空。
  VAULT_TOKEN: z.string().optional(),
  VAULT_TOKEN_FILE: z.string().optional(),
  JWT_ISSUER: z.string().url(),
  JWT_AUDIENCE: z.string().min(1),
  JWT_JWKS_URL: z.string().url(),
  ALLOWED_KEY_IDS: z.string().min(1),
  AUDIT_LOG_PATH: z.string().min(1).default('/var/log/license-signing-api/audit.jsonl'),
  LICENSES_SLACK_WEBHOOK: z.string().url().optional().or(z.literal('')),
  LOG_LEVEL: z.enum(['debug', 'info', 'warn', 'error']).default('info'),
});

export type Config = z.infer<typeof ConfigSchema> & {
  allowedKeyIdRegex: RegExp;
  /** 动态读 Vault token（支持 Vault Agent 文件轮换）。每次调用最多缓存 1 分钟。 */
  readVaultToken(): string;
};

/** Vault Agent 写的 token 文件每次轮换会更新；读时带 mtime 缓存避免每请求 IO。 */
function makeTokenReader(opts: {
  inlineToken?: string;
  tokenFile?: string;
}): () => string {
  let cached: { token: string; mtimeMs: number; readAtMs: number } | null = null;
  return () => {
    // env 优先（dev/staging 直接配置）
    if (opts.inlineToken && opts.inlineToken.length > 0) return opts.inlineToken;
    if (!opts.tokenFile) {
      throw new Error(
        'VAULT_TOKEN or VAULT_TOKEN_FILE must be configured (Vault Agent injector writes /vault/secrets/vault-token)',
      );
    }
    const nowMs = Date.now();
    // 60s 缓存上限：避免每请求 stat+read，又能在 token 轮换后 ≤1min 内拿到新值
    if (cached && nowMs - cached.readAtMs < 60_000) {
      const stat = statSync(opts.tokenFile);
      if (stat.mtimeMs === cached.mtimeMs) return cached.token;
    }
    const stat = statSync(opts.tokenFile);
    const token = readFileSync(opts.tokenFile, 'utf8').trim();
    if (!token) {
      throw new Error(`VAULT_TOKEN_FILE ${opts.tokenFile} is empty`);
    }
    cached = { token, mtimeMs: stat.mtimeMs, readAtMs: nowMs };
    return token;
  };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = ConfigSchema.parse(env);
  if (!parsed.VAULT_TOKEN && !parsed.VAULT_TOKEN_FILE) {
    throw new Error(
      'VAULT_TOKEN or VAULT_TOKEN_FILE must be set (Vault Agent Injector writes /vault/secrets/vault-token)',
    );
  }
  const readVaultToken = makeTokenReader({
    inlineToken: parsed.VAULT_TOKEN,
    tokenFile: parsed.VAULT_TOKEN_FILE,
  });
  // 启动时 eager 校验 token 至少可读
  readVaultToken();
  return {
    ...parsed,
    allowedKeyIdRegex: new RegExp(parsed.ALLOWED_KEY_IDS),
    readVaultToken,
  };
}
