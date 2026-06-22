# EnvDrop — Product Requirements Document (PRD)

**Status:** Draft v1.0
**Author:** Abdullah (+ team)
**Last updated:** 2026-06-19
**Type:** PWA / Web App — zero-knowledge, self-destructing environment-variable sharing

---

## 0. TL;DR

Developers routinely share `.env` files over WhatsApp, Slack, and email so teammates
can test APIs/endpoints. This is insecure: secrets sit in plaintext forever, get
cloud-backed-up, indexed, and can never be revoked.

**EnvDrop** is a zero-knowledge, self-destructing env-sharing PWA. The sender pastes
an `.env`, gets a link, and shares *only the link*. The teammate opens it once and the
secret self-destructs. The server **never** sees the plaintext — encryption and
decryption happen entirely in the browser, with the decryption key living in the URL
fragment (which is never transmitted to any server).

---

## 1. Problem statement

Abdullah is a software engineer at an AI company. After building a backend system, he
often needs a teammate to test the APIs/endpoints. To do that, the teammate needs the
environment configuration (API keys, DB URLs, secrets). Today Abdullah shares the raw
`.env` file over WhatsApp or similar platforms.

### Why this is unsafe
1. **Persistence** — the message lives forever on both devices and in cloud backups.
2. **No access control** — anyone who sees the chat/screen gets the keys.
3. **No expiry or revocation** — once leaked, it cannot be pulled back.
4. **No audit** — Abdullah never knows if, when, or by whom it was opened.

Any acceptable solution must fix **all four**, not merely relocate the file to a nicer place.

---

## 2. Goals & non-goals

### Goals
- Let a developer share an env securely in **under 30 seconds**.
- Guarantee the **server never sees plaintext secrets** (zero-knowledge).
- Make secrets **expire**, be **view-limited**, and be **revocable**.
- Notify the sender when the secret is **opened**.
- Work seamlessly as an installable **PWA** on mobile + desktop.

### Non-goals (v1)
- Full secrets-management platform (env sync, runtime injection across all environments) — that's the long-term moat, not the MVP.
- Endpoint/device security — if a device is already compromised, we can't help.
- Replacing CI/CD secret stores (Vault, AWS Secrets Manager) for production workloads.

### Success metrics
- Time-to-share (paste → link) **< 30s** median.
- ≥ 80% of created drops are **opened before expiry** (signal that the flow works).
- Zero plaintext secrets recoverable from a full DB dump (verified internally).
- Tier-2 retention: teams that create ≥ 1 project return within 7 days.

---

## 3. Personas

- **Abdullah (Sender / Backend engineer):** wants to hand off env config fast, hates the "did you get it?" back-and-forth, security-aware.
- **Teammate (Receiver / QA / frontend dev):** just needs working env vars to test endpoints, low friction tolerance.
- **Team lead (Tier 2 admin):** wants visibility, audit logs, and the ability to revoke access when someone leaves.

---

## 4. Product tiers

Build **Tier 1** fully first; design the data model so **Tier 2** slots in without a rewrite.

| | **Tier 1 — Anonymous Drop** | **Tier 2 — Team Accounts** |
|---|---|---|
| **Auth** | None | Email / OAuth login |
| **Primary use** | One-off "send this env once" | Persistent shared envs per project |
| **Revocation** | Auto-expire / view-once | Manual revoke + rotate |
| **Audit** | "Opened" ping to sender | Full per-member access log |
| **Storage** | Redis (TTL'd blobs) | Redis + Postgres (accounts, projects, logs) |
| **Target** | Individual devs, quick handoffs | Teams, ongoing collaboration |

---

## 5. Security model (the core of the product)

The entire value proposition is: **the server can never read your secrets.** Everything
else is features built around that guarantee.

### 5.1 End-to-end flow

```
┌─────────────────────────── SENDER BROWSER ───────────────────────────┐
│ 1. paste .env text                                                    │
│ 2. K  = crypto.getRandomValues()        // 256-bit AES key            │
│ 3. iv = crypto.getRandomValues()        // 96-bit nonce               │
│ 4. ciphertext = AES-GCM(plaintext, K, iv)                             │
│ 5. (optional) wrap K with PBKDF2(passphrase) if user sets one         │
└───────────────┬───────────────────────────────────────────────────────┘
                │  POST { ciphertext, iv, ttl, maxViews }      ← K never sent
                ▼
┌─────────────────────────────── SERVER ────────────────────────────────┐
│ stores blob in Redis with TTL; returns { id }                          │
│ knows: ciphertext, expiry, view count.   knows NOT: K, plaintext       │
└───────────────┬───────────────────────────────────────────────────────┘
                │  link = https://envdrop.app/s/<id>#<K base64url>
                ▼  (the #fragment is client-only, never hits the wire)
┌────────────────────────── RECEIVER BROWSER ───────────────────────────┐
│ GET /api/s/<id> → ciphertext+iv                                        │
│ read K from location.hash → AES-GCM decrypt → render vars              │
│ then POST /api/s/<id>/burn → server deletes blob, fires "opened" hook  │
└────────────────────────────────────────────────────────────────────────┘
```

### 5.2 Design rationale
- **AES-GCM** — authenticated encryption; any tampering with the ciphertext is detected on decrypt.
- **Key in URL fragment (`#`)** — browsers never send the fragment in HTTP requests, so servers, proxies, and logs only ever see opaque ciphertext. This is what makes it genuinely zero-knowledge.
- **Optional passphrase** — defends the one weak link (link interception on WhatsApp). The passphrase should be shared on a *different* channel (phone call, Signal).
- **TTL in Redis** — expiry is enforced by the datastore itself, not by app logic that could be forgotten or bypassed.

### 5.3 Threat model

| Threat | Mitigated? | How |
|---|---|---|
| DB / server breach | ✅ | Only ciphertext stored; key never sent |
| Network sniffing | ✅ | TLS + key in URL fragment |
| Replay / re-read | ✅ | View-once burn + TTL |
| Whoever obtains the WhatsApp link | ⚠️ Partial | Add passphrase via a separate channel |
| Compromised sender/receiver device | ❌ Out of scope | Endpoint security is the user's responsibility |
| Malicious / XSS'd frontend | ⚠️ Partial | Strict CSP, SRI, no third-party scripts on crypto pages |

> **Honesty note for README:** the gaps above (device compromise, trusting the served
> JS) are inherent to *every* E2E web app. We state them explicitly rather than overclaim.

---

## 6. Data model

```
# Tier 1 — Redis (key = secret:<id>)
secret
  ciphertext      bytes
  iv              bytes
  max_views       int        (default 1)
  views           int
  expires_at      unix ts    (Redis TTL set to match)
  notify_token    string?    (opaque; lets sender poll "was it opened?")
  has_passphrase  bool

# Tier 2 — Postgres
user(id, email, created_at, ...)
project(id, owner_id, name, created_at)
membership(project_id, user_id, role)          # role: owner | member | viewer
audit_log(id, secret_id, actor, action, ip_hash, ts)
```

**Invariant:** no plaintext, no decryption key, and no individual env values ever touch
persistent storage. Only ciphertext + metadata.

---

## 7. API surface

```
POST   /api/secrets            { ciphertext, iv, ttl, maxViews, hasPassphrase }
                               → { id, notifyToken }

GET    /api/secrets/:id        → { ciphertext, iv, viewsLeft }
                               | 404 if burned / expired

POST   /api/secrets/:id/burn   → 204   (idempotent; decrements view, deletes at 0)

GET    /api/secrets/:id/status?notifyToken=…
                               → { opened: bool, openedAt }     (sender polling)

DELETE /api/secrets/:id        → 204   (manual revoke)
```

Design principle: the server is essentially a TTL'd blob store with a view counter. All
cryptography lives in the client.

---

## 8. User flows

### 8.1 Sender (Abdullah)
1. Open PWA → paste env text or drag-drop the `.env` file.
2. App parses and shows a **checklist of detected keys**, so he can untick anything he didn't mean to include (e.g. a prod secret). *(Safety touch.)*
3. Choose options:
   - **Expiry:** 1h / 24h / 7d
   - **Max views:** 1 / 5 / unlimited
   - **Passphrase:** on / off
4. Receive link → **Copy link** or **Share** (native share sheet on mobile).
5. Optional **status chip** flips to "✅ Opened 2 min ago."

### 8.2 Receiver (teammate)
1. Tap link → if passphrase required, prompt for it.
2. View vars rendered as a table with:
   - **Copy all**
   - **Download .env**
   - **CLI snippet** (e.g. `export $(cat .env | xargs)`)
3. Banner: "This link has now been destroyed."

---

## 9. Tech stack

### Frontend / PWA
- **Framework:** Next.js (App Router) or SvelteKit
- **Crypto:** Web Crypto API (native — no third-party crypto library needed)
- **PWA:** service worker via `next-pwa` / Workbox (installable + offline shell)
- **Notifications:** Web Push for the "opened" alert

### Backend
- Thin, stateless service: Node (Hono / Fastify) or Go

### Storage
- **Redis** for TTL'd ciphertext blobs (Upstash for serverless + free tier)
- **Postgres** added only at Tier 2 (accounts, projects, audit logs)

### Hosting
- PWA → Vercel / Netlify
- API + Redis → Fly.io / Railway
- All have free tiers — runs at **$0** to start.

### Security hardening (must-haves)
- Strict **HTTPS / HSTS**
- **CSP** blocking inline scripts (protects the crypto page from XSS)
- **Subresource Integrity (SRI)** on served assets
- **Rate limiting** on `POST /api/secrets`
- **Payload size cap** (~64 KB)
- No third-party scripts on any page that touches plaintext or keys

---

## 10. Build roadmap

| Phase | Scope | Outcome |
|---|---|---|
| **Week 1 — MVP** | Anonymous drop, AES-GCM in browser, Redis TTL, view-once, copy/download | Replaces WhatsApp on day one |
| **Week 2 — Polish** | Passphrase, "opened" notification, env key-picker, PWA install + offline shell, native share | Feels like a real product |
| **Week 3+ — Tier 2** | Accounts, projects, persistent shared envs, audit log, manual revoke | Team collaboration |
| **Later — The moat** | **CLI** — `envdrop push` / `envdrop pull <id>` so secrets never touch a chat app *or* a browser | Becomes a real dev tool (how Doppler/Infisical win) |

---

## 11. Open questions / decisions to make

- [ ] Framework: Next.js vs SvelteKit?
- [ ] Hosting combo: Vercel + Upstash, or all-in on Fly.io?
- [ ] Default expiry and max-views values?
- [ ] Tier 2 auth: email magic-link, Google OAuth, GitHub OAuth, or all three?
- [ ] Do we offer self-hosting from day one (appeals to security-conscious teams)?
- [ ] Branding / final product name (working name: **EnvDrop**).

---

## 12. Competitive landscape (don't reinvent blindly)

Existing tools solve the *team workflow* angle well: **Doppler**, **Infisical**
(open-source, self-hostable), **1Password**, **Dotenv Vault**. They sync env vars and
inject them at runtime (`doppler run -- npm start`) so teammates never touch a raw file.

**EnvDrop's wedge:** dead-simple, zero-account, zero-knowledge **one-time sharing** — the
gap those heavier tools don't focus on. The CLI (Phase 4) is where it grows from a
single-purpose tool into a real workflow.

---

## 13. Appendix — glossary

- **Zero-knowledge:** the server has no ability to read user secrets; it only stores ciphertext.
- **AES-GCM:** authenticated symmetric encryption providing confidentiality + integrity.
- **URL fragment:** the part of a URL after `#`; never sent to the server by browsers.
- **TTL:** time-to-live; automatic expiry of stored data.
- **Burn:** destroying a secret after it has been viewed (view-once semantics).
```
