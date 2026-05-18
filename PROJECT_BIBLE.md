# PROJECT_BIBLE.md — operating playbook for all bots

**Last updated**: 2026-05-17 by A1
**Read this FIRST every session.** Saves ~5× the tokens vs reading every governance file at start.

This doc is the **operating playbook** — rules, macros, recipes, landmines. For the **inventory** (what exists: tables, views, crons, edge functions, vault, services), read `RESOURCES_BIBLE.md`.

**⚠ BEFORE CREATING ANY NEW TABLE / VIEW / RPC / CRON / EDGE-FN — check `RESOURCES_BIBLE.md` first.** 132 tables + 152 views + 75+ crons + 40+ edge fns already exist. Recurring waste: re-implementing `event_metrics`, `*_xref`, `*_pending`, `v_event_*` patterns when one already exists. Quick check: `SELECT relname FROM pg_class JOIN pg_namespace n ON n.oid=relnamespace WHERE nspname='public' AND relkind IN ('r','v','m')` — search the output for keywords before authoring.

| Need | Read |
|---|---|
| **What's open right now? (all lanes, severity-sorted)** | **`KANBAN.md §🟢 OPEN WORK` — single source of truth, populate-as-you-go, delete-when-fixed** |
| What can I do? Hard rules, hierarchy, macros, recipes | **This file** |
| What exists? Tables/views/crons/edge-fn inventory | `RESOURCES_BIBLE.md` |
| Who can push to where? | `BOT_HIERARCHY.md` |
| How do I apply a migration? | `MIGRATION_CONVENTIONS.md` |
| Security rules + lockdown invariants | `CLAUDE.md` |

---

## 1. Hard rules (you can't override these)

1. **SQL data is read-only by default.** Any `INSERT`/`UPDATE`/`DELETE`/DDL on prod requires explicit operator permission per call. Standing exceptions: `bot_chat` writes via `bot_chat_log()`, Supabase branch creation (copy-on-write fork, no prod mutation), authoring migration files (apply gated separately).
2. **Upstream third-party APIs are READ-ONLY.** TEvo, SeatGeek, SeatData, TickPick, Vivid — GET endpoints only. No order POSTs, holds, webhook config changes without explicit operator authorization.
3. **HTML / JS in your assigned lane is free reign** — no per-step approval.
4. **Render workspace is per-service scoped** (§2 ownership matrix). Cross-service writes = lane violation.
5. **A1 is sole pusher to `main`** (see `MIGRATION_CONVENTIONS.md §9`).
6. **Cross-lane file edits require coordination** via `bot_chat` `question` or PR comment to the lane owner.
7. **Edge function auth: platform `verify_jwt=true` is NOT sufficient.** It accepts ANY valid Supabase JWT — including the publishable anon JWT exposed at `/api/public/config`. Edge functions that mutate data or burn paid upstream APIs MUST add body-level `requireCronSecret(req)` from `supabase/functions/_shared/cron-auth.ts`. Pattern verified across 12 existing functions; 3 exceptions caught in B1 audit PR #172 (2026-05-16) and patched in PR #174.
8. **Check `KANBAN.md §🟢 OPEN WORK` before claiming new work.** It is the single-source-of-truth for what's currently actionable across all lanes — severity-sorted, with the smallest fix for each finding. **Fixing bot DELETES its row from that section in the same PR as the fix** (row's absence IS the closure signal; archive sections below preserve the historical detail). Populate as you go — anyone can add a row; B1 maintains for security findings, each lane for its own. Broadcast: bot_chat 311 (2026-05-17).

When in doubt → ask via `AskUserQuestion` or post a `bot_chat` question.

---

## 2. Bot hierarchy + Render service ownership

```
A1 (admin · sole prod pusher · Render workspace owner)
├── B1 (security · monitors all; CRIT push allowed)
└── C1 (canonical · drift monitor only since PR #109)
    ├── D0 (Terminal FE · static site)
    ├── D1 (Consumer Retail · storefront/search)
    ├── D2 (Order Clients · ops dashboard)
    ├── D3 (Broadway Scraper · sub of D2)
    ├── D4 (Ticketing infra · UNASSIGNED)
    └── E1 (Kalshi/markets · future stub)
```

| Bot | Render service | Service ID | Scope |
|---|---|---|---|
| A1 | workspace-wide | — | full (read + write + provisioning + delete) |
| **D0** | **workspace-wide** | — | **full Render parity with A1 (2026-05-16)** — read + write + provisioning + delete across all services |
| D1 | `vibepass-storefront-test` | `srv-d8140bnaqgkc73al4asg` | code author only; Render MCP read-only (writes route through D0 + A1) |
| D2 | `d2-orders-dashboard` | `srv-d82b4kl7vvec73b4r3r0` | code author only; Render MCP read-only (writes route through D0 + A1) |
| B1, C1, D3, D4, E1 | (all services) | — | read only |

**Testing-unified architecture (2026-05-16, PR #168)**: All runtime traffic flows through `vibepass-storefront-test` (starter plan, no cold starts). It hosts D0 terminal + D1 storefront + D2 dashboard via `app.include_router` mounts. `vibepass-terminal-test` continues to serve as a CDN for D0 static files; `d2-orders-dashboard` stays alive as a beta-time placeholder but has no live traffic. At beta, each surface migrates back to its own service via dedicated DNS + un-mounting from `app.py`.

Code-dir ownership (per `LANE_DISCIPLINE.md`):
- D0 → `static/terminal/*` + Terminal FE
- D1 → `static/store/*` + storefront API
- D2 → ops dashboard
- A1 → `supabase/migrations/*`, governance docs, cross-cutting

---

## 3. Column-name landmines (catch SQL bugs before you author)

Every entry here cost real session time when discovered. CHECK column names against this table FIRST.

| Table | Wrong name | Correct name |
|---|---|---|
| `seatgeek_sales_snapshots` | `sold_at`, `price`, `captured_at` | `sale_at_utc`, `broadcast_price`, `pulled_at` |
| `seatgeek_listings_snapshots` | `price` | `broadcast_price` (+ `retail_price_all_in` for all-in display) |
| `seatgeek_event_metrics` | `cost_min/median/p90` (DROPPED 2026-05-18) | `listings_all_min/median/p90` (full firehose) or `listings_owned_min/median/p90` (broker-owned subset) — PR-4a/4b |
| `event_alerts` | `event_id`, `created_at` | `tevo_event_id`, `fired_at` |
| `nws_alerts` | `expires` | `expires_at` |
| `weather_observations` | `captured_at` | `observed_at` (reading) + `fetched_at` (ingest) |
| `venue_assets` | `is_outdoor`, 882 rows | `is_indoor`, **111 rows** (outdoor = `is_indoor = false`) |
| `sd_sales_normalized` | `observed_at`, `aq_short_event_id` | `sale_timestamp`, `tevo_event_id` |
| `events` | `is_classified`, `tbd` | (neither exists — use `EXISTS(event_xref...)` for sports; parse `(Date TBD)` from name) |
| `listings_snapshots` (TEvo firehose 8M rows) | filter by `aq_short_event_id` | **0% populated** — query by `event_id` only. Filter ours: `is_owned=true AND brokerage_id=1768` |
| `seatgeek_sales/listings_snapshots.tevo_event_id` | use as join key | **0% populated** — always query by `sg_event_id` (indexes added 2026-05-16) |
| `seatgeek_sales_snapshots` aggregates | `count(*)` / `SUM(broadcast_price)` directly | **11–23× overcount** — UNIQUE `(sg_event_id, sg_sale_id, pulled_at)` means each logical sale re-inserts every poll. **MANDATORY**: `DISTINCT ON (sg_sale_id) ORDER BY sg_sale_id, pulled_at DESC` before any aggregate. `MAX()` alone is safe (idempotent). Exemplars: `v_event_sales_metrics_filtered`, `v_event_sales_velocity` (PR #161); v3 RPC `sg_broker_sales` (PR #191). |
| `v_event_weather_with_fallback.is_climo_fallback` | (column doesn't exist) | Derive `weather_kind = 'climatology_outdoor'`. Values: `'none' / 'forecast_indoor' / 'forecast_outdoor' / 'climatology_outdoor'`. |
| `v_event_weather_with_fallback.climo_temp_f` | wrong name (no `_avg`) | Actual is `climo_avg_temp_f`. Sibling climo cols: `climo_avg_precip_in`, `climo_avg_wind_mph`, `climo_stddev_temp_f`, `climo_precip_pct`. The view also exposes top-level pre-resolved `temp_f / precip_in / precip_pct / wind_mph / weather_summary` — use those if you don't need a forecast-vs-climo badge. |
| `sg_events_canonical` Parking pseudo-events | match against TEvo | **TEvo merges parking into main listing** — skip `sg_category IN ('Parking','parking')` and `*venue_name ILIKE '%parking%'` rows. Matcher v3 enforces this. |
| TEvo `/v9/events` date filter | `occurs_at_gte` (underscore) | **`"occurs_at.gte"` (dotted)** — underscore returns 422 Invalid Parameters |

---

## 4. Canonical SECDEF RPCs (the hot 15 of 32)

| RPC | Args | When to call |
|---|---|---|
| `get_broker_event_page_v2(p_event_id, p_chart_hours)` | int, int (default 720) | **D0 Phase 2a primary**. 11 payload keys incl. sales_tape/weather/espn/sg_side_by_side/splits/freshness. Email-gated `@s4kent.com`. ~185ms. |
| `get_broker_event_page(p_event_id, p_chart_hours)` | — | v1; v2 composes it for base payload |
| `match_to_aq_event_id(source, src_id, name, venue, date, lat, lon, [src_venue_id])` | — | 4-tier matcher (direct id / venue+id / venue-exact / venue-fuzzy) |
| `create_system_aq_event(source, name, venue, date, src_id)` | — | SYS-md5 fallback when matcher returns NULL |
| `match_unmatched_orders_sweep(max, create_synth)` | int, bool | Cron-driven order sweep across 5 surfaces |
| `match_unmatched_listings_chunked(max_events, create_synth)` | int, bool | Listings firehose backfill (per-event chunked) |
| `bot_chat_log(level, lane, type, msg, pr, mig, in_reply_to, meta)` | — | **Standing permission**. Cross-lane coordination. |
| `bot_chat_resolve(id, level, lane, note)` | — | Standing permission. Close out a question/flag. |
| `cron_should_fire(jobname)` | text | Wrap every new cron body with this gate |
| `cron_resume_with_gate(jobname)` | text | Re-enable paused crons through the gate |
| `sg_classify_events()` | — | Refresh tier classifications in `sg_event_priority_state` |
| `sg_priority_poll_tick(max_polls)` | int | HOT/WARM polling driver |
| `espn_scoreboard_queue(lookahead_days)` | int (default **270**) | ESPN scoreboard ingest. Bumped 2026-05-16 to capture full NFL season. |
| `espn_scoreboard_process()` | — | Process ESPN responses → date_lookup |
| `refresh_sg_broker_sales_event_metrics(max_events)` | int (default 200) | Populate `seatgeek_event_metrics.sold_*` from deduped (DISTINCT ON sg_sale_id) sales snapshots. Hourly cron @ :17. |
| `sg_canonical_refresh_v2_pull(window_minutes)` | int (default 15; NULL = full) | Reconciles `sg_events_canonical.last_v2_pull_at` + `last_v2_listings_count` + `last_v2_status` + `has_v2_listings_pulled` from `seatgeek_listings_snapshots`. Cron @ :12,:42. Backfill ran 2026-05-16: 574 rows brought to 100% coverage. |
| `sg_broker_listings_process(p_limit)` / `sg_broker_sales_process(p_limit)` | int (default **50**) | **Bounded drain** (2026-05-17). Reads `sg_broker_pending` rows that have an `_http_response`, joins `aq_event_map` + `seatgeek_event_xref` once, inserts rows + marks resolved. Cron is the 1-min priority variant only (30-min duplicates unscheduled). If pendings outpace 50/min, raise the param. |
| `sweep_all_expired_pg_net_pending(ttl_hours)` | int (default 12) | Cron-driven housekeeping. Includes `sg_broker_pending` as of 2026-05-17. Marks `resolved_at = now()` for pendings where the `_http_response` row has been pruned. |
| `sg_attempt_event_xref_v3(...)` | bigint, text, date, timestamptz, text, [text], [text], [text] | **Matcher v3**: ±24h date tolerance + parking skip + `cross_source_venue_resolve` lookup. Replaces v2 in `cross_source_match_tick`. |
| `auto_match_sg_canonical_v3()` | — | Sweeps all unlinked SG canonical rows through matcher v3. Returns `(attempted, newly_matched, parking_skipped, still_unmatched, needs_tevo_search)`. |
| `cross_source_venue_resolve(name, city, state)` | text, [text], [text] | Returns `tevo_venue_id` from any-source venue name via 3-tier match (canonical / aliases array / prefix). Driven by `cross_source_venue_map` (391 TEvo rows + 129 SG / 94 TickPick / 85 Vivid aliases as of 2026-05-16). |
| `refresh_cross_source_venue_map()` | — | Rebuilds `cross_source_venue_map` from events/sg_events_canonical/tickpick_orders.raw/vivid_orders.raw. Idempotent. |
| `release_health_check()` | — | All-checks rollup |

For the full RPC list + arg detail + composition relationships → `RESOURCES_BIBLE.md §3` and the migration headers.

---

## 5. Cross-source bridge topology

```
events (TEvo) ─── PK e.id ─────────────────────────────┐
   │                                                    │
   │ via entity_performer_map (perfid + ±6h date)       │
   ▼                                                    ▼
event_xref ──── espn_event_id ───────► espn_event_date_lookup
   │                                    espn_event_snapshots (gameday-scope)
   │                                    espn_team_snapshots
   │                                    espn_injuries_snapshots
   ▼
seatgeek_event_xref ── sg_event_id ──► sg_events_canonical
   │                                    seatgeek_listings_snapshots
   │                                    seatgeek_sales_snapshots (DISTINCT ON sg_sale_id !)
   │                                    seatgeek_event_metrics
   ▼
aq_event_map ── aq_short_event_id ────► universal canonical key
   │                                    (SYS-md5 hash convention for derived rows)
   ▼
venue_short_id ──► aq_venue_map / venue_assets / weather_observations
performer_short_id ──► aq_performer_map / espn_team_snapshots
```

**D0 canonical entry** (Phase 2a):

```sql
SELECT * FROM public._v_d0_event_index WHERE sg_event_id = $1;
-- OR for non-SG events (NFL etc.) — v2 RPC has fallback that resolves via event_xref:
SELECT public.get_broker_event_page_v2($tevo_event_id, 168);
```

**Snapshot inventory** (where the firehose tables live + what's available to surface as event-page tabs / time-series panels):
- 5 live firehoses (SG listings, SG sales, TEvo listings, TEvo orders, SG seller orders) → `RESOURCES_BIBLE.md` "Snapshot streams" table
- 3 lower-volume order streams (TickPick, SG seller listings, Vivid) → same table
- 4 specialized live snapshots (ESPN event/injuries/team, event_competitors) → same table
- 4 idle/empty (seatdata × 2, event_section_row, legacy `snapshots`) → same table
- **D0 tab option matrix** (already shipped + 8 next-surface candidates with RPC patterns) → `RESOURCES_BIBLE.md` "D0 tab option matrix"

Rule: before proposing a new snapshot capture, check the inventory — there's probably already a firehose for what you want, you just need a SECDEF RPC wrapper. 24h activity stats refresh on each major doc rebase.

---

## 6. MCP tools by lane

| MCP family | A1 | B1 | C1 | D0 | D1 | D2 | D3/D4/E1 |
|---|---|---|---|---|---|---|---|
| Supabase `execute_sql` (read) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Supabase mutation/migration | ✓ | CRIT only | drift-monitor only | ✗ | ✗ | ✗ | ✗ |
| Supabase `create_branch` (copy-on-write) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Render: read (list/logs/metrics) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Render: write (own service only) | all | ✗ | ✗ | terminal | storefront | dashboard | ✗ |
| Slack | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| scheduled-tasks | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| GitHub (`gh` via Bash) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

---

## 7. SQL macros (operational patterns bots use repeatedly)

### `bot_chat_log` — durable cross-lane coordination
```sql
SELECT public.bot_chat_log(
  p_level := 'data-collection', p_lane := 'A1',
  p_event_type := 'change_log',     -- change_log | question | flag | resolve_request
  p_message := 'did X. details: ...',
  p_related_pr := 154, p_related_mig := '20260516070000',
  p_in_reply_to := NULL, p_meta := NULL);
```

### Cancel-pattern SKIP (used in `sg_classify_events`)
```sql
WHERE sg_event_name ~* '(cancelled|if necessary|\(date tbd\)|^TBD at )'
```

### SG sales dedupe (mandatory — 11× duplication factor)
```sql
SELECT DISTINCT ON (sg_sale_id) *
FROM seatgeek_sales_snapshots
WHERE sg_event_id = $1
ORDER BY sg_sale_id, pulled_at DESC;
```

### Sports event gate (no `events.is_classified`)
```sql
EXISTS (SELECT 1 FROM event_xref WHERE tevo_event_id = events.id AND espn_event_id IS NOT NULL)
```

### Outdoor venue gate (no `is_outdoor`)
```sql
venue_assets.is_indoor = false  -- explicit FALSE, never NULL
```

### Cron body wrapper (always use the policy gate)
```sql
DO $body$ BEGIN
  IF NOT public.cron_should_fire('your_cron_name') THEN RETURN; END IF;
  -- work here
END $body$;
```

### Function signature changes — drop old overloads explicitly
Adding (or removing) a parameter — **even one with a `DEFAULT`** — creates a NEW overload, not a replacement. The old function survives and callers that pass no args resolve ambiguously: `function X() is not unique`. Caught twice now: A1 bot_chat 258 (`match_to_aq_event_id` 7-arg), A1 mig 20260517160004 (`sg_broker_*_process` 0-arg). Pattern:
```sql
-- before adding a parameter to existing fn, drop the prior signature
DROP FUNCTION IF EXISTS public.your_fn(text, int);     -- prior signature
CREATE OR REPLACE FUNCTION public.your_fn(p_a text, p_b int, p_new int DEFAULT 50) ...
```
If you can't predict the prior signature, query `pg_proc` for `proname` to enumerate overloads before authoring the migration.

### `sg_broker_pending` — drains via 1-min priority cron
The bounded-drain functions (`sg_broker_listings_process(p_limit=50)` / `sg_broker_sales_process(p_limit=50)`) run from the 1-min priority crons. The 30-min variants were unscheduled 2026-05-17 (redundant). If you need to drain faster ad-hoc, pass a larger `p_limit`. Pending rows whose `_http_response` has been pruned (>6h old) are housekept by `sweep_all_expired_pg_net_pending` at `:20` hourly.

### Email gate inside SECDEF RPC
```sql
v_email := coalesce(auth.jwt()->>'email', '');
IF v_email NOT LIKE '%@s4kent.com' THEN
  RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
END IF;
```

### SYS-md5 hash convention (used by `create_system_aq_event` + v2 RPC fallback)
```sql
v_aq := 'SYS-' || substring(md5(name || '|' || venue || '|' ||
            to_char(date::timestamptz, 'YYYY-MM-DD"T"HH24:MI')) from 1 for 10);
```

### TEvo `/v9/events` search procedure (autotrack cold bridge)
For events we have in SG/TickPick/Vivid but missing from local `events` table — use the active search bridge instead of waiting for broker-listed events.

**Endpoint**: `GET /v9/events` (signed HMAC-SHA256, see `tevo_sign_get()`)

**Filter params (verified 2026-05-16)**:
- `venue_id` (int) — TEvo venue id; resolve from `cross_source_venue_map` via `cross_source_venue_resolve(name, city, state)`
- `name` (text, partial match) — fallback when venue_id unknown
- `performer_id` (int)
- `category_id` (int)
- `"occurs_at.gte"` / `"occurs_at.lte"` (text dates, **dotted notation required** — `occurs_at_gte` returns 422)
- `per_page` (int, max 100), `page` (int)
- `only_with_available_tickets` (bool) — set FALSE for full event lookup, TRUE for crawl-ready listings

**Two-tier search strategy** (matches edge fn `sg-to-tevo-search-bridge`):
1. Tier 1: `venue_id` + date range — most precise
2. Tier 2: `name` (team name) + date range — fallback if no venue_id resolved or empty result

**Result scoring**: `+50` venue_id match, `+40` slug venue match, `+25` prefix venue match, `+10/token` team-name overlap, `+24-hoursAway` date proximity. Accept at `score >= 50` (= venue OK + at least 1 team hit).

**Attempt tracking**: every search writes to `sg_tevo_search_attempts` (PK `sg_event_id`) with result `matched | no_results | low_score`. Don't retry within 24h.

**Live invocation pattern**:
```sql
SELECT public._cron_invoke_edge_fn(
  'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/sg-to-tevo-search-bridge?limit=40&min_score=50',
  '{}'::jsonb);
```

**Observed hit rate (2026-05-16)**: 75% on first live batch (30/40), with venue-map-resolved candidates scoring 64–214.

---

## 8. Workflow recipes

### "I want to author a migration"
1. Read §3 landmines FIRST before writing column names
2. Test query shape on 5-10 sample rows via `execute_sql` (read-only)
3. Write `supabase/migrations/YYYYMMDDHHMMSS_descriptive_name.sql` per `MIGRATION_CONVENTIONS.md`
4. **Ask operator permission** via `AskUserQuestion` before `apply_migration`
5. Apply via MCP `apply_migration`
6. Verify post-apply on same 5-10 samples
7. Update header `## Already applied to prod  Applied via MCP YYYY-MM-DD`
8. Commit + push + open PR (A1 only pushes to main)

### "I want to wire a UI panel"
1. D0: call `supabase.rpc('get_broker_event_page_v2', {p_event_id, p_chart_hours})`
2. Branch on `data.bridge_ids.sg_event_id IS NULL` → render TEvo-only state
3. Branch on `data.weather.hidden=true` → hide weather strip
4. Branch on `data.espn.hidden=true` → hide ESPN panel
5. `data.sales_tape` is pre-deduped + capped at 20 rows
6. `data.freshness.*_latest` for per-source freshness chips

### "I want to flag a cross-lane issue"
```sql
SELECT public.bot_chat_log(
  p_level := 'data-collection', p_lane := 'D0', p_event_type := 'question',
  p_message := 'D1: add my Render origin to CORS_ALLOWED_ORIGINS', ...);
```

### "I want to spawn a cron"
1. Author the underlying SQL fn
2. Wrap body with `cron_should_fire('jobname')` gate
3. INSERT row in `cron_policy` with limits + work_check_sql
4. `cron.schedule('jobname', '*/X * * * *', $body$ ... $body$)`
5. Verify firings via `cron.job_run_details` + `cron_gate_decisions`

---

## 9. Recent landmark migrations (don't re-do these)

| Date | Migration | Effect |
|---|---|---|
| 2026-05-13 | cron policy gate | 4-stage conservation (budget/interval/work-check/window) |
| 2026-05-14 | universal AQ matcher | 4-tier `match_to_aq_event_id` + `create_system_aq_event` |
| 2026-05-14 | tiered polling | `sg_event_priority_state` + HOT/WARM/COOL/COLD tiers |
| 2026-05-15 | `get_broker_event_page` v1 RPC | D0 Phase 1 Path C foundation |
| **2026-05-16** | 20260516030000 | D0 Phase 2a prep: cancelled-filter + `tevo_event_id` col + `_v_d0_event_index` view |
| 2026-05-16 | 20260516040000 | Resume `listings_aq_backfill_overnight` cron |
| 2026-05-16 | 20260516050000 | `get_broker_event_page_v2` RPC (7 new keys, 185ms) |
| 2026-05-16 | 20260516060000 | SG `sg_event_id` indexes (perf for v2) |
| 2026-05-16 | 20260516070000 | NFL ESPN→TEvo→AQ→SG bridge + v2 RPC fallback fix |
| 2026-05-16 | 20260516080000 | Multi-sport bridge (MLB/MLS/WNBA/NBA/NHL) |
| 2026-05-16 | 20260516090000 | `espn_scoreboard_queue` default 90d → 270d |
| 2026-05-16 | 20260516100000 | `evo_orders` event-mapping columns (tevo_event_id + aq_short_event_id) + backfill |
| 2026-05-16 | 20260516110000 | NEW RPC `refresh_sg_broker_sales_event_metrics` + hourly cron; populates `seatgeek_event_metrics.sold_*` from `seatgeek_sales_snapshots` |
| 2026-05-16 | 20260516120000 | 3 analytics views: `v_event_sales_velocity`, `v_event_sales_metrics_filtered`, `v_event_price_arbitrage` |
| **2026-05-17** | 20260517160000 | **sg_broker_{listings,sales}_process bounded drain** — added `p_limit int DEFAULT 50` + lifted aq_event_map + seatgeek_event_xref into LEFT JOIN (drops per-row correlated subqueries). New rows born with `tevo_event_id` populated where xref exists. Unscheduled 30-min variants (redundant with 1-min priority). Drains 50 pendings in ~5s; was timing out at 2min draining unbounded. |
| 2026-05-17 | 20260517160001 | Partial indexes `(*_prev_*_null_idx)` on `listings_snapshots` + `seatgeek_listings_snapshots` — fixes the seq-scan in `listings_deltas_backfill_chunked` that A1 PR #189 didn't address. Backfill of 15 events now <1s (was 5min timeout). |
| 2026-05-17 | 20260517160002 | `match_listings_to_sg_tick` narrow + indexes — D2's bot_chat 225 sketch shipped: window 24h→6h, `ROW_NUMBER()` uniqueness instead of triple `NOT EXISTS`, helper indexes. 591ms vs prior 5min timeout. |
| 2026-05-17 | 20260517160003 | `sweep_all_expired_pg_net_pending` now covers `sg_broker_pending` + one-shot drain of 1,595 zombies (orphaned by `net._http_response` prune). |
| 2026-05-17 | 20260517160004 | Hotfix: drop legacy 0-arg overloads of `sg_broker_{listings,sales}_process`. Mig 20260517160000's `DEFAULT 50` addition created an overload not a replacement; cron `SELECT fn()` resolved ambiguously. Same class as A1 bot_chat 258 lesson. |
| 2026-05-17 | 20260517260000 | **SG broker-listings event metrics** — 18 new cols on `seatgeek_event_metrics`: `listings_all_*` (full firehose) + `listings_owned_*` (`is_broker_owned=true` subset), both from `broadcast_price`. New `refresh_sg_broker_listings_event_metrics(p_max_events int)` hourly cron @ :47. Companion to PR #161 sales-side @ :17. Also DROP NOT NULL on `tevo_event_id` to allow SG-only events. |
| **2026-05-18** | 20260518010000 | **event_sentiment cron**: schedule existing `backfill_event_sentiment(200)` @ :15,:45 via cron_should_fire gate. Fn existed since mig 20260509130000, never had a cron. |
| 2026-05-18 | 20260518020000 | **event_competitors cron re-schedule**: re-schedule `refresh_event_competitors()` @ :40 hourly (was scheduled in mig 20260509350000 and lost). Sparse coverage by-design — only events with 20mi/24h venue neighbors. |
| 2026-05-18 | 20260518030000 | **event_section_row_snapshots batch + cron**: new `rollup_event_section_row_batch(p_max_events int)` wrapper around existing single-event `rollup_event_section_row` (mig 20260512100150). Hourly cron @ :03. Writes source=tevo only; SG mirror pending future PR. |
| 2026-05-18 | 20260518040000–040004 | **cost_* reader migration (5 readers)**: `v_event_price_arbitrage` + `v_event_full_v2` + `v_event_velocity_windows` + v2 RPC + v3 RPC all swap `cost_*` → `listings_all_*` (or `listings_owned_*` for arbitrage). Payload key names also renamed. |
| 2026-05-18 | 20260518050000 | **cost_* columns DROP** + retire `compute_seatgeek_event_metrics` (legacy SellerDirect-only populator). 8 deprecated cost_* cols removed from `seatgeek_event_metrics`. |
| 2026-05-18 | 20260518060000 | **event_metrics owned distribution DDL**: ADD COLUMN `owned_p25/p75/p90` numeric. Writer (Python app.py event-processor) is cross-lane — bot_chat handoff posted. Cols sit at NULL until writer-side ship. |
| **2026-05-19** | 20260519100000 | **SG sales DISTINCT ON view cleanup**: 4 views (`seatgeek_event_latest`, `unified_orders`, `v_aq_match_quality`, `v_orphan_seatgeek_data`) were aggregating without DISTINCT ON sg_sale_id, silently 11–23× overcounting. Rebuilt with proper dedup. 2 dependents (`unified_orders_by_event`, `order_status_coverage`) recreated unchanged. Spot-check: event 3091415 sales_count went 8,431 → 368; unified_orders sg_sales rows went 1.82M → 121K. |

---

## 10. Drift watchlist (known gaps — don't waste cycles rediscovering)

| Gap | Status | Symptom / workaround |
|---|---|---|
| `tevo_event_id` populated on SG snapshot tables | Partial: PR #178 backfilled to 87.35%; mig 20260517160000 ensures NEW rows are born populated where xref exists | Query by `sg_event_id` when `tevo_event_id IS NULL` (no xref) |
| `seatgeek_event_xref.last_listings_at`/`last_sales_at` | Dead globally (0/967) | Use `MAX(captured_at)` on snapshot tables |
| `sg_events_canonical.has_v2_listings_pulled` | Dead (25/4609 = 0.5%) | Same |
| ESPN snapshot pipeline = gameday-scope only | (specced, not built) | Forward-look ESPN panels empty by design |
| 29% active TEvo events have no SG bridge | NWSL/USL/AHL/niche real gap | First-class TEvo-only UI state |
| SG doesn't carry most NFL regular-season | SG coverage decision | NFL Event Detail renders TEvo+ESPN+AQ; SG hidden |
| `aq_short_event_id` 0% on `listings_snapshots` | Cron resumed 2026-05-16; firing 04:02 UTC | Use `event_id` for TEvo reads |

---

## 11. Self-check before any task

1. ☐ Did I read this playbook (§1-§8)?
2. ☐ Is my action covered by §1 hard rules?
3. ☐ Am I editing files in my own lane (§2)?
4. ☐ Did I verify schema column names against §3 landmines?
5. ☐ For mutations: did I ask operator permission?
6. ☐ For new crons: did I wrap with `cron_should_fire`?
7. ☐ For cross-lane work: did I `bot_chat_log` a question?
8. ☐ Is my work already shipped per §9 (don't re-do)?
9. ☐ Is my "discovery" a §10 known gap (don't waste cycles)?

If YES to all → proceed. Else fall back to `RESOURCES_BIBLE.md` for inventory or `CLAUDE.md` for security rules.

---

**Refresh policy**: A1 updates this playbook when (a) new canonical RPC ships, (b) hard rule changes, (c) column-name landmine discovered, (d) landmark migration lands. Inventory deltas go in `RESOURCES_BIBLE.md`. Don't edit without A1 review (drift prevention).
