# PROJECT_BIBLE.md — operating playbook for all bots

**Last updated**: 2026-05-25 by A1 (PRs #345–359: Render-primary docs, D-tier goals/plan, B1 anon-data-leak security sweep [14 views + 5 fns REVOKEd + detector harness], TEvo Fernet decrypt, D1 TEvo Checkout dormant, D4 Stripe fulfillment idempotency, Dependabot deps — §9 + §10 updated)
**Read this FIRST every session.** Saves ~5× the tokens vs reading every governance file at start.

This doc is the **operating playbook** — rules, macros, recipes, landmines. For the **inventory** (what exists: tables, views, crons, edge functions, vault, services), read `RESOURCES_BIBLE.md`.

**⚠ BEFORE CREATING ANY NEW TABLE / VIEW / RPC / CRON / EDGE-FN — check `RESOURCES_BIBLE.md` first.** 132 tables + 152 views + 75+ crons + 40+ edge fns already exist. Recurring waste: re-implementing `event_metrics`, `*_xref`, `*_pending`, `v_event_*` patterns when one already exists. Quick check: `SELECT relname FROM pg_class JOIN pg_namespace n ON n.oid=relnamespace WHERE nspname='public' AND relkind IN ('r','v','m')` — search the output for keywords before authoring.

| Need | Read |
|---|---|
| **What's open right now? (all lanes, severity-sorted)** | **`KANBAN.md §🟢 OPEN WORK` — single source of truth, populate-as-you-go, delete-when-fixed** |
| What can I do? Hard rules, hierarchy, macros, recipes | **This file** |
| What exists? Tables/views/crons/edge-fn inventory | `RESOURCES_BIBLE.md` |
| Where's each lane going? (north-star + endgame) | `docs/d_tier_goals.md` |
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
└── C1 (canonical · drift + checkpoint + token-discipline + quality/continuity monitor — see docs/c1_quality_continuity_charter.md)
    ├── D0 (Terminal FE · static site)
    ├── D1 (Consumer Retail · storefront/search)
    ├── D2 (Order Clients · ops dashboard)
    ├── D3 (Broadway Scraper · sub of D2)
    ├── D4 (Exos/Bridge · primary-market ticketing — greenfield, own exos_* schema)
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
- D4 → `d4_bridge/*` (Exos app) + `exos_*` / `bridge_event_xref` migrations (authors; A1 applies)
- A1 → `supabase/migrations/*`, governance docs, cross-cutting

**D4 / Exos (Bridge)** — primary-market ticketing, greenfield. Separate React app (`d4_bridge/*`) on its own `exos_*` schema (Firestore → Supabase migration **complete** 2026-05-23 — Firebase fully removed). Served at `/bridge/` via the unified Render service (`static/bridge/` — last rebuilt **2026-05-25** picking up PRs #336/#338/#339). Railway was the primary host (PR #319) but is now redundant — `static/bridge/` is current and Railway can be decommissioned. Same-origin `localStorage` means the hub's Supabase session carries over automatically (no double sign-in). Links to canonical events **by value** via `bridge_event_xref` and **never writes D0 tables**. Build: `npm --prefix d4_bridge run build` then copy `dist/ → static/bridge/`; Supabase keys must be in `d4_bridge/.env.local` (gitignored) at build time. **Always commit `static/bridge/` after a source change or Render serves the stale bundle.** Schema/value landmines in §3; full detail in `docs/d4_bridge_charter.md`.

**D4 migration state (updated 2026-05-25):**

✅ **Schema live — all 5 phases + free-first batch applied to prod.** Phase-1/2 (PR #305) + phase-3/4/5 (PR #308) B1-cleared. Free-first batch (migs 20260523130000–20260524160000) applied A1-session 2026-05-25 — adds drainer schema, oversell cap, server HMAC verify, purchase limits, growth RPCs, mail templates, security hardening. 12 `exos_*` tables + `bridge_event_xref` RLS-on; anon-EXECUTE revoked on all write-path RPCs. 0 rows — data populates via normal UI flows.

✅ **Supabase Auth** — `lib/auth.ts` + `AuthContext.tsx` fully on Supabase Auth. No Firebase Auth anywhere. `AppUser` shape maps from `SupabaseUser`; `isAdminUser()` checks `app_metadata.admin` (server-set, unforgeable).

✅ **Data libs wired** — `lib/events.ts`, `lib/orgs.ts`, `lib/tickets.ts` all read/write via `supabase-js` against `exos_*` tables. A transitional `Timestamp` shim remains purely for type-compat with `src/types.ts` — converts Postgres timestamptz strings to the old Firestore `Timestamp` shape so views stay drop-in. Safe to remove after the `src/types.ts` type sweep.

✅ **`lib/storage.ts`** — Supabase Storage replaces Firebase Storage. `exos-media` bucket live (mig 20260520150000), path-scoped RLS (`event-images/{uid}/` + `org-logos/{orgId}/`), 5 MB cap, SVG excluded (hosted XSS risk on public bucket). `lib/orgLogo.ts` migrated.

✅ **`lib/mail.ts`** — `queueEmail()` calls `supabase.rpc('exos_queue_mail', { p_template, p_ref_id })`. The SECDEF RPC (mig 20260520160000) server-derives recipient from the related record — no open relay (B1 SEC-HIGH closed bot_chat #438). Mail rows accumulate as `status='pending'`; **drainer deployed** (`exos-mail-drain` edge fn, 2026-05-24, cron `exos-mail-drain-2min` `*/2 * * * *` work-check-gated). ⚠️ **`RESEND_API_KEY` + `EXOS_MAIL_FROM` not yet set** — operator must set these Supabase edge-fn secrets in the dashboard before mail actually sends.

✅ **Data cut-over resolved** — operator confirmed all Firestore data is test-only; no migration needed. `exos_*` tables start fresh at 0 rows and populate via normal UI flows (org create → events → tickets). `scripts/migrate-to-orgs.ts` was a Firestore-internal restructuring pass and is not applicable to the Supabase path. D4-OPS-2 closed 2026-05-23.

❌ **`src/types.ts` Timestamp shim** — `Timestamp` type from `firebase/firestore` still used for date fields in `Event`/`Ticket`/`Transfer`. After cut-over, replace with `Date | string`; remove `toTs()` helpers.

✅ **SW scope** — fixed PR #322 (2026-05-23): `BASE` derived from `self.location.href`; all manifest.json paths prefixed `/bridge/`. D4-OPS-1 closed.

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
| `v_rivalry_events` aggregates | `count(*)` / first-row per `tevo_event_id` | **Duplicate rows emitted when both teams are competitors** — view joins both home + away through `sporting_rivalries`. Dedupe Python-side keyed on `tevo_event_id` (first match wins) before consuming. Exemplars: `app.py:1198` event-page enrichment, `_compute_movers` Specials rail (PR #275). |
| `v_event_weather_with_fallback.is_climo_fallback` | (column doesn't exist) | Derive `weather_kind = 'climatology_outdoor'`. Values: `'none' / 'forecast_indoor' / 'forecast_outdoor' / 'climatology_outdoor'`. |
| `v_event_weather_with_fallback.climo_temp_f` | wrong name (no `_avg`) | Actual is `climo_avg_temp_f`. Sibling climo cols: `climo_avg_precip_in`, `climo_avg_wind_mph`, `climo_stddev_temp_f`, `climo_precip_pct`. The view also exposes top-level pre-resolved `temp_f / precip_in / precip_pct / wind_mph / weather_summary` — use those if you don't need a forecast-vs-climo badge. |
| `sg_events_canonical` Parking pseudo-events | match against TEvo | **TEvo merges parking into main listing** — skip `sg_category IN ('Parking','parking')` and `*venue_name ILIKE '%parking%'` rows. Matcher v3 enforces this. |
| TEvo `/v9/events` date filter | `occurs_at_gte` (underscore) | **`"occurs_at.gte"` (dotted)** — underscore returns 422 Invalid Parameters |
| `pg_net.http_get()` inside a loop | `PERFORM pg_sleep(N)` between calls to pace upstream rate limits | **NO-OP for rate limiting** — pg_net is **asynchronous**. The function returns a request_id immediately; HTTP fire happens in a background dispatch worker that doesn't honor function-side `pg_sleep`. Evidence: 50 queued GETs fired with IDENTICAL `_http_response.created` timestamp `02:34:45.137759`. PR #212/#214 pg_sleep stagger never worked. **Right pattern**: cap burst size to ≤ upstream token quota and use cron frequency for throughput. Codified as macro in §7. Discovered via PR #228 / mig 20260519140000. |
| `espn_team_id` / `espn_event_id` cross-table reads | filter by id alone | **Cross-league collision** — espn_team_id `"28"` maps to BOTH MLB Atlanta Braves AND an NHL team (`28` had 1,400 NHL injury rows vs 3 MLB rows in 7-day window). Always **scope by `espn_league`** when reading `espn_injuries_snapshots` / `espn_event_snapshots` / cross-team joins. `event_xref.espn_league` carries it through from the TEvo side. Discovered via PR #237 / mig 20260519150000. |
| ESPN team-ID resolution for forward-look events | `espn_event_snapshots` | **Snapshot pipeline is gameday-scope only** (§10 drift). For future events use `espn_event_date_lookup` (forward-look home/away/game_at_utc) first, fall back to snapshots only for past games. |
| PL/pgSQL `EXCEPTION WHEN OTHERS` to swallow a `statement_timeout` | `WHEN OTHERS THEN ...` | **Does NOT trap `query_canceled` (SQLSTATE 57014)** — that's exactly what `statement_timeout` raises, and `OTHERS` deliberately excludes it (so users can always cancel). A function meant to soft-fail on timeout MUST list `WHEN query_canceled THEN ...` explicitly (then optionally `WHEN OTHERS`). Reset `statement_timeout` to a safe value before any trailing work in the handler or the next statement re-cancels. Discovered live: `compute_event_breakdowns` non-fatal fix (mig 20260520410000) — first cut used `OTHERS`, still 502'd; `query_canceled` caught it cleanly. Exemplar: `backfill_stale_zone_metrics`. |
| MCP `execute_sql` heavy ad-hoc scans (audit queries) | run unbounded against prod | **MCP runs as `service_role` (NO `statement_timeout` cap); PostgREST anon/auth has 3s/8s.** Heavy seq-scans over `listings_snapshots` (8M rows) / `seatgeek_*_snapshots` compete for shared_buffers + IO and can tip otherwise-fast user-facing RPCs past their 8s ceiling (observed: `/api/broker/movers` 500 while an MCP 7-day scan ran). **Mitigations**: `SET statement_timeout='Ns'` on audit queries; prefer indexed predicates (`WHERE event_id IN (...)`, `event_id + captured_at`) over date-range seq-scans; use `latest_event_metrics` (matview, ~1k rows) instead of scanning `listings_snapshots` for "latest per event". |
| `exos_events.occurs_at_local` (D4/Exos) | naive wall-clock timestamp | **Offset-bearing TEXT** `"YYYY-MM-DDTHH:MM:SS±HH:MM"` (e.g. `2026-05-21T20:00:00-04:00`) — mirrors `public.events`; derive via `utcToOccursAtLocal()`. The create flow MUST set `occurs_at_local` + `event_type` or they land NULL (shape-consistent ≠ value-consistent). |
| `exos_events.event_type` (D4/Exos) | fine-grained map / "complete" every row | **Coarse category map only**: Sports→`game`, Music→`concert`, Arts→`show`; Nightlife/Tech/Food→`NULL` (matches the ~60% of TEvo rows that are NULL — don't backfill it). |
| `exos_tickets` barcode/QR (D4/Exos) | store the barcode or QR payload | **Not stored** — only `barcode_secret` (plaintext HMAC key, RLS-gated to owner/buyer/staff). QR is computed + rotated **client-side** as `HMAC-SHA256(secret, "ticketId:ownerId:bucket")`. |

---

## 4. Canonical SECDEF RPCs (the hot 15 of 32)

| RPC | Args | When to call |
|---|---|---|
| `get_broker_event_page_v2(p_event_id, p_chart_hours)` | int, int (default 720) | **D0 Phase 2a primary**. 11 payload keys incl. sales_tape/weather/espn/sg_side_by_side/splits/freshness. Email-gated `@s4kent.com`. ~185ms. |
| `get_broker_event_page(p_event_id, p_chart_hours)` | — | v1; v2 composes it for base payload |
| `get_event_chart_extended(p_event_id, p_chart_hours, p_espn_home_team, p_espn_away_team)` | int, int (default 168), text, text | **D0 chart expansion (PR #237 / mig 20260519150000)**. 5 SG-side time-series (listings_median/owned_median/listings_count/sales_median/sales_count) + 2 ESPN annotation arrays (injuries LAG(status) per athlete league-scoped + game_state LAG(status_short)). Adaptive bucket (15min..1d). Auto-resolves home/away from `espn_event_date_lookup` if not passed. Returns `sg_hidden:true` for TEvo-only events. ~308ms warm @ 7d. |
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
| `exos_queue_mail(p_template, p_ref_id)` | text, uuid (default NULL) | **D4 transactional mail** (mig 20260520160000). Server-derives `to_email` + body from the related record — no open relay. Templates: `transfer-initiated`/`transfer-claimed` (refId=transfer.id), `org-invite` (refId=invite.token), `event-cancelled`/`event-updated` (refId=ticket.id, staff only), `event-announce` (refId=event.id, followers, via `exos_announce_to_followers`), `ticket-issued` (refId=ticket.id, via `exos_queue_ticket_issued`). SECDEF + auth check. Rows land in `exos_mail` as `status='pending'`; drained by `exos-mail-drain` edge fn (deployed 2026-05-24). |
| `exos_follow_org(p_org_id)` / `exos_unfollow_org(p_org_id)` | uuid | **D4 org follows** (mig 20260520140000). Idempotent (`ON CONFLICT DO NOTHING`); `followers_count` counter updated atomically only on actual insert/delete — cannot drift. SECDEF. |
| `exos_create_org(p_name, p_slug)` | text, text | **D4 org bootstrap** (mig 20260520120000). Only path to create an org; seeds owner membership. Validates slug uniqueness. SECDEF. |

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

### `LANGUAGE sql` function bodies are validated at CREATE (declare after their tables)
A `LANGUAGE sql` function body is parsed **and its table/column references validated at CREATE time** — unlike `LANGUAGE plpgsql`, whose body is deferred to first call. So a SQL-language helper that reads a table must be declared **after** that table exists in the same migration, or apply fails with `ERROR: relation "..." does not exist`. Caught in D4 mig `20260520130000`: `exos_holds_ticket()` (LANGUAGE sql) was declared before `exos_tickets` and failed apply; fixed by moving it below the table. plpgsql RPCs are immune (deferred validation), which is why they can be defined before the tables they touch.

### `sg_broker_pending` — drains via 5-min priority cron
The bounded-drain functions (`sg_broker_listings_process(p_limit=50)` / `sg_broker_sales_process(p_limit=50)`) run from the 5-min priority crons (rebased 1min→5min per mig 20260519120000). The 30-min variants were unscheduled 2026-05-17 (redundant). If you need to drain faster ad-hoc, pass a larger `p_limit`. Pending rows whose `_http_response` has been pruned (>6h old) are housekept by `sweep_all_expired_pg_net_pending` at `:20` hourly.

The bounded-FIRE functions (`sg_broker_listings_queue` / `sg_broker_sales_queue` / `sg_priority_poll_tick`) were burst-size-capped to 8/8/6 events per call per mig 20260519140000 to fit under SG's 10-req/8s quota — see the pg_net pattern macro below.

### pg_net rate-limiting pattern (burst cap, NOT pg_sleep)
```sql
-- ❌ WRONG (no-op): pg_sleep inside a loop doesn't pace pg_net's async dispatch
FOR r IN <select> LOOP
  SELECT net.http_get(...) INTO v_req;
  PERFORM pg_sleep(0.9);  -- has no effect on HTTP dispatch timing
END LOOP;

-- ✅ RIGHT: cap LIMIT to ≤ upstream token quota; let cron frequency drive throughput
-- e.g. SG quota = 10 req / 8s, so:
FOR r IN <select> ... ORDER BY ... LIMIT p_max_events  -- cap at 8 in cron caller
LOOP
  SELECT net.http_get(...) INTO v_req;  -- async-dispatched; bucket sees 8 < 10
END LOOP;
-- Then schedule cron @ */5 * * * *  (5min >> 8s reset; bucket refills between firings)
```
**Throughput math**: (burst × firings/hr) ≥ inflow_rate. SG sustained: 96 listings + 96 sales + 72 priority = 0.73 req/sec << 1.25 req/sec quota.

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

### "I am D4 — how do I call a write RPC?"
All D4 mutations go through SECURITY DEFINER RPCs — **never raw `.insert()`/`.update()` on base tables** (anon-EXECUTE revoked on all 10 write-path RPCs; mig 20260520230000). Authenticated callers invoke via `supabase.rpc()`.
```typescript
// ✅ Correct — SECDEF RPC (requires authenticated Supabase session)
const { data, error } = await supabase.rpc('exos_create_org', {
  p_name: 'My Org', p_slug: 'my-org', p_description: null,
});

// ❌ Wrong — authenticated base-table writes are REVOKED on write tables
await supabase.from('exos_orgs').insert({ name: 'My Org' });
```
**Available write RPCs** (migs 20260520120000 + 20260520130000):
| RPC | Purpose |
|---|---|
| `exos_create_org(p_name, p_slug, p_description)` | Bootstrap org + auto-profile + add caller as owner |
| `exos_claim_invite(p_invite_id uuid)` | Accept an org invite (joins org at invited role) |
| `exos_mint_tickets(p_tier_id, p_qty, p_buyer_profile_id)` | Staff/admin comp-ticket path — enforces tier cap + event cap + purchase limit (mig 20260523180000); admin bypasses all |
| `exos_check_in_ticket(p_ticket_id, p_event_id, p_barcode_payload, p_secret)` | Scan-in — 4-arg (mig 20260523160000): server HMAC verify + ±2-bucket tolerance via `extensions.hmac()`. Atomic double-scan guard → `exos_scan_rejects` |
| `exos_create_transfer(p_ticket_id, p_recipient_email)` | Initiate ticket transfer |
| `exos_cancel_transfer(p_transfer_id uuid)` | Cancel pending transfer |
| `exos_claim_transfer(p_transfer_id uuid)` | Recipient accepts transfer |
| `exos_void_ticket(p_ticket_id uuid, p_reason text)` | Void ticket (admin/staff) |
| `exos_assert_purchase_limit(p_event_id, p_buyer, p_qty)` | Pre-check purchase limit (raises on breach) — call before mint in paid path |
| `exos_queue_ticket_issued(p_ticket_id uuid)` | Queue `ticket-issued` confirmation mail to ticket owner (mig 20260523210000) |
| `exos_notify_event_holders(p_event_id uuid, p_template text)` | Bulk-queue `event-cancelled`/`event-updated` to all non-voided holders (staff/admin) |
| `exos_issue_ticket_to_email(p_event_id, p_tier_id, p_recipient_email, p_qty, p_order_ref)` | Look up/create user by email → mint tickets → queue confirmation. Idempotent on `order_ref` |
| `exos_redeem_discount_code(p_event_id uuid, p_code text)` | Validate promo/access code → `{valid, type, value, unlocks_tier_ids, remaining}` (read-only; consumption at mint) |
| `exos_announce_to_followers(p_event_id uuid)` | Bulk-queue `event-announce` to all org followers (staff/admin, published events only) |

**Read access**: `lib/events.ts`, `lib/orgs.ts`, `lib/tickets.ts` read the base tables directly (RLS enforces own-org scoping). Public/cross-org reads go through `exos_public_*` VIEWs (anon + authenticated).

**Auth pattern**: `supabase.auth.signInWithOtp()` / `supabase.auth.signInWithOAuth()` — NOT Firebase Auth. Session persists via `localStorage` (configured in `lib/supabase.ts`).

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
| **2026-05-19** | 20260519000000 | **D0 weather localized RPC**: `get_event_weather_localized(p_event_id)` returns venue-localized forecast (`v_event_weather_with_fallback`) + NWS alerts filtered to event's UGC zones (`v_event_nws_alerts`). Replaces v3 RPC's global-alert behavior. Email-gated. |
| 2026-05-19 | 20260519010000 | **D0 SG zones/splits RPC**: `get_event_sg_zones_splits(p_event_id)` per-section rollup (min/median/max broadcast_price + listings + tickets) + per-quantity-bucket splits (singles/pairs/triples/quads/five_plus) over 24h deduped SG listings. Bridge via `seatgeek_event_xref`. Email-gated. |
| 2026-05-19 | 20260519100000 | **SG sales DISTINCT ON view cleanup**: 4 views (`seatgeek_event_latest`, `unified_orders`, `v_aq_match_quality`, `v_orphan_seatgeek_data`) were aggregating without DISTINCT ON sg_sale_id, silently 11–23× overcounting. Rebuilt with proper dedup. 2 dependents (`unified_orders_by_event`, `order_status_coverage`) recreated unchanged. Spot-check: event 3091415 sales_count went 8,431 → 368; unified_orders sg_sales rows went 1.82M → 121K. |
| 2026-05-19 | 20260519110000 | **SG broker 429-aware pipeline**: processors set `sg_broker_pending.rows_persisted = -429` (re-queueable) vs `-1` (terminal failure) vs `>=0` (success row count). 429 rows auto-retry on next firing instead of staying terminal. Sentinel feeds the 429 monitoring views in mig 130000. |
| 2026-05-19 | 20260519120000 | **SG priority crons 1min→5min**: `sg_priority_poll_tick_5min`, `sg_priority_listings_process_5min`, `sg_priority_sales_process_5min` renamed with staggered minute offsets. Reduces pg_cron load + 429 collision risk. Tier policy (240s/300s/1800s) still governs per-event cadence; cron just wakes the driver. |
| 2026-05-19 | 20260519130000 | **SG broker 429 monitoring protocol**: `v_sg_broker_429_health` (hourly pct_429 rollup over 24h), `v_sg_broker_429_starved_events` (events 429'd 3+ times with no recent success), `check_sg_broker_429_health()` with hysteresis-protected bot_chat flag @ pct_429 > 15%. 15-min cron `sg_broker_429_health_check_15min`. |
| **2026-05-19** | 20260519140000 | **🔥 SG broker burst-size emergency hotfix (PR #228)**: caps burst to 8 events/call on `sg_broker_listings_queue` + `sg_broker_sales_queue` (3+3 polls on `sg_priority_poll_tick`) — under SG's 10-token bucket. Drops broken `PERFORM pg_sleep(0.9)` calls (no-op given pg_net async dispatch — see §3 landmine + §7 macro). New schedules: listings `*/5`, sales `2-57/5`, poll_tick `4-59/5`. pct_429 went 70.7% (02:00 hour) → 0.0% on every firing 02:50 onward. Sustained 0.73 req/sec << 1.25 req/sec quota. |
| 2026-05-19 | 20260519150000 | **D0 chart expansion RPC (PR #237)**: `get_event_chart_extended(p_event_id, p_chart_hours DEFAULT 168, p_espn_home_team text, p_espn_away_team text)` returns 5 SG-side series (listings_median/owned_median/listings_count/sales_median/sales_count over adaptive 15min..1d buckets) + 2 ESPN annotation arrays (injuries LAG(status) per athlete league-scoped; game_state LAG(status_short) per espn_event_id). Auto-resolves home/away from `espn_event_date_lookup` (forward-look) → `espn_event_snapshots` (gameday) when not passed. SECDEF + email gate. Landmine surfaced: `espn_team_id` collides cross-league (id=28 = MLB + NHL); RPC scopes by `espn_league`. Codified in §3 + §4. Latency 308ms warm @ 7d. |
| 2026-05-19 | _(app code, no migration)_ | **D1 storefront movers reshape (PR #275)**: `/api/store/movers` response shape changed from `{events, rest}` (single strip + grid + label-bucket round-robin from PR #273/#274) to **4 themed-slider arrays**: `moving_fast` (SG sales ≥10 OR TEvo d24h ≤ -50), `price_drops` (retail_min < 0.7× SG median), `climbing` (TEvo `getin +5%` AND d24h<0, OR SG median +5% AND listings -5%), `specials` (`v_event_holidays` window match OR `v_rivalry_events` match, gated `owned > 100`). First 3 sections gate `owned > 50`. `_compute_movers` builds one candidate pool; each section filter is independent (event can appear in 0-2 sections). Label-bucket helpers (`_movers_compute_labels`, `_round_robin_pop_by_label`, `_LABEL_PRIORITY`, etc.) retired. v_rivalry_events dedupe rule codified in §3. |
| **2026-05-20** | 20260520400000 | **Featured-pricing 10-min cron (PR #288)**: `collect_listings_featured_refresh(p_max_events int DEFAULT 50)` + cron `collect-listings-featured-10min` (`3-53/10`). Refreshes TEvo `/v9/ticket_groups` for NYC venue + `owned>100` + 24h–90d events (superset of the storefront Featured rail) every 10 min, fixing the ~6h–multi-day pricing staleness from the twice-daily windowed crons. Round-robins oldest-`captured_at`-first, skips <9min-fresh + 0-24h events. Writes land in `event_metrics`; matview `latest_event_metrics_refresh_5min` (@`:2`) makes them visible. ~5,760 extra TEvo calls/day. |
| 2026-05-20 | 20260520410000 | **`compute_event_breakdowns` non-fatal (PR #289)**: self-caps zone+section steps at 6s (under the 8s `authenticator` ceiling), traps **`query_canceled` explicitly** (bare `WHEN OTHERS` misses 57014 — see §3 landmine), soft-fails a slow step → returns status jsonb instead of erroring. Stops the false 502s on heavy events (`collect-listings` calls this AFTER pricing persists; the RPC timeout was 502-ing pulls whose pricing already succeeded). |
| 2026-05-20 | 20260520420000 | **Breakdowns backfill re-enable + extend (PR #290)**: re-enables `zone-backfill-isolated-10min` cron + upgrades `backfill_stale_zone_metrics` to recompute BOTH zone+section (was zones only), detect staleness via the `latest_event_metrics` matview (not an 8M-row `listings_snapshots` scan), and trap `query_canceled`. Out-of-band catch-up for heavy events that soft-fail the inline 6s RPC. **Known gap**: the heaviest events (1300+ listings) exceed even the 90s cap — `compute_event_zone_metrics`'s per-row `match_performer_zone()` LATERAL needs dedup optimization (tracked, §10). |
| **2026-05-22** | 20260520120000 | **D4/Exos phase-1 — APPLIED to prod 2026-05-22** (B1 sign-off PR #304). `exos_*` orgs+events schema (profiles/orgs/org_secrets/memberships/invites/events/ticket_tiers/discount_codes + `bridge_event_xref`). Deny-by-default RLS, all 9 tables RLS-enabled; base-table grants REVOKE'd from anon + re-GRANT CRUD to authenticated (own-org only per RLS). Cross-org browse via `exos_public_*` VIEWs. Org bootstrap via `exos_create_org()` SECDEF. 0 rows — schema ready, data cut-over pending. |
| **2026-05-22** | 20260520130000 | **D4/Exos phase-2 — APPLIED to prod 2026-05-22** (B1 sign-off PR #304). `exos_tickets`/`exos_transfers` + check-in + scan-reject audit logs + 6 write-path SECDEF RPCs (mint/check-in/transfer/cancel/claim/void). Atomic tier-claim closes oversell; atomic status-flip closes double-scan. All 8 write-path RPCs: anon-EXECUTE revoked (mig 20260520230000 same day). 0 rows — ready for first mint. See §8 D4 write-path recipe. |
| **2026-05-22** | 20260520200000 | **SG broker 60d+ polling — APPLIED (PR #251)**. `sg_events_canonical.last_60d_pulled_at` column + `sg_broker_60d_plus_{listings,sales}_queue(p_max_events int DEFAULT 8)`. 4 crons: `sg_60d_listings_morning` / `sg_60d_sales_morning` (UTC 4-9, ~576 events/day each) + `sg_60d_listings_afternoon` / `sg_60d_sales_afternoon` (UTC 17-19, ~288 events/day each). Round-robins oldest-`last_60d_pulled_at`-first; drains via existing priority process crons. Closes the 60d+ gap: Yankees-Mets/Dodgers/Red Sox (35 games had 0 SG data before). 98.8% event coverage within 24h. |
| **2026-05-23** | 20260520140000 | **D4/Exos phase-3 — org follow graph — APPLIED (PR #308, B1-cleared)**. `exos_org_follows(follower_uid, org_id)` PK + `exos_orgs.{description, followers_count}` + `exos_public_orgs` view refresh (adds bio + count). `exos_follow_org` / `exos_unfollow_org` SECDEF RPCs — idempotent `ON CONFLICT DO NOTHING`, counter updated atomically only on real change. anon REVOKE'd from table; SELECT granted to authenticated. |
| 2026-05-23 | 20260520150000 | **D4/Exos phase-4 — media storage bucket — APPLIED (PR #308, B1-cleared)**. `exos-media` public bucket (5 MB cap). SVG excluded — SVG carries executable script; on a public bucket a direct object URL executes in the storage origin (hosted XSS, B1 SEC-MED bot_chat #438). Path-scoped RLS: `event-images/{uid}/…` → own-uid gate; `org-logos/{orgId}/…` → org-membership gate. Update/delete limited to object owner. |
| 2026-05-23 | 20260520160000 | **D4/Exos phase-5 — transactional mail queue — APPLIED (PR #308, B1-cleared)**. `exos_mail` table (RLS on, zero client policies — service_role drainer only). `exos_queue_mail(p_template, p_ref_id)` SECDEF RPC server-derives `to_email` + body from the related record — open relay closed (B1 SEC-HIGH bot_chat #438, commit 3dc943f fixed 5 column/role refs). 5 templates: transfer-initiated/claimed, org-invite, event-cancelled/updated. Mail rows land as `status='pending'`; drainer (edge fn + email provider) is the next D4 milestone. |
| 2026-05-23 | _(app code, no migration)_ | **D4/Bridge blank-app fix (PR #316)**: previous `static/bridge/` builds had `VITE_SUPABASE_URL`/`VITE_SUPABASE_ANON_KEY` unset at build time — Supabase client initialised with empty strings, app rendered blank. Rebuilt with prod keys baked in via `d4_bridge/.env.local` (gitignored). **Landmine**: these Vite env vars must be present in `.env.local` whenever a new Bridge build is cut. |
| 2026-05-23 | _(app code, no migration)_ | **Bridge as 4th hub surface (PR #318)**: `static/home/index.html` gets a Bridge card (violet `#c084fc`, always unlocked — Bridge handles own auth). Grid updated 3-col → 2×2. `static/home/home.js` shows a soft note when signed out; hides it when any session exists. |
| 2026-05-23 | _(app code, no migration)_ | **Railway as Bridge primary host (PR #319)**: Bridge card now links to `/bridge/` (same Railway origin) instead of the external Render URL. Same-origin `localStorage` means the hub's Supabase session auto-carries-over to Bridge — one sign-in for all four surfaces. `app.py` route comment updated. |
| 2026-05-23 | 20260523120000 | **D4/Bridge Realtime multi-lane check-in + SW scope fix (PR #322)**: `exos_event_checkins` added to `supabase_realtime` publication (idempotent). `OrganizerCheckIn` subscribes to `postgres_changes` INSERT — remote check-ins propagate to all door lanes in ~1s (RLS-gated to org staff, closes double-admit race D4-OPS-10). Reconnect re-pull (offline→online) closes offline gap. SW `BASE` now derived from `self.location.href` — `/bridge/` prefix handled correctly. manifest.json paths all prefixed. CSV voided label fixed. Load harness validated: 6-lane stampede on 50 tickets → 0 double-admits. |
| **2026-05-24/25** | 20260523130000–20260524160000 | **D4 free-first batch — APPLIED to prod (A1 session 2026-05-25).** 10 migrations in dependency order: |
| | 20260523130000 | **Mail drainer schema**: `exos_mail` adds `sending` status + `attempts`/`claimed_at`/`last_attempt_at` cols + `exos_mail_claimable_idx`. `exos_mail_claim_batch(p_limit, p_max_attempts)` + `exos_mail_mark(p_id, p_ok, p_error, p_max_attempts)` — service_role-only, FOR UPDATE SKIP LOCKED for concurrent-safe drain. |
| | 20260523150000 | **Event-level oversell cap**: `exos_events.total_tickets` int (0 = uncapped). `exos_mint_tickets` enforces cap before minting. |
| | 20260523160000 | **Server HMAC barcode verify**: `exos_check_in_ticket` upgraded to 4 args (adds `p_event_id uuid`, `p_barcode_payload text DEFAULT NULL`). When payload present, verifies rotating-QR HMAC server-side via `extensions.hmac()` with ±2-bucket tolerance — rejects forged/expired QRs before the DB write. |
| | 20260523180000 | **Per-person purchase limits**: `exos_assert_purchase_limit(p_event_id, p_buyer, p_qty)` pre-check (raises on breach). `exos_mint_tickets` superset: enforces tier cap + event cap + purchase limit atomically; admin/service-role bypasses all caps. |
| | 20260523200000 | **Growth primitives** (applied modified — `exos_distribution_listings` ALTER skipped, dormant table): `exos_orgs.marketing jsonb` (social handles, pixels, shareImageUrl); `exos_redeem_discount_code(p_event_id, p_code)` → validity + type + unlock tier IDs; `exos_announce_to_followers(p_event_id)` → bulk-queues `event-announce` mail to all org followers (staff-gated, published events only). |
| | 20260523210000 | **Ticket-issued mail**: `exos_queue_ticket_issued(p_ticket_id uuid)` → queues purchase-confirmation `ticket-issued` mail to owner. Extends `exos_mail_template_check` with `ticket-issued`. Caller must be owner OR org staff. |
| | 20260523220000 | **Notify holders**: `exos_notify_event_holders(p_event_id, p_template)` → bulk-queues `event-cancelled` or `event-updated` to all non-voided ticket holders (org staff / admin only). |
| | 20260523230000 | **Issue to email**: `exos_issue_ticket_to_email(p_event_id, p_tier_id, p_recipient_email, p_qty, p_order_ref)` → looks up or creates Supabase user by email, mints `p_qty` tickets, queues confirmation. Idempotent on `order_ref`. Admin / org staff only. |
| | 20260524150000 | **Public marketing view**: `exos_public_orgs` refreshed to expose `marketing` jsonb (social handles + pixel IDs + shareImageUrl). Anon-readable. |
| | 20260524160000 | **Security hardening**: `exos_touch_updated_at()` trigger fn pinned `search_path = public, pg_temp` (Supabase advisor: `function_search_path_mutable`). `exos_has_org_role` anon-EXECUTE revoked via `REVOKE FROM anon, PUBLIC` (Supabase advisor: `anon_security_definer_function_executable`). Internal RLS/SECDEF callers unaffected. |
| 2026-05-24/25 | _(edge fn)_ | **`exos-mail-drain` deployed** (v1, ACTIVE, `verify_jwt=false`): reads `exos_mail` claim batch → Resend API → `exos_mail_mark`. Cron `exos-mail-drain-2min` (`*/2 * * * *`) work-check-gated via `cron_policy.work_check_sql`. ⚠️ Awaiting operator: `RESEND_API_KEY` + `EXOS_MAIL_FROM` secrets in Supabase edge-fn dashboard. |
| 2026-05-25 | _(app code, no migration)_ | **static/bridge rebuild**: `d4_bridge/` rebuilt locally and synced to `static/bridge/` — captures PRs #336 (consent banner basename + spinner), #338 (CreateEvent doors→show/end auto-fill), #339 (back-camera scanner + wallet QR timer). Render now serves current bundle; Railway redundant. |
| **2026-05-25** | _(app.py, no migration)_ | **Camera Permissions-Policy for `/bridge` (PR #340)**: `app.py` shell now includes `camera` in the `Permissions-Policy` response header for the `/bridge/*` route, enabling the door-scanner's `getUserMedia` camera prompt. Without it, the browser silently blocked the API regardless of FE code. |
| **2026-05-25** | _(FE only, needs rebuild)_ | **D4/Bridge FE batch — PRs #341–342** (static/bridge must be rebuilt+deployed): **#341** — wallet QR stamp `REDEEMED` renamed to **`ENTERED`** with "Scanned \<time\>" subline (fallback "SCANNED") on both `TicketDetail` + `WalletPass`; wording only, mute+auto-refresh unchanged. **#342** — (a) TRANSFER link disabled (greyed, with reason label) for `used`/`voided`/`pending` tickets — UX mirror of server-side `exos_create_transfer` `status='active'` guard; (b) "Inside Venue" counter on `OrganizerCheckIn` now shows `countEventCheckins(eventId)` (realtime scanned-in head-count via existing Realtime subscription) instead of `ticketsSold`. |
| **2026-05-25** | 20260523170000 _(dormant — not applied, not deployed)_ | **D4 Stripe backend completion (PR #344)**: two gaps closed in the scaffold. (1) `exos_fulfill_checkout` now queues `ticket-issued` mail to buyer after minting — exception-safe (mail hiccup can't unwind the mint). (2) New `exos_refund_checkout(p_session_id, p_reason)` service-role RPC: voids still-**active** tickets, frees inventory (`tier.sold` + `event.tickets_sold` decremented), idempotent, leaves scanned tickets untouched; wired to `stripe-webhook` on `charge.refunded`. `'refunded'` added to session status CHECK. **All dormant — gated on Stripe creds.** Activation checklist: apply mig (branch-validate first), deploy `exos-checkout`/`stripe-webhook`/`exos-connect-onboard` (`--no-verify-jwt`), set `STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET`, add `charge.refunded` + `checkout.session.completed` to webhook endpoint, B1 review. |
| 2026-05-25 | _(docs only)_ | **D-tier governance docs (PRs #347/#348)**: `docs/d_tier_goals.md` — operator-ratified north-star per lane (D0=trading desk, D1=secondary→D4-discovery eventual, D2=sales-data backend, D3=data source, D4=venue arm+ticket infra, E1=betting pool). `docs/d_tier_unification_plan.md` — B1-reviewed + goals aligned; §0.5 adds D1 sequencing reconcile flag (secondary-first vs v1 D1↔D4 loop; pending operator confirm). |
| 2026-05-25 | _(app code)_ | **TEvo Fernet barcode decrypt (PR #351)**: `evo_client.decrypt_barcode(barcode, secret)` — Fernet-decodes encrypted barcodes from TEvo `/v9/orders` + `/v9/listings` (key = `base64url(secret[:32])`). Lazy `cryptography` import so broker read pipeline loads without dep; only the call site needs it. `requirements.txt`: `cryptography>=46.0.5,<49.0` — clears `GHSA-r6ph-v2qm-q3c2` (SECT curve subgroup attack, HIGH, first-patched 46.0.5). Tests: `tests/test_evo_barcode.py`. No consuming surface wired yet. |
| **2026-05-25** | _(security — migrations + harness)_ | **B1 anon data-leak sweep (PRs #350/#354 + harness PR #352)**: Full enumeration of ~150 anon-readable view/matview surface found 14 SECDEF objects owned by `postgres` (`rolbypassrls=true`) readable by anon (publishable key) — live broker-intel leak (3,681 rows from `v_event_price_arbitrage`, 1,411 from `latest_event_metrics` matview) + latent order-PII (`unified_orders` 0 rows now; activates when orders flow). Root cause: Supabase auto-grants `ALL` to `anon` on every new public view/matview; PR #298 (functions/tables) never swept views/matviews. **PR #350**: `REVOKE ALL … FROM anon` on 12 views + 2 matviews (`authenticated`/`service_role` untouched; D2 dashboard + storefront unaffected). **PR #354**: `REVOKE EXECUTE FROM anon` on 5 residual ungated SECDEF functions (advisor sweep). **PR #352**: new harness `anon_secdef_relation_audit()` + Phase-2 KANBAN policy-gate — detects future anon-on-SECDEF regressions. Verify fix: `SET ROLE anon; SELECT * FROM public.v_event_price_arbitrage LIMIT 1;` → `permission denied`. |
| 2026-05-25 | _(app code, D1, DORMANT)_ | **D1 TEvo Hosted Checkout — wired but dormant (PR #353)**: `app.py` + `static/store/` wired to redirect secondary-market purchases to TEvo's hosted checkout page. **Env-gated**: fires only when `TEVO_CHECKOUT_ENABLED=true` (not set in prod). Activation = set the env var on `vibepass-storefront-test` + verify TEvo checkout URL scheme. No DB migration; no B1 gate (read-only redirect). |
| 2026-05-25 | _(app code, D4, DORMANT)_ | **D4 Stripe fulfillment idempotency (PR #359)**: `exos_fulfill_checkout` / `stripe-webhook` tightened — persists `'failed'` status on crash (no dangling session), idempotent terminal-state guard (replay `checkout.session.completed` on already-`fulfilled`/`failed` = no-op; closes double-mint on webhook replay). Cherry-picked orphan from `claude/d4-stripe-backend` (committed post-PR-#344 merge). Still dormant — same gate as PR #344. |
| 2026-05-25 | _(deps)_ | **Dependabot dep bumps (PRs #355–#358)**: `actions/setup-python` 5→6; `uvicorn` patch; `anthropic` patch; `fastapi` patch. All within `requirements.txt` pinned `<` ranges; no API surface changes. |

---

## 10. Drift watchlist (known gaps — don't waste cycles rediscovering)

| Gap | Status | Symptom / workaround |
|---|---|---|
| `tevo_event_id` populated on SG snapshot tables | Partial: PR #178 backfilled to 87.35%; mig 20260517160000 ensures NEW rows are born populated where xref exists | Query by `sg_event_id` when `tevo_event_id IS NULL` (no xref) |
| `seatgeek_event_xref.last_listings_at`/`last_sales_at` | Dead globally (0/967) | Use `MAX(captured_at)` on snapshot tables |
| `sg_events_canonical.has_v2_listings_pulled` | Dead (25/4609 = 0.5%) | Same |
| ESPN snapshot pipeline = gameday-scope only | (specced, not built) | Forward-look ESPN panels empty by design. Use `espn_event_date_lookup` for forward-look team IDs / game_at_utc. |
| 29% active TEvo events have no SG bridge | NWSL/USL/AHL/niche real gap | First-class TEvo-only UI state |
| SG doesn't carry most NFL regular-season | SG coverage decision | NFL Event Detail renders TEvo+ESPN+AQ; SG hidden |
| `aq_short_event_id` 0% on `listings_snapshots` | Cron resumed 2026-05-16; firing 04:02 UTC | Use `event_id` for TEvo reads |
| `compute_event_zone/section_metrics` too slow for heavy events | Open (tracked task) | Per-row `match_performer_zone()` LATERAL exceeds even 90s for 1300+ listing events (Yankees). Their zone/section breakdowns stay stale; non-fatal RPC (mig 410000) just soft-fails them. Fix = dedup zone match (compute once per distinct section/row). 54.7% of DB time per 2026-05-14 audit. |
| D4 Firestore → Supabase cut-over | **CLOSED 2026-05-23** — no migration needed | Operator confirmed all Firestore data was test-only. `exos_*` tables start at 0 rows. Remaining: `src/types.ts` Timestamp shim. |
| D4 SW scope mismatch (D4-OPS-1) | **CLOSED 2026-05-23** — PR #322 | SW `BASE` derived from `self.location.href`; all manifest.json paths `/bridge/`-prefixed. |
| D4 `exos-mail-drain` — RESEND creds unset | **Open — awaiting operator** | `RESEND_API_KEY` + `EXOS_MAIL_FROM` must be set in Supabase edge-fn secrets dashboard. Cron work-check-gated (silent until pending rows exist). |
| D4 Railway decommission | **Open** | `static/bridge/` current as of 2026-05-25 rebuild. Railway service can be deleted once confirmed healthy on Render. |
| D4 Stripe backend dormant (PRs #344/#359) | **Open — gated on Stripe creds** | Mig `20260523170000` + edge fns `exos-checkout`/`stripe-webhook`/`exos-connect-onboard` not applied/deployed. Activation checklist in §9 PR #344 entry. |
| D1 TEvo Hosted Checkout dormant (PR #353) | **Open — env-gated** | Code merged; fires when `TEVO_CHECKOUT_ENABLED=true` on `vibepass-storefront-test`. Set env var to activate. |
| D4 `static/bridge/` needs rebuild for PRs #341/#342 | **Open — FE-only** | PRs #341 (ENTERED stamp) + #342 (transfer gate + inside-venue counter) merged but `static/bridge/` bundle not yet rebuilt. Run `npm --prefix d4_bridge run build` + `cp -r d4_bridge/dist static/bridge` + commit. |
| B1 anon-SECDEF surface (PR #352 harness) | **Ongoing — harness live** | `anon_secdef_relation_audit()` now runs in CI; any new SECDEF view/matview auto-granted to anon will surface. Zero findings post-PRs #350/#354. |

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
