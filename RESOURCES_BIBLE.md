# RESOURCES_BIBLE.md

**Living inventory of every Terminal-2 resource — what it is, who owns it, who reads it, and where it came from. Updated 2026-05-13 (main HEAD `0a9459b`).**

Companion to `BOT_HIERARCHY.md` (which is *who* can push) and `MIGRATION_CONVENTIONS.md` (which is *how* to push). This doc is *what exists*.

Conventions:
- **Lane** = current owner per `BOT_HIERARCHY.md` (A1/B1/C1/D0/D1/D2/D3)
- **PR** = where the resource was created or last meaningfully changed. "pre-history" = predates the current PR numbering (migration timestamp in repo).
- Sizes in this doc are as of 2026-05-13; track real-time via Supabase dashboard.

---

## 1. External services + integrations

| Service | Purpose | Lane that owns the integration | Where it lives | Secret in vault |
|---|---|---|---|---|
| **Supabase** (Postgres + Edge Functions + Vault + Storage + Auth) | Primary DB and runtime | A1 (DB) + D1 (storefront uses anon key) | `hzrizjeaxlqcxfrtczpq` | (anon + service_role keys, exposed via `/api/public/config`) |
| **Render** | Hosts `vibepass-storefront-test` (`app.py` + `static/store/*`) | **D1 (sole owner)** | service `srv-d8140bnaqgkc73al4asg` | env-side, not vault |
| **TEvo** (TicketEvolution v9 API) | Live ticket inventory + (eventually) order placement | D2 (orders), D1 (storefront reads) | `evo_client.py` + `EvoClient` Python | `TEVO_API_TOKEN`, `TEVO_SECRET` |
| **SeatGeek** | Marketplace data (orders, listings, performers) | D2 | `seatgeek_*` tables + edge fn `collect` | `SEATGEEK_API_TOKEN` |
| **SeatData** | Wholesale-channel sales feed | D2 | `seatdata_*` tables | `SEATDATA_API_KEY` |
| **ESPN** (public APIs) | Sports schedules, scores, injuries, news | C1 | `espn-collect`, `espn-rosters`, `crawl-espn-team-assets` edge fns + `espn_*` tables | none required (public) |
| **NOAA / NWS** | Weather forecasts + alerts for outdoor events | C1 | `nws_alerts*`, `weather_*` tables + cron pipeline | none required |
| **Wikipedia** | Performer metadata | C1 | `wiki-collect` edge fn + `performer_wikipedia` | none required |
| **FRED** (Fed Reserve Economic Data) | Macro indicators (UMCSENT consumer sentiment, etc.) | A1 | `macro_indicators`, `macro_series_config`, `fred_*` crons | `FRED_API_KEY` |
| **Reddit** | (PAUSED 2026-05-13 — no use case) | A1 (stopped) | `reddit_posts`, `reddit_pending`, `performer_subreddits` (tables retained, crons removed) | none |
| **Google Geocode / Nominatim** | Venue lat/lng | C1 | `venue_geocode_*` pipeline | none |
| **GitHub** | Source of truth, PR review/merge surface | A1 | `JulianS4K/Terminal-2` | personal access token (Bash only) |
| **pg_net** | Async HTTP from inside Postgres (powers cron→edge fn invokes) | A1 | extension `pg_net 0.20.0` + `_cron_invoke_edge_fn` helper | reads from vault |

---

## 2. Database tables — by domain

Total: **~135 base tables** in `public`. Grouped here by purpose. Where a PR/migration is listed, that's the origin or last canonical rework.

### 2.1 Events (canonical + raw)

| Table | Size | Purpose | Owner | Key consumers | Origin |
|---|---|---|---|---|---|
| `events` | 1.9 MB / 3,433 rows | TEvo-derived canonical event list (1 row per event) | C1 | almost everyone | pre-history |
| `event_xref` | 560 kB | Cross-source event ID map (TEvo ↔ SeatGeek ↔ SeatData ↔ ESPN) | A1 | C1, D1, D2 | pre-history; refactored PR #50 |
| `seatgeek_event_xref` | 48 kB | Path B canonical resolution table for SG events | C1 | C1, D2 | PR #50 |
| `seatdata_event_xref` | 48 kB | SD ↔ TEvo event mapping | C1 | D2 | pre-history |
| `event_match_attempts` | 48 kB | Audit trail of attempted SG→TEvo matches (success/fail) | A1 | C1 | PR #50 |
| `entity_xref_overrides` | 16 kB | Manual override pins for stuck event matches | A1 | C1 | pre-history |
| `entity_xref_conflicts` | 24 kB | Detected collisions (same external id → 2 TEvo events) | A1 | C1 | pre-history |
| `event_pulls` | 96 kB | Provenance/log of every TEvo event-list pull | A1 | A1 | pre-history |
| `event_lifecycle` (view) | — | Computed status (active / ghost_eliminated / cancelled / completed) | C1 | A1 sweeps | pre-history |
| `event_alerts` | 1.6 MB | Generated user-facing alerts (price moves, sellouts, etc.) | A1 | terminal dashboards | pre-history |
| `event_sentiment` | 48 kB | Aggregated event-level sentiment scores | C1 | dashboards | pre-history |
| `event_competitors_snapshot` | 248 kB | Pre-computed "competing event in same market" snapshots | C1 | dashboards | pre-history |
| `event_section_row_snapshots` | 32 kB | Per-section-row aggregate snapshots (zone analytics) | C1 | dashboards | PR #61 |

### 2.2 Listings (ticket inventory snapshots)

| Table | Size | Purpose | Owner | Origin |
|---|---|---|---|---|
| **`listings_snapshots`** | **2.4 GB / ~9.6M rows** | Every TEvo ticket_group pulled, with retail/wholesale price + section/row | A1 (snapshots), D1 (reads via storefront fallback) | pre-history; TTL/dedup/keep5 in **PR #66**, sweeps active |
| `seatgeek_listings_snapshots` | 91 MB | SeatGeek mirror — every SG listing pulled per event | D2 | pre-history |
| `seatgeek_seller_listings` | 1.2 MB | Our own listings on the SG marketplace (broker view) | D2 | pre-history |
| `seatdata_listings_snapshots` | 32 kB | SeatData mirror | D2 | pre-history |
| `listing_xref` | 80 kB | Per-listing cross-source resolution (TEvo ticket_group ↔ SG listing) | A1 (matcher), C1 (schema) | PR #66 matcher; C1 owns the table |
| `tevo_ticket_groups_cache` | 320 kB | Short-lived TEvo ticket_groups cache (5-min TTL) for storefront reads | D1 | pre-history |

### 2.3 Sales (order tables — **never swept, forever retention**)

| Table | Size | Purpose | Owner | Origin |
|---|---|---|---|---|
| `evo_orders` | 808 kB | Our TEvo orders (raw) | D2 | pre-history |
| `evo_order_items` | 472 kB | Line items for each TEvo order | D2 | pre-history |
| `seatgeek_orders` | 1.1 MB | Our SG seller orders (raw) | D2 | pre-history |
| `seatgeek_order_tickets` | 24 kB | Per-ticket detail under each SG order | D2 | pre-history |
| `seatgeek_orders_resolved` | 248 kB | **Path B sidecar** — C1 resolves raw SG orders into canonical TEvo ids (D2 does NOT add parallel tevo_event_id writes, per row 64) | C1 | C1 phase 13 (PR #51) |
| `seatgeek_seller_listings` | 1.2 MB | Our SG listings inventory (broker view) | D2 | pre-history |
| `seatgeek_historic_sales` | 496 kB | Historic SG sales data (3-year window) | D2 | pre-history |
| `seatgeek_sales_snapshots` | 1.1 MB | Periodic SG sales snapshots | D2 | pre-history |
| `seatdata_sales_snapshots` | 144 kB | SeatData wholesale-channel sales | D2 | pre-history |
| `order_status_xref` | 64 kB | Normalize order-state names across sources | A1 | pre-history |
| `order_fee_schedule` | 32 kB | Fee math for net-revenue calculation | C1 | pre-history |

### 2.4 Aggregates / metrics

| Table | Size | Purpose | Owner | Origin |
|---|---|---|---|---|
| `event_metrics` | 13 MB / ~32K rows | Per-event-per-capture aggregate stats (medians, retail/wholesale spreads) | A1 | pre-history; **refresh path adjusted PR #71** |
| `section_metrics` | 516 MB | Per-section aggregate (largest non-snapshot table) | A1 | pre-history |
| `zone_metrics` | 15 MB | Per-zone aggregate | A1 | pre-history |
| `seatgeek_event_metrics` | 680 kB | SG-side mirror of event_metrics | D2 | pre-history |
| `latest_event_metrics` (matview) | 392 kB | Per-event LATEST row, refreshed every 5 min | A1 | **PR #71** (was a slow view, blocked storefront) |
| `v_dashboard_writes_24h` (matview) | 56 kB | 24h write velocity matview (refreshed every 60s — see advisor flag) | C1 | pre-history |
| `performer_baselines`, `venue_baselines` | 32 kB each | Pre-computed performer/venue baselines for delta calculations | C1 | pre-history |
| `seatdata_event_stats` | 32 kB | SD-side event stats | D2 | pre-history |

### 2.5 Canonical / cross-source

| Table | Size | Purpose | Owner | Origin |
|---|---|---|---|---|
| `canonical_external_ids` | 1.2 MB | Master external-id table for events/performers/venues | C1 | pre-history (C1 phase 13 work in PR #51) |
| `sg_events_canonical` | 232 kB | SG event records resolved to canonical | C1 | pre-history |
| `espn_teams_canonical` | 64 kB | ESPN team records resolved to canonical | C1 | pre-history |
| `performer_external_ids` | 528 kB | Performer-side external id map | C1 | pre-history |
| `seatgeek_performer_xref` | 192 kB | SG ↔ TEvo performer mapping | C1 | pre-history |
| `seatgeek_venue_xref` | 104 kB | SG ↔ TEvo venue mapping | C1 | pre-history |
| `seatdata_performer_xref`, `seatdata_venue_xref`, `seatdata_section_xref`, `seatdata_zone_xref` | 24-32 kB | SD-side xref tables | C1 / D2 | pre-history |
| `performer_espn_team_xref` | 96 kB | Performer ↔ ESPN team | C1 | pre-history |
| `team_xref` (view) | — | Unified team-id resolution view | C1 | pre-history |
| `taxonomy_xref` | 96 kB | TEvo taxonomy / category lookups | C1 | pre-history |
| `broker_xref` | 32 kB | TEvo broker_id → name | A1 | pre-history |

### 2.6 ESPN (sports overlay)

| Table | Size | Purpose | Owner |
|---|---|---|---|
| `espn_runs` | 1.8 MB | ESPN scoreboard pull runs | C1 |
| `espn_event_snapshots` | 848 kB | ESPN game snapshots over time | C1 |
| `espn_event_date_lookup` | 768 kB | Event-date index for ESPN lookups | C1 |
| `espn_news` | 728 kB | ESPN news feed | C1 |
| `espn_athletes` | 472 kB | Athlete master list | C1 |
| `espn_athlete_team_history` | 328 kB | Athletes ↔ teams over time | C1 |
| `espn_team_snapshots` | 296 kB | Team-state snapshots | C1 |
| `espn_injuries_snapshots` | 6.1 MB | Injury report history | C1 |
| `espn_tournament_events` | 2.6 MB | Tournament events from ESPN | C1 |
| `espn_tournament_pending`, `espn_scoreboard_pending` | 48-80 kB | Pending-job queues for ESPN | C1 |
| `espn_asset_crawl_state` | 64 kB | Crawl checkpointing | C1 |
| `tournament_categories`, `tournament_search_pending`, `tournament_search_queries`, `tournament_category_pending` | 32-48 kB | Tournament discovery pipeline | C1 |
| `mlb_branded_series`, `school_break_windows`, `holidays`, `major_event_calendar` | 32-144 kB | Calendar context overlays | C1 |
| `sporting_rivalries` | 160 kB | Rivalry pairs (e.g. Yankees-Red Sox) | C1 |
| `matchup_xref` | 184 kB | Cross-source matchup resolution | C1 |

### 2.7 Weather + alerts

| Table | Size | Purpose | Owner |
|---|---|---|---|
| `weather_observations` | 59 MB | Historic + forecast weather observations per venue | C1 |
| `weather_forecast_pending` | 192 kB | NWS forecast pull queue | C1 |
| `nws_alerts` | 6.9 MB | NOAA active weather alerts | C1 |
| `nws_alert_zones`, `nws_alert_references`, `nws_alert_pending` | 280-1456 kB | Alert geometry + ref + queue | C1 |
| `venue_nws_points_pending` | 88 kB | NWS station point-lookup queue | C1 |

### 2.8 Performer / venue metadata

| Table | Size | Purpose | Owner |
|---|---|---|---|
| `performer_metadata` | 4 MB | Generic performer info | C1 |
| `performer_wikipedia` | 592 kB | Wikipedia extracts per performer | C1 |
| `performer_home_venues` | 120 kB | Performer → home venue mapping | C1 |
| `performer_zones`, `performer_zone_rules` | 168-872 kB | Section→zone classification rules | C1 |
| `performer_crawl_state`, `performer_wiki_pending` | 16-160 kB | Crawl checkpointing | C1 |
| `important_x_accounts` | 264 kB | Curated Twitter handles per performer/team | C1 |
| `performer_subreddits`, `general_subreddits` | 32-88 kB | Reddit source map (table retained, cron paused) | A1 |
| `reddit_posts`, `reddit_pending` | 280-4720 kB | Reddit data (CRONS DROPPED 2026-05-13 PR #72; tables retained) | A1 |
| `venue_assets`, `venue_geocode_pending`, `venue_crawl_state`, `venue_pulls`, `venue_pull_log` (cf log table) | 32-320 kB | Venue master + crawl state | C1 |

### 2.9 Chat / NLU

| Table | Size | Purpose | Owner |
|---|---|---|---|
| `chat_corpus` | 232 kB | Source corpus for chat retrieval | C1 |
| `chat_aliases` | 1 MB | Alias resolution dictionary | C1 |
| `chat_term_frequency`, `chat_term_freq_in`, `chat_term_freq_out` | 80-240 kB | Term-frequency splits (incoming vs outgoing) | C1 |
| `chat_audit_findings` | 96 kB | Chat audit results | C1 |
| `chat_rate_limits`, `chat_stopwords`, `chat_glossary_known` | 32-64 kB | Chat infrastructure | C1 |

### 2.10 Storefront (D1)

| Table | Size | Purpose | Owner |
|---|---|---|---|
| `share_links` | 32 kB | Revocable share links for events (PR #54) | D1 |
| `watchlist` | 144 kB | User watchlists (terminal-side) | C1 |
| `watch_sources` | 536 kB | What sources to watch for what events | C1 |

### 2.11 Coordination + governance

| Table | Size | Purpose | Owner |
|---|---|---|---|
| **`bot_chat`** | 168 kB | **Bot ↔ bot coordination log** (event_type: change_log/question/flag/sync/status/collision/broadcast/p0_security) | A1 (schema) | PR #64; hardened **PR #67/#68** |
| `bot_messages` | 248 kB | Older bot message log (predecessor to bot_chat) | A1 | pre-history |
| `bot_users` | 32 kB | Bot identity registry | A1 | pre-history |
| `data_sources`, `data_source_field_map` | 32-88 kB | Field-level mapping between sources | C1 |
| `settings` | 32 kB | Generic app settings KV | A1 |
| `leads` | 96 kB | Inbound leads | A1 |
| `snapshots`, `runs` | 88-200 kB | Generic snapshot/run logs | A1 |

### 2.12 Macro indicators

| Table | Size | Purpose | Owner | Origin |
|---|---|---|---|---|
| `macro_indicators` | 48 kB | Latest FRED indicator values (UMCSENT etc.) | A1 | **PR #53** |
| `macro_series_config` | 32 kB | FRED series to track + pull schedule | A1 | PR #53 |
| `fred_pending` | 48 kB | FRED queue table | A1 | PR #53 |

### 2.13 Pending / queue tables (the `*_pending` pattern)

| Pattern | Used by | Purpose |
|---|---|---|
| `*_pending` (12+ tables) | C1, A1 | Generic queue for cron-driven backfills (events, listings, weather, NWS, ESPN, tournament, etc.). `pg_net` retention sweep keeps them tidy. |
| `*_pull_log`, `*_pull_budget`, `pull_rate_limits` | A1 | Provenance + rate-limit governance for outbound pulls |
| `seatgeek_seller_pending`, `sg_seller_pending`, `sg_listings_pending`, `sg_event_backfill_pending`, `sg_event_match_pending`, `evo_event_backfill_pending`, `evo_orders_pending` | D2 | Per-source backfill queues |

---

## 3. Materialized views (the matview surface)

Only 2 matviews — both perf-critical.

| Matview | Refresh cadence | Purpose | Owner | Origin | Status |
|---|---|---|---|---|---|
| `latest_event_metrics` | 5 min (`3-58/5`) via `refresh_latest_event_metrics()` | Per-event latest aggregate row — feeds `/api/store/events` catalog | A1 | **PR #71** | LIVE. 272ms warm (was 50,372ms as a view) |
| `v_dashboard_writes_24h` | **60s** (every minute) — see advisor flag | 24h write velocity for dashboards | C1 | pre-history | 5.3s mean refresh × 60/min = 8.8% of clock time — **bot_chat row 65 flagged for cadence reduction** |

---

## 4. Views

**140 views in `public`**. Major patterns:

### 4.1 Canonical resolution views (C1)

| View | Purpose |
|---|---|
| `v_canonical_event`, `v_canonical_performer`, `v_canonical_venue` | Unified canonical entity views |
| `v_canonical_coverage`, `v_canonical_coverage_v2`, `v_canonical_drift` | Coverage + drift audit |
| `sg_canonical_match_view` | SG → canonical match diagnostics |
| `cross_source_coverage`, `cross_source_event_audit` | Cross-source audits |

### 4.2 Event-context views (C1 + dashboards)

`v_event_full`, `v_event_full_sports`, `v_event_full_v2`, `v_event_base`, `v_event_calendar_context`, `v_event_competitors`, `v_event_competing_events`, `v_event_data_freshness`, `v_event_evo_orders`, `v_event_holidays`, `v_event_home_away`, `v_event_injuries`, `v_event_espn_news`, `v_event_espn_state`, `v_event_espn_injuries`, `v_event_line_movement`, `v_event_major_calendar`, `v_event_mlb_branded_series`, `v_event_nws_alerts`, `v_event_overlay_summary`, `v_event_reddit`, `v_event_sales_combined`, `v_event_school_breaks`, `v_event_seating_chart`, `v_event_sporting_rivalries`, `v_event_team_standings`, `v_event_tournament_context`, `v_event_velocity_windows`, `v_event_weather`, `v_event_weather_with_fallback`, `v_event_why_context`, `v_event_xref_collisions`, `v_event_xref_proposed`

### 4.3 Broker terminal views (A1)

`broker_event_metrics`, `broker_event_sections`, `broker_event_zones`, `broker_listings`, `v_broker_configurations`, `v_pricing_cross_source`, `v_arbitrage_opportunities`

### 4.4 Retail-storefront views (D1 consumes; C1 owns)

`retail_events`, `retail_event_metrics`, `retail_event_sections`, `retail_event_zones`, `retail_listings`

### 4.5 Health + ops (A1)

`v_cron_health`, `v_pg_net_queue_health`, `v_bot_chat_unresolved`, `v_dashboard_coverage`, `v_dashboard_freshness`, `v_macro_indicators_health`, `v_macro_indicators_latest`, `v_one_to_one_health`

### 4.6 SeatGeek-specific (D2)

`seatgeek_event_latest`, `seatgeek_categorized_listings`, `seatgeek_orders_by_event`, `v_seatgeek_listings_classified`, `v_sg_*` (10+ views: events_by_status, events_pending_match, historic_*, sales_by_*, unmatched_*)

### 4.7 Unified / combined (C1)

`unified_listings`, `unified_orders`, `unified_orders_by_event`, `our_orders`, `our_orders_with_net`, `our_orders_by_event`, `our_orders_by_event_with_net`

To query: `SELECT viewname FROM pg_views WHERE schemaname='public' AND viewname LIKE 'v_event_%' ORDER BY 1;` — schema is the source of truth, this doc is a roadmap.

---

## 5. Cron jobs — all 67 active

Sorted by category. All run in `postgres` role under `pg_cron 1.6.4`. `cron.use_background_workers=off`, `max_running_jobs=32`.

### 5.1 Master orchestrator + sweeps

| jobid | name | sched | command | Owner | Notes |
|---|---|---|---|---|---|
| 38 | `master-cascade-2min` | `*/2 * * * *` | `master_cascade_2min()` | C1? | **15.5% of DB time (11s mean)** — bot_chat row 65 flagged |
| 36 | `midnight-catchup-sweep` | `0 0 * * *` | `midnight_catchup_sweep()` | A1 | |
| 6 | `sweep-old-listings` | `0 3 * * *` | `sweep_old_listings()` | A1 | TTL 30d, **PR #66** |
| 117 | `sweep_duplicate_listings_hourly` | `15 * * * *` | `sweep_duplicate_listings(50)` | A1 | **PR #66**, batched per-event |
| 118 | `sweep_terminal_event_listings_hourly` | `20 * * * *` | `sweep_terminal_event_listings(50)` | A1 | **PR #66**, keep-5 for terminal events |
| 114 | `sweep_expired_pg_net_pending_hourly` | `17 * * * *` | `sweep_all_expired_pg_net_pending(12)` | C1 | PR #65 (pg_net retention) |
| 102 | `sweep_inactive_event_states_daily` | `0 5 * * *` | `sweep_inactive_event_states()` | C1 | |
| 20 | `sweep_tevo_ticket_groups_cache` | `15 * * * *` | `sweep_tevo_ticket_groups_cache()` | D1 | |
| 18 | `sweep-bot-messages` | `10 4 * * *` | `sweep_old_bot_messages()` | A1 | |
| 69 | `wiki_pending_sweep_daily` | `30 3 * * *` | `wiki_pending_sweep()` | C1 | |
| 73 | `orphan_backfill_sweep_daily` | `35 3 * * *` | `orphan_backfill_sweep()` | C1 | |
| 80 | `tournament_search_pending_sweep_weekly` | `10 4 * * 0` | `tournament_search_pending_sweep()` | C1 | |

### 5.2 Listings collection (TEvo + SeatGeek)

| jobid | name | sched | Owner |
|---|---|---|---|
| 108 | `collect-listings-0-24h` | `*/20` | A1 |
| 109 | `collect-listings-1-7d` | `:05/hr` | A1 |
| 110 | `collect-listings-7-30d` | `:10/4h` | A1 |
| 111 | `collect-listings-30-60d` | `:15/12h` | A1 |
| 112 | `collect-listings-60d+` | `:20 02:00` | A1 |
| 53–57 | `sg_listings_0-24h` … `60d+` | same window cadence | D2 |
| 58 | `sg_listings_process_5min` | `2-59/5` | D2 |

### 5.3 Orders pipeline (D2)

| jobid | name | sched |
|---|---|---|
| 61 | `evo_orders_queue_30min` | `*/30` |
| 62 | `evo_orders_process_30min` | `5-59/30` |
| 63 | `sg_seller_orders_queue_30min` | `*/30` |
| 64 | `sg_seller_listings_queue_30min` | `2-59/30` |
| 65 | `sg_seller_process_30min` | `5-59/30` |
| 71 | `orphan_event_backfill_queue_15min` | `*/15` |
| 72 | `orphan_event_backfill_process_15min` | `2-59/15` |

### 5.4 Cross-source matchers (C1 + A1)

| jobid | name | sched | Owner |
|---|---|---|---|
| 68 | `cross_source_match_tick_30min` | `*/30` | C1 |
| 90 | `match_tournaments_daily` | `30 04` | C1 |
| 101 | `match_events_to_espn_10min` | `*/10` | C1 |
| **120** | `match_listings_to_sg_30min` | `7,37 * * * *` | A1 (**PR #66**) |
| **124** | `latest_event_metrics_refresh_5min` | `3-58/5` | A1 (**PR #71**) |
| 91 | `dashboard_writes_24h_refresh_60s` | `* * * * *` | C1 (**bot_chat row 65 flagged for cadence reduction**) |

### 5.5 Performer + venue crawl (C1)

| jobid | name | sched |
|---|---|---|
| 43 | `performer_wiki_queue_searches_5min` | `*/5` |
| 44 | `performer_wiki_process_searches_5min` | `1-59/5` |
| 45 | `performer_wiki_process_summaries_5min` | `2-59/5` |
| 46 | `venue_geocode_queue_5min` | `*/5` |
| 47 | `venue_geocode_process_5min` | `1-59/5` |
| 70 | `event_competitors_refresh_hourly` | `40 *` |
| 81 | `tournament_pull_queue_weekly` | `0 04 Sun` |
| 82 | `tournament_pull_process_weekly` | `5 04 Sun` |
| 83 | `venue_pull_queue_weekly` | `15 04 Sun` |
| 88 | `espn_tournament_queue_weekly` | `0 04 Sun` |
| 96 | `espn_tournament_process_after_queue` | `5,15,30 04 Sun` |
| 97 | `venue_pull_process_weekly` | `20 04 Sun` |
| 106 | `crawl-venues-and-performers-3min` | `*/3` (edge fn) |
| 107 | `crawl-espn-team-assets-3min` | `*/3` (edge fn) |
| 105 | `backfill-event-configurations-5min` | `*/5` (edge fn) |
| 113 | `espn-team-daily` | `0 05` (edge fn) |

### 5.6 ESPN scoreboard (C1)

| jobid | name | sched |
|---|---|---|
| 99 | `espn_scoreboard_queue_4h` | `0 */4` |
| 100 | `espn_scoreboard_process_5min` | `5-59/5` |

### 5.7 Weather + alerts (C1)

| jobid | name | sched |
|---|---|---|
| 48 | `weather_forecast_queue_30min` | `*/30` |
| 49 | `weather_forecast_process_30min` | `5-59/30` |
| 50 | `weather_climatology_weekly` | `0 06 Sun` |
| 84 | `nws_points_queue_daily` | `15 04` |
| 95 | `nws_points_process_after_queue` | `25 04` |
| 93 | `nws_alerts_queue_30min` | `*/30` |
| 94 | `nws_alerts_process_aligned` | `5,20 * * * *` |

### 5.8 Alerts + chat + zones (C1 + A1)

| jobid | name | sched | Owner |
|---|---|---|---|
| 74 | `compute_alerts_tick_15min` | `5-59/15` | A1 |
| 92 | `auto_ack_stale_alerts_30min` | `8-59/30` | A1 |
| 98 | `zone-backfill-isolated-10min` | `4-59/10` | C1 — **14.3% DB time, bot_chat row 65 flagged** |
| 21 | `refresh-chat-corpus` | `30 *` | C1 |
| 27 | `run-daily-chat-audit` | `0 04` | C1 |
| 29 | `refresh-chat-term-freq-split-hourly` | `15 *` | C1 |

### 5.9 Macro (A1)

| jobid | name | sched |
|---|---|---|
| 103 | `fred_queue_daily` | `30 15` |
| 104 | `fred_process_5min` | `5-59/5` |

### 5.10 Watchlist + misc

| jobid | name | sched | Owner |
|---|---|---|---|
| 34 | `ensure-watchlist-coverage-daily` | `0 06` | C1 |

### Removed crons (audit trail)

- `reddit_queue_30min` (was jobid 75) — **PR #72**, 2026-05-13
- `reddit_process_30min` (was jobid 76) — PR #72
- `reddit_pending_sweep_daily` (was jobid 77) — PR #72

---

## 6. Edge functions — all 25 active

Hosted in Supabase; deployed via `supabase functions deploy`. Source under `supabase/functions/<slug>/index.ts`.

| Slug | verify_jwt | Purpose | Owner | Used by cron? |
|---|---|---|---|---|
| `collect` | false | Generic data-collection multiplexer (initial pull on signup) | A1 | no |
| `collect-listings` | false | TEvo listings pull per time window | A1 | yes (5 windowed crons 108–112) |
| `sg-collect` (path-style? — check) | n/a | n/a | — | (covered by `sg_listings_*` SQL crons) |
| `espn-collect` | false | ESPN scoreboard pull | C1 | yes (113) |
| `espn-rosters` | false | ESPN team roster pull | C1 | on-demand |
| `crawl-espn-team-assets` | false | ESPN team logo/branding crawler | C1 | yes (107) |
| `crawl-venues-and-performers` | true | Generic venue+performer enrichment | C1 | yes (106) |
| `backfill-event-configurations` | true | Backfill event configurations | C1 | yes (105) |
| `wiki-collect` | false | Wikipedia performer enrich | C1 | (driven by SQL crons 43–45) |
| `match-sg-performers-to-tevo` | true | SG performer → TEvo performer matcher | C1 | on-demand |
| `bulk-add-watchlist` | false | Bulk add events to watchlist | C1 | on-demand |
| `seed-home-venues` | false | One-shot venue seeding | A1 | one-shot |
| `chat` | **true** | Retail/terminal chatbot endpoint | C1 (paused?) | on-demand HTTP |
| `sms-bot` | false | SMS bot entrypoint | C1 | on-demand HTTP |
| `web-bot` | false | Web bot entrypoint | C1 | on-demand HTTP |
| `espn` | true | ESPN UI helper | C1 | on-demand |
| `tevo-perf-find` | true | TEvo performer search helper | C1 | on-demand |
| `tevo-fallback-search` | true | TEvo fallback search | C1 | on-demand |
| `diag-ticket-groups` | false | Diagnostic for TEvo ticket_groups (debug) | A1 | dev only |
| `probe-tevo-category` | false | Diagnostic for TEvo category endpoint | A1 | dev only |
| `probe-tevo-performer` | true | Diagnostic for TEvo performer | A1 | dev only |
| `probe-tevo-events-by-venue` | true | Diagnostic | A1 | dev only |
| `probe-seating-charts` | true | Diagnostic | A1 | dev only |
| `probe-espn-data` | true | Diagnostic | A1 | dev only |
| `why-noaa-weather-alerts` | true | Why-this-event helper for NOAA alerts | C1 | on-demand |

**Anon-callable (verify_jwt=false)**: `collect`, `collect-listings`, `diag-ticket-groups`, `sms-bot`, `web-bot`, `bulk-add-watchlist`, `probe-tevo-category`, `seed-home-venues`, `espn-collect`, `espn-rosters`, `wiki-collect`, `crawl-espn-team-assets`. B1 has these on the security-review surface (some are cron-only and should not be reachable from anon if at all possible).

---

## 7. Vault secrets

| Key | Used by | Lane that maintains |
|---|---|---|
| `CRON_SECRET` | `_cron_invoke_edge_fn` to authenticate cron → edge fn calls | A1 |
| `EDGE_FN_ANON_JWT` | Edge functions reading their own anon JWT for callbacks | A1 |
| `TEVO_API_TOKEN` | `evo_client.py`, TEvo edge fns | D2 (client) + D1 (reads) |
| `TEVO_SECRET` | TEvo HMAC signing | D2 |
| `SEATGEEK_API_TOKEN` | SeatGeek pulls | D2 |
| `SEATDATA_API_KEY` | SeatData pulls | D2 |
| `FRED_API_KEY` | FRED macro pulls (**PR #53**). Note: this key is "free to everyone" per operator 2026-05-12 — benign exposure | A1 |

Rotation history: `CRON_SECRET` rotated 2026-05-11 (custom 128-char, three-way sync to vault + Supabase Edge + Render). Legacy JWT keys (anon/service_role `eyJ...`) appear to have been rotated server-side around 2026-05-12 — **see `docs/evo_store_next_steps.md` step #2** for D1 swap to `sb_publishable_*` / `sb_secret_*`.

---

## 8. Installed Postgres extensions

| Extension | Schema | Version | Why |
|---|---|---|---|
| `plpgsql` | pg_catalog | 1.0 | PL/pgSQL procedural language (every function) |
| `pgcrypto` | extensions | 1.3 | hashing, gen_random_uuid |
| `uuid-ossp` | extensions | 1.1 | uuid generation |
| `pg_cron` | pg_catalog | 1.6.4 | the scheduler (67 jobs run here) |
| `pg_net` | extensions | 0.20.0 | async HTTP from SQL (used by `_cron_invoke_edge_fn` to invoke edge fns from crons) |
| `pg_stat_statements` | extensions | 1.11 | query telemetry (powers the advisor flag in row 65) |
| `pg_trgm` | public | 1.6 | trigram fuzzy matching (used by event name matchers) |
| `supabase_vault` | vault | 0.3.1 | encrypted secret storage |
| `unaccent` | public | 1.1 | accent-insensitive text search |

Extensions present but NOT installed: postgis, vector, pgsodium, pgmq, pg_partman, http (the synchronous one — we use `pg_net` async instead), pg_graphql, pg_jsonschema, dblink, etc. If a task needs one, A1 enables it via migration.

---

## 9. HTTP API surface

Backend = `app.py` (FastAPI on Render). Two surfaces:

### 9.1 Public storefront (`/api/store/*`) — D1 lane

| Endpoint | Verb | Purpose | Status |
|---|---|---|---|
| `/healthz` | GET | Render health | ✅ live |
| `/api/public/config` | GET | Returns supabase_url + anon_key + allowed_email_domain | ✅ live |
| `/api/store/events` | GET | Catalog list (paginated, filtered) | ✅ live post-PR #71 |
| `/api/store/events/{id}` | GET | Event detail with live TEvo enrichment | ✅ live |
| `/api/store/events/{id}/zones` | GET | Section→zone map for event | ✅ live |
| `/api/store/events/near` | GET | Geo proximity listing | ✅ live |
| `/api/store/search` | GET | Search performers/teams/venues/cities | ✅ live |
| `/api/store/movers` | GET | Top events by 24h velocity | ✅ live |
| `/api/store/reserve` | POST | **MOCK — never charges. PR #75 punch list § B** | 🟥 not real |
| `/api/store/share` | POST | Create revocable share link | ✅ live (PR #54) |
| `/api/store/share/{id}` | GET / DELETE | Fetch / revoke share | ✅ live |
| `/api/store/shares` | GET | List my shares | ✅ live |
| `/store`, `/store/event/{id}`, `/s/{share_id}` | GET | Static HTML pages | ✅ live |

### 9.2 Terminal / broker (`/api/broker/*`, `/api/events/*`, `/api/portfolio`, etc.) — A1 lane

40+ endpoints. Catalog: `Grep '@app\.(get\|post\|delete\|put)' app.py`. Includes:
- `/api/broker/event/{id}/overview`, `/section-zones`, `/zones`, `/section-metrics`, `/raw-tevo`, `/chart-data`, `/cadences`, `/espn`
- `/api/broker/watchlist-movers`, `/api/broker/movers`, `/api/broker/news`, `/api/broker/leagues`
- `/api/broker/performers/by-league/{league}`, `/api/broker/performer/{id}/assets`, `/espn`
- `/api/portfolio`, `/api/watchlist` (GET/POST/DELETE)
- `/api/events`, `/api/events/{id}`, `/api/events/{id}/series`, `/sections/series`
- `/api/performers`, `/api/venues`, `/api/configurations`, `/api/runs`, `/api/snapshots/{latest,velocity}`
- `/api/collect/run` (manual collect trigger)
- `/api/admin/seed-home-venues`, `/api/admin/wire-sg-to-tevo`, `/api/admin/wire-sd-to-tevo`

### 9.3 Static surfaces

| Path | Purpose | Owner |
|---|---|---|
| `static/store/index.html` | Storefront catalog page | D1 |
| `static/store/event.html` | Storefront event detail | D1 |
| `static/store/shares.html` | Share-link admin | D1 |
| `static/store/store.js` | 1862-line client (unminified) | D1 |
| `static/store/style.css` | Storefront styles | D1 |
| `static/<other>` | Terminal/broker UI | A1 |

---

## 10. Service-level external surfaces

### Render

| Field | Value |
|---|---|
| Service id | `srv-d8140bnaqgkc73al4asg` |
| Service name | `vibepass-storefront-test` |
| Branch | `claude/store-sql-only-demo-mode` (**9928 lines behind main** — see `docs/evo_store_next_steps.md`) |
| Autodeploy | yes |
| Owner | D1 (sole — INFRA OWNERSHIP RULE, bot_chat row 57) |

### Supabase project

| Field | Value |
|---|---|
| Project id | `hzrizjeaxlqcxfrtczpq` |
| Region | (per project) |
| Statement timeout | platform default `120s` (function-level overridable via `set_config` per PR #71 pattern) |
| Max connections | `60` (only 17 active typically) |
| pg_cron worker pool | `max_running_jobs=32`, `use_background_workers=off` |

---

## 11. Quick-find: "which PR added X?"

For any resource, finding the originating PR is reproducible:

```bash
# 1. Find the migration that creates it
grep -rn "CREATE TABLE.*<name>" supabase/migrations/
grep -rn "CREATE FUNCTION.*<name>" supabase/migrations/

# 2. Find the merge commit that landed that migration
git log --all --oneline -- supabase/migrations/<filename>

# 3. PR # is in the merge subject (e.g. "feat(admin): … (#71)")
```

For resources created pre-2026-05 (most legacy tables), the PR numbering wasn't yet in place; treat the migration timestamp as the origin.

---

## 12. What's intentionally NOT in this bible

- **Indexes** — hundreds; not worth enumerating. Query: `SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename='<x>';`
- **Constraints + triggers** — same.
- **RLS policies** — B1's lane; see B1's security migrations (000100-000400 series + PR #67/#68 follow-ups). Auditable via `SELECT * FROM pg_policies;`
- **Edge function source code** — too volatile; `supabase/functions/<slug>/index.ts` is source-of-truth.
- **Frontend file inventory** — see `BOT_HIERARCHY.md` §4 + `static/store/` directory.
- **Test fixtures + scripts** — under `tests/`.

---

## 13. Maintenance

- Refresh this doc after any PR that adds/removes a table, matview, function, cron, edge fn, vault secret, or external service.
- For minor changes (e.g. column added to existing table), git history is enough — don't touch this doc.
- A1 owns the refresh; C1/B1/D1 should flag drift via `bot_chat` `event_type='question'` if they spot a stale entry.

Owner: A1. Mirror in `DOCUMENTATION_INDEX.md` after the next full refresh of that doc.
