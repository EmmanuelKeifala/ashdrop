# EnvDrop — System Design Document (SDD)

**Status:** Draft v1.0
**Author:** Principal Architect
**Last updated:** 2026-06-19
**Companion doc:** `envdrop-prd.md`
**Audience:** Engineering, SRE, Security review board

> Design philosophy: the system's single hardest constraint is **zero-knowledge** —
> the server must never be *able* to read a secret. Every architectural decision below
> is subordinate to that invariant. The second constraint is that secrets are
> **small, write-once, read-once, and short-lived**, which is what lets us scale this
> cheaply and horizontally.

---

## 1. Scope & requirements

### 1.1 Functional
- Create an encrypted secret (env blob) → return a shareable link.
- Retrieve + decrypt a secret client-side; enforce view-once / view-limited semantics.
- Auto-expire by TTL; manual revoke.
- Notify the sender when a secret is opened.
- Tier 2: accounts, projects, persistent shared envs, audit logs, RBAC.

### 1.2 Non-functional (the ones that drive the design)

| Attribute | Target |
|---|---|
| **Availability** | 99.95% for read/create (control plane); 99.9% notifications |
| **Latency** | p99 create < 150 ms, p99 read < 100 ms (regional) |
| **Durability** | Ciphertext must survive until TTL; **0 plaintext** ever persisted |
| **Confidentiality** | Server cannot decrypt; verified by design + audit |
| **Scale (design target)** | 100M drops/day, 10:1 read:write peaks, 50k RPS peak |
| **Payload size** | Hard cap 64 KB ciphertext (env files are tiny) |
| **Global** | Multi-region, active-active, < 100 ms to nearest edge |

### 1.3 Explicit non-goals
- Large-file transfer (this is for KB-scale secrets, not blobs/artifacts).
- Long-term secret storage (max TTL bounded, e.g. 30 days).
- Server-side search over secret contents (impossible by design — it's all ciphertext).

---

## 2. Back-of-the-envelope capacity planning

Design target: **100M drops/day.**

```
Writes:   100M / 86,400s        ≈ 1,160 writes/s average
Peak (5×):                       ≈ 5,800 writes/s
Reads:    10× writes            ≈ 11,600 reads/s avg, ~58k/s peak

Payload:  avg 4 KB ciphertext, p99 64 KB
Hot data: a drop lives ~24h avg before burn/expiry
          100M/day × 4 KB × ~1 day resident ≈ 400 GB hot working set
          → fits comfortably in a sharded in-memory tier (Redis cluster)

Bandwidth (peak read): 58k/s × 4 KB ≈ 230 MB/s egress at peak
Metadata/audit (Tier 2): append-only, ~100M rows/day → time-partitioned Postgres / OLAP sink
```

**Takeaways**
- The working set is *small and ephemeral* → an in-memory, TTL-native store (Redis) is the
  primary datastore, not a cache in front of something else.
- Writes and reads are both cheap, uniform, and embarrassingly shardable by `secret_id`.
- The expensive/stateful parts are **Tier 2** (accounts, audit) — isolate them so Tier 1
  stays a stateless, infinitely-scalable lane.

---

## 3. High-level architecture

```
                          ┌────────────────────────────────────────────┐
                          │            Global Anycast / GeoDNS          │
                          │     (Cloudflare / Route53 latency-based)    │
                          └───────────────────┬────────────────────────┘
                                              │
              ┌───────────────────────────────┼───────────────────────────────┐
              ▼                                ▼                                ▼
      ┌───────────────┐                ┌───────────────┐                ┌───────────────┐
      │  REGION us-east│               │  REGION eu-west│              │ REGION ap-sout│
      │  (active)      │               │  (active)      │              │  (active)     │
      └───────┬────────┘               └───────┬────────┘              └───────┬───────┘
              │  (each region is identical; secrets are region-pinned — see §6)   │
              ▼                                                                    ▼
 ┌──────────────────────────────────────── REGION INTERNALS ───────────────────────────────┐
 │                                                                                          │
 │  ┌────────────┐   ┌──────────────────┐   ┌────────────────────────┐                      │
 │  │ Edge / CDN │──▶│  API Gateway     │──▶│  Secrets Service (stateless, autoscaled)     │
 │  │ static PWA │   │  WAF + rate limit │   │  - POST /secrets  - GET /secrets/:id         │
 │  │ assets,SRI │   │  + auth (Tier 2)  │   │  - burn / revoke / status                    │
 │  └────────────┘   └──────────────────┘   └───────┬─────────────────────┬────────────────┘
 │                                                   │                     │
 │                                  ┌────────────────▼─────────┐   ┌───────▼──────────────┐
 │                                  │  Redis Cluster (sharded) │   │  Event Bus (Kafka/    │
 │                                  │  ciphertext + meta + TTL │   │  SQS) → notify, audit │
 │                                  │  view counter (atomic)   │   └───────┬──────────────┘
 │                                  └──────────────────────────┘           │
 │                                                                ┌─────────▼──────────┐
 │   ┌──────────────────── TIER 2 ONLY ───────────────────────┐  │ Notification Svc   │
 │   │ Auth Svc (OIDC) · Project Svc · Postgres (accounts,    │  │ (Web Push / email) │
 │   │ projects, RBAC) · Audit sink → ClickHouse/BigQuery     │  └────────────────────┘
 │   └─────────────────────────────────────────────────────────┘                       │
 └──────────────────────────────────────────────────────────────────────────────────────┘
```

### Component responsibilities

| Component | Responsibility | State |
|---|---|---|
| **Edge/CDN** | Serve immutable, integrity-checked PWA assets globally | Stateless |
| **API Gateway** | TLS termination, WAF, rate limiting, authN (Tier 2), routing | Stateless |
| **Secrets Service** | Create/read/burn/revoke; enforce view & TTL semantics | **Stateless** |
| **Redis Cluster** | Primary store for ciphertext + metadata; atomic view counter; native TTL | Stateful (ephemeral) |
| **Event Bus** | Decouple "opened/created" events from request path | Durable queue |
| **Notification Svc** | Deliver "opened" pings (Web Push, email) | Stateless workers |
| **Auth/Project Svc** | Tier 2 identity, projects, RBAC | Stateless |
| **Postgres** | Tier 2 accounts, projects, memberships | Stateful (durable) |
| **Audit sink** | Append-only access logs at scale | OLAP (ClickHouse/BigQuery) |

**Key separation:** Tier 1 (anonymous drops) has **no dependency on Postgres or auth**.
It is a self-contained, stateless lane that can scale to the moon independently. Tier 2
adds the durable/relational machinery without slowing Tier 1 down.

---

## 4. The zero-knowledge crypto design (the heart)

### 4.1 Client-side (browser, Web Crypto API)
```
On CREATE:
  plaintext      = env text (UTF-8)
  K              = crypto.getRandomValues(32 bytes)         // AES-256 key
  iv             = crypto.getRandomValues(12 bytes)         // GCM nonce
  ciphertext     = AES-GCM-encrypt(plaintext, K, iv)        // authenticated
  IF passphrase:
      salt       = random(16)
      wrapKey    = PBKDF2(passphrase, salt, 600k iters, SHA-256)   // OWASP-tuned
      K_wrapped  = AES-GCM-encrypt(K, wrapKey, iv2)
      send { ciphertext, iv, K_wrapped, iv2, salt, hasPassphrase:true }
  ELSE:
      send { ciphertext, iv }
      K goes ONLY into the URL fragment:  /s/<id>#<base64url(K)>

On OPEN:
  fetch { ciphertext, iv, ... }
  K = passphrase ? unwrap(K_wrapped, PBKDF2(passphrase, salt)) : fromFragment()
  plaintext = AES-GCM-decrypt(ciphertext, K, iv)   // throws if tampered → reject
  POST /burn
```

### 4.2 Why this is provably zero-knowledge
- The server receives **only** ciphertext + IV (+ optionally a *passphrase-wrapped* key it
  also can't unwrap). It never receives `K` in the clear.
- The URL fragment (`#…`) is, by HTTP spec, never transmitted to the server. CDNs, LBs,
  proxies, and access logs never see it.
- A full database/memory dump yields nothing but AEAD ciphertext.

### 4.3 Defense-in-depth around the served JavaScript
The one residual trust is "is the JS the browser runs honest?" Mitigations:
- Strict **CSP** (`script-src 'self'`, no `unsafe-inline`), **SRI** on all assets.
- Crypto pages served from an **immutable, versioned** path; assets are content-hashed.
- No third-party scripts (analytics, tag managers) on any page touching plaintext/keys.
- Optional: publish build provenance (reproducible builds / Sigstore) for the truly paranoid.

---

## 5. Data model & storage strategy

### 5.1 Tier 1 — Redis (primary store, not a cache)
```
KEY  secret:{id}            (id = 128-bit random, base62; unguessable)
HASH
  ciphertext      bytes
  iv              bytes
  k_wrapped       bytes?      # only if passphrase
  salt, iv2       bytes?
  max_views       int
  views           int         # mutated via atomic Lua / HINCRBY
  notify_token    string?     # opaque; sender-only polling handle
  has_passphrase  bool
  created_region  string
TTL  = min(user_choice, MAX_TTL=30d)   # Redis-native expiry
```
- **Burn is atomic:** a Lua script decrements `views` and `DEL`s the key at 0 in one round
  trip — no race between two simultaneous opens.
- **Sharding:** Redis Cluster hashes on `{id}` → uniform distribution, linear scale-out.
- **Durability:** AOF (`appendfsync everysec`) + replicas per shard. We tolerate a tiny
  window of loss on hard crash — acceptable because secrets are ephemeral by nature and the
  sender can re-drop. We deliberately **do not** trade latency for stronger durability here.

### 5.2 Tier 2 — Postgres (durable, relational)
```
user(id, email, oauth_sub, created_at)
project(id, owner_id, name, created_at)
membership(project_id, user_id, role)          # owner | member | viewer
shared_env(id, project_id, secret_id, label, rotated_at)
```
Postgres holds **references and ACLs only** — never plaintext. A "persistent shared env"
is still an encrypted blob; rotation = new blob + pointer swap.

### 5.3 Audit at scale
100M events/day is wrong for row-by-row Postgres inserts. Audit events flow through the
**event bus → ClickHouse/BigQuery** (columnar, append-only, cheap, queryable). IPs are
stored **hashed** (privacy + still useful for anomaly detection).

---

## 6. Multi-region & consistency

**Secrets are region-pinned, not globally replicated.** This is a deliberate simplification
that the access pattern permits:
- A drop is created in one region; its link embeds a region hint (`/s/<region>-<id>`).
- Reads route back to the owning region via GeoDNS + path routing.
- No cross-region replication of secrets → **no global consistency problem**, no
  conflicting view-counter updates, lower blast radius, and data-residency wins (an
  EU-created secret never leaves EU).
- Trade-off: if a region is hard-down, *its* in-flight secrets are unreachable until
  recovery. Acceptable: secrets are short-lived and re-creatable; we optimize for
  correctness of the view-once guarantee over availability of a single ephemeral item.

Tier 2 relational data uses a single primary region with read replicas (or a distributed
SQL engine like CockroachDB/Spanner if/when global write latency demands it).

---

## 7. Request lifecycles

### 7.1 Create (write path)
```
client → CDN(miss, API) → Gateway(rate-limit, size-cap 64KB, WAF)
       → Secrets Svc → Redis SET secret:{id} EX ttl
       → emit "created" event (async)
       → 201 { id, notifyToken, region }
```
p99 budget: gateway 20ms + service 10ms + Redis 5ms = comfortably < 150ms.

### 7.2 Open (read + burn)
```
client → Gateway → Secrets Svc → Redis GET secret:{id}
       → return ciphertext (NOT yet burned)
client decrypts locally
client → POST /burn → Lua{ HINCRBY views; if views>=max_views: DEL } (atomic)
       → emit "opened" event → Notification Svc pings sender
```
Burn-after-decrypt (not before) avoids destroying a secret the receiver couldn't actually
read (wrong passphrase, network drop mid-decrypt).

### 7.3 Notification (async, off the hot path)
Event bus → Notification workers → Web Push / email. Decoupled so a slow push provider
never adds latency to the user-facing request.

---

## 8. Scalability & performance

- **Stateless services** behind HPA/KEDA autoscaling on RPS + CPU. Scale-to-zero off-peak.
- **Redis Cluster** scales by adding shards; resharding is online. Working set is small
  (~400 GB) and bounded by TTL, so memory never grows unboundedly.
- **CDN** absorbs 100% of static PWA traffic; origin only serves API calls.
- **Backpressure:** gateway-level token-bucket rate limits per IP + per account; 429 with
  `Retry-After` rather than collapsing.
- **Hot-key safety:** IDs are random 128-bit → no natural hot partition; a maliciously
  hammered single ID is shielded by per-key rate limiting.

---

## 9. Security & abuse

| Surface | Control |
|---|---|
| Transport | TLS 1.3 everywhere, HSTS preload |
| App XSS | Strict CSP, SRI, no inline scripts on crypto pages |
| Enumeration | 128-bit random unguessable IDs; constant-time 404 for burned/expired |
| Brute-force passphrase | PBKDF2 600k iters + per-id attempt rate limiting + lockout |
| DoS / spam drops | Per-IP & per-account rate limits, size caps, WAF, proof-of-work/CAPTCHA on abuse signal |
| Malicious content | EnvDrop carries opaque ciphertext; abuse handled at link/report layer, not content scan (we *can't* scan — by design) |
| Secret leakage in logs | Structured logging with allow-list fields; ciphertext & fragments never logged |
| Insider threat | Zero-knowledge means even a rogue operator/DB dump yields no plaintext |

---

## 10. Observability & SLOs

- **Metrics (RED + USE):** create/read/burn rates, p50/p99 latency, error rate, Redis
  memory/evictions, queue depth, notification delivery rate.
- **SLOs:** 99.95% control-plane availability; p99 read < 100ms; error budget burn alerts.
- **Tracing:** OpenTelemetry across gateway → service → Redis → event bus.
- **Logging:** strictly redacted; never plaintext, key, fragment, or full ciphertext.
- **Crucial invariant alarm:** a synthetic canary asserts that **no plaintext is ever
  recoverable server-side** — a continuously-running test that dumps a sample blob and
  confirms it's undecryptable without the fragment.

---

## 11. Failure modes & resilience

| Failure | Behavior | Mitigation |
|---|---|---|
| Redis shard down | Reads/writes to that shard fail | Replica failover; secrets are re-creatable |
| Region down | That region's secrets unreachable | GeoDNS sheds to healthy regions for *new* drops |
| Event bus backlog | "Opened" pings delayed | Async by design; user-facing path unaffected |
| Notification provider outage | No push | Retry w/ backoff; degrade to in-app status poll |
| Gateway overload | 429 backpressure | Autoscale + per-client rate limits |
| Bad deploy | Crypto bug risk | Canary + immutable versioned crypto bundle + instant rollback |

**Design stance:** we favor **correctness of the zero-knowledge + view-once guarantees**
over the availability of any single ephemeral secret. Losing one re-creatable drop is fine;
leaking one plaintext is not.

---

## 12. Cost model (order of magnitude)

- **Tier 1 dominates volume but is cheap:** stateless compute (scales with RPS) + a
  modest Redis cluster (~400 GB hot, sharded) + CDN egress. The 64 KB cap and short TTL
  keep memory and bandwidth bounded.
- **Tier 2** adds Postgres + OLAP audit — costs scale with *active teams*, not raw traffic.
- Start serverless (Upstash Redis + Vercel/Fly) at ~$0; the architecture above is the
  *destination* at 100M/day, reachable incrementally without redesign.

---

## 13. Rollout / evolution path

```
Phase 0  Single-region MVP: 1 stateless service + 1 Redis + CDN'd PWA.        (Week 1)
Phase 1  Add event bus + notifications; harden CSP/SRI/rate-limits.           (Week 2)
Phase 2  Tier 2: auth, projects, Postgres, audit sink.                        (Week 3+)
Phase 3  Multi-region active-active + region-pinned secrets + GeoDNS.         (scale)
Phase 4  CLI (`envdrop push/pull`) + CI plugin → the workflow moat.           (product)
```
Every phase is additive; nothing in Phase 0 is thrown away. The MVP *is* the production
architecture in miniature.

---

## 14. Key architectural decisions (ADR summary)

1. **Redis as primary store, not cache** — workload is small, ephemeral, TTL-native. Right tool.
2. **Key in URL fragment** — the mechanism that makes zero-knowledge real, not aspirational.
3. **Region-pinned secrets** — sidesteps global consistency; gives data residency for free.
4. **Tier 1 fully decoupled from Tier 2** — the high-volume lane has zero relational/auth deps.
5. **Async notifications & audit via event bus** — keep the hot path lean.
6. **Atomic Lua burn** — the only correct way to enforce view-once under concurrency.
7. **Favor guarantee-correctness over single-item availability** — secrets are re-creatable; trust is not.
```
