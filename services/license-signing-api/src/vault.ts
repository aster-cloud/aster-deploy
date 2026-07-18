import type { Config } from './config.js';
import { base64url, fromBase64 } from './canonical-json.js';
import { AppError } from './errors.js';

export type Purpose = 'license' | 'revocation' | 'regression-transition';

export interface VaultStatus {
  sealed: boolean;
}

export interface VaultSignature {
  signatureBase64Url: string;
  keyVersion: string;
}

export interface VaultClient {
  status(): Promise<VaultStatus>;
  sign(keyId: string, canonicalPayload: string): Promise<VaultSignature>;
}

export function assertKeyPurpose(purpose: Purpose, keyId: string): void {
  if (purpose === 'license' && !keyId.startsWith('license-signing-')) {
    throw new AppError(400, 'purpose-key-mismatch', 'license purpose must use license-signing key');
  }
  if (purpose === 'revocation' && !keyId.startsWith('revocation-signing-')) {
    throw new AppError(400, 'purpose-key-mismatch', 'revocation purpose must use revocation-signing key');
  }
  // ★P0-A S1（信任层5 transition authorization）：独立 Vault Transit key（密钥分离 > purpose 字段分离），
  // regression-transition purpose 必须用 regression-transition-signing 前缀的 key——即使 license/revocation
  // key 泄露也不能伪造升级授权 manifest，反之亦然。
  if (purpose === 'regression-transition' && !keyId.startsWith('regression-transition-signing-')) {
    throw new AppError(400, 'purpose-key-mismatch', 'regression-transition purpose must use regression-transition-signing key');
  }
}

export class VaultTransitClient implements VaultClient {
  constructor(private readonly config: Config) {}

  async status(): Promise<VaultStatus> {
    const res = await fetch(`${this.config.VAULT_ADDR}/v1/sys/seal-status`, {
      headers: { 'x-vault-token': this.config.VAULT_TOKEN },
    });
    if (!res.ok) throw new AppError(503, 'vault-unreachable', 'Vault status failed');
    const body = (await res.json()) as { sealed?: boolean };
    return { sealed: body.sealed === true };
  }

  async sign(keyId: string, canonicalPayload: string): Promise<VaultSignature> {
    if (!this.config.allowedKeyIdRegex.test(keyId)) {
      throw new AppError(400, 'key-not-allowed', 'keyId not allowed');
    }

    const input = Buffer.from(canonicalPayload, 'utf8').toString('base64');
    const res = await fetch(`${this.config.VAULT_ADDR}/v1/transit/sign/${encodeURIComponent(keyId)}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-vault-token': this.config.readVaultToken(),
      },
      body: JSON.stringify({ input }),
    });

    if (!res.ok) {
      throw new AppError(502, 'vault-sign-failed', `Vault sign failed: ${res.status}`);
    }

    const body = (await res.json()) as { data?: { signature?: string } };
    const signature = body.data?.signature ?? '';
    const match = /^vault:v([0-9]+):(.+)$/.exec(signature);
    // Both capture groups are required by the pattern; under strict mode
    // TS still types match[N] as string | undefined, so check explicitly.
    if (!match || match[1] === undefined || match[2] === undefined) {
      throw new AppError(502, 'vault-signature-invalid', 'Vault signature format invalid');
    }

    return {
      keyVersion: match[1],
      signatureBase64Url: base64url(fromBase64(match[2])),
    };
  }
}
