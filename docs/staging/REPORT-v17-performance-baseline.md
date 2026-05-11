# Performance Baseline + DB Index Audit (v17)

| | |
|---|---|
| Phase | 3B |
| Sprint | 3B-1 + 3B-4 |
| Date | 2026-05-11 |
| Status | 🟡 Awaiting `perf-env` deployment for k6 execution |

---

## 1. Executive summary

Phase 3B deliverables in this report:
- ✅ k6 baseline + policy-evaluation scripts (`aster-deploy/perf/`)
- ✅ DB index audit of `aster-cloud` schema (29 tables)
- 🚧 Actual k6 execution requires `perf-env` deployment (BD/DevOps dependency)

This report identifies **2 missing composite indexes** in `aster-cloud` that will become hotspots as WAADR scales. Recommended migration is included.

---

## 2. k6 scripts shipped

| Script | Purpose | Acceptance gate |
|---|---|---|
| [`perf/k6-baseline.js`](../../perf/k6-baseline.js) | Anonymous SSR + dev landing | P99 < 1000ms, fail rate < 0.1% |
| [`perf/k6-policy-evaluation.js`](../../perf/k6-policy-evaluation.js) | 1000 RPS sustained + 2000 RPS burst | **P99 < 200ms, fail rate < 0.1%** (PM 02 counter-metric) |
| `perf/k6-ai-sse.js` (TODO) | SSE worker pool isolation | Phase 3B-3 |

### Execution prerequisites (Phase 3 DevOps task)

1. Provision `perf-env` k3s namespace (separate from staging)
2. Seed 100 demo policies via `aster-cloud/src/scripts/seed-usability-tenant.ts`
3. Mint API key with rate-limit waiver
4. Run: `API_KEY=<perf-key> POLICY_IDS=p1,p2,...,p100 k6 run perf/k6-policy-evaluation.js`

---

## 3. DB index audit (aster-cloud, 29 tables)

### 3.1 Inventory

Audit method: read `src/db/schema.ts` and trace `WHERE` clauses in all query call sites.

**Tables with comprehensive indexes** (no action needed):
- `users` (email, stripeCustomerId, emailNormalized)
- `policies` (userId, teamId, groupId, shareSlug, deletedAt)
- `policyVersions` (policyId+version, sourceHash, status, policyId+status, policyId+isDefault)
- `policyApprovals` (versionId, approverId, createdAt)
- `apiCallRecords` (userId+periodMonth, tenantId+createdAt, apiKeyId+createdAt)
- `usedNonces` (expiresAt, policyId)
- `aiUsageRecords` (userId+periodMonth, userId+createdAt, teamId+periodMonth, promptHash+userId)
- `teams` (ownerId, slug)
- `teamMembers` (teamId+userId, userId)

### 3.2 Hot path gaps

#### Gap 1: AHA detection idempotency lookup

**Query**: `auditLogs WHERE userId = ? AND action = ?`
**Location**: `src/lib/metrics/aha-detection.ts:35`
**Current indexes**: `AuditLog_userId_idx` + `AuditLog_action_idx` (single-column each)
**Hot path frequency**: Once per policy approval (≥ 1k QPS at NSM target)
**Issue**: Postgres can intersect bitmaps but composite is faster + smaller

**Recommended migration**:

```sql
-- aster-cloud Phase 3B-4 migration
CREATE INDEX CONCURRENTLY "AuditLog_userId_action_idx"
  ON "AuditLog" ("userId", "action");

-- Optional: drop single-column userId index if redundant (composite covers it)
-- DROP INDEX CONCURRENTLY "AuditLog_userId_idx";
-- (Keep both for now; only drop after benchmark proves redundancy.)
```

#### Gap 2: User audit timeline (Phase 4 GDPR Article 15 export)

**Query**: `auditLogs WHERE userId = ? ORDER BY createdAt DESC LIMIT 1000`
**Location**: future GDPR data export endpoint
**Current indexes**: `AuditLog_userId_idx` + `AuditLog_createdAt_idx`
**Issue**: Postgres ORDER BY ... LIMIT with WHERE filter needs index on (filter, sort) tuple

**Recommended migration**:

```sql
CREATE INDEX CONCURRENTLY "AuditLog_userId_createdAt_idx"
  ON "AuditLog" ("userId", "createdAt" DESC);
```

#### Gap 3: Stripe reconcile cron (low priority)

**Query**: `teams.findMany` (full table scan, no WHERE)
**Frequency**: Daily cron (24h interval)
**Verdict**: Full scan acceptable at < 10k teams. Re-evaluate at 100k+.

### 3.3 Indexes that look redundant (no action — keep monitoring)

| Index | Reason kept |
|---|---|
| `User_email_idx` (single) | Used for password-based login lookup; non-uniqueness OK (soft-deleted accounts) |
| `Account_userId_idx` (single) | NextAuth-internal |

---

## 4. Drizzle migration draft

Save as `aster-cloud/drizzle/migrations/0xxx_phase3_audit_log_composite_indexes.sql`:

```sql
-- Phase 3B-4: composite indexes for hot AHA + GDPR queries
-- Background: REPORT-v17 §3.2

CREATE INDEX CONCURRENTLY IF NOT EXISTS "AuditLog_userId_action_idx"
  ON "AuditLog" ("userId", "action");

CREATE INDEX CONCURRENTLY IF NOT EXISTS "AuditLog_userId_createdAt_idx"
  ON "AuditLog" ("userId", "createdAt" DESC);
```

**Apply order**:
1. Apply migration to staging via `pnpm db:migrate`
2. Verify with `EXPLAIN ANALYZE` on AHA lookup
3. Roll to production after 7 days of staging soak

---

## 5. Risks & mitigations

| Risk | Mitigation |
|---|---|
| `CREATE INDEX CONCURRENTLY` on busy table can take hours | Schedule during low-traffic window (~04:00 China time per Mixpanel data) |
| Composite indexes increase write amplification | AHA detection is read-heavy; estimated 5% write overhead acceptable |
| Single-column indexes become redundant | Monitor `pg_stat_user_indexes`; drop only after composite hit-rate ≥ 99% for 14 days |
| k6 load test crashes `perf-env` | Run dry-run with 10 RPS first; ensure DB connection pool ≥ 200 |

---

## 6. Open items

1. **DevOps**: provision `perf-env` k3s namespace
2. **Drizzle migration apply**: Phase 3B-4 sub-task (after this report acceptance)
3. **aster-api perf scripts**: Phase 3B-1 deliverable (covered by this report's k6 scripts)
4. **Audit log async pipeline**: Phase 3B-2 (separate report v18)

---

**Version**: v17 · 2026-05-11
**Author**: Phase 3B engineering
**Next**: REPORT-v18 covering audit log async + monitoring
