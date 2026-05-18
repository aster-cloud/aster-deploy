import { createPublicKey, generateKeyPairSync, verify } from 'node:crypto';
import { createServer, type Server } from 'node:http';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { exportJWK, SignJWT } from 'jose';
import { createApp } from '../src/index.js';
import { JsonlAuditLogger } from '../src/audit-log.js';
import { InMemoryApprovalStore, ReplayCache, FixedWindowRateLimiter } from '../src/approval-store.js';
import { createJwtAuth } from '../src/auth.js';
import { VaultTransitClient } from '../src/vault.js';
import type { Config } from '../src/config.js';

const vaultAddr = 'http://127.0.0.1:18200';
const vaultToken = 'root';
const issuer = 'https://idp.aster.integration';
const audience = 'aster-license-signing-api';

describe('license-signing-api integration', () => {
  let vault: ChildProcessWithoutNullStreams;
  let jwksServer: Server;
  let jwksUrl: string;
  let dir: string;
  let privateKey: CryptoKey | Uint8Array | unknown;
  let publicJwk: Record<string, unknown>;

  beforeAll(async () => {
    dir = await mkdtemp(join(tmpdir(), 'license-signing-api-it-'));
    vault = spawn('docker', [
      'run',
      '--rm',
      '-p',
      '18200:8200',
      '-e',
      `VAULT_DEV_ROOT_TOKEN_ID=${vaultToken}`,
      '-e',
      'VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200',
      'hashicorp/vault:1.17',
      'server',
      '-dev',
    ]);
    await waitForVault();
    await vaultWrite('/v1/sys/mounts/transit', { type: 'transit' });
    await vaultWrite('/v1/transit/keys/license-signing-v2-2026-01', {
      type: 'ed25519',
      exportable: false,
      allow_plaintext_backup: false,
    });
    await vaultWrite('/v1/transit/keys/revocation-signing-v2-2026-01', {
      type: 'ed25519',
      exportable: false,
      allow_plaintext_backup: false,
    });

    const keyPair = generateKeyPairSync('rsa', { modulusLength: 2048 });
    privateKey = keyPair.privateKey;
    publicJwk = await exportJWK(keyPair.publicKey);
    publicJwk.kid = 'test-rsa';
    publicJwk.alg = 'RS256';
    publicJwk.use = 'sig';

    jwksServer = createServer((req, res) => {
      if (req.url === '/.well-known/jwks.json') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ keys: [publicJwk] }));
        return;
      }
      res.writeHead(404);
      res.end();
    });
    jwksServer.listen(0);
    await once(jwksServer, 'listening');
    const address = jwksServer.address();
    if (!address || typeof address === 'string') throw new Error('jwks server failed');
    jwksUrl = `http://127.0.0.1:${address.port}/.well-known/jwks.json`;
  }, 60_000);

  afterAll(async () => {
    jwksServer.close();
    vault.kill('SIGTERM');
    await rm(dir, { recursive: true, force: true });
  });

  function config(): Config {
    return {
      PORT: 8443,
      VAULT_ADDR: vaultAddr,
      VAULT_TOKEN: vaultToken,
      VAULT_TOKEN_FILE: '',
      JWT_ISSUER: issuer,
      JWT_AUDIENCE: audience,
      JWT_JWKS_URL: jwksUrl,
      ALLOWED_KEY_IDS: '^(license|revocation)-signing-v2-[0-9]{4}-[0-9]{2}$',
      AUDIT_LOG_PATH: join(dir, 'audit.jsonl'),
      LICENSES_SLACK_WEBHOOK: '',
      LOG_LEVEL: 'error',
      allowedKeyIdRegex: /^(license|revocation)-signing-v2-[0-9]{4}-[0-9]{2}$/,
    };
  }

  function app() {
    const cfg = config();
    return createApp({
      config: cfg,
      auth: createJwtAuth(cfg),
      vault: new VaultTransitClient(cfg),
      audit: new JsonlAuditLogger(cfg.AUDIT_LOG_PATH),
      approvals: new InMemoryApprovalStore(),
      replay: new ReplayCache(),
      approvalLimiter: new FixedWindowRateLimiter(100, 60_000),
      signLimiter: new FixedWindowRateLimiter(100, 60_000),
    });
  }

  async function jwt(sub: string, role: string, expiresInSeconds = 240): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    return new SignJWT({ role })
      .setProtectedHeader({ alg: 'RS256', kid: 'test-rsa' })
      .setIssuer(issuer)
      .setAudience(audience)
      .setSubject(sub)
      .setIssuedAt(now)
      .setNotBefore(now - 1)
      .setExpirationTime(now + expiresInSeconds)
      .sign(privateKey as never);
  }

  it('approves, signs through real Vault Transit, and verifies Ed25519 signature', async () => {
    const hono = app();
    const payload = { schemaVersion: 2, licenseId: 'lic_it_1', tier: 'enterprise' };
    const operator = await jwt('operator-it', 'license-operator');
    const witness = await jwt('witness-it', 'license-witness');

    const approve = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload }),
    });
    expect(approve.status).toBe(200);
    const approval = await approve.json() as { approvalToken: string };

    const sign = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload, approvalToken: approval.approvalToken }),
    });
    expect(sign.status).toBe(200);
    const signed = await sign.json() as { canonicalPayload: string; signature: string };
    const publicKey = await transitPublicKey('license-signing-v2-2026-01');
    expect(verify(null, Buffer.from(signed.canonicalPayload, 'base64url'), publicKey, Buffer.from(signed.signature, 'base64url'))).toBe(true);
  }, 60_000);

  it('rejects replay', async () => {
    const hono = app();
    const payload = { schemaVersion: 2, licenseId: 'lic_it_2' };
    const operator = await jwt('operator-replay', 'license-operator');
    const witness = await jwt('witness-replay', 'license-witness');
    const approve = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload }),
    });
    const approval = await approve.json() as { approvalToken: string };
    const body = JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload, approvalToken: approval.approvalToken });
    const first = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body,
    });
    const second = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body,
    });
    expect(first.status).toBe(200);
    expect(second.status).toBe(409);
  }, 60_000);

  it('rejects expired JWT', async () => {
    const hono = app();
    const operator = await jwt('operator-expired', 'license-operator', -10);
    const res = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload: { schemaVersion: 2 } }),
    });
    expect(res.status).toBe(401);
  }, 60_000);

  it('rejects crossed keyId', async () => {
    const hono = app();
    const operator = await jwt('operator-cross', 'license-operator');
    const res = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'license', keyId: 'revocation-signing-v2-2026-01', payload: { schemaVersion: 2 } }),
    });
    expect(res.status).toBe(400);
  }, 60_000);
});

async function waitForVault(): Promise<void> {
  const started = Date.now();
  while (Date.now() - started < 45_000) {
    try {
      const res = await fetch(`${vaultAddr}/v1/sys/health`, { headers: { 'x-vault-token': vaultToken } });
      if (res.status === 200 || res.status === 429) return;
    } catch {
      // Vault still booting
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  throw new Error('Vault dev server did not start');
}

async function vaultWrite(path: string, body: unknown): Promise<void> {
  const res = await fetch(`${vaultAddr}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-vault-token': vaultToken },
    body: JSON.stringify(body),
  });
  if (!res.ok && res.status !== 400) {
    throw new Error(`vault write failed ${path}: ${res.status}`);
  }
}

async function transitPublicKey(keyId: string) {
  const res = await fetch(`${vaultAddr}/v1/transit/keys/${keyId}`, {
    headers: { 'x-vault-token': vaultToken },
  });
  const body = await res.json() as { data: { keys: Record<string, { public_key: string }> } };
  const raw = Buffer.from(body.data.keys['1'].public_key, 'base64');
  const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
  return createPublicKey({
    key: Buffer.concat([spkiPrefix, raw]),
    format: 'der',
    type: 'spki',
  });
}
