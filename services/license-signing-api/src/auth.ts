import type { Context } from 'hono';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import type { Config } from './config.js';
import { AppError } from './errors.js';

export type Role = 'license-operator' | 'license-witness' | 'license-admin';

export interface Principal {
  sub: string;
  role: Role;
  iat: number;
  exp: number;
}

export interface AuthService {
  verifyOperator(c: Context): Promise<Principal>;
  verifyWitness(c: Context): Promise<Principal>;
  verifyAdmin(c: Context): Promise<Principal>;
}

export function createJwtAuth(config: Config): AuthService {
  const jwks = createRemoteJWKSet(new URL(config.JWT_JWKS_URL));

  async function verifyToken(token: string, expectedRole: Role): Promise<Principal> {
    let payload: Record<string, unknown>;
    try {
      const verified = await jwtVerify(token, jwks, {
        issuer: config.JWT_ISSUER,
        audience: config.JWT_AUDIENCE,
      });
      payload = verified.payload as Record<string, unknown>;
    } catch {
      throw new AppError(401, 'auth-failed', 'JWT verification failed');
    }

    const sub = typeof payload.sub === 'string' ? payload.sub : '';
    const role = typeof payload.role === 'string' ? payload.role : '';
    const iat = typeof payload.iat === 'number' ? payload.iat : 0;
    const exp = typeof payload.exp === 'number' ? payload.exp : 0;

    if (!sub || role !== expectedRole || !iat || !exp) {
      throw new AppError(403, 'auth-forbidden', 'JWT role or required claims invalid');
    }
    if (exp - iat > 300) {
      throw new AppError(403, 'auth-forbidden', 'JWT lifetime exceeds 5 minutes');
    }
    return { sub, role: expectedRole, iat, exp };
  }

  return {
    verifyOperator(c) {
      const token = c.req.header('x-operator-jwt');
      if (!token) throw new AppError(401, 'auth-missing', 'X-Operator-JWT missing');
      return verifyToken(token, 'license-operator');
    },
    verifyWitness(c) {
      const token = c.req.header('x-witness-jwt');
      if (!token) throw new AppError(401, 'auth-missing', 'X-Witness-JWT missing');
      return verifyToken(token, 'license-witness');
    },
    verifyAdmin(c) {
      const auth = c.req.header('authorization') ?? '';
      const token = auth.toLowerCase().startsWith('bearer ') ? auth.slice(7) : '';
      if (!token) throw new AppError(401, 'auth-missing', 'Bearer admin JWT missing');
      return verifyToken(token, 'license-admin');
    },
  };
}
