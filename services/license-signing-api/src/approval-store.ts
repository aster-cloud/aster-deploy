import { sha256Hex, utcNow } from './canonical-json.js';
import type { Purpose } from './vault.js';

export interface PendingApproval {
  approvalToken: string;
  purpose: Purpose;
  keyId: string;
  canonicalPayload: string;
  payloadSha256: string;
  operatorSub: string;
  operatorSession: string;
  expiresAtMs: number;
  createdAt: string;
}

export interface ApprovalStore {
  put(input: Omit<PendingApproval, 'approvalToken' | 'createdAt' | 'expiresAtMs'>): PendingApproval;
  consume(approvalToken: string): PendingApproval | undefined;
  peek(approvalToken: string): PendingApproval | undefined;
  /** 当前未过期 approval 数量；用于 Prometheus pending_approvals gauge。 */
  size(): number;
}

export class InMemoryApprovalStore implements ApprovalStore {
  private readonly entries = new Map<string, PendingApproval>();

  constructor(private readonly ttlMs = 10 * 60 * 1000) {}

  put(input: Omit<PendingApproval, 'approvalToken' | 'createdAt' | 'expiresAtMs'>): PendingApproval {
    this.gc();
    const approvalToken = sha256Hex(`${input.canonicalPayload}${input.operatorSub}${input.operatorSession}`);
    const approval: PendingApproval = {
      ...input,
      approvalToken,
      createdAt: utcNow(),
      expiresAtMs: Date.now() + this.ttlMs,
    };
    this.entries.set(approvalToken, approval);
    return approval;
  }

  peek(approvalToken: string): PendingApproval | undefined {
    this.gc();
    return this.entries.get(approvalToken);
  }

  consume(approvalToken: string): PendingApproval | undefined {
    this.gc();
    const approval = this.entries.get(approvalToken);
    if (!approval) return undefined;
    this.entries.delete(approvalToken);
    return approval;
  }

  size(): number {
    this.gc();
    return this.entries.size;
  }

  private gc(): void {
    const now = Date.now();
    for (const [token, approval] of this.entries) {
      if (approval.expiresAtMs <= now) this.entries.delete(token);
    }
  }
}

export class ReplayCache {
  private readonly seenBySubject = new Map<string, string[]>();
  private readonly seenSet = new Map<string, Set<string>>();

  constructor(private readonly maxTokensPerSubject = 1000) {}

  has(subject: string, token: string): boolean {
    return this.seenSet.get(subject)?.has(token) ?? false;
  }

  add(subject: string, token: string): void {
    const list = this.seenBySubject.get(subject) ?? [];
    const set = this.seenSet.get(subject) ?? new Set<string>();
    if (set.has(token)) return;
    list.push(token);
    set.add(token);
    while (list.length > this.maxTokensPerSubject) {
      const evicted = list.shift();
      if (evicted) set.delete(evicted);
    }
    this.seenBySubject.set(subject, list);
    this.seenSet.set(subject, set);
  }
}

export class FixedWindowRateLimiter {
  private readonly buckets = new Map<string, { windowStart: number; count: number }>();

  constructor(
    private readonly max: number,
    private readonly windowMs: number,
  ) {}

  allow(subject: string): boolean {
    const now = Date.now();
    const bucket = this.buckets.get(subject);
    if (!bucket || now - bucket.windowStart >= this.windowMs) {
      this.buckets.set(subject, { windowStart: now, count: 1 });
      return true;
    }
    if (bucket.count >= this.max) return false;
    bucket.count += 1;
    return true;
  }
}
