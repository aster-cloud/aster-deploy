import { describe, expect, it } from 'vitest';
import { canonicalStringify, sha256Hex } from '../src/canonical-json.js';

describe('canonicalStringify', () => {
  it('is independent of object property order', () => {
    const left = {
      tier: 'enterprise',
      features: ['sso', 'audit-export'],
      nested: { b: 2, a: 1 },
    };
    const right = {
      nested: { a: 1, b: 2 },
      features: ['sso', 'audit-export'],
      tier: 'enterprise',
    };
    expect(canonicalStringify(left)).toEqual(canonicalStringify(right));
    expect(sha256Hex(canonicalStringify(left))).toEqual(sha256Hex(canonicalStringify(right)));
  });
});
