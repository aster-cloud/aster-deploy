import { createPublicKey, generateKeyPairSync, verify, randomBytes } from 'node:crypto';
import { createServer, type Server } from 'node:http';
import { spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
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

/**
 * Pick the first available container runtime. The original `docker` literal
 * fails on machines where `docker` is a shell alias for `podman` (alias 不
 * 走 spawn)，导致 ENOENT。Honor explicit override via VAULT_CONTAINER_CMD
 * for CI that pins one runtime.
 */
function detectContainerRuntime(): string | null {
  const override = process.env.VAULT_CONTAINER_CMD?.trim();
  if (override) return override;
  for (const cmd of ['docker', 'podman']) {
    const r = spawnSync(cmd, ['--version'], { stdio: 'ignore' });
    if (r.status === 0) return cmd;
  }
  return null;
}

const CONTAINER_CMD = detectContainerRuntime();
const SKIP_REASON = !CONTAINER_CMD
  ? 'no docker/podman runtime detected — set VAULT_CONTAINER_CMD or install docker'
  : '';

// Tests opt-in via SKIP_VAULT_INTEGRATION=1 also accepted (CI without runtime).
// Default: run if a runtime is available. Adds a clear log so skipped CI runs
// don't look like silent passes.
const SHOULD_SKIP =
  !CONTAINER_CMD || process.env.SKIP_VAULT_INTEGRATION === '1';
if (SHOULD_SKIP) {
  // eslint-disable-next-line no-console
  console.warn(
    `[license-signing-api integration] SKIPPED — ${SKIP_REASON || 'SKIP_VAULT_INTEGRATION=1'}`,
  );
}

/**
 * Unique container name per test process — lets afterAll() reliably remove
 * the vault even if SIGTERM to the foreground client doesn't propagate
 * (podman on macOS leaves the underlying container `--rm`-pending until the
 * actual stop is observed; explicit `rm -f` by name guarantees teardown).
 */
const VAULT_NAME = `license-signing-api-it-vault-${process.pid}-${Date.now()}`;

describe.skipIf(SHOULD_SKIP)('license-signing-api integration', () => {
  let jwksServer: Server;
  let jwksUrl: string;
  let dir: string;
  let privateKey: CryptoKey | Uint8Array | unknown;
  let publicJwk: Record<string, unknown>;

  beforeAll(async () => {
    dir = await mkdtemp(join(tmpdir(), 'license-signing-api-it-'));
    // detectContainerRuntime() 已保证 CONTAINER_CMD 不为 null（否则 describe
    // 已 skip）。-d 后台启动 + 命名容器，让 afterAll 可以稳定 `rm -f` 清理。
    // 旧实现用 foreground spawn + SIGTERM，在 podman/macOS 下容器会泄漏到
    // 下次 run，污染 18200 端口或 metric 数据。
    spawnSync(CONTAINER_CMD!, ['rm', '-f', VAULT_NAME], { stdio: 'ignore' });
    const start = spawnSync(
      CONTAINER_CMD!,
      [
        'run',
        '-d',
        '--rm',
        '--name',
        VAULT_NAME,
        '-p',
        '18200:8200',
        '-e',
        `VAULT_DEV_ROOT_TOKEN_ID=${vaultToken}`,
        '-e',
        'VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200',
        'docker.io/hashicorp/vault:1.17',
        'server',
        '-dev',
      ],
      { encoding: 'utf8' },
    );
    if (start.status !== 0) {
      throw new Error(
        `${CONTAINER_CMD} run failed (status=${start.status}): ${start.stderr || start.stdout}`,
      );
    }
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
    // P0-A S1：独立 Vault Transit key（密钥分离），签升级授权 manifest。
    await vaultWrite('/v1/transit/keys/regression-transition-signing-v2-2026-01', {
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
    // 显式 rm -f：vault.kill('SIGTERM') 对 podman/macOS 没用（spawn 的是
    // podman client，不是容器进程本身）。--rm 只在容器自然退出时清，所以
    // 必须主动 stop。-d 模式下 spawnSync 立刻返回，没有 ChildProcess
    // handle 要 kill。
    spawnSync(CONTAINER_CMD!, ['rm', '-f', VAULT_NAME], { stdio: 'ignore' });
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
      ALLOWED_KEY_IDS: '^(license|revocation|regression-transition)-signing-v2-[0-9]{4}-[0-9]{2}$',
      AUDIT_LOG_PATH: join(dir, 'audit.jsonl'),
      LICENSES_SLACK_WEBHOOK: '',
      LOG_LEVEL: 'error',
      allowedKeyIdRegex: /^(license|revocation|regression-transition)-signing-v2-[0-9]{4}-[0-9]{2}$/,
      // VaultTransitClient.sign() calls this; without it the header becomes
      // literally "undefined" and Vault rejects with 403, manifesting as
      // vault-sign-failed. loadConfig() wires this up in prod from
      // VAULT_TOKEN / VAULT_TOKEN_FILE — tests must mirror it.
      readVaultToken: () => vaultToken,
    };
  }

  /**
   * 创建一个 fresh app 实例 + 各依赖。每个 it 单独构造避免 approval/replay
   * 状态泄漏。opts 让具体测试调小 TTL / 限速以模拟边界条件。
   */
  function app(opts: {
    approvalTtlMs?: number;
    approvalLimit?: number;
    signLimit?: number;
    auditPath?: string;
    vaultClient?: ConstructorParameters<typeof VaultTransitClient>[0] extends Config ? VaultTransitClient : never;
  } = {}) {
    const cfg = config();
    if (opts.auditPath) cfg.AUDIT_LOG_PATH = opts.auditPath;
    return createApp({
      config: cfg,
      auth: createJwtAuth(cfg),
      vault: opts.vaultClient ?? new VaultTransitClient(cfg),
      audit: new JsonlAuditLogger(cfg.AUDIT_LOG_PATH),
      approvals: new InMemoryApprovalStore(opts.approvalTtlMs),
      replay: new ReplayCache(),
      approvalLimiter: new FixedWindowRateLimiter(opts.approvalLimit ?? 100, 60_000),
      signLimiter: new FixedWindowRateLimiter(opts.signLimit ?? 100, 60_000),
    });
  }

  /** Reusable license payload with required v3 deploymentBinding. */
  function licensePayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
    return {
      schemaVersion: 2,
      licenseId: `lic_it_${randomBytes(4).toString('hex')}`,
      customer: 'Integration Customer',
      tier: 'enterprise',
      deploymentBinding: {
        deploymentId: 'a'.repeat(64),
        deploymentLabel: 'integration-test',
      },
      ...overrides,
    };
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
    const payload = licensePayload({ licenseId: 'lic_it_1' });
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

    // 验证 binding 字段穿过签名通道仍然可解析（保护契约：on-prem verify 严格
    // 读 deploymentBinding.deploymentId 与 ASTER_DEPLOYMENT_ID 比对，不能漏字段）
    const canonical = JSON.parse(Buffer.from(signed.canonicalPayload, 'base64url').toString());
    expect(canonical.deploymentBinding).toEqual({
      deploymentId: 'a'.repeat(64),
      deploymentLabel: 'integration-test',
    });
  }, 60_000);

  it('P0-A S1：regression-transition manifest 经真 Vault Transit（独立 key）签名并验签通过', async () => {
    const hono = app();
    const KEY = 'regression-transition-signing-v2-2026-01';
    // upgrade-manifest：无 deploymentBinding（binding 是 license-only），含 X→Y toolchain + 批准元数据。
    const manifest = {
      schemaVersion: 1,
      purpose: 'regression-transition',
      baselineToolchainId: 'abi=1.0;core=1.0.13;validator=1;build=oldsha',
      currentToolchainId: 'abi=1.0;core=1.0.14;validator=1;build=newsha',
      policyId: 'pol-it-1',
      approvedBy: 'user-approver-it',
    };
    const operator = await jwt('operator-regr', 'license-operator');
    const witness = await jwt('witness-regr', 'license-witness');

    const approve = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'regression-transition', keyId: KEY, payload: manifest }),
    });
    expect(approve.status).toBe(200);
    const approval = (await approve.json()) as { approvalToken: string };

    const sign = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body: JSON.stringify({ purpose: 'regression-transition', keyId: KEY, payload: manifest, approvalToken: approval.approvalToken }),
    });
    expect(sign.status).toBe(200);
    const signed = (await sign.json()) as { canonicalPayload: string; signature: string };
    // ★用**独立 key**（regression-transition-signing）的公钥验签——密钥分离闭环。
    const publicKey = await transitPublicKey(KEY);
    expect(
      verify(null, Buffer.from(signed.canonicalPayload, 'base64url'), publicKey, Buffer.from(signed.signature, 'base64url')),
    ).toBe(true);
    // manifest 字段穿过签名通道可解析（cloud verify 会读 baseline/current toolchainId）。
    const canonical = JSON.parse(Buffer.from(signed.canonicalPayload, 'base64url').toString());
    expect(canonical.baselineToolchainId).toBe(manifest.baselineToolchainId);
    expect(canonical.currentToolchainId).toBe(manifest.currentToolchainId);
  }, 60_000);

  it('rejects replay', async () => {
    const hono = app();
    const payload = licensePayload({ licenseId: 'lic_it_2' });
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
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload: licensePayload() }),
    });
    expect(res.status).toBe(401);
  }, 60_000);

  it('rejects crossed keyId', async () => {
    const hono = app();
    const operator = await jwt('operator-cross', 'license-operator');
    const res = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'license', keyId: 'revocation-signing-v2-2026-01', payload: licensePayload() }),
    });
    expect(res.status).toBe(400);
  }, 60_000);

  // ───────── E follow-ups ─────────

  it('rejects license payload without deploymentBinding (real stack)', async () => {
    const auditPath = join(dir, `audit-binding-${randomBytes(4).toString('hex')}.jsonl`);
    const hono = app({ auditPath });
    const operator = await jwt('operator-nobind', 'license-operator');
    const res = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      // 显式不带 deploymentBinding → 必须 400
      body: JSON.stringify({
        purpose: 'license',
        keyId: 'license-signing-v2-2026-01',
        payload: { schemaVersion: 2, licenseId: 'lic_no_bind', customer: 'X' },
      }),
    });
    expect(res.status).toBe(400);
    // 公开 error masked 为 request-failed（详见 src/index.ts onError）；audit 保留真实原因。
    const audit = await readFile(auditPath, 'utf8');
    expect(audit).toContain('binding-required');
  }, 60_000);

  it('rejects sign when operator == witness even with valid approval', async () => {
    const hono = app();
    const operator = await jwt('same-user', 'license-operator');
    const witness = await jwt('same-user', 'license-witness');
    const payload = licensePayload();
    const approve = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload }),
    });
    const approval = await approve.json() as { approvalToken: string };
    const sign = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload, approvalToken: approval.approvalToken }),
    });
    expect(sign.status).toBe(403);
  }, 60_000);

  it('rejects sign with an approval token that was never issued', async () => {
    const hono = app();
    const operator = await jwt('operator-fake-token', 'license-operator');
    const witness = await jwt('witness-fake-token', 'license-witness');
    const fakeToken = randomBytes(32).toString('hex');
    const res = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body: JSON.stringify({
        purpose: 'license',
        keyId: 'license-signing-v2-2026-01',
        payload: licensePayload(),
        approvalToken: fakeToken,
      }),
    });
    expect(res.status).toBe(404);
  }, 60_000);

  it('rejects sign when payload was tampered between approve and sign', async () => {
    const hono = app();
    const operator = await jwt('operator-tamper', 'license-operator');
    const witness = await jwt('witness-tamper', 'license-witness');
    const original = licensePayload({ seatLimit: 100 });
    const approve = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload: original }),
    });
    const approval = await approve.json() as { approvalToken: string };
    // 给 sign 提交一个不同的 payload（同 binding 但 seatLimit 改大）
    const tampered = { ...original, seatLimit: 9999 };
    const res = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body: JSON.stringify({
        purpose: 'license',
        keyId: 'license-signing-v2-2026-01',
        payload: tampered,
        approvalToken: approval.approvalToken,
      }),
    });
    expect(res.status).toBe(403);
  }, 60_000);

  it('rejects sign after approval TTL expires', async () => {
    const hono = app({ approvalTtlMs: 100 });
    const operator = await jwt('operator-ttl', 'license-operator');
    const witness = await jwt('witness-ttl', 'license-witness');
    const payload = licensePayload();
    const approve = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload }),
    });
    const approval = await approve.json() as { approvalToken: string };
    // 等到 TTL + margin 后 sign，approval 应已被 gc 视为 not-found。
    await new Promise((resolve) => setTimeout(resolve, 300));
    const res = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload, approvalToken: approval.approvalToken }),
    });
    expect(res.status).toBe(404);
  }, 60_000);

  it('signs revocation payload through real Vault without deploymentBinding (license-only invariant)', async () => {
    const hono = app();
    const operator = await jwt('operator-rev', 'license-operator');
    const witness = await jwt('witness-rev', 'license-witness');
    // 撤销 payload 不要求 binding —— 验证 assertLicenseBinding 真的 purpose-scoped。
    const payload = { schemaVersion: 1, version: 1, publishedAt: new Date().toISOString(), revoked: [] };

    const approve = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'revocation', keyId: 'revocation-signing-v2-2026-01', payload }),
    });
    expect(approve.status).toBe(200);
    const approval = await approve.json() as { approvalToken: string };

    const sign = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body: JSON.stringify({
        purpose: 'revocation',
        keyId: 'revocation-signing-v2-2026-01',
        payload,
        approvalToken: approval.approvalToken,
      }),
    });
    expect(sign.status).toBe(200);
    const signed = await sign.json() as { canonicalPayload: string; signature: string };
    const publicKey = await transitPublicKey('revocation-signing-v2-2026-01');
    expect(
      verify(
        null,
        Buffer.from(signed.canonicalPayload, 'base64url'),
        publicKey,
        Buffer.from(signed.signature, 'base64url'),
      ),
    ).toBe(true);
  }, 60_000);

  it('rate-limits approve requests per operator and records denial', async () => {
    const auditPath = join(dir, `audit-rate-${randomBytes(4).toString('hex')}.jsonl`);
    const hono = app({ approvalLimit: 2, auditPath });
    const operator = await jwt('operator-rate', 'license-operator');
    const body = () =>
      JSON.stringify({
        purpose: 'license',
        keyId: 'license-signing-v2-2026-01',
        payload: licensePayload(),
      });
    const r1 = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: body(),
    });
    const r2 = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: body(),
    });
    const r3 = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: body(),
    });
    expect(r1.status).toBe(200);
    expect(r2.status).toBe(200);
    expect(r3.status).toBe(429);
    const audit = await readFile(auditPath, 'utf8');
    expect(audit).toContain('approval-rate-limited');
  }, 60_000);

  it('returns 502 and audits when Vault is unreachable mid-sign', async () => {
    // 用一个故意指向无人监听端口的 client 模拟 Vault 中途失联。
    const brokenCfg: Config = { ...config(), VAULT_ADDR: 'http://127.0.0.1:1' };
    const auditPath = join(dir, `audit-vault-${randomBytes(4).toString('hex')}.jsonl`);
    const hono = createApp({
      config: { ...brokenCfg, AUDIT_LOG_PATH: auditPath },
      auth: createJwtAuth(brokenCfg),
      vault: new VaultTransitClient(brokenCfg),
      audit: new JsonlAuditLogger(auditPath),
      approvals: new InMemoryApprovalStore(),
      replay: new ReplayCache(),
      approvalLimiter: new FixedWindowRateLimiter(100, 60_000),
      signLimiter: new FixedWindowRateLimiter(100, 60_000),
    });
    const operator = await jwt('operator-vault-down', 'license-operator');
    const witness = await jwt('witness-vault-down', 'license-witness');
    const payload = licensePayload();
    const approve = await hono.request('/v1/approve', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload }),
    });
    const approval = await approve.json() as { approvalToken: string };
    const sign = await hono.request('/v1/sign', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-operator-jwt': operator, 'x-witness-jwt': witness },
      body: JSON.stringify({ purpose: 'license', keyId: 'license-signing-v2-2026-01', payload, approvalToken: approval.approvalToken }),
    });
    expect(sign.status).toBe(502);
    const audit = await readFile(auditPath, 'utf8');
    expect(audit).toContain('sign-denied');
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
