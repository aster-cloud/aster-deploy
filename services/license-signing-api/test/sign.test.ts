import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Context } from 'hono';
import { createApp, type AppDeps } from '../src/index.js';
import type { AuthService, Principal } from '../src/auth.js';
import { InMemoryApprovalStore, ReplayCache, FixedWindowRateLimiter } from '../src/approval-store.js';
import { JsonlAuditLogger } from '../src/audit-log.js';
import type { Config } from '../src/config.js';
import type { VaultClient, VaultSignature, VaultStatus } from '../src/vault.js';

function config(auditPath: string): Config {
  return {
    PORT: 8443,
    VAULT_ADDR: 'http://vault.test:8200',
    VAULT_TOKEN: 'service-token',
    JWT_ISSUER: 'https://idp.aster.test',
    JWT_AUDIENCE: 'aster-license-signing-api',
    JWT_JWKS_URL: 'https://idp.aster.test/.well-known/jwks.json',
    ALLOWED_KEY_IDS: '^(license|revocation)-signing-v2-[0-9]{4}-[0-9]{2}$',
    AUDIT_LOG_PATH: auditPath,
    LICENSES_SLACK_WEBHOOK: '',
    LOG_LEVEL: 'error',
    allowedKeyIdRegex: /^(license|revocation)-signing-v2-[0-9]{4}-[0-9]{2}$/,
  };
}

class FakeAuth implements AuthService {
  constructor(
    private readonly operatorSub = 'operator-1',
    private readonly witnessSub = 'witness-1',
    private readonly failWitness = false,
  ) {}

  async verifyOperator(): Promise<Principal> {
    return { sub: this.operatorSub, role: 'license-operator', iat: 1, exp: 2 };
  }

  async verifyWitness(): Promise<Principal> {
    if (this.failWitness) throw new Error('expired');
    return { sub: this.witnessSub, role: 'license-witness', iat: 1, exp: 2 };
  }

  async verifyAdmin(): Promise<Principal> {
    return { sub: 'admin-1', role: 'license-admin', iat: 1, exp: 2 };
  }
}

class FakeVault implements VaultClient {
  public fail = false;
  public calls: Array<{ keyId: string; payload: string }> = [];

  async status(): Promise<VaultStatus> {
    return { sealed: false };
  }

  async sign(keyId: string, canonicalPayload: string): Promise<VaultSignature> {
    this.calls.push({ keyId, payload: canonicalPayload });
    if (this.fail) throw new Error('vault-5xx');
    return { signatureBase64Url: 'c2ln', keyVersion: '1' };
  }
}

describe('signing flow', () => {
  let dir: string;
  let auditPath: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), 'license-signing-api-'));
    auditPath = join(dir, 'audit.jsonl');
  });

  afterEach(async () => {
    await rm(dir, { recursive: true, force: true });
  });

  function app(auth: AuthService = new FakeAuth(), vault: FakeVault = new FakeVault()) {
    const cfg = config(auditPath);
    const deps: Partial<AppDeps> = {
      config: cfg,
      auth,
      vault,
      audit: new JsonlAuditLogger(auditPath),
      approvals: new InMemoryApprovalStore(),
      replay: new ReplayCache(),
      approvalLimiter: new FixedWindowRateLimiter(100, 60_000),
      signLimiter: new FixedWindowRateLimiter(100, 60_000),
    };
    return { app: createApp(deps), vault };
  }

  async function approveAndSign(overrides: Record<string, unknown> = {}, auth?: AuthService, vault?: FakeVault) {
    const subject = app(auth, vault);
    const payload = {
      schemaVersion: 2,
      licenseId: 'lic_123',
      customer: 'Acme Corp',
      tier: 'enterprise',
      // v3 起 deploymentBinding 必填，sign.ts 在 approve / sign 入口都会校验
      deploymentBinding: {
        deploymentId: 'a'.repeat(64),
        deploymentLabel: 'acme-test',
      },
    };
    const approve = await subject.app.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({
        purpose: 'license',
        keyId: 'license-signing-v2-2026-01',
        payload,
        ...overrides,
      }),
    });
    const approval = await approve.json() as { approvalToken: string };
    const sign = await subject.app.request('/v1/sign', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-operator-jwt': 'operator',
        'x-witness-jwt': 'witness',
      },
      body: JSON.stringify({
        purpose: 'license',
        keyId: 'license-signing-v2-2026-01',
        payload,
        approvalToken: approval.approvalToken,
      }),
    });
    return { ...subject, approve, sign, approval };
  }

  it('signs after operator approval and witness approval', async () => {
    const { sign, vault } = await approveAndSign();
    expect(sign.status).toBe(200);
    await expect(sign.json()).resolves.toMatchObject({
      signature: 'c2ln',
      keyVersion: '1',
    });
    expect(vault.calls).toHaveLength(1);
    expect(vault.calls[0].keyId).toBe('license-signing-v2-2026-01');
  });

  it('blocks replay of the same approval token', async () => {
    const { app: hono } = app();
    const payload = {
      schemaVersion: 2,
      licenseId: 'lic_123',
      deploymentBinding: {
        deploymentId: 'a'.repeat(64),
        deploymentLabel: 'replay-test',
      },
    };
    const approve = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload }),
    });
    const { approvalToken } = await approve.json() as { approvalToken: string };
    const body = JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload, approvalToken });
    const first = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator', 'x-witness-jwt': 'witness' },
      body,
    });
    const second = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator', 'x-witness-jwt': 'witness' },
      body,
    });
    expect(first.status).toBe(200);
    expect(second.status).toBe(409);
  });

  it('denies crossed purpose and keyId', async () => {
    const { app: hono } = app();
    const res = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({
        purpose: 'license',
        keyId: 'revocation-signing-v2-2026-01',
        payload: { schemaVersion: 2 },
      }),
    });
    expect(res.status).toBe(400);
  });

  it('denies expired witness jwt', async () => {
    const { sign } = await approveAndSign({}, new FakeAuth('operator-1', 'witness-1', true));
    expect(sign.status).toBe(500);
  });

  it('denies operator and witness with same sub', async () => {
    const { sign } = await approveAndSign({}, new FakeAuth('same-user', 'same-user'));
    expect(sign.status).toBe(403);
  });

  it('denies keyId outside whitelist', async () => {
    const { app: hono } = app();
    const res = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({
        purpose: 'license',
        keyId: 'license-signing-v1-old',
        payload: { schemaVersion: 2 },
      }),
    });
    expect(res.status).toBe(400);
  });

  it('returns 502 and audits when Vault fails', async () => {
    const vault = new FakeVault();
    vault.fail = true;
    const { sign } = await approveAndSign({}, undefined, vault);
    expect(sign.status).toBe(502);
    const audit = await readFile(auditPath, 'utf8');
    expect(audit).toContain('vault-5xx');
  });

  it('rejects license payload without deploymentBinding at approve time', async () => {
    const subject = app();
    const res = await subject.app.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({
        purpose: 'license',
        keyId: 'license-signing-v2-2026-01',
        // no deploymentBinding → must 400
        payload: { schemaVersion: 2, licenseId: 'lic_no_binding', customer: 'X' },
      }),
    });
    expect(res.status).toBe(400);
    // 应有 audit 记录拒绝原因（生产 onError 把对外 error 统一打成 request-failed
    // 防泄漏 internal 细节，但 audit log 保留真实 reason）。
    const audit = await readFile(auditPath, 'utf8');
    expect(audit).toContain('binding-required');
  });

  it('rejects license payload with malformed deploymentBinding', async () => {
    const subject = app();
    const res = await subject.app.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({
        purpose: 'license',
        keyId: 'license-signing-v2-2026-01',
        payload: {
          schemaVersion: 2,
          deploymentBinding: { deploymentId: 'not-hex', deploymentLabel: 'X' },
        },
      }),
    });
    expect(res.status).toBe(400);
  });

  it('allows revocation purpose without deploymentBinding (binding is license-only)', async () => {
    const subject = app();
    const res = await subject.app.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({
        purpose: 'revocation',
        keyId: 'revocation-signing-v2-2026-01',
        payload: { schemaVersion: 1, version: 1, revoked: [] },
      }),
    });
    expect(res.status).toBe(200);
  });
});
