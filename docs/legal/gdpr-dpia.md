# GDPR Data Protection Impact Assessment (DPIA) — Aster Lang Cloud SaaS

| | |
|---|---|
| Phase | 3C-4 |
| Status | Draft — internal review, not yet signed |
| Regulation | EU GDPR (Regulation 2016/679) Article 35 |
| Conducted by | Aster Lang founding team |
| Last review | 2026-05-11 |
| Next review | Annual or upon major change |

> **⚠️ Legal disclaimer**: This DPIA is a self-assessment. For high-risk processing (e.g. financial decisions affecting data subjects), consult external counsel and consider DPA consultation per Article 36.

---

## 1. Description of processing

### 1.1 Nature
Aster Lang Cloud is a **multi-tenant SaaS platform** where customers:
- Author business rules in controlled natural language (CNL)
- Submit input data for rule evaluation
- Receive deterministic decisions + audit trails
- Optionally use AI to draft rules

### 1.2 Scope
- **Geographic**: Global, with primary hosting in US (Cloudflare + Vercel)
- **Data subjects**: Customer's end-users (whose data flows through customer-defined rules)
- **Data categories**: see DPA §4

### 1.3 Context
Aster does NOT operate the customer's business — Aster executes customer-defined logic. **Customer is the data Controller; Aster is the Processor**.

### 1.4 Purposes
1. Rule evaluation (core service)
2. AI assistance (optional)
3. Audit and compliance reporting
4. Billing and quota management
5. Abuse detection

---

## 2. Necessity and proportionality

### 2.1 Lawful basis (GDPR Article 6)

Aster relies on:

- **Article 6(1)(b)** — Performance of a contract — for processing necessary to provide the Service
- **Article 6(1)(f)** — Legitimate interests — for abuse detection, security monitoring, telemetry
- **Article 6(1)(a)** — Consent — for optional features (AI assistance opt-in, telemetry sharing)

Customer (as Controller) must establish their own lawful basis for the data they submit to Aster.

### 2.2 Data minimization
- Customer chooses what data to submit; Aster enforces no PII detection but flags candidates
- Aster collects no analytics beyond Customer's account and quota usage
- AI prompts: Aster does not retain prompt content beyond 30 days

### 2.3 Storage limitation
- Audit logs: per Customer plan (7d Free / 90d Pro / configurable Enterprise)
- AI usage records: 90 days (PM 07)
- Account data: until account deletion + 30-day soft-delete window
- Aggregated metrics: indefinite (anonymized)

---

## 3. Risks to data subjects

### 3.1 Risk inventory

| # | Risk | Likelihood | Severity | Mitigated risk |
|---|---|---|---|---|
| R1 | Unauthorized access to Customer Data via stolen credentials | Medium | High | Low (MFA + audit + rate limit) |
| R2 | Data breach via vulnerable dependency | Low | High | Low (renovate-bot + Phase 3D pen-test) |
| R3 | Cross-tenant data leakage | Low | High | Low (RLS-equivalent code paths, no shared DB connections per tenant) |
| R4 | AI model leaks Customer prompt content | Low | High | Low-Med (BYOK option; OpenAI/Anthropic ToS confirm no training on API data) |
| R5 | Insider access misuse | Low | High | Med (no formal employee policy yet — Phase 3C-3) |
| R6 | Audit log tampering | Very Low | High | Very Low (SHA-256 hash chain) |
| R7 | Loss of data subject access right | Low | Medium | Low (Article 15 export endpoint exists) |
| R8 | Vendor breach (Sub-Processor) | Low | High | Med-Low (DPA + sub-processor list) |

### 3.2 Risk mapping to GDPR principles

| Risk | Article(s) | Principle |
|---|---|---|
| R1, R3, R5 | 5(1)(f), 32 | Integrity & confidentiality / Security |
| R2 | 32, 25 | Security / Privacy by design |
| R4 | 5(1)(b), 28 | Purpose limitation / Processor |
| R6 | 32 | Security |
| R7 | 15-22 | Data subject rights |
| R8 | 28(2)-(4) | Sub-Processor |

---

## 4. Measures to address risks

### 4.1 Technical measures

| Measure | Status | Effective against |
|---|---|---|
| TLS 1.3 in transit | ✅ | R1, R3 |
| AES-256 at rest | ✅ | R1, R5 |
| pgcrypto encryption of BYOK keys | ✅ | R4 |
| NextAuth + GitHub MFA | ✅ | R1 |
| Account lockout after 5 failed attempts | ✅ | R1 |
| API key HMAC signing | ✅ | R1 |
| Rate limiting (per user / per IP) | ✅ | R1, R5 |
| RBAC on team workspaces | ✅ | R3 |
| Hash-chained audit log | ✅ | R6 |
| AI quota + circuit breaker | ✅ | R4 (limits exposure) |
| CSP + CSRF headers (Phase 3D) | 🚧 | R2 (XSS), R5 (CSRF) |
| Pen-test (Phase 3D) | 🚧 | R2 |
| SOC 2 Type II (Phase 4) | 📋 | R5, R8 |

### 4.2 Organizational measures

| Measure | Status |
|---|---|
| Formal employee security policy | 🔴 Phase 3C-3 |
| Vendor risk register | 🔴 Phase 3C-3 |
| Incident response plan | 🔴 Phase 3C-3 |
| DR runbook + testing | 🔴 Phase 3C-3 → Phase 4 |
| Annual DPIA review | This document — recurring |

---

## 5. Residual risks

After mitigations:

| Risk | Residual level |
|---|---|
| R1 (credential theft) | **Low** — MFA + lockout |
| R2 (dependency vulnerability) | **Low** post-Phase 3D pen-test |
| R3 (cross-tenant leak) | **Low** |
| R4 (AI prompt content) | **Low-Med** — depends on chosen LLM provider's posture; BYOK shifts risk to Customer |
| R5 (insider misuse) | **Med-Low** until Phase 3C-3 employee policy |
| R6 (audit tampering) | **Very Low** |
| R7 (data subject rights) | **Low** |
| R8 (sub-processor) | **Med-Low** — DPA mitigates, but Customer relies on sub-processor's own DPA |

### 5.1 Cases requiring DPA consultation (Article 36)

If Aster processes data of a category currently excluded (special-category data per Article 9), the Customer / Aster must consult the supervisory authority before processing.

---

## 6. Conclusion

Aster Lang Cloud's processing is **necessary and proportionate** for the stated purposes. Identified risks are mitigated to **low or low-medium** residual levels with the controls described.

The DPIA finds **no need for Article 36 consultation** under the current scope.

**Recommended actions**:
1. Close Phase 3C-3 organizational gaps before Q4 2026 (Enterprise GTM blocker)
2. Complete Phase 3D pen-test
3. Begin SOC 2 Type II audit period
4. Annual DPIA review or upon any of:
   - New Sub-Processor
   - New data category
   - New geographic deployment (e.g. China data residency)
   - Material change to AI features

---

**Document version**: v1.0 · 2026-05-11
**Approved by counsel**: 🚧 pending (Phase 3C-4 BD dependency)
