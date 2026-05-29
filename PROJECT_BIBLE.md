# PROJECT_BIBLE.md — operating playbook for all bots

> **Doc version:** v1.1.0 · baseline 2026-05-28 (A1). Section-level version + bot-ref convention → [`README.md`](README.md) *Doc-writing rules*.

**Last updated**: 2026-05-28 by A1 — **governance reconciliation** (B1 appraisal): §1 rule 4 + §6 Render-write row now state D0's workspace-wide Render parity with A1 (2026-05-16), resolving the §1↔§2↔§6 scope contradiction. | prior: 2026-05-28 by D0 — **doc consolidation**: §5 cross-source topology → pointer to `D0_BIBLE.md §3` (canonical owner); §9 landmark log → `MIGRATION_CONVENTIONS.md §14`; §10 drift → `KANBAN.md`; §2 roster → `BOT_HIERARCHY.md`, D4 block → `docs/d4_bridge_charter.md`; +2 verified §3 landmines (`public.events.occurs_at_local` is TEXT; `bid_ask_proxy` dropped). | prior: §5e/§5f performer+venue mapping chains; mig 380000 TD↔TEvo linkage; D0_BIBLE.md created; bot reorg + prod fixes 350000–370000
**Read this FIRST every session.** Saves ~5× the tokens vs reading every governance file at start.

This doc is the **operating playbook** — rules, macros, recipes, landmines. For the **inventory** (what exists: tables, views, crons, edge functions, vault, services), read `RESOURCES_BIBLE.md`.

**⚠ BEFORE CREATING ANY NEW TABLE / VIEW / RPC / CRON / EDGE-FN — check `RESOURCES_BIBLE.md` first.** 132 tables + 152 views + 75+ crons + 40+ edge fns already exist. Recurring waste: re-implementing `event_metrics`, `*_xref`, `*_pending`, `v_event_*` patterns when one already exists. Quick check: `SELECT relname FROM pg_class JOIN pg_namespace n ON n.oid=relnamespace WHERE nspname='public' AND relkind IN ('r','v','m')` — search the output for keywords before authoring.

| Need | Read |
|---|---|
| **What's open right now? (all lanes, severity-sorted)** | **`KANBAN.md §🟢 OPEN WORK` — single source of truth, populate-as-you-go, delete-when-fixed** |
| What can I do? Hard rules, hierarchy, macros, recipes | **This file** |
| What exists? Tables/views/crons/edge-fn inventory | `RESOURCES_BIBLE.md` |
| **D0-specific: table inventory, cross-source links, ops health, diagnostic SQL** | **`D0_BIBLE.md`** |
| Where's each lane going? (north-star + endgame) | `docs/d_tier_goals.md` |
| Who can push to where? | `BOT_HIERARCHY.md` |
| How do I apply a migration? | `MIGRATION_CONVENTIONS.md` |
| Security rules + lockdown invariants | `CLAUDE.md` |

---

## 1. Hard rules (you can't override these) *(v1.1 · A1 · 2026-05-28)*

1. **SQL data is read-only by default.** Any `INSERT`/`UPDATE`/`DELETE`/DDL on prod requires explicit operator permission per call. Standing exceptions: `bot_chat` writes via `bot_chat_log()`, Supabase branch creation (copy-on-write fork, no prod mutation), authoring migration files (apply gated separately).
2. **Upstream third-party APIs are READ-ONLY.** TEvo, SeatGeek, SeatData, TickPick, Vivid — GET endpoints only. No order POSTs, holds, webhook config changes without explicit operator authorization.
3. **HTML / JS in your assigned lane is free reign** — no per-step approval.
4. **Render workspace is per-service scoped** (§2 ownership matrix) — **except D0, which has workspace-wide parity with A1 (2026-05-16)**. Cross-service writes by any other lane = lane violation.
5. **A1 is sole pusher to `main`** (see `MIGRATION_CONVENTIONS.md §9`).
6. **Cross-lane file edits require coordination** via `bot_chat` `question` or PR comment to the lane owner.
7. **Edge function auth: platform `verify_jwt=true` is NOT sufficient.** It accepts ANY valid Supabase JWT — including the publishable anon JWT exposed at `/api/public/config`. Edge functions that mutate data or burn paid upstream APIs MUST add body-level `requireCronSecret(req)` from `supabase/functions/_shared/cron-auth.ts`. Pattern verified across 12 existing functions; 3 exceptions caught in B1 audit PR #172 (2026-05-16) and patched in PR #174.
8. **Check `KANBAN.md §🟢 OPEN WORK` before claiming new work.** It is the single-source-of-truth for what's currently actionable across all lanes — severity-sorted, with the smallest fix for each finding. **Fixing bot DELETES its row from that section in the same PR as the fix** (row's absence IS the closure signal; archive sections below preserve the historical detail). Populate as you go — anyone can add a row; B1 maintains for security findings, each lane for its own. Broadcast: bot_chat 311 (2026-05-17).

When in doubt → ask via `AskUserQuestion` or post a `bot_chat` question.

---

## 2. Bot hierarchy + Render service ownership

**Reorg 2026-05-28** — new mandate split; D1-E1 paused until D0 is working.

```
A1 (SQL monitor + DB ops + git + connectors · sole prod pusher)
└── B1 (security + governance monitor · bibles/git/bot-notes)
    └── C1 (D-tier project coordinator + drift prevention)
        └── D0 ← PRIORITY (Terminal FE · user visual layer · visual of A1 for user)

⏸  D1 (Consumer Retail) · D2 (Order Clients) · D3 (Broadway)
⏸  D4 (Exos/Ticketing) · E1 (Integration/Automation)
    — all paused until D0 is working —
```

**Roster — full detail (mandate · status · Render scope · push authority) is owned by `BOT_HIERARCHY.md` (single source of truth).** At a glance: **A1 · B1 · C1 · D0 = ACTIVE** (D0 is PRIORITY, workspace-wide Render parity with A1); **D1 · D2 · D3 · D4 · E1 = PAUSED** until D0 ships. A1 is sole pusher to `main`.

**Testing-unified (2026-05-16, PR #168)**: all runtime traffic flows through `vibepass-storefront-test` (starter, no cold starts) — it mounts D0 terminal + D1 storefront + D2 dashboard via `app.include_router`. `vibepass-terminal-test` is the D0 static CDN. Full deploy chain → `D0_BIBLE.md` (PART 1, deploy).

Code-dir ownership (full per-lane scope → `BOT_HIERARCHY.md`):
- D0 → `static/terminal/*` + terminal `app.py` routes
- D1 → `static/store/*` + `/api/store/*`
- D2 → `d2_dashboard/*`
- D4 → `d4_bridge/*` (Exos app) + `exos_*` / `bridge_event_xref` migrations (D4 authors; A1 applies)
- A1 → `supabase/migrations/*`, governance docs, cross-cutting

**D4 / Exos (Bridge)** — primary-market ticketing, greenfield React app on its own `exos_*` schema (Firestore→Supabase complete 2026-05-23, Firebase fully removed). Served at `/bridge/` via the unified Render service (`static/bridge/`, last rebuilt 2026-05-25). Links to canonical events **by value** via `bridge_event_xref` and **never writes D0 tables**. **Full charter, migration state, and build steps → `docs/d4_bridge_charter.md`; open D4 items → `KANBAN.md §🟢 OPEN WORK`.** D4 schema/value landmines stay in §3. (D4 is PAUSED — see roster above.)

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
| `public.events` time column | `occurs_at` (no such column) | **`occurs_at_local` is the ONLY event-time column — and it's `TEXT`** (offset-bearing `"YYYY-MM-DDTHH:MM:SS±HH:MM"`, nullable). There is NO `occurs_at timestamptz`. Cast/parse the text if you need a real timestamp. Verified vs prod 2026-05-28. |
| `bid_ask_proxy` | reference the table / view / column anywhere | **Permanently dropped — does not exist** (no table, no view, no column). Verified absent in prod 2026-05-28. Don't reintroduce reads against it; derive spread-style signals from `event_metrics` / `listings_*`. |
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
| `INSERT ... ON CONFLICT ... RETURNING` + separate DELETE to expire old rows — use `clock_timestamp()` as `v_now` | `v_now := clock_timestamp()` in DECLARE; UPSERT sets col `= now()` (transaction start) | **Transaction-start-time vs wall-clock mismatch kills the index.** `clock_timestamp()` advances continuously; `now()` is fixed for the entire transaction. If DECLARE captures `clock_timestamp()` at `T+0ms`, but the UPSERT sets `last_computed_at = now()` (transaction start, necessarily ≤ `T+0ms`), then the DELETE `WHERE last_computed_at < v_now` fires immediately after and removes every row just inserted. **Fix**: use `v_now := now()` everywhere — DECLARE + UPSERT SET + DELETE WHERE all use the same fixed transaction timestamp; rows inserted in this tx have `last_computed_at = v_now` exactly, so the DELETE condition `< v_now` is false. Diagnosed on `compute_event_movers_index` 2026-05-27: function returned 20 (inserted) but table stayed empty. |
| Postgres `format()` with float placeholders | `format('%.1f', v)` or `format('%.0f', v)` | **Only `%s`, `%I`, `%L` are valid.** `%.1f` → `unrecognized format() type specifier "."`. Numeric formatting: `round(v::numeric, 1) \|\| '%'` or `'val = ' \|\| round(v, 0)`. Discovered in `evo_sg_discovery_gaps()` 2026-05-27. |
| `SELECT DISTINCT ON (…) … UNION ALL …` | direct UNION member | **Illegal in Postgres** — `DISTINCT ON` with `ORDER BY` cannot be a direct UNION/UNION ALL member. Wrap in a subquery: `SELECT * FROM (SELECT DISTINCT ON (x) … ORDER BY x, y) qN UNION ALL …`. Discovered in `evo_sg_discovery_gaps()` 2026-05-27. |
| `bot_chat_log` first arg | `'status'`, `'info'` | **`p_level` is a bot tier, not severity**: valid values are `'admin','security','supervisor','primary-sales','secondary-sales','data-collection'`. D0 uses `'data-collection'`. Passing `'info'` → `bot_chat_bot_level_check` constraint violation. Discovered 2026-05-27. |

---

## 4. Canonical SECDEF RPCs (the hot subset)

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

For the full RPC list + arg detail + composition relationships → the migration headers (canonical source) + `D0_BIBLE.md §5` (D0-facing RPCs). Note: `RESOURCES_BIBLE.md` indexes tables / views / crons / edge-fns — it has no standalone RPC inventory section.

---

## 5. Cross-source bridge topology — see `D0_BIBLE.md §3` (canonical owner)

> **Single source of truth moved to `D0_BIBLE.md §3a–§3g` (2026-05-28).** The full ID-namespace rules, the `aq_event_map` hub diagram, the TD→TEvo 5-step resolution chain, and the performer/venue mapping chains all live there with matching detail. This section keeps only the must-know teaser so a non-D0 bot knows the rule and where to look — don't duplicate the chains here.

**The 4 rules that prevent wasted sessions:**
1. **Source IDs are source-internal — NEVER join cross-source on raw numeric/text IDs.** TEvo `event_id` (3.0–3.4M), SG `sg_event_id` (17M+), TD `event_id`, ESPN `espn_event_id` (text) never line up.
2. **`aq_event_map` is THE hub** — carries `tevo_event_id` / `sg_event_id` / `sh_event_id` / `vivid_event_id` / `tm_event_id` + `venue_short_id` + `performer_short_id`. Canonical IDs everything resolves to: **`tevo_event_id` / `tevo_performer_id` / `tevo_venue_id`** (all bigint).
3. **`aq_short_event_id` is TWO different systems** (the #1 landmine): `listings_snapshots.aq_short_event_id` = TEvo `SYS-{hex}`, **0% populated** (query by `event_id`); `ticketsdata_event_xref.aq_short_event_id` = 7-char alphanumeric (e.g. `K9KX32Z`), **100% join** to `aq_event_map`. Never join the two to each other — zero matches guaranteed.
4. **No numeric bridge → text + date match.** `performer + date` is unique (touring artists don't double-book a market same-day); sports use `home_team + away_team + date`. Never match on source-internal `venue_id` / `sg_venue_id` / `tevo_venue_id` across sources.

**Do NOT rebuild these — they already exist** (full arg detail in §4 + the migration headers):
- `cross_source_venue_resolve(name, city, state)` → `tevo_venue_id` (3-tier text match)
- `sg_attempt_event_xref_v3(...)` / `auto_match_sg_canonical_v3()` → SG→TEvo matcher v3 (±24h, parking skip)
- `refresh_td_event_links()` (mig 20260528380000) → nightly TD link sync, 5-step chain incl. text fallback
- `sg_to_tevo_search_bridge_30min` cron → fills `aq_event_map.tevo_event_id`

**D0 canonical entry** (Phase 2a):
```sql
SELECT * FROM public._v_d0_event_index WHERE sg_event_id = $1;
-- non-SG events (NFL etc.): v2 RPC resolves via event_xref fallback
SELECT public.get_broker_event_page_v2($tevo_event_id, 168);
```

**Snapshot inventory** — before proposing a new snapshot capture, check what firehoses already exist (5 live + 3 order streams + 4 specialized + 4 idle) → `RESOURCES_BIBLE.md` "Snapshot streams" + "D0 tab option matrix". Rule: there's probably already a firehose for what you want — you just need a SECDEF RPC wrapper.

---

## 6. MCP tools by lane *(v1.1 · A1 · 2026-05-28)*

| MCP family | A1 | B1 | C1 | D0 | D1 | D2 | D3/D4/E1 |
|---|---|---|---|---|---|---|---|
| Supabase `execute_sql` (read) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Supabase mutation/migration | ✓ | CRIT only | drift-monitor only | ✗ | ✗ | ✗ | ✗ |
| Supabase `create_branch` (copy-on-write) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Render: read (list/logs/metrics) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Render: write (scope per cell) | all | ✗ | ✗ | workspace-wide (2026-05-16) | storefront | dashboard | ✗ |
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

## 9. Recent landmark migrations → see `MIGRATION_CONVENTIONS.md §14`

> **Moved (2026-05-28).** The hand-curated landmark-migration log ("don't re-do shipped work") now lives in **`MIGRATION_CONVENTIONS.md §14`** — the natural home for migration provenance, and the single source of truth. Auto-generated release notes live in `CHANGELOG.md` (release-please-owned — do NOT hand-edit). This playbook no longer duplicates the log; **before authoring any migration, check `MIGRATION_CONVENTIONS.md §14` to avoid re-shipping work.**

---

## 10. Drift watchlist → see `KANBAN.md`

> **Moved (2026-05-28).** Open drift / gaps now live in **`KANBAN.md`** — the single source of truth for "what's open right now": actionable items in **§🟢 OPEN WORK** (severity-sorted), durable shape-of-the-data workarounds under **"Known data-architecture gaps (don't rediscover)"**. Resolved/shipped fixes are recorded in `MIGRATION_CONVENTIONS.md §14` + `CHANGELOG.md`. **Before treating a "discovery" as new, check KANBAN** — it's probably a known gap with a standing workaround.

---

## 11. Self-check before any task

1. ☐ Did I read this playbook (§1-§8)?
2. ☐ Is my action covered by §1 hard rules?
3. ☐ Am I editing files in my own lane (§2)?
4. ☐ Did I verify schema column names against §3 landmines?
5. ☐ For mutations: did I ask operator permission?
6. ☐ For new crons: did I wrap with `cron_should_fire`?
7. ☐ For cross-lane work: did I `bot_chat_log` a question?
8. ☐ Is my work already shipped per `MIGRATION_CONVENTIONS.md §14` (don't re-do)?
9. ☐ Is my "discovery" a known gap in `KANBAN.md` (don't waste cycles)?
10. ☐ **About to create a new doc?** STOP — the canonical doc set is CLOSED (see the README registry). Add the fact to its owning doc; never create a new root/governance `.md`; never state one fact in two places — link instead.

If YES to all → proceed. Else fall back to `RESOURCES_BIBLE.md` for inventory or `CLAUDE.md` for security rules.

---

**Refresh policy**: A1 updates this playbook when (a) new canonical RPC ships, (b) hard rule changes, (c) column-name landmine discovered, (d) landmark migration lands. Inventory deltas go in `RESOURCES_BIBLE.md`. Don't edit without A1 review (drift prevention).
