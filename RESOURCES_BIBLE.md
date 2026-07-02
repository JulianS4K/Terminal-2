# RESOURCES_BIBLE.md — resource catalog

> **Doc version:** v2.10.0 (2026-07-01; §5: per-source freshness SLA monitor — `record_source_freshness()` on the 5-min health cadence, `source_freshness` checks on the D0 health page, mig `20260701221500`). Full prior doc-version history → [`docs/archive/2026-07-02-doc-version-history.md`](docs/archive/2026-07-02-doc-version-history.md).

What exists: services, DB inventory, secrets (names only), taxonomy + data RULES. Companion: ownership → `PROJECT_BIBLE §2`; cross-source ID architecture → `PROJECT_BIBLE §5`; per-session rules + column landmines → `PROJECT_BIBLE §3`; migration mechanics → `MIGRATION_CONVENTIONS`.

**Before creating any table/view/RPC/cron/edge-fn: check it doesn't already exist.** This doc lists key objects by domain; for the FULL set query the DB (it is source of truth — this doc is the roadmap):
```sql
SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND relkind IN ('r','v','m');           -- tables/views/matviews
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND prokind='f';                        -- functions
SELECT jobname,schedule,active FROM cron.job;                    -- crons
```

## 0. Live counts (snapshot 2026-06-19; verify via queries above)

| Object | Count |
|---|---|
| base tables | 212 |
| views | 178 |
| matviews | 4 |
| functions | 536 |
| crons | 164 (151 active) |
| edge functions | 29 (`supabase/functions/`, excl. `_shared`) |

Common name collisions before authoring: `*_metrics`, `*_xref`, `v_event_*`, `v_sg_*`, `*_pending`, `*_snapshots`.

---

## 1. External services + integrations

| Service | Purpose | Owner | Where | Secret (name only) |
|---|---|---|---|---|
| **Supabase** | Postgres + Edge + Vault + Auth | A1 | project `hzrizjeaxlqcxfrtczpq` | anon + service_role (anon exposed via `/api/public/config`) |
| **Render** | FastAPI + static hosting | D0 (D1 sub) | `srv-d8140bnaqgkc73al4asg` | env-side |
| **Sentry** (opt-in) | error tracking / exception capture | B1 | `core/observability.py` (`init_sentry`) | `SENTRY_DSN` (env; **inert until set** — no-op + zero behavior change without it) |
| **TEvo** (TicketEvolution v9) | listings/orders feed | A1 | `evo_client.py` | `TEVO_API_TOKEN`, `TEVO_SECRET` |
| **SeatGeek** | marketplace + seller data | A1 | `seatgeek_client.py`, `sg_*` tables | `SEATGEEK_API_TOKEN` |
| **SeatData** | wholesale sales feed | A1 | `seatdata_client.py`, `seatdata_*` | `SEATDATA_API_KEY` |
| **TicketsData** (SH/VD/GT/TP/TM) | cross-platform listings | A1 | `ticketsdata_client.py`, `td_*` | `TICKETSDATA_USERNAME`/`_PASSWORD` |
| **AXS** (primary box office, veritix) | primary on-sale seat-level (via TD `/fetch?platform=axs`) | A1 | `axs_client.py`, `axs_*` | reuses TICKETSDATA creds |
| **TickPick / Vivid / GoTickets** | order/listing clients | A1/D3 | `tickpick_client.py`/`vivid_client.py`/`gotickets_client.py` | per-client |
| **Broadway.com** | availability scrape | D3 | `broadway_client.py`, `broadway_extension/` | `BROADWAY_USER_AGENT` (opt) |
| **ESPN** | schedules/scores/injuries | A1 | `espn*` edge fns, `espn_*` | none (public) |
| **NOAA/NWS** | weather + alerts | A1 | `nws_*`/`weather_*` | none |
| **Open-Meteo** | weather observations/forecast | A1 | `weather_observations` | none |
| **Wikipedia** | performer metadata | A1 | `wiki-collect`, `performer_wikipedia` | none |
| **FRED** | macro indicators | A1 | `macro_*`, `fred_*` | `FRED_API_KEY` (free) |
| **Stripe** | Exos checkout/payments | D4 | `stripe-webhook`, `exos-checkout` | `STRIPE_*` (D4) |
| **GitHub** | source + PR surface | A1 | `JulianS4K/Terminal-2` | PAT (Bash only) |
| **pg_net** | async HTTP from SQL | A1 | ext `pg_net 0.20.0` + `_cron_invoke_edge_fn` | vault |

Reddit: PAUSED 2026-05-13 (tables `reddit_*` retained, crons dropped). Railway: legacy deploy home, migrating off → Render.

**Render landing:** `/` serves the VibePass **5-surface hub** (`static/home/index.html` — Terminal/Undelivered/Orders/Store/Bridge, auth-gated) on the `vibepass-storefront-test` web service (`uvicorn server:app`, `branch: main`, `autoDeploy`, `STOREFRONT_AS_LANDING=false`); the `vibepass-terminal-test` static CDN redirects `/`→`/home/` to the same hub. Set `STOREFRONT_AS_LANDING=true` to revert `/`→`/store`. Frontend has a Playwright browser net (`tests/frontend/`, `frontend-smoke` CI job) over the hub + store + terminal pages.

**Shared `*_client.py` layer (BR-CODE-2):** the 9 read-only clients share three `core/` modules instead of hand-rolled copies — `core/readonly_guard.py` (the RULE-2 GET-only guard body; **security-CRIT** — see `PROJECT_BIBLE §2.6`), `core/http_retry.py` (`fetch_with_retry`: 429/5xx Retry-After→capped-exponential-backoff loop; evo/seatgeek/seatdata/tickpick/vivid/gotickets use it; axs fixed-delay + broadway scraper opt out), `core/vault.py` (`vault_secret`: the `get_app_secret` Vault resolver used by seatgeek/seatdata/ticketsdata/axs). Each client still declares its own auth + parse + the per-file RULE-2 tokens.

---

## 2. Tables by domain (key only; full list = query pg_class)

**Reads are by `tevo_event_id` everywhere downstream; source tables are native-keyed + AQ-derived `tevo_event_id` (often NULL on fresh rows). Map via AQ hub — see `PROJECT_BIBLE §5`. Never join raw source IDs.**

### 2.1 Events / cross-source hub
`events` (TEvo canonical, 1/event), `event_xref` (TEvo↔ESPN), `aq_event_map` (**THE cross-source hub** — PK `aq_short_event_id`; carries tevo/sg/sh/vivid/tm ids; N rows can share one tevo_event_id — dedupe+validate), `sg_events_canonical` (SG↔TEvo), `ticketsdata_event_xref` (TD; `event_id` is platform-native NOT tevo), `seatgeek_event_xref`, `seatdata_event_xref`, `canonical_external_ids` (**dormant** — not the hub), `entity_xref_overrides`/`_conflicts`, `event_match_attempts`, `event_pulls`, `event_alerts`.

### 2.2 Listings (firehoses — query carefully)
| Table | Size | Key | Time col | Notes |
|---|---|---|---|---|
| `listings_snapshots` | 48 GB / ~9M | `event_id` | `captured_at` | TEvo firehose; ours = `is_owned AND brokerage_id=1768`; `aq_short_event_id` 0% pop |
| `seatgeek_listings_snapshots` | 13 GB | `sg_event_id` | `captured_at` | SG; price=`broadcast_price`; `tevo_event_id` 0% pop |
| `seatgeek_sales_snapshots` | 7.5 GB | `sg_sale_id` | `sale_at_utc`(actual)/`pulled_at`(ingest) | **MANDATORY DISTINCT ON (sg_sale_id) — 11–23× overcount** |
| `ticketsdata_listings_snapshots` | 7.6 GB | `aq_short_event_id`+`platform` | `captured_at` | SH/GT/VD/TP/TM |
| `seatgeek_seller_listings` | — | `seller_listing_id` | — | OUR SG SellerDirect inv |
| `seatdata_listings_snapshots` | — | — | — | dormant |

Config: `collector_cadence` (per-(source,scope,band) poll intervals), `evo_listings_poll_state` (per-event EVO clock; SG reuses `sg_event_priority_state.last_fired_listings_at`). `tevo_ticket_groups_cache` (5-min TTL). `listing_xref`.

### 2.3 Orders / sales (forever retention; native-keyed)
`evo_orders`(+`evo_order_items` — `event_id` IS tevo id), `seatgeek_orders`(+`_tickets`,`_resolved`), `tickpick_orders`, `vivid_orders`, `seatdata_sales_snapshots`, `seatgeek_historic_sales`, `order_status_xref`, `order_fee_schedule`. Map to tevo via `backfill_order_tevo_from_aq()` (hourly :40).

### 2.4 Aggregates / metrics
`event_metrics` (172 MB; per-event-per-capture; 120d TTL), `section_metrics` (8.1 GB; 60d), `zone_metrics` (45d), `seatgeek_event_metrics` (cols `listings_all_*`/`listings_owned_*`/`sold_*`; NOT `cost_*`), `latest_event_metrics` (matview, ~1k rows — use for "latest per event"), `event_listing_snapshot_daily` (3 slots/day, INDEFINITE retention, cross-source medians + `amalgam_*`), `event_movers_index`(+`_history`,`_agg`), `discovery_gap_alerts`, `performer_baselines`/`venue_baselines`/`performer_metrics_daily`/`venue_metrics_daily`.

### 2.5 Cross-source maps (canonical IDs: `tevo_performer_id`/`tevo_venue_id`)
Performer: `entity_performer_map` (**start here** — PK tevo_performer_id, espn ids, home_venue_ids[], genre), `performer_external_ids`, `seatgeek_performer_xref`, `seatdata_performer_xref`, `performer_espn_team_xref`, `aq_performer_map`, `espn_teams_canonical`. Venue: `venue_assets` (**start here** — PK tevo_venue_id, is_indoor, capacity, lat/lon, espn+nws fields), `entity_venue_map`, `seatgeek_venue_xref`, `seatdata_venue_xref`, `aq_venue_map`, `cross_source_venue_map` (use `cross_source_venue_resolve(name,city,state)`). Other: `taxonomy_xref`, `broker_xref`, `matchup_xref`, `team_xref`(view).

### 2.6 ESPN
`espn_event_snapshots` (gameday-scope), `espn_event_date_lookup` (forward-look), `espn_injuries_snapshots` (627 MB — `ORDER BY ... LIMIT 1`, never no-WHERE max()), `espn_athletes`/`_athlete_team_history`, `espn_team_snapshots`, `espn_teams_canonical`, `espn_news`, `espn_runs`, `espn_tournament_events`, `*_pending`, `sporting_rivalries`, `mlb_branded_series`, `holidays`, `school_break_windows`, `major_event_calendar`. **RULE 1: always scope by `espn_league` (team_id reused across leagues).**

### 2.7 Weather
`weather_observations` (232 MB; Open-Meteo; `is_forecast` flag), `nws_alerts` (250 MB), `nws_alert_zones`/`_references`/`_pending`, `weather_forecast_pending`, `venue_nws_points_pending`.

### 2.8 Performer/venue metadata
`performer_metadata` (branding + espn_team_id), `performer_wikipedia`, `performer_home_venues`, `performer_zones`(+`_rules`)/`zone_rules`, `important_x_accounts`, `why_signals`, `venue_assets`, `venue_section_map` (+ `seatmap_manifest`).

### 2.9 Chat/NLU
`chat_corpus`, `chat_aliases`, `chat_term_freq*`, `chat_audit_findings`, `chat_rate_limits`/`_stopwords`/`_glossary_known`.

### 2.10 Storefront / watchlist
`share_links`, `watchlist`/`event_watchlist`, `watch_sources`, `user_alerts`, `concierge_events`, `world_cup_2026`, `wc_price_daily`, `leads` (HARD RESTRICT — no auto-purchase).

### 2.11 Exos / Bridge (D4)
`exos_events`, `exos_orgs`/`_org_memberships`/`_org_follows`/`_org_invites`/`_org_secrets`, `exos_tickets`/`_ticket_tiers`, `exos_transfers`, `exos_profiles`, `exos_mail`, `exos_discount_codes`, `exos_event_checkins`/`_scan_rejects`, `bridge_event_xref`. **Barcode: only `barcode_secret` stored, QR computed client-side.**

### 2.12 Coordination / governance / macro / TD
`bot_chat` (cross-lane log; `bot_chat_log()`/`_resolve()`), `bot_messages`/`bot_users`, `settings`, `data_sources`/`data_source_field_map`, `macro_indicators`/`macro_series_config`/`fred_pending`, `td_*` (`td_pull_queue`, `td_match_queue`/`_results`, `td_discover_targets`, `td_{gt,tp,tm,sg}_performers`, `td_poll_policy`/`_failures` — **tier enqueue RETIRED 2026-06-30; `collector_cadence`+`td_enqueue_peak` is authoritative, see §5.1**), `cron_policy`/`cron_gate_decisions`, `health_*`.

### 2.13 Pending/queue pattern
`*_pending` (12+; cron backfill queues), `*_pull_log`/`*_pull_budget`/`pull_rate_limits`.

### 2.14 Retention ladder (mig 20260531180000 + 20260603190000)
raw `listings_snapshots` 15d · other raw snapshots 30d · `event_metrics` 120d · `section_metrics` 60d · `event_section_rows` 30d · `espn_injuries` 90d · `event_listing_snapshot_daily` INDEFINITE · order tables forever.

### 2.15 AXS (primary box office)
Primary ticketer NOT resale. axs.com hosts primary+dead pages → `/fetch?platform=axs` probe is the discriminator (`body.meta.api='veritix'` ⇒ primary). Tables: `axs_events` (registry; `probe_status`, `tevo_event_id`), `axs_event_snapshots` (1873 MB; per-pull; `raw`), `axs_section_snapshots`, `axs_seat_snapshots` (722 MB; per-seat), `axs_venues` (341 pegged to tevo_venue_id), `axs_probe`. **Landmines: amounts in CENTS (/100); `9000000…` offerIDs = resale; `occurs_at_local` offset-naive ±1d; `tevo_event_id` AQ-derived (NULL until `axs_apply_aq`).** Map: `axs_aq_match()` (±48h). Pipeline: cron `axs-probe-drain` (1min, serial); **AXS fetches route through `ticketsdata.com/fetch?platform=axs` = TD credits, and now LOG to `ticketsdata_credit_usage` (platform='AXS') at ingest via `axs_probe_step` (mig 20260630160000); true per-fetch cost ≈1 (see `v_td_credit_cost_per_call`).** Grouping: `v_axs_seat_groups` (gaps-and-islands consecutive seats → blocks), `v_axs_listings` (EVO listing standard).

---

## 3. Matviews (4)
`latest_event_metrics` (5min refresh; per-event latest; feeds `/api/store/events`; anon-exposed by design), `v_dashboard_writes_24h` (24h write velocity; high refresh cost — flagged), `mv_sg_blindspot_movers`, `mv_tevo_blindspot_movers` (10min refresh).

## 4. Views (178; patterns)
- Canonical: `v_canonical_{event,performer,venue}`, `v_canonical_coverage[_v2]`/`_drift`, `sg_canonical_match_view`, `cross_source_{coverage,event_audit}`.
- Event-context: `v_event_*` (~40 — full/sports/weather/injuries/espn_state/calendar/competitors/rivalries/velocity/why_context/…). Product-boundary: `broker_event_*` (full) vs `retail_event_*` (S4K-owned, no wholesale).
- Listings/orders: `unified_listings`, `unified_orders`(+`_by_event`), `our_orders`(+`_by_event`/`_with_net`), `v_market_listings_by_event`, `v_pricing_cross_source`.
- SG: `seatgeek_event_latest`, `v_sg_*` (sales_by_{event,section}, broker_sales_by_*, historic_*, events_by_status, token_budget, broker_429_health, blindspot_*).
- Health/ops: `v_cron_health`, `v_pg_net_queue_health`, `v_bot_chat_unresolved`, `v_dashboard_{coverage,freshness}`, `v_macro_indicators_{health,latest}`, `v_td_poll_health`.
- AXS: `v_axs_{listings,seat_groups,events_classified,venues_mapped,venues_unmapped}`.
- TD credit accounting (mig 20260630160000): `v_td_credit_usage_by_platform` (daily per platform), `v_td_credit_usage_mtd` (MTD+today), `v_td_credit_cost_per_call` (true per-call cost via quota deltas, partitioned by counter-group `{SH}`/`{VD,GT,TM}`/`{AXS}`; AXS now in-ledger).

## 5. Crons — catalog + scheduling policy (177 total / 156 active; full list = `cron.job`)
**Categories:** listings pollers (`evo_listings_poll_2min`, `sg_listings_poll_owned_1min`, `sg_sales_poll_5min`, `collect-listings-*`), orders (`evo_orders_*`, `sg_seller_*`, `vivid_orders_*`; tickpick OFF), matchers (`cross_source_match_tick_30min`, `auto_match_sg_canonical_v3_hourly`, `match_events_to_espn_10min`, `backfill-order-tevo-from-aq-hourly :40`, `*-search-bridge`), TD (`td_pull_drain` 1m, `td_normalize_drain` 2m, `td_match_drain`/`sg-match-map-tick`, `td_enqueue_peak_{sh,vd,gt,tm,tp,sg}` staggered — **`td_tier_enqueue_*` RETIRED 2026-06-30, see §5.1**), ESPN/weather/wiki/venue crawl, snapshots (`event_snapshot_{morning,midday,evening}`, `compute_movers_index_post_snapshot`), sweeps (`sweep-old-*` retention, `sweep_*_pending`), AXS (`axs-probe-drain`), Exos (`exos-mail-drain-2min`), macro (`fred_*`). **High DB-time (flagged):** `master-cascade-2min` (OFF), `zone-backfill-isolated-10min`, `dashboard_writes_24h_refresh`.

**Constraints:** `cron.max_running_jobs=32` (not raisable), `use_background_workers=off` (each job = a backend vs `max_connections=60`); a >2-min job holds a slot. **Keep peak concurrent ≤20** (leave ~12 for future lanes). "job startup timeout" in `pg_cron.log` = budget blown.

**Tiers:** T0 storefront-critical `*/10` (≤4) · T1 near-live `*/10–20` (≤10) · T2 standard `*/30` staggered (≤30) · T3 daily 03–06 UTC (≤20) · T4 weekly Sun (≤10). Stagger minute offsets within a tier (no two on the same mark; avoid saturated `:02/:05/:07`).

**Per-event listings model (collector-cadence):** one ~2-min tick/source reads `collector_cadence` (`collector_band(source,scope,hours)`, peak-aware) + per-event clocks (`evo_listings_poll_state`; SG reuses `sg_event_priority_state.last_fired_listings_at`); fires only due events. Cadence by horizon — EVO (≈unlimited): ≤7d 15m…61d+ 12h; SG (rate-limited): ≤7d 1h…31d+ 24h. SG owned/non split (owned=tight ACTIVE, non=once-daily OFF). **SG token ≈5 req/10s, SHARED with an external prod program** → `tick(p_max=5)`, backs off on `ratelimit-remaining`, clock advances only on HTTP 200; watch `v_sg_token_budget`/`v_sg_broker_429_health`. Trading-hours: **TD peak ET 09:00–01:59** (data-derived from SG sales, `is_peak()`) + per-source leapfrog + 250k-real/cycle phased budget — **full TD model in §5.1**. SG broker token serial-metronomed per shared token (consumers phase-offset by minute). Cadences live in `collector_cadence` (data → instant revert). **EVO tick ordering = band-priority** (mig `20260701191500`): due events ordered `required_min ASC, overdue_ratio DESC` — the tightest-cadence (nearest-event) band is served first every tick, so the ≤3d/5-min band is never starved by chronically-stale far-out events (pure `overdue_ratio DESC` let a 30-day-stale 6-mo-out event outrank a 25-min-stale ≤3d one). **Metrics fed to D0:** `listings_snapshots` → `event_metrics` (per-pull, ~real-time) → `latest_event_metrics` matview (10-min refresh); `zone_metrics`+`section_metrics` via `backfill_stale_zone_metrics` (`zone-backfill-isolated-10min`, RE-ENABLED bounded @ p_max=20, mig `20260701192000`) — heavier per-event compute, so rolling stalest-first (~120 ev/hr), not per-pull.

**New cron:** wrap body with `cron_should_fire('jobname')`; INSERT a `cron_policy` row; verify peak ≤20; new lane defaults to T2.

**Live cron roster (UI):** the D0 health page (`static/terminal/health.html`) renders **every** scheduled job (active + inactive) with 24h run health — `get_health_dashboard()` returns a `crons[]` array (jobname, schedule, active, runs/ok/fail 24h, pct_ok, latest_error, derived status off/idle/ok/warn/fail), built from `cron.job` ⨝ `cron.job_run_details` (mig `20260630270000`; mirrors the `v_cron_health` rollup but includes inactive jobs). **Per-source freshness SLAs (mig `20260701221500`):** `record_source_freshness()` (piggybacked on `health_monitor_5min`) writes a `source_freshness` check row per source every 5 min — newest-row age vs SLA (evo_listings 10/30m · evo_event_metrics 20/60m · zone_section 45/180m · td 8h/26h · axs 12h/36h · sg 90m/6h) — status `off` when the source's poller cron is intentionally inactive (doesn't trip the overall banner); `warn`/`fail` when a source goes silently stale (the SG-dark-for-2.5-days failure mode).

**Scheduler-wedge protection (mig `20260701182336` + `20260701190000`; `server.py`).** With `use_background_workers=off`, ONE cron job that runs unbounded holds an open txn that blocks `cron_should_fire()`/the launcher → the WHOLE scheduler freezes (happened 3× on 2026-07-01, ~13h degraded). Two-layer defense: **(1) self-bounding loops** — every per-event cron loop now carries a loop-level wall-clock budget (`EXIT WHEN clock_timestamp()-v_start > interval 'Ns'`), because a per-iteration `SET LOCAL statement_timeout` is a **no-op** on the running statement (only a top-level `SET statement_timeout` before the call caps it; the cron commands carry that — see `PROJECT_BIBLE §3`). Bounded: `backfill_stale_zone_metrics` (90s), `evo_event_backfill_queue`/`sg_event_backfill_queue` (60s). **(2) durable watchdog** — `scheduler_watchdog_kill_stale_backends(p_stale_minutes=6,p_min_active_seconds=300)` (SECURITY DEFINER, service_role-only; self-guards: no-op unless `max(cron.job_run_details.start_time)` is stale) is polled every ~60s by `_scheduler_watchdog_loop()` in the always-on FastAPI service (the one place that survives a DB-side freeze); on a wedge it terminates the long-running client backend holding the launcher and records a `scheduler` row to `health_check_history`. Manual status: `GET /api/admin/scheduler-watchdog/status` (auth-gated). **`orphan_event_backfill_queue_15min` + `midnight-catchup-sweep` stay DISABLED** — re-enable is gated on the deferred orphan-scan index build + observing runs complete under budget.

### 5.1 TD/AXS sourcing model — credit-budgeted (redesign 2026-06-30, migs `20260630160000`–`250000`)
- **Budget = one plan pool, billing cycle resets the 9th** (NOT calendar month) → `td_credits_this_cycle()`. Gate `td_budget_ok()` = `td_daily_budget_ok()` AND `td_monthly_budget_ok()`, both compared in **REAL** credits via the measured **1.276× real:recorded ratio** (recorded ledger undercounts — non-200s burn quota unlogged). **Phased by date:** until 7/9 = 300k plan (loose, 40k/day·300k cycle real — burn expiring surplus); from 7/9 = **8k real/day · 248k/cycle** (just under the 250k pool). `/fetch` = 1 credit; `/match` = 12 credits + 1 Market-Intel report (separate report cap, 2,000/mo plan).
- **Cadence = peak/off-peak, data-derived.** `is_peak()` = ET **09:00–01:59** (≈93% of SG realized sales; off-peak 02:00–08:59), DST-safe. `collector_band('TD',scope,hrs)` returns peak/offpeak interval, × a date-gated **phase-A ×0.6 boost** (TD-only, until 7/9). Per-source enqueue crons **leapfrog** at even 2-min offsets: SH`:00` · VD`:02` · GT`:04` · TM`:06` · AXS`:08`.
- **Breadth ladder + non-owned policy** — `td_should_poll(platform,hours,owned)`: SH all bands · VD all(owned)/≤30d(non-owned) · **GT ≤30d · TP ≤3d** · TM=MSG-only(venue 896) · SG=temp burn. **Non-owned capped at 1 poll/day** (interval floored 1440m; SG exempt); owned = full ladder; `enqueues_today ≤ 4/day/(event,platform)`.
- **Consolidation:** `td_enqueue_peak_*` (collector_cadence) is the ONLY enqueue path; duplicate `td_tier_enqueue_*` (td_poll_policy tiers) **disabled/retired**. `td_enqueue_peak` date source is robust (sgc → `events.occurs_at_local` → `aq.event_date`) so it covers SH-mapped-but-no-SG events the tier path used to carry.
- **Enrollment:** `td_seed_mapped_xref(limit,apply,owned_only)` enrolls AQ-mapped events on SH/VD (URL templated from sh/vivid id, owned-first); GT via discovery; TM seeded for MSG. **AXS:** own probe `axs-probe-drain` (fires `* * * * *` but **peak-only** body — `is_peak`+`td_budget_ok` gated — calling `axs_probe_step(p_refresh_hours=>6)` ⇒ ~4 pulls/day per confirmed-AXS event during peak; off-peak fire removed 2026-06-30 mig `20260630260000`); charges the TD ledger at ingest. **Outage note:** TD `/fetch?platform=axs` returns HTTP-200 `{"status":500,"error":"Scheduled maintenance ..."}` during upstream maintenance → probe logs `non_json`, 0 veritix/snapshots; the function's 30-min non-veritix backoff throttles re-fires; cadence resumes automatically on recovery.
- **Mapping chain (grow SH coverage):** EVO→SG (FREE: `sg_canonical_auto_match`/`sg_to_tevo_search_bridge`) → TD `/match` (`sg-match-map-tick`, **SeatGeek-anchored**) fills `sh_event_id` → seed → poll. `sh_event_id` is writable ONLY by `/match`.
- **Temporary (auto-reverts 7/9):** TD-SeatGeek surplus burn (`integration_policy.td_seatgeek_emergency_override=true` + `td_enqueue_peak_sg` enrolling ~1,948 events) — `td_sg_burn_teardown` cron re-arms the kill-switch + deactivates SG xref on/after 7/9.

## 6. Edge functions (29; `supabase/functions/`)
**Data pipeline (A1):** `collect`, `collect-listings`, `espn`, `espn-collect`, `espn-rosters`, `crawl-espn-team-assets`, `crawl-venues-and-performers`, `backfill-event-configurations`, `wiki-collect`, `seatdata-poll`, `seatmap-manifest-sync`, `match-sg-performers-to-tevo`, `tevo-perf-find`, `tevo-blindspot-discovery`, `aq-to-tevo-search-bridge`, `sg-to-tevo-search-bridge`, `sg-seller-webhook`, `bulk-add-watchlist`, `seed-home-venues`, `why-noaa-weather-alerts`, `chat`, `alert-mail-drain`.
**Exos (D4):** `exos-api`, `exos-checkout`, `exos-connect-onboard`, `exos-distribute`, `exos-mail-drain`, `exos-webhook-drain`, `stripe-webhook`.
**Auth landmine (`PROJECT_BIBLE §1` rule 7):** platform `verify_jwt=true` accepts the public anon JWT → data-mutating / paid-API fns MUST add body-level `requireCronSecret()` from `_shared/cron-auth.ts`.

## 7. Vault secrets (names only — never values)
`CRON_SECRET`, `EDGE_FN_ANON_JWT`, `TEVO_API_TOKEN`, `TEVO_SECRET`, `SEATGEEK_API_TOKEN`, `SEATDATA_API_KEY`, `TICKETSDATA_USERNAME`, `TICKETSDATA_PASSWORD`, `FRED_API_KEY` (free), `STRIPE_*` (D4). Rotation: `CRON_SECRET` 128-char, 3-way sync (vault+Edge+Render); legacy JWTs → `sb_publishable_*`/`sb_secret_*`.

**Observability env (Render env-side, not vault):** `SENTRY_DSN` (unset = error tracking off), `SENTRY_TRACES_SAMPLE_RATE` (default `0.0`), `LOG_LEVEL` (default `INFO`). Wired in `core/observability.py`; the app logs structured stdout always and only sends to Sentry once `SENTRY_DSN` is set.

**Resilience env (Render env-side, not vault; production-readiness P0/P1, 2026-06-26):**
- `SUPABASE_TIMEOUT_SECONDS` (default `30`, clamped `[1,120]`) — bounds the PostgREST/storage/function per-request timeout so a Supabase blip fails fast instead of piling up → OOM. Wired in **`core/db.py`** (`make_supabase_client`), used by `server.py` to build `sb`.
- `DB_CIRCUIT_FAIL_THRESHOLD` (default `5`) + `DB_CIRCUIT_RESET_SECONDS` (default `30`) — the shared Supabase **circuit breaker** in **`core/resilience.py`** (`CircuitBreaker` + `resilient_call` + `safe_read`); `server.py._db_breaker` is surfaced on `/healthz` as `db_circuit` and storefront reads go through `safe_sb_read` (stale-snapshot fallback; `store_home` first-paint uses it).
- `REDIS_URL` (unset = in-process limiter) — when set + reachable, **`core/ratelimit.py`** (`make_rate_limiter`) swaps the in-process `_IPRateLimiter` for a Redis fixed-window backend (multi-instance safe). **Set this + `SESSION_SIGNING_SECRET` before scaling past 1 dyno.**
- `SESSION_SIGNING_SECRET` (falls back to `CRON_SECRET`, then an ephemeral per-process key) — pins the `vp_human` cookie HMAC key so signed cookies survive across instances (`core/auth.py`).

## 8. Extensions
`plpgsql`, `pgcrypto`, `uuid-ossp`, `pg_cron 1.6.4` (`max_running_jobs=32`, `use_background_workers=off`), `pg_net 0.20.0` (async — `pg_sleep` does NOT rate-limit it), `pg_stat_statements`, `pg_trgm`, `unaccent`, `supabase_vault`. Absent (enable via migration if needed): postgis, vector, http(sync), pgmq, pg_partman.

## 9. HTTP API surface (`server.py` + `routers/*`; full: `grep '@app\.\(get\|post\|delete\)' server.py routers/*.py`) — renamed from app.py 2026-06-26 (entrypoint `uvicorn server:app`)
- **Public storefront `/api/store/*`** (D1): `events`(+`/{id}`,`/zones`,`/near`), `search`, `movers`, `share`(+CRUD), `reserve` (MOCK — never charges). `/api/public/config` (anon key).
- **Terminal/broker `/api/broker/*`** (A1+D0, 40+): `event/{id}/{overview,zones,section-metrics,raw-tevo,chart-data,cadences,espn}`, `movers` (v2 `?window_days=&source=&category=`), `performer/{id}/assets`, `news`, `leagues`. Plus `/api/{events,performers,venues,configurations,portfolio,watchlist}`, `/api/axs/event/{id}/{listings,sections,series}`, `/api/collect/run`, `/api/admin/*`.
- DB platform statement_timeout 120s (overridable); MCP runs service_role (NO timeout cap → bound audit scans).
- **Code map (BR-CODE-1 decomposition — where each route group lives):** `server.py` (shell + the big broker/store blocks still inline) + dedicated `routers/*`: `shares.py` (`/api/store/share*`), `seatmap.py` (`/api/store/seatmap/*`), `retail_chat.py` (`/api/(store/)retail-chat`), `store.py` (`/api/store/events/{id}` (+`/zones`)), `catalog.py`, `lists.py`, `broker.py`, `seatdata.py`, `axs.py`, `seatgeek.py`, `misc.py`, `site_essentials.py`. Shared store SQL-only/listing helpers → `core/store_events.py` (`fetch_event_from_db`, `fetch_owned_ticket_groups[_from_db]`, `build_zone_resolver`); `resolve_event_with_filters` (the event-detail composer) is now in `core/store_events.py` too (patchable collaborators injected); the `/api/store/*` event-detail **routes** are still in `server.py`, now unblocked to lift into a router. One-directional import: `core` never imports `server`.

## 10. Cross-cutting data RULES (durable)
**RULE 0 — categorize new data.** New table/column/feed/metric/price-source → add to this doc's domain (§2) + assign a §11 bucket, same PR as the schema change.

**RULE 1 — ESPN `team_id` is league-scoped.** IDs reused across leagues (`18` = NBA Knicks AND MLB Pirates AND NFL Saints…). EVERY ESPN query filters `(espn_team_id, espn_league)` together. Omitting league returned 229 rows where 12 were real. Corollary: `is_baseline` only reliable for MLB/NHL — verify before filtering.

**RULE 2 — upstream APIs strictly READ-ONLY.** Canonical statement: `CLAUDE.md §2`. Enforcement (3 layers): runtime `_assert_readonly_method()`+`ALLOWED_HTTP_METHODS=frozenset({"GET"})` in each `*_client.py`; static `scripts/check_readonly.py` (CI); `tests/test_readonly_guards.py`. Sole carve-out: SeatData `POST /event-request-add` (metadata, no S4K/price/inventory data). New client → copy guard pattern + add to `CLIENT_FILES` + mirror tests + list in §1.

**RULE 7 — retail product = S4K-owned only.** Storefront surfaces only events we hold inventory for. `/api/store/*` carveout: `we_own`/`owned_tix`/`owned_groups_count` intentionally exposed (availability signals); broader `is_owned`/wholesale/`brokerage_*` stripping still applies to broker/terminal responses.

## 11. Data buckets (feature vocabulary)
Core (10): 1 Pricing (`event_metrics`/`zone`/`section_metrics`: retail_*/getin/wholesale) · 2 Inventory volume · 3 Owned position (`brokerage_id=1768`) · 4 Splits/format · 5 Market structure · 6 Standings/form (`espn_team_snapshots`) · 7 Player health (`espn_injuries_snapshots`) · 8 Game context (`espn_event_snapshots`) · 9 News/narrative (`espn_news`/`wiki_*`/`why_signals`) · 10 Map/config (`events`/`performer_zones`/`venue_assets`/`v_broker_configurations.fanvenues_key`).
ML feature groups (7): 11 Temporal/calendar · 12 Demand/popularity · 13 Historical/narrative · 14 External signals (`why_signals`) · 15 Brokerage microstructure (not yet a metrics table) · 16 Classification (§taxonomy) · 17 Major event calendar (`major_event_calendar` — F1/NASCAR/majors; no team performer).

## 12. Classification taxonomy
`performer_metadata.top_category_name` (4): Concerts, Sports, Comedy, Theater. Derived: `what_event_type` (game/concert/comedy/show), `genre` (~13, non-game), `events.event_type`. Sports leaves: Football(NFL/NCAA/UFL…), Soccer(MLS/NWSL/WC/EPL…), Baseball(MLB/MiLB), Basketball(NBA/WNBA), Hockey(NHL/AHL/PWHL), Fighting(MMA/WWE/Boxing), Auto. **Behavior gates:** HOME/AWAY + ESPN context only for `what_event_type='game'` w/ `performer_home_venues`/`espn` source. **ESPN coverage:** full (performer+event pages) NBA/MLB; performer-page-only NFL/NHL/MLS/WNBA/WC; none for NCAA/MiLB/Fighting (gameday ingest = NBA+MLB only — known gap).

## 13. Intentionally NOT here (query directly)
Indexes (`pg_indexes`), constraints/triggers, RLS policies (`pg_policies`; A1 lane), edge-fn source (`supabase/functions/<slug>/index.ts`), frontend file inventory (`docs/d0_terminal_build.md §B2`), full table/view/fn/cron enumeration (§0 queries).

Owner: A1. Refresh after any PR adding/removing a service, secret, or domain-key table; refresh §0 counts quarterly (B1-NEXT-25).
