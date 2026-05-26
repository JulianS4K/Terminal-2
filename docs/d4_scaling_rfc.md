# D4 / Exos — Scaling RFC (next-sprint planning)

**Status:** planning · **Owner:** D4 (authors) + A1 (applies) + operator (infra) · **Created** by D4 this session.
**Companion:** `KANBAN.md` D4-OPS-29…36 · load evidence in `KANBAN.md` D4-OPS-11.

## Context

D4/Exos is pre-launch (free-first). Correctness under load is **already proven**: the
`D4-OPS-11` branch harness minted 1000 tickets and ran an 8-lane concurrent check-in +
a 6-lane stampede on 50 tickets with **0 double-admits** — the atomic tier/event CAS
and the check-in guard hold at µs/op **in-DB**. Recent throughput wins (PR #375):
incremental door count (no `count(*)` per scan) and free-claim idempotency.

So the scaling risk is **not in-DB correctness**. It's at three layers the harness
didn't cover: (1) **concurrency at the PostgREST/connection layer** during an onsale
spike, (2) the **single global counter** as a serialization point, and (3) **shared
infrastructure** with the broker lane. This RFC sequences fixes across sprints.

---

## Sprint 1 — cheap, self-contained throughput wins (D4 authors · A1 applies)

These need no infra change and remove known traps before they bite.

- **D4-OPS-29 — Server-side report aggregation (M).** `OrganizerEventReport` + the
  dashboard fetch tickets and aggregate **in the browser** (per-promoter, per-tier,
  totals). Fine at hundreds, ugly at tens-of-thousands (transfer + memory blowup).
  Add `exos_event_sales_summary(p_event_id)` SECDEF RPC returning totals + per-tier +
  per-promoter rollups; paginate `listOrgEvents` (server-side, cursor on `date`).
- **D4-OPS-30 — Mail drainer throughput (S, gated on keys).** The `*/2` single-batch
  `exos-mail-drain` won't keep up with an onsale burst of `ticket-issued` rows. Raise
  `exos_mail_claim_batch` limit, make the drain Resend-rate-limit-aware (chunk + small
  concurrency), and consider `*/1`. Tune once `RESEND_API_KEY` is set (D4-OPS-8/9).
- **D4-OPS-31 — Per-event metrics rollup (S→M).** Back "tickets sold" / "inside venue"
  with a small matview or maintained counter so dashboards + the door don't scan
  `exos_tickets`/`exos_event_checkins`. Supports D4-OPS-33.

## Sprint 2 — onsale concurrency: the actual wall (D4 design + A1 apply)

- **D4-OPS-32 — High-demand onsale admission control (L).** Thousands of simultaneous
  buyers serialize on the hot tier row; the lock queue + PostgREST 8s ceiling are the
  failure mode (slow/timing-out onsale, not bad data). Add a **virtual waiting-room**:
  issue a queue token and admit N claims/sec. Options:
  - (a) `pgmq` (Postgres message queue ext) + an admit worker — recommended, in-DB.
  - (b) app-level `exos_onsale_queue` table + admit cron (cron-gated).
  - (c) edge-fn token-bucket gate in front of `exos_claim_free_tickets`/checkout.
  Reuse for the paid (Stripe) path so checkout inherits the same gate.
- **D4-OPS-33 — Decouple the global house-cap counter (M).** Every claim hot-writes the
  single `exos_events.tickets_sold` row → all claims for an event serialize on it
  regardless of tier (worse than the per-tier lock). Stop the per-claim global write:
  - (a) **recommended:** derive `tickets_sold = Σ tier.sold` for display (view/matview)
    and enforce the house cap against that sum; keep the per-tier CAS as the hard limit.
  - (b) sharded counter (N sub-rows, sum on read) if a stored value is required.
  Removes the worst single-row contention; pairs with D4-OPS-31 for display.
- **D4-OPS-34 — Connection-pool + claim-txn posture (S).** Confirm the claim path is a
  minimal txn (it is), add `SET statement_timeout` on the claim RPC, verify
  transaction-mode pooling, and **load-test at the PostgREST/RLS layer** (the part
  D4-OPS-11 didn't cover) — concurrent real sessions, not in-DB loops.

## Sprint 3 — infrastructure isolation (operator-led)

- **D4-OPS-35 — Dedicated Supabase project for D4 (L, operator).** D4 shares the DB with
  the broker lane's 8M-row `listings_snapshots` firehose + ~75 crons + service_role
  scans — documented to tip user-facing RPCs past 8s. No code change fixes noisy-neighbor
  contention; D4 wants its **own project**. Cutover plan: provision project → replay
  `exos_*` migrations → repoint `d4_bridge` env + edge-fn secrets → verify → flip. Big;
  needs an operator decision + a migration/data-cutover window.
- **D4-OPS-36 — Per-surface Render service (S, planned).** Un-mount `/bridge` from the
  unified `vibepass-storefront-test` app at the beta DNS split so a D4 onsale doesn't
  compete with terminal traffic on one instance. Already in the testing-unified plan.

## Cross-cutting (track, act if it bites)

- **Auth SMTP at scale (D4-OPS-9, operator)** — custom SMTP + raised limits; prefer
  magic-link/OAuth + a pre-event "claim your ticket" nudge to spread sign-ins off the door.
- **Realtime fan-out at large gates** — `postgres_changes` on `exos_event_checkins`
  evaluates RLS per subscriber per change; at a many-lane gate this could lag. Mitigated
  by the offline registry + the PR #375 incremental count; if it bites, move the
  cross-lane lock to a lighter broadcast or short poll.
- **Idempotency hardening** — the free-claim `order_ref` dedup is select-then-insert,
  not concurrency-proof. Add an advisory lock keyed on `(uid, order_ref)` (or a claim
  ledger row with a unique constraint) for the true-concurrent double-submit case.
- **Bundle/CDN** — serve `static/bridge` via CDN + code-split the 360 KB `qr` chunk.

## Open decisions for operator

1. **Dedicated D4 Supabase project** — yes, and when? (Gates D4-OPS-35; biggest lever.)
2. **Peak onsale concurrency target** — size the waiting-room (1k? 10k simultaneous?).
3. **Paid (Stripe) timeline** — checkout should reuse the D4-OPS-32 queue + D4-OPS-33
   counter work, so sequence them together if payments are near.

## Recommended order

Sprint 1 (cheap wins, no infra) → Sprint 2 (onsale concurrency = the real wall) →
Sprint 3 (infra isolation, operator-led). Gate any high-demand paid onsale on
D4-OPS-32 + D4-OPS-34 + a physical rehearsal (D4-OPS-11).
