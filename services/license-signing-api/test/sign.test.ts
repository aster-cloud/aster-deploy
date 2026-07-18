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
    ALLOWED_KEY_IDS: '^(license|revocation|regression-transition)-signing-v2-[0-9]{4}-[0-9]{2}$',
    AUDIT_LOG_PATH: auditPath,
    LICENSES_SLACK_WEBHOOK: '',
    LOG_LEVEL: 'error',
    allowedKeyIdRegex: /^(license|revocation|regression-transition)-signing-v2-[0-9]{4}-[0-9]{2}$/,
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

  // ── P0-A S1（信任层5 transition authorization）：regression-transition purpose，mirror revocation ──

  const REGR_KEY = 'regression-transition-signing-v2-2026-01';
  const REGR_MANIFEST = {
    schemaVersion: 1,
    purpose: 'regression-transition',
    baselineToolchainId: 'abi=1.0;core=1.0.13;validator=1;build=oldsha',
    currentToolchainId: 'abi=1.0;core=1.0.14;validator=1;build=newsha',
    policyId: 'pol-1',
    approvedBy: 'user-approver',
  };

  it('regression-transition：full 2-人 ceremony approve+sign 通过（独立 key，无需 deploymentBinding）', async () => {
    const subject = app();
    const approve = await subject.app.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({ purpose: 'regression-transition', keyId: REGR_KEY, payload: REGR_MANIFEST }),
    });
    expect(approve.status).toBe(200);
    const approval = (await approve.json()) as { approvalToken: string };
    const sign = await subject.app.request('/v1/sign', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-operator-jwt': 'operator',
        'x-witness-jwt': 'witness',
      },
      body: JSON.stringify({
        purpose: 'regression-transition', keyId: REGR_KEY, payload: REGR_MANIFEST,
        approvalToken: approval.approvalToken,
      }),
    });
    expect(sign.status).toBe(200);
    const body = (await sign.json()) as { signature?: string; keyVersion?: string; canonicalPayload?: string };
    expect(body.signature).toBeTruthy();
    expect(body.canonicalPayload).toBeTruthy();
  });

  it('regression-transition：错 key 前缀（用 license key）→ 400 purpose-key-mismatch（密钥分离）', async () => {
    const subject = app();
    const res = await subject.app.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({
        purpose: 'regression-transition',
        keyId: 'license-signing-v2-2026-01', // 错：应用 regression-transition-signing 前缀
        payload: REGR_MANIFEST,
      }),
    });
    expect(res.status).toBe(400);
  });

  it('regression-transition：反向——license purpose 用 regression-transition key → 400（密钥不可混用）', async () => {
    const subject = app();
    const res = await subject.app.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({ purpose: 'license', keyId: REGR_KEY, payload: { schemaVersion: 2 } }),
    });
    expect(res.status).toBe(400);
  });

  // ── Codex 复审阻断修复：被签 payload 必须自证协议域（严格 manifest schema）──

  async function approveRegr(payload: unknown) {
    const subject = app();
    return subject.app.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator' },
      body: JSON.stringify({ purpose: 'regression-transition', keyId: REGR_KEY, payload }),
    });
  }

  it('regression-transition：payload 缺 purpose → 400 manifest-invalid（签名体须自证协议域）', async () => {
    const { purpose: _omit, ...noPurpose } = REGR_MANIFEST;
    void _omit;
    expect((await approveRegr(noPurpose)).status).toBe(400);
  });

  it('regression-transition：payload.purpose=license（≠外层）→ 400（防跨协议：不能用 transition key 签 license 声明）', async () => {
    expect((await approveRegr({ ...REGR_MANIFEST, purpose: 'license' })).status).toBe(400);
  });

  it('regression-transition：缺 baselineToolchainId/currentToolchainId → 400（无 X→Y 不是 manifest）', async () => {
    const { baselineToolchainId: _b, ...noBaseline } = REGR_MANIFEST;
    void _b;
    expect((await approveRegr(noBaseline)).status).toBe(400);
    const { currentToolchainId: _cc, ...noCurrent } = REGR_MANIFEST;
    void _cc;
    expect((await approveRegr(noCurrent)).status).toBe(400);
  });

  it('regression-transition：baseline===current → 400 manifest-not-directional（升级必须有方向）', async () => {
    const same = 'abi=1.0;core=1.0.14;validator=1;build=x';
    expect((await approveRegr({ ...REGR_MANIFEST, baselineToolchainId: same, currentToolchainId: same })).status).toBe(400);
  });

  it('regression-transition：缺 policyId 或 approvedBy → 400（批准元数据必需）', async () => {
    const { policyId: _p, ...noPolicy } = REGR_MANIFEST;
    void _p;
    expect((await approveRegr(noPolicy)).status).toBe(400);
    const { approvedBy: _a, ...noApprover } = REGR_MANIFEST;
    void _a;
    expect((await approveRegr(noApprover)).status).toBe(400);
  });

  it('regression-transition：任意 payload（如 {foo:1}）→ 400（不再接受 z.record 任意对象）', async () => {
    expect((await approveRegr({ foo: 1 })).status).toBe(400);
  });

  it('regression-transition：/sign 入口**也**独立校验 manifest（防未来误删 approve-only 守卫）', async () => {
    // 直接打 /sign 带非法 manifest（无需先 approve）——sign 入口的 assertRegressionTransitionManifest
    // 在 approval 消费/hash 比对**之前**就该 400 manifest-invalid（Codex 复审非阻断建议：锁 /sign 二次守卫）。
    const subject = app();
    const res = await subject.app.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': 'operator', 'x-witness-jwt': 'witness' },
      body: JSON.stringify({
        purpose: 'regression-transition', keyId: REGR_KEY,
        payload: { foo: 1 }, // 非法 manifest
        approvalToken: 'a'.repeat(64),
      }),
    });
    expect(res.status).toBe(400);
  });
});
