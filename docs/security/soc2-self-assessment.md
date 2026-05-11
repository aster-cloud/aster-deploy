# SOC 2 Type II Self-Assessment

| | |
|---|---|
| Phase | 3C |
| Status | Draft — pre-auditor engagement |
| Trust Service Categories | Security, Confidentiality, Availability |
| Target audit period | 6 months (Q3-Q4 2026) |
| Auditor | TBD (Vanta / Drata / Thoropass shortlist) |

---

## 1. Purpose

This is the pre-engagement self-assessment for SOC 2 Type II. It identifies **gaps** between current Aster Lang security posture and the AICPA Trust Services Criteria, so we can close them before an external auditor begins fieldwork.

**Out of scope** (Phase 4):
- Processing Integrity (not relevant — Aster does not process customer-defined business outcomes)
- Privacy (covered by GDPR DPIA, see `legal/gdpr-dpia.md`)

---

## 2. Criteria self-assessment

Legend: ✅ implemented · 🟡 partial / documented · 🔴 gap · ⚪ N/A

### CC1: Control Environment

| Criterion | Status | Evidence / Gap |
|---|---|---|
| CC1.1 — Demonstrates commitment to integrity and ethical values | 🟡 | Code of Conduct (`docs/CONTRIBUTING.md`); need formal employee policy |
| CC1.2 — Board oversees control environment | 🔴 | Pre-formal board; informal founding-team review |
| CC1.3 — Establishes structures, reporting lines, authorities | 🟡 | Founding team org chart exists; need formal RACI |
| CC1.4 — Demonstrates commitment to competence | 🟡 | Engineering hires gated on technical interview; no formal job descriptions yet |
| CC1.5 — Enforces accountability | 🟡 | Code review + audit log; no formal disciplinary policy |

### CC2: Communication and Information

| Criterion | Status | Evidence / Gap |
|---|---|---|
| CC2.1 — Information used to support functioning of internal control | 🟡 | Mixpanel + audit_logs; need formal data classification policy |
| CC2.2 — Internal communication of objectives and responsibilities | 🟡 | Slack + this docs repo |
| CC2.3 — External communication relevant to internal control | 🔴 | No public security disclosure policy / `SECURITY.md` |

### CC3: Risk Assessment

| Criterion | Status | Evidence / Gap |
|---|---|---|
| CC3.1 — Specifies objectives | ✅ | PM 02 (north-star metric), PM 05 (pricing), PM 01 (one-pager) |
| CC3.2 — Identifies and assesses risks | 🟡 | Phase 1-3 staging reports document risks; no formal risk register |
| CC3.3 — Considers fraud potential | 🔴 | AI quota abuse detection exists (Phase 1); broader fraud risk register absent |
| CC3.4 — Identifies and assesses significant change | 🟡 | Phase reports cover major changes; no formal change-impact assessment |

### CC4: Monitoring Activities

| Criterion | Status | Evidence / Gap |
|---|---|---|
| CC4.1 — Conducts ongoing and/or separate evaluations | 🟡 | vitest + cron health checks; no formal periodic review schedule |
| CC4.2 — Communicates internal control deficiencies | 🟡 | GitHub Issues; no formal escalation matrix |

### CC5: Control Activities

| Criterion | Status | Evidence / Gap |
|---|---|---|
| CC5.1 — Selects and develops control activities | ✅ | Documented in Phase 1-3 staging reports + PR review |
| CC5.2 — Selects and develops general controls over technology | ✅ | Phase 1A-4 (Lexicon SPI ABI), CI typecheck, hash-chain audit, MFA on GitHub |
| CC5.3 — Deploys through policies and procedures | 🟡 | Runbooks emerging; no formal SOP repository yet |

### CC6: Logical and Physical Access Controls

| Criterion | Status | Evidence / Gap |
|---|---|---|
| CC6.1 — Implements logical access security | ✅ | NextAuth + GitHub OAuth + MFA (GitHub-side) + API key HMAC |
| CC6.2 — Registers and authorizes new users | ✅ | NextAuth flow + email verification + GDPR Article 15 export |
| CC6.3 — Manages access credentials and authentication | ✅ | Password hashing (Argon2id via Auth.js); session expiry; account lockout |
| CC6.4 — Restricts physical access | ⚪ | N/A — cloud-only; underlying providers (Vercel, Cloudflare, K3S host) handle physical |
| CC6.5 — Discontinues physical access | ⚪ | Same |
| CC6.6 — Implements logical access security measures | ✅ | RBAC on team workspaces (Phase 1C SOX); rate-limiting; Helmet headers (Phase 3D) |
| CC6.7 — Transmission of sensitive information | ✅ | TLS 1.3 enforced; HSTS planned in Phase 3D |
| CC6.8 — Prevents/detects unauthorized software | 🟡 | renovate-bot dependency updates; no formal allowlist policy |

### CC7: System Operations

| Criterion | Status | Evidence / Gap |
|---|---|---|
| CC7.1 — Detects and monitors deficiencies | 🟡 | Sentry + console logs; no formal SIEM yet |
| CC7.2 — Monitors system components and operation | 🟡 | dashboard tiles (AHA / dunning); Phase 3E adds Grafana |
| CC7.3 — Evaluates security incidents | 🔴 | No formal incident response plan |
| CC7.4 — Responds to identified security incidents | 🔴 | Same |
| CC7.5 — Recovery and continuity | 🟡 | DB backups (managed Postgres); no formal DR runbook |

### CC8: Change Management

| Criterion | Status | Evidence / Gap |
|---|---|---|
| CC8.1 — Authorizes, designs, develops, configures, documents, tests, approves, implements changes | ✅ | PR review + CI typecheck + 660+ test suite + audit_logs |

### CC9: Risk Mitigation

| Criterion | Status | Evidence / Gap |
|---|---|---|
| CC9.1 — Identifies, selects, develops risk-mitigation activities | 🟡 | Phase 1-3 plans; no formal risk-mitigation prioritization |
| CC9.2 — Assesses and manages vendor / business-partner risk | 🔴 | No formal vendor risk policy (Stripe, OpenAI, Cloudflare, Vercel) |

### Additional categories

#### Availability (A)

| Criterion | Status | Evidence / Gap |
|---|---|---|
| A1.1 — Maintains, monitors, evaluates capacity | 🟡 | AI global circuit breaker; need Phase 3B perf baseline |
| A1.2 — Authorizes, designs, develops backup and recovery | 🟡 | Managed Postgres backups; no formal RPO/RTO target |
| A1.3 — Tests recovery procedures | 🔴 | Never tested |

#### Confidentiality (C)

| Criterion | Status | Evidence / Gap |
|---|---|---|
| C1.1 — Identifies and maintains confidential information | ✅ | PII detection + classification (aster-api `policy` module) |
| C1.2 — Disposes of confidential information | 🟡 | GDPR Article 17 (right to erasure) implemented; no formal retention schedule |

---

## 3. Top 10 prioritized gaps (Phase 3C — fix before auditor)

| # | Gap | Effort | Sprint |
|---|---|---|---|
| 1 | No `SECURITY.md` / responsible-disclosure policy | 0.1 wk | 3C-3 |
| 2 | No formal incident response plan | 0.3 wk | 3C-3 |
| 3 | No vendor risk register (Stripe / OpenAI / Cloudflare / Vercel / Managed Postgres) | 0.3 wk | 3C-3 |
| 4 | No formal DR test on staging | 0.5 wk | 3C → 4 |
| 5 | No formal risk register | 0.2 wk | 3C-3 |
| 6 | No SIEM / centralized log aggregation | 1 wk | Phase 3E (Grafana setup) |
| 7 | No formal employee security policy / handbook | 0.2 wk | 3C-3 |
| 8 | No public security disclosure channel | 0.1 wk | 3C-3 (`security@aster-lang.cloud` + `SECURITY.md`) |
| 9 | No RACI matrix | 0.2 wk | 3C-3 |
| 10 | No formal change-management SOP (PR review is informal) | 0.3 wk | 3C-3 |

**Total Phase 3C engineering effort**: ~3 weeks (across 0.3 FTE for the quarter)

---

## 4. Auditor engagement decision matrix

| Factor | Vanta | Drata | Thoropass |
|---|---|---|---|
| Price (annual) | $$$ | $$$$ | $$ |
| Continuous monitoring | ✅ | ✅ | 🟡 |
| Maven Central / npm integration | 🟡 | 🟡 | 🔴 |
| China data-residency compliance | 🔴 | 🔴 | ✅ |
| Best for | US Enterprise prospects | US SaaS | Asia-Pacific |

**Recommendation**: pilot Vanta (US Enterprise alignment); evaluate Thoropass at 6 months if Chinese clients dominate pipeline.

---

## 5. Next steps

1. Founders sign off on auditor vendor decision (BD dependency)
2. Procurement of Vanta / Drata (BD + finance dependency)
3. Phase 3C-3 closes top 10 gaps
4. 3-month auditor evidence collection period
5. Type I attestation (~Phase 4 Q3)
6. Type II attestation (~Phase 4 Q4 / Year 2)

**Type I provides immediate Enterprise GTM marketing value; Type II is the real audit.**
