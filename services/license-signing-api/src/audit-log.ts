import { mkdir, open, readFile } from 'node:fs/promises';
import { dirname } from 'node:path';
import { utcNow } from './canonical-json.js';
import type { Purpose } from './vault.js';

export type AuditEventName = 'approval' | 'sign' | 'sign-denied' | 'replay-attempt';

export interface AuditEvent {
  timestamp?: string;
  requestId: string;
  event: AuditEventName;
  operatorSub?: string;
  witnessSub?: string;
  keyId?: string;
  purpose?: Purpose;
  approvalToken?: string;
  payloadSha256?: string;
  vaultKeyVersion?: string;
  licenseId?: string;
  errorReason?: string;
}

export interface AuditLogger {
  append(event: AuditEvent): Promise<void>;
  recent(limit: number): Promise<AuditEvent[]>;
  /** 可选 cleanup hook（graceful shutdown 调用）；JSONL impl 是 no-op，因为每次 append 都 open+close。 */
  close?(): Promise<void>;
}

export class JsonlAuditLogger implements AuditLogger {
  constructor(
    private readonly path: string,
    private readonly slackWebhook?: string,
  ) {}

  async append(event: AuditEvent): Promise<void> {
    const fullEvent = { timestamp: utcNow(), ...event };
    await mkdir(dirname(this.path), { recursive: true });
    const handle = await open(this.path, 'a', 0o600);
    try {
      await handle.appendFile(`${JSON.stringify(fullEvent)}\n`, 'utf8');
    } finally {
      await handle.close();
    }
    if (fullEvent.event === 'sign' && this.slackWebhook) {
      await this.postSlack(fullEvent).catch(() => undefined);
    }
  }

  async recent(limit: number): Promise<AuditEvent[]> {
    try {
      const data = await readFile(this.path, 'utf8');
      return data
        .trim()
        .split('\n')
        .filter(Boolean)
        .slice(-limit)
        .map((line) => JSON.parse(line) as AuditEvent);
    } catch {
      return [];
    }
  }

  private async postSlack(event: AuditEvent): Promise<void> {
    if (!this.slackWebhook) return;
    // ★审计标签按 purpose 分——regression-transition/revocation sign 不该在合规审计里被标成
    // "license signing event"（误导）。purpose 未知时回落通用 "signing event"。
    const label = event.purpose === 'license'
      ? 'license signing event'
      : event.purpose === 'revocation'
        ? 'revocation signing event'
        : event.purpose === 'regression-transition'
          ? 'regression-transition signing event'
          : 'signing event';
    const body = {
      text: `${label}: operator=${event.operatorSub ?? '-'} witness=${event.witnessSub ?? '-'} key=${event.keyId ?? '-'} purpose=${event.purpose ?? '-'} licenseId=${event.licenseId ?? '-'}`,
      metadata: {
        event_type: 'license_signing_api_sign',
        event_payload: {
          requestId: event.requestId,
          operatorSub: event.operatorSub,
          witnessSub: event.witnessSub,
          keyId: event.keyId,
          purpose: event.purpose,
          licenseId: event.licenseId,
          vaultKeyVersion: event.vaultKeyVersion,
        },
      },
    };
    await fetch(this.slackWebhook, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
  }
}
