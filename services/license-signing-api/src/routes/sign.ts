import { randomBytes, timingSafeEqual } from 'node:crypto';
import { Hono } from 'hono';
import { z } from 'zod';
import type { AppDeps, AppVariables } from '../index.js';
import { AppError } from '../errors.js';
import { base64url, canonicalStringify, sha256Hex } from '../canonical-json.js';
import { assertKeyPurpose, type Purpose } from '../vault.js';

const PurposeSchema = z.enum(['license', 'revocation', 'regression-transition']);

const ApproveBodySchema = z.object({
  purpose: PurposeSchema,
  keyId: z.string().min(1).max(128),
  payload: z.record(z.unknown()),
});

const SignBodySchema = ApproveBodySchema.extend({
  approvalToken: z.string().regex(/^[0-9a-f]{64}$/),
});

// Shape of deploymentBinding for license payloads (required since v3).
// We don't validate the full LicensePayloadV2 here — that's aster-cloud's job
// at verify time — but binding is non-negotiable: a license without binding
// is a regression to the v1/v2 "one key, N deployments" attack model.
const DeploymentBindingSchema = z.object({
  deploymentId: z.string().regex(/^[0-9a-f]{64}$/, 'deploymentId must be 64-hex sha256'),
  deploymentLabel: z.string().min(1).max(256),
  deploymentUrl: z.string().url().optional(),
});

/**
 * Reject sign requests for `purpose='license'` whose payload lacks a valid
 * deploymentBinding. License signing is the only path that mutates trust
 * surface for on-prem; revocation payloads have a different schema (no
 * binding) and are not affected.
 */
function assertLicenseBinding(purpose: Purpose, payload: unknown): void {
  if (purpose !== 'license') return;
  const binding = (payload as Record<string, unknown> | null)?.deploymentBinding;
  const parsed = DeploymentBindingSchema.safeParse(binding);
  if (!parsed.success) {
    throw new AppError(
      400,
      'binding-required',
      'license payload must include deploymentBinding { deploymentId, deploymentLabel, deploymentUrl? }',
    );
  }
}

function constantTimeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}

function parseLicenseId(purpose: string, payload: unknown): string | undefined {
  if (purpose !== 'license' || !payload || typeof payload !== 'object') return undefined;
  const value = (payload as Record<string, unknown>).licenseId;
  return typeof value === 'string' ? value : undefined;
}

function validateKeyId(deps: AppDeps, purpose: Purpose, keyId: string): void {
  if (!deps.config.allowedKeyIdRegex.test(keyId)) {
    throw new AppError(400, 'key-not-allowed', 'keyId not allowed');
  }
  assertKeyPurpose(purpose, keyId);
}

export function createSignRoutes(deps: AppDeps): Hono<{ Variables: AppVariables }> {
  const app = new Hono<{ Variables: AppVariables }>();

  app.post('/approve', async (c) => {
    const requestId = c.get('requestId');
    const operator = await deps.auth.verifyOperator(c);
    if (!deps.approvalLimiter.allow(operator.sub)) {
      await deps.audit.append({
        requestId,
        event: 'sign-denied',
        operatorSub: operator.sub,
        errorReason: 'approval-rate-limited',
      });
      throw new AppError(429, 'rate-limited', 'approval rate limit exceeded');
    }

    const body = ApproveBodySchema.parse(await c.req.json());
    validateKeyId(deps, body.purpose, body.keyId);
    assertLicenseBinding(body.purpose, body.payload);

    const canonicalPayload = canonicalStringify(body.payload);
    const payloadSha256 = sha256Hex(canonicalPayload);
    const operatorSession = randomBytes(32).toString('hex');
    const approval = deps.approvals.put({
      purpose: body.purpose,
      keyId: body.keyId,
      canonicalPayload,
      payloadSha256,
      operatorSub: operator.sub,
      operatorSession,
    });

    // exactOptionalPropertyTypes: spread licenseId only when defined.
    const licenseIdForAudit = parseLicenseId(body.purpose, body.payload);
    await deps.audit.append({
      requestId,
      event: 'approval',
      operatorSub: operator.sub,
      keyId: body.keyId,
      purpose: body.purpose,
      approvalToken: approval.approvalToken,
      payloadSha256,
      ...(licenseIdForAudit !== undefined ? { licenseId: licenseIdForAudit } : {}),
    });

    return c.json({
      approvalToken: approval.approvalToken,
      expiresAt: new Date(approval.expiresAtMs).toISOString().replace(/\.\d{3}Z$/, 'Z'),
      payloadSha256,
    });
  });

  app.post('/sign', async (c) => {
    const requestId = c.get('requestId');
    const [operator, witness] = await Promise.all([
      deps.auth.verifyOperator(c),
      deps.auth.verifyWitness(c),
    ]);

    if (operator.sub === witness.sub) {
      await deps.audit.append({
        requestId,
        event: 'sign-denied',
        operatorSub: operator.sub,
        witnessSub: witness.sub,
        errorReason: 'same-subject',
      });
      throw new AppError(403, 'same-subject', 'operator and witness must differ');
    }

    if (!deps.signLimiter.allow(witness.sub)) {
      await deps.audit.append({
        requestId,
        event: 'sign-denied',
        operatorSub: operator.sub,
        witnessSub: witness.sub,
        errorReason: 'sign-rate-limited',
      });
      throw new AppError(429, 'rate-limited', 'sign rate limit exceeded');
    }

    const body = SignBodySchema.parse(await c.req.json());
    validateKeyId(deps, body.purpose, body.keyId);
    assertLicenseBinding(body.purpose, body.payload);

    if (deps.replay.has(witness.sub, body.approvalToken)) {
      await deps.audit.append({
        requestId,
        event: 'replay-attempt',
        operatorSub: operator.sub,
        witnessSub: witness.sub,
        keyId: body.keyId,
        purpose: body.purpose,
        approvalToken: body.approvalToken,
        errorReason: 'approval-token-replayed',
      });
      throw new AppError(409, 'replay', 'approval token replayed');
    }

    const canonicalPayload = canonicalStringify(body.payload);
    const payloadSha256 = sha256Hex(canonicalPayload);
    const approval = deps.approvals.consume(body.approvalToken);
    if (!approval) {
      await deps.audit.append({
        requestId,
        event: 'sign-denied',
        operatorSub: operator.sub,
        witnessSub: witness.sub,
        keyId: body.keyId,
        purpose: body.purpose,
        approvalToken: body.approvalToken,
        payloadSha256,
        errorReason: 'approval-not-found',
      });
      throw new AppError(404, 'approval-not-found', 'approval not found');
    }

    const expectedToken = sha256Hex(`${approval.canonicalPayload}${approval.operatorSub}${approval.operatorSession}`);
    if (
      !constantTimeEqual(expectedToken, body.approvalToken) ||
      approval.operatorSub !== operator.sub ||
      approval.purpose !== body.purpose ||
      approval.keyId !== body.keyId ||
      approval.payloadSha256 !== payloadSha256 ||
      approval.canonicalPayload !== canonicalPayload
    ) {
      await deps.audit.append({
        requestId,
        event: 'sign-denied',
        operatorSub: operator.sub,
        witnessSub: witness.sub,
        keyId: body.keyId,
        purpose: body.purpose,
        approvalToken: body.approvalToken,
        payloadSha256,
        errorReason: 'approval-mismatch',
      });
      throw new AppError(403, 'approval-mismatch', 'approval mismatch');
    }

    deps.replay.add(witness.sub, body.approvalToken);

    try {
      const signed = await deps.vault.sign(body.keyId, canonicalPayload);
      const licenseIdForSign = parseLicenseId(body.purpose, body.payload);
      await deps.audit.append({
        requestId,
        event: 'sign',
        operatorSub: operator.sub,
        witnessSub: witness.sub,
        keyId: body.keyId,
        purpose: body.purpose,
        approvalToken: body.approvalToken,
        payloadSha256,
        vaultKeyVersion: signed.keyVersion,
        ...(licenseIdForSign !== undefined ? { licenseId: licenseIdForSign } : {}),
      });
      return c.json({
        signature: signed.signatureBase64Url,
        keyVersion: signed.keyVersion,
        canonicalPayload: base64url(canonicalPayload),
      });
    } catch (err) {
      await deps.audit.append({
        requestId,
        event: 'sign-denied',
        operatorSub: operator.sub,
        witnessSub: witness.sub,
        keyId: body.keyId,
        purpose: body.purpose,
        approvalToken: body.approvalToken,
        payloadSha256,
        errorReason: err instanceof Error ? err.message : 'vault-sign-failed',
      });
      throw new AppError(502, 'vault-sign-failed', 'Vault sign failed');
    }
  });

  return app;
}
