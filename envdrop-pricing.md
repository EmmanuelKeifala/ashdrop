# EnvDrop — Pricing Model (Tier 2 Monetization)

**Status:** Draft v1.0
**Author:** Principal Architect / Product
**Last updated:** 2026-06-19
**Companion docs:** `envdrop-prd.md`, `envdrop-system-design.md`

---

## 0. Guiding principle

Our infrastructure cost is trivial — stateless compute + a small, TTL-bounded Redis tier
(see SDD §2, §12). Therefore Tier 2 pricing is **value-based, not cost-plus**.

> We do **not** charge for ciphertext bytes, drops, or API calls.
> We charge for **control, collaboration, and compliance** — the things teams feel pain over.

Charging per-usage would be self-defeating: it would penalize the exact behavior we want
(sharing more secrets, onboarding more teammates). Price aligns with *value delivered*, not
resources consumed.

---

## 1. The three-tier ladder

| | **Free** | **Team** | **Enterprise** |
|---|---|---|---|
| **Price** | $0 | **$8 / user / mo** (annual) · $10 monthly | **Custom** (~$15–25/user + platform fee) |
| **Target** | Solo devs; the WhatsApp-replacement hook | Startups, small/mid teams | Security-conscious & regulated orgs |
| **Anonymous drops (Tier 1)** | ✅ Unlimited | ✅ Unlimited | ✅ Unlimited |
| **Members** | 1 | Up to ~50 | Unlimited |
| **Projects** | 1 | Unlimited | Unlimited |
| **Persistent shared envs** | ❌ | ✅ | ✅ |
| **Audit log retention** | 7 days | 90 days | 1 yr+ / configurable |
| **Manual revoke + rotate** | ✅ | ✅ | ✅ |
| **RBAC** | — | owner / member / viewer | + custom roles |
| **SSO / SAML / SCIM** | ❌ | ❌ | ✅ |
| **CLI + CI/CD plugin** | ✅ basic | ✅ full | ✅ full |
| **Self-hosting** | — | — | ✅ |
| **Support** | Community | Email | Dedicated + 99.95% SLA |
| **Data residency (region pin)** | — | — | ✅ |

---

## 2. Rationale — why each call

### 2.1 Free is generous on Tier 1, hard-walled at Tier 2
The anonymous self-destructing drop is the **viral hook** — it must be unlimited and
frictionless so it spreads developer-to-developer. The paywall lands at the moment a team
wants **persistence + audit + multiple people** — the natural "I'd pay for this" line.

### 2.2 Per-seat, not per-secret / per-API-call
- Usage metering penalizes the behavior we want (more sharing) — self-defeating.
- Seats align price with the value (team collaboration) and are **predictable** for buyers.
- It matches buyer expectations set by Doppler / 1Password / Infisical.

### 2.3 $8/seat anchors below incumbents (~$18 Doppler/Infisical)
As the new entrant whose wedge is **simplicity**, undercutting while the product matures is
the right play. Raise later once the CLI/CI moat is real and switching cost is higher.

### 2.4 Enterprise gates the three things that close big deals
**SSO/SCIM**, **self-hosting**, and **data residency** are non-negotiables for regulated
buyers — and have near-zero marginal cost for us:
- Data residency falls out of the **region-pinned architecture** (SDD §6) almost for free.
- Self-hosting is a packaging exercise, not new architecture (the MVP *is* the prod arch).

### 2.5 Audit retention as a clean tier lever
Append-only OLAP storage (SDD §5.3) is cheap for us and highly valued by compliance teams.
It differentiates tiers **without crippling** the core product — a non-punitive lever.

---

## 3. Billing mechanics

- **Processor:** Stripe.
- **Default term:** annual (~20% cheaper than monthly) to pull cash forward and reduce churn; monthly option available.
- **Trial:** 14-day Team trial, **no credit card**, to remove friction.
- **Upgrade trigger:** in-product, at the point of pain — the moment a user clicks
  *"invite a teammate"* or *"save this env"*, prompt the Free→Team upgrade.
- **Proration & seats:** add/remove seats mid-cycle with standard proration; annual true-up at renewal.

---

## 4. Unit economics (sanity check)

| | Per-seat assumption |
|---|---|
| Price (Team, annual) | ~$8 / user / mo |
| Marginal infra cost / active seat | cents (stateless compute + tiny Redis footprint) |
| Gross margin | **very high (SaaS-typical 85%+)** |

The cost driver is **active teams**, not raw traffic — Tier 1 volume can balloon without
materially moving COGS, because it's stateless + ephemeral + CDN-absorbed (SDD §12).

---

## 5. Honest caveat

Pricing is a **hypothesis until validated by real users.** Ship these numbers, watch where
teams actually convert, and tune.

- **Durable part:** the *structure* — Free Tier 1 → per-seat Team → Enterprise control plane.
- **Tunable part:** the dollar figures, seat caps, and retention windows.

Recommended: instrument conversion events (invite, save-env, hit-a-limit) from day one so
pricing decisions are data-driven, not guessed.

---

## 6. Open questions

- [ ] Final Team price: $8 vs $10/seat at launch?
- [ ] Seat cap on Team before forcing Enterprise — 50 the right number?
- [ ] Offer a cheaper "Pro" solo tier between Free and Team, or keep it clean at three tiers?
- [ ] Usage-based add-on for extreme audit retention, or keep it purely seat-based?
- [ ] Education / open-source / nonprofit discount program at launch?
