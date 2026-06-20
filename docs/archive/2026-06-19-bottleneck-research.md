# Bottleneck research — Terminal-2 (2026-06-19)

> **Non-canonical, dated archive artifact** (per `CLAUDE.md §6` — ephemeral research lives in `docs/archive/`, not a new root doc). Operator-directed cross-axis bottleneck sweep. The actionable program lives in `KANBAN.md §🟢 OPEN WORK → 🔴 URGENT`; this file is the evidence narrative behind it.

## TL;DR

**It is not feature bloat.** The tree has **1** TODO/FIXME in total and effectively no dead code. The binding constraints are two:

1. **Data-plane physics** — upstream rate limits + snapshot storage growth. Caps the *product* (data freshness & correctness).
2. **Architecture debt** — a monolithic `app.py` + copy-pasted clients + thin tests. Caps *engineering velocity*.

Governance overhead (~5,200 lines across 9 canonical docs, per-bot sweeps, multi-lane sign-offs) is real but third-order and proportionate to the safety guarantees; it is not what is blocking shipping.

## Method

Three parallel read-only investigations (code/architecture, data/DB, infra/cron/process) plus direct repo measurement. Evidence is cited to doc lines / migration filenames / KANBAN IDs.

---

## Tier 1 — hard ceilings on the product (data-plane physics)

### 1. SeatGeek broker token (→ `A1-OPS-3`)
One token, ~5 req/10s, **shared with a separate external prod program whose draw is invisible and unthrottlable**. Measured: **63–77% HTTP 429**, **1,235 starved events**, **10 of 30 sampled MLB games 2–3 days stale** (sg_event_ids enumerated in `A1-OPS-3`). The owned-focus redesign (mig `20260608030000`) cut load 3,600→1,800 listings/day as mitigation; the non-owned poller is now OFF with a ~1,700-event backlog parked (`A1-OPS-21`). This is a physics limit — refactoring does not fix it; token isolation does. (`CRON_HIERARCHY.md §4b–4c`)

### 2. Snapshot firehose storage + bloat (→ `A1-OPS-15..21`)
- `listings_snapshots` — 3.6 GB / 8.96M rows, 455k captures/day (retention already 30d→15d, mig `20260603190000`).
- `seatgeek_listings_snapshots` — 3.2 GB / 3.84M rows (11× dedup factor).
- `seatgeek_sales_snapshots` — 1.18 GB / 1.73M rows (11–23× overcount; every poll re-inserts each sale).
- `espn_injuries_snapshots` — 175 MB for ~16.5k live rows (wide bloat); historically forced an 18.8s full scan on every event-page load (fixed to ~0.5s in the `get_broker_event_page` v1→v2→v3 chain, mig `20260530120000`).

Retention Waves 2–4 (SG-sales dedup · change-detection write-gate · range-partition by `captured_at` + one-time `VACUUM FULL`) are pending; growth is the trajectory risk.

---

## Tier 2 — architecture debt (velocity ceiling)

### 3. `app.py` monolith (→ `BR-CODE-1`)
8,753 LOC, **112 routes + 236 functions** serving every surface (terminal, store, seatgeek, seatdata, axs, admin, bridge) in one file, **302 inline SQL/supabase calls**, no DB-access layer. Five functions exceed 220 lines (`_compute_movers` 481, `broker_event_chart_data` 469, `_bulk_event_context` 351, `_resolve_event_with_filters` 340, `require_auth` 257). Every route re-writes the same filter chains.

### 4. Nine `*_client.py` clients (→ `BR-CODE-2`)
Each copy-pastes ~100 LOC of read-only guard, retry/backoff, vault-secret resolution, session/headers — with *inconsistent* retry logic across sources, which feeds the uneven rate-limit handling in Tier 1. A shared `BaseReadOnlyClient` reclaims ~900 LOC and unifies backoff (incl. honoring `ratelimit-remaining`).

### 5. Test coverage ~12% (→ `BR-CODE-3`)
5,951 test LOC vs ~46.5k app LOC. **60+ broker/admin routes are untested**: `/api/broker/*/chart-data`, `/movers`, `/overview`, `/zones`, all `/api/admin/*`, `/api/seatdata/*`, `/api/axs/*`, `/api/configurations/*`, `/api/venues/*`.

### 6. Frontend bloat (→ `BR-CODE-4`)
`event.js` 5,595 LOC with 130+ loose global state vars manually synced to localStorage and 5+ near-duplicate render functions; `store.js` 3,160 LOC; ~300–400 LOC of duplicated CSS variables across `static/terminal/style.css` + `static/store/style.css` (no shared theme file).

---

## Tier 3 — data quality, infra, process

- **AQ mapper debt** (→ `A1-OPS-22`): 235 `tevo_event_id`s with ≥2 map rows (duplicates + false matches); fresh order/sales rows have NULL `tevo_event_id` → invisible in terminal views until backfill (SG ~87%, TickPick ~81%, AXS often NULL). Safe-class consolidation fn built (`aq_consolidate_safe_dups`), pending operator apply.
- **Cron headroom**: 32-slot hard ceiling (Supabase, not raisable), target ≤20, only 12 slots buffer; two heavy jobs held paused (`master-cascade-2min` 15.5% DB-time, `zone-backfill-isolated-10min` 14.3%). (`CRON_HIERARCHY.md §1, §4`)
- **Render deploy debt**: all three frontends consolidated into one starter service to dodge cold starts; "migrate-back-at-beta" not tracked as an epic. (`BOT_HIERARCHY.md §4`, `D0_BIBLE.md §B7`)
- **Governance overhead**: ~5,200 lines / 9 canonical docs, per-bot aging sweeps, multi-lane sign-offs; ~+5 min/migration, ~10–15 min session ramp. Proportionate to safety guarantees; not the shipping bottleneck.

---

## Recommended order

1. **P0 (operator):** SG token isolation + interim `p_max 8→4` cut (`A1-OPS-3`); finish retention Waves 3–4 (`A1-OPS-17/18`).
2. **P1 (code, autonomous):** carve `app.py` into a `routers/` package (`BR-CODE-1`); extract `BaseReadOnlyClient` (`BR-CODE-2`).
3. **P2:** broker/admin route tests (`BR-CODE-3`); apply AQ consolidation (`A1-OPS-22`).
4. **P3:** frontend render/CSS de-duplication (`BR-CODE-4`).

Code-side items (P1–P3) are executable on a feature branch with CI verification; P0 needs operator action (external coordination + centralized prod-DB apply on A1).
