# Data Processing Agreement (DPA) — Aster Lang

| | |
|---|---|
| Phase | 3C-4 |
| Status | Template — review with counsel before use with customers |
| Effective version | v1.0 draft 2026-05-11 |

> **⚠️ Legal disclaimer**: This template is a starting point. Run by counsel before signing with any customer. Variances by jurisdiction (EU GDPR, UK GDPR, China PIPL, California CCPA, Brazil LGPD).

---

## Parties

This Data Processing Agreement ("**DPA**") is entered into between:

- **Controller**: [Customer legal name] ("Customer")
- **Processor**: Aster Lang Authors (legal entity TBD) ("Aster")

Effective on the latter of: (a) Customer's Aster Lang subscription start date, or (b) the date Customer accepts this DPA via the Aster Cloud signup flow.

---

## 1. Definitions

Capitalized terms have the meanings in the GDPR (Regulation 2016/679) unless redefined here.

- **Aster Services**: the Aster Lang platform, including aster-cloud SaaS, REST/GraphQL APIs, hosted LLM features, and any self-hosted runtime artifacts.
- **Customer Data**: any Personal Data (as defined in GDPR Article 4(1)) provided by Customer to Aster through the Aster Services, including but not limited to: rule source code, evaluation inputs, audit logs, AI prompt content.

---

## 2. Subject matter and duration

- **Subject matter**: Processing of Customer Data for the purpose of providing Aster Services.
- **Duration**: As long as Customer's Aster Lang subscription is active, plus a 30-day post-termination window for data export (GDPR Article 32(1)(c)).

---

## 3. Nature and purpose of processing

Aster processes Customer Data to:

1. Execute Customer-defined policies (rule evaluation)
2. Generate audit logs (hash-chained, immutable)
3. Provide AI assistance (drafting / explaining / repairing rules)
4. Render UI in aster-cloud
5. Compute billing and quota usage
6. Detect abuse (rate limiting, ban list)

**Aster does NOT**: train AI models on Customer Data without explicit opt-in; sell or share Customer Data with third parties beyond Sub-Processors listed in §6.

---

## 4. Type of personal data

| Category | Examples | Source |
|---|---|---|
| Account data | Email, name, OAuth identifier | Customer registers |
| Authentication data | Hashed password, session tokens | Customer login |
| Usage data | Policy evaluations, API calls, AI prompts | Customer activity |
| Audit data | Hash-chained log of every policy decision | System-generated |
| AI prompt content | Customer-supplied natural-language inputs | Customer usage of AI features |

**Special categories** (GDPR Article 9, e.g. health, biometrics): Customer is responsible for not submitting such data into rule inputs or AI prompts. If Customer's use case involves such data, a separate agreement is required.

---

## 5. Data subject rights (GDPR Articles 15-22)

Aster supports the following through the aster-cloud UI:

| Right | Endpoint / mechanism | SLA |
|---|---|---|
| Article 15 — Access | `GET /api/user/ai-data-export` + audit log download | 30 days |
| Article 16 — Rectification | Self-service profile edit | Immediate |
| Article 17 — Erasure | Account deletion flow → 30-day soft-delete, then purge | 30 days |
| Article 18 — Restriction of processing | Pause subscription | Immediate |
| Article 20 — Portability | JSON export of all Customer Data | 30 days |
| Article 21 — Object to processing | Account deletion (no granular opt-out for processing necessary to service) | 30 days |
| Article 22 — Automated decision-making | Customer-defined policies; Aster only executes — no Aster-imposed automated decisions affecting data subjects | N/A |

---

## 6. Sub-Processors

Aster engages the following Sub-Processors. Customer's continued use of Aster Services after notice of any change constitutes consent (GDPR Article 28(2)).

| Sub-Processor | Location | Purpose | Data category |
|---|---|---|---|
| Cloudflare | Global (EU/US/AP) | CDN, DDoS protection | All HTTP traffic |
| Vercel | US (primary) | aster-cloud hosting | All aster-cloud requests |
| Managed Postgres (Vercel / Neon / Supabase TBD) | US / EU | Application database | All Customer Data |
| Stripe | US / EU | Billing | Payment data, customer profile |
| OpenAI / Anthropic / Vertex AI (Customer-selected) | US (or per BYOK) | LLM inference | AI prompt content |
| Resend | US | Transactional email | Email + content |

Aster will provide 30 days' notice of any new Sub-Processor via email. Customer may object in writing, in which case parties negotiate in good faith; absent resolution, Customer may terminate.

---

## 7. International transfers

- Aster's primary infrastructure is in the **United States**.
- For Customer Data subject to **GDPR**, transfers rely on:
  - **Standard Contractual Clauses (SCCs)** — Module 2 (Controller-to-Processor)
  - Supplementary measures: TLS 1.3 in transit, AES-256 at rest, audit logging
- For Customer Data subject to **China PIPL**: Customer must opt into BYOK or self-hosted deployment; aster-cloud SaaS is **not certified** for cross-border data export from China.

---

## 8. Security measures (GDPR Article 32)

Aster implements the following technical and organizational measures:

| Control | Implementation |
|---|---|
| Encryption in transit | TLS 1.3 enforced; HSTS (Phase 3D) |
| Encryption at rest | AES-256 (managed Postgres); pgcrypto column encryption for BYOK keys |
| Access control | NextAuth + MFA; RBAC on team workspaces; API key HMAC |
| Authentication | Argon2id password hashing; account lockout |
| Audit logging | Hash-chained immutable audit log per evaluation |
| Backup | Daily managed Postgres backups; 30-day retention |
| Vulnerability management | renovate-bot dependency monitoring; planned pen-test (Phase 3D) |
| Personnel | All staff sign confidentiality agreement; planned formal employee policy (Phase 3C SOC 2) |

---

## 9. Personal Data breach notification (GDPR Article 33)

In case of a Personal Data breach, Aster will notify Customer:

- **Within 48 hours** of becoming aware
- Via the email registered to Customer's primary account
- Including: nature of breach, categories of data subjects and data records, likely consequences, measures taken/proposed

---

## 10. Audit rights (GDPR Article 28(3)(h))

Customer may audit Aster's compliance:

1. By reviewing Aster's annual **SOC 2 Type II report** (Phase 4 deliverable) — preferred
2. By submitting a written questionnaire — Aster responds within 30 days
3. By on-site audit at Customer's expense — subject to 30-day notice, NDA, and limit of one audit per 12-month period

---

## 11. Termination and return / deletion of data

Upon termination of the Aster Lang subscription:

1. Customer has **30 days** to export their data via `GET /api/user/ai-data-export` and other endpoints
2. After 30 days, Aster **deletes** all Customer Data, except:
   - Audit logs retained per Customer's plan (90 days Pro, configurable Enterprise) for compliance replay
   - Anonymized aggregate metrics (e.g. count of evaluations) for billing reconciliation

---

## 12. Governing law

This DPA is governed by the laws of [jurisdiction TBD — likely Delaware, USA for US Enterprise, or Singapore for APAC]. Disputes resolved by arbitration in [city TBD].

---

## 13. Signatures

For Aster:
Name: ________________________
Title: ________________________
Date: ________________________

For Customer:
Name: ________________________
Title: ________________________
Date: ________________________

---

**Template version**: v1.0 · 2026-05-11
**Approved by counsel**: 🚧 pending (Phase 3C-4 BD dependency)
