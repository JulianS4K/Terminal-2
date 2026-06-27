# Production-readiness launch blockers

> **Purpose:** the operator-action punch-list for taking Terminal-2 from "strong
> beta" to a real-money / multi-instance launch. These are the items that need
> **operator authority** (DB/infra config, secrets, provisioning, legal, or an
> operator-gated DB migration) — not more application code. Engineering-side
> refactors (decomposition, BR-CODE-2) are tracked separately in
> `KANBAN.md` (BR-CODE-*).
>
> **Last reviewed:** 2026-06-26 (B1, from the code-production-readiness audit).
> Living checklist — update the **Status** column as items land; don't delete
> rows (strike them through when done).

## How to read this

Three tiers. **P0** must be true before charging a real card or storing real PII
at scale. **P1** is resilience you want before an SLA or >1 instance. **P2** is
deferred/product. Each row: who owns the lever, the concrete next action, rough
effort (**S** <1d · **M** 1–3d · **L** week+), and a link to the tracking row if
one exists.

---

## P0 — hard blockers for a real-money launch

| # | Blocker | Why it blocks | Owner | Concrete action | Effort |
|---|---|---|---|---|---|
| 1 | **Legal copy is placeholder** | about/privacy/terms ship "consult counsel before launch" text; can't take a real purchase or store PII without it. | Operator / counsel | Provide counsel-reviewed Privacy + Terms; D1 swaps into the existing shells (no code beyond content). | M (mostly external) |
| 2 | **No Supabase connection pooling** *(partially addressed)* | App uses one global service-role client. A traffic spike or a 2–5 min Supabase blip can pile up requests → dyno OOM → outage. **Code side shipped:** `core/db.make_supabase_client` now bounds the PostgREST/storage/function timeout (env `SUPABASE_TIMEOUT_SECONDS`, default 30s) so a blip fails fast per-request instead of piling up. **Still operator:** enabling Supabase's Transaction/Session pooler + load-verify. | A1 / Operator | ~~Bound per-request timeout~~ ✅ done. Remaining: enable the **Transaction/Session pooler** + verify under load. | S–M |
| 3 | ~~**`seatgeek_seller_listings` NULL-key upsert dup**~~ ✅ **FIXED + APPLIED** | `ON CONFLICT(sg_listing_id,content_hash)` never matched NULL `sg_listing_id` (Postgres `NULL≠NULL`) → unbounded duplicate rows. | A1 / Operator | **Done (2026-06-26):** mig `20260626120000` applied to prod — dedup now `UNIQUE (sg_event_id, content_hash)` (non-null); upsert repointed in `seatgeek_client.py` + regression test. Verified: 2,859 rows intact, 0 dups. | ✅ done |

## P1 — resilience (before an SLA or running >1 instance)

| # | Item | Why | Owner | Concrete action | Effort |
|---|---|---|---|---|---|
| 4 | ~~**No circuit breaker / retry on the DB client**~~ ✅ **shipped** | A Supabase hiccup cascaded instead of failing fast + shedding load. | B1 / A1 | **Done:** `core/resilience.py` (CircuitBreaker + retry/backoff + `safe_read`); shared `_db_breaker` surfaced on `/healthz` (`db_circuit`) and fed by the health probe; the customer-facing first-paint reads now go through `safe_sb_read` (breaker + retry + conservative-empty fallback): **all customer-facing storefront read sites now run through the shared breaker.** The passive homepage strips degrade to empty-on-blip — `store_home` (LEM matview + events query), `store_concierge`, `store_movers` cold-compute, `store_events/near` (hybrid merge + supabase pull). `store_search`, an **active** query, instead surfaces an explicit **502** ("search temporarily unavailable") on failure rather than a misleading empty result, while still feeding the breaker for load-shedding (via `sb_read_or_raise`/`resilient_call`). Tunable via `DB_CIRCUIT_FAIL_THRESHOLD`/`DB_CIRCUIT_RESET_SECONDS`. **Code side complete.** | M |
| 5 | **In-process rate limiter** *(code shipped; needs Redis provisioned)* | At >1 dyno the in-process limit is per-instance (bypassable). | Operator (provision) + B1 (code) | **Code side done:** `core/ratelimit.make_rate_limiter` selects a Redis fixed-window backend when `REDIS_URL` is set + reachable, else falls back to in-process (transparent `check()`). Session secret is already env-pinnable via `SESSION_SIGNING_SECRET` (`core/auth.py`). **Remaining (operator):** provision Redis + set `REDIS_URL` (+ pin `SESSION_SIGNING_SECRET`) **before scaling past 1 instance**. | M |
| 6 | **Uptime monitoring is degraded** | The GitHub-Actions cron is self-admittedly throttled to ~hourly; a real outage can stay silent 30+ min. | Operator | Stand up an external monitor (UptimeRobot / Better Uptime / Datadog) hitting `/healthz`; wire alerts to a channel you watch. | S |
| 7 | **No tested migration rollback** *(runbook shipped)* | 631 migrations, no reverse/PITR path exercised; a bad apply has no fast recovery. | A1 / Operator | **Done (doc):** `MIGRATION_CONVENTIONS.md §11.3` — a 3-path rollback runbook (forward reverse-migration · restore-one-object · Supabase PITR) with a worked reverse of mig `20260626120000`. **Remaining (operator):** dry-run a reverse on a Supabase branch to exercise it live. | M |
| 8 | **Error tracking wired but OFF** | Sentry was added this session (`core/observability.py`) but is inert until a DSN is set. | Operator | Create a Sentry project, set `SENTRY_DSN` (+ optional `SENTRY_TRACES_SAMPLE_RATE`) in Render env. `/healthz` will then report `error_tracking: sentry`. | S |

## P2 — product decisions / deferred

| # | Item | Notes | Owner |
|---|---|---|---|
| 9 | **Holiday-window asymmetry** | `core/movers.py` builds holiday options for `-2…+1` days (matches its comment). Whether to extend to `+2` is a product call, not a bug. | D0 / Operator — see **KANBAN `BUGHUNT-2`** |
| 10 | **Real purchase path (Stripe)** | Dormant by design; `/api/store/reserve` is a mock that never calls `/v9/orders`. This is the gate to "real money" (Sprint 2). | Operator / D4 |

---

## Already addressed (context — not blockers)

So the list above is read against an accurate baseline, these were closed in the
2026-06-25/26 production-readiness pass (all on PR #685):

- **Test coverage 51.9% → 100%** (line **+ branch**) with a CI `--cov-fail-under` ratchet. *(was the #1 "can't see regressions" gap)*
- **6 correctness bugs fixed** (incl. a money-path one: `/reserve` admitting sold-out inventory). 2 more filed (rows 3 + 9 above).
- **Observability** — structured stdout logging replacing scattered `print()`, + opt-in Sentry (row 8 turns it on).
- **Decomposition in progress** (`server.py` 6,705 → ~5,636 LOC; the keystone helper untangled) — velocity/maintainability, **not** a launch blocker. Tracked in `KANBAN.md` BR-CODE-1.

## Verdict

The app is a **solid beta**: secure (the read-only RULE-2 lockdown is genuinely
strong), well-tested now, and observable once the DSN is set. It is **not yet
ready to charge real money or run multiple instances** — that gate is **P0 #1–3**
plus **P1 #5**, all of which need operator action (legal, Supabase config, a DB
migration, Redis). None require a large engineering effort; they require
decisions and provisioning only you can do.
