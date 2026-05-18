import { createHash, randomBytes } from 'node:crypto';

export function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === 'object') {
    const input = value as Record<string, unknown>;
    return Object.keys(input)
      .sort()
      .reduce<Record<string, unknown>>((acc, key) => {
        acc[key] = sortKeys(input[key]);
        return acc;
      }, {});
  }
  return value;
}

export function canonicalStringify(value: unknown): string {
  return JSON.stringify(sortKeys(value));
}

export function sha256Hex(input: string | Buffer): string {
  return createHash('sha256').update(input).digest('hex');
}

export function base64url(input: string | Buffer): string {
  return Buffer.from(input).toString('base64url');
}

export function fromBase64(input: string): Buffer {
  return Buffer.from(input, 'base64');
}

export function utcNow(): string {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export function ulid(): string {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  const bytes = Buffer.alloc(16);
  let ts = BigInt(Date.now());
  for (let i = 5; i >= 0; i -= 1) {
    bytes[i] = Number(ts & 0xffn);
    ts >>= 8n;
  }
  randomBytes(10).copy(bytes, 6);
  let value = 0n;
  for (const byte of bytes) value = (value << 8n) | BigInt(byte);
  let out = '';
  for (let i = 0; i < 26; i += 1) {
    out = alphabet[Number(value & 31n)] + out;
    value >>= 5n;
  }
  return out;
}
