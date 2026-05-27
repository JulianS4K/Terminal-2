# RESOURCES_BIBLE.md

**Living inventory of every Terminal-2 resource — what it is, who owns it, who reads it, and where it came from. Updated 2026-05-17 (main HEAD `e04387e`+post-#191).**

**⚠ READ THIS BEFORE CREATING ANY TABLE / VIEW / RPC / CRON.** The inventory below is curated — if a name nearby fits your need, reuse instead of creating. Common collisions: `*_metrics`, `*_xref`, `v_event_*`, `sg_*_pending`. Run `SELECT relname FROM pg_class JOIN pg_namespace n ON n.oid=relnamespace WHERE nspname='public' AND relkind IN ('r','v','m')` before authoring net-new structures.

## Snapshot streams — generation rates, 24h window @ 2026-05-17 ~21:42 UTC

**Five live firehoses + six smaller/idle/derived snapshot tables. D0: this is the surface area for event-page tabs / time-series panels. Pick from this list before proposing new captures.**

### Live firehoses (high-volume, query carefully)

| Stream | Source table | Rows/24h | Events/24h | Last row | Dedup key | Time col | Notes |
|---|---|---:|---:|---|---|---|---|
| **SG listings** (marketplace) | `seatgeek_listings_snapshots` | **1,224,517** | 437 | 21:41 | `sglid` (DISTINCT ON) | `captured_at` | SG broker-data `/v2/listings`. 11× pull dedup. 3.2 GB / 3.84M rows. Use `sg_event_id` (idx_sg_listings_sg_event_id_time). |
| **SG sales** (marketplace) | `seatgeek_sales_snapshots` | **516,054** | 601 | 21:42 | `sg_sale_id` (DISTINCT ON) | `pulled_at` (ingest) + `sale_at_utc` (actual) | SG broker-data `/v2/sales`. 11× dedup mandatory. 1.18 GB / 1.73M rows. `idx_sg_sales_sg_event_id_time`. |
| **TEvo listings** (broker) | `listings_snapshots` | **454,795** | 413 | 21:41 | `(event_id, tevo_ticket_group_id, captured_at)` | `captured_at` | TEvo `/v9/ticket_groups`. Includes OUR office (`is_owned=true AND brokerage_id=1768`). 3.6 GB / 8.96M rows. |
| **TEvo orders** (our pipeline) | `evo_orders` + `evo_order_items` | 11 new | 0 new (all repulls) | 21:35 | `evo_order_id` (PK) | `pulled_at` + `evo_created_at` | Our office's `/v9/orders`. `tevo_event_id` 99.5% populated. 1.3 MB. |
| **SG seller orders** (our SG SellerDirect) | `seatgeek_orders` | 400 (repulls) | 186 | 21:37 | `sg_order_id` (PK) | `pulled_at` + `created_at_sg` | OUR office's SG SellerDirect orders. Static 400 rows. Different from sales firehose. |

### Lower-volume / per-broker order streams (forever retention)

| Stream | Source table | Rows/24h | Events/24h | Last row | Notes |
|---|---|---:|---:|---|---|
| **TickPick orders** | `tickpick_orders` | 74 | 0 new (repulls) | 21:18 | 1,223 total. `tevo_event_id` ~81%; matcher v3 active. |
| **SG seller listings** (our SG SellerDirect) | `seatgeek_seller_listings` | 71 | 6 | 19:07 | OUR office's SG inventory. 1,031 total / 47 events all-time. |
| **Vivid orders** | `vivid_orders` | 31 | 0 new (repulls) | 21:26 | 945 total. `tevo_event_id` ~91%. |

### Idle / specialized / derived snapshots

| Source table | Rows/24h | Status | Purpose |
|---|---:|---|---|
| `espn_event_snapshots` | 581 | LIVE (gameday-scope) | Per-game state (score, status, attendance, win-prob). Captured during/near game time only. |
| `espn_injuries_snapshots` | 514 | LIVE | Per-athlete injury report history (status, return date, comment). |
| `espn_team_snapshots` | 71 | LIVE | Team-state (wins/losses, streak, playoff seed). Daily-ish. |
| `event_competitors_snapshot` | 816 | LIVE (cron @ :40 hourly via mig 20260518020000) | Per-event "competing event in same market" rollup. Sparse coverage by-design — only events with 20mi/24h venue neighbors get rows. |
| `event_sentiment` | 8+ (growing) | LIVE (cron @ :15,:45 via mig 20260518010000) | Per-event sentiment + velocity signals (sentiment_index, tix_per_hour, getin_per_hour, owned_share_change, pairs_change_per_hour). NULL when no prior 6-36h snapshot. |
| `event_section_row_snapshots` | 1,268+ (growing) | LIVE (cron @ :03 hourly via mig 20260518030000) | Per-section-row aggregate from listings_snapshots (source=tevo). C1-owned schema, A1 wrote populator + scheduler. SG-side mirror pending future PR. |
| `seatdata_sales_snapshots` | 0 | **STALE** (last 2026-05-09) | SeatData wholesale-channel sales. Pipeline dormant. |
| `seatdata_listings_snapshots` | 0 | **EMPTY** | SeatData mirror. Pipeline dormant. |
| `snapshots` (legacy) | 0 | **LEGACY** (last 2026-04-23) | Pre-history per-event aggregate. Superseded by `event_metrics`. Do not write. |
| `ticketsdata_listings_snapshots` | growing (1 day since 2026-05-27) | **LIVE** — TD cross-platform snapshots (SH/GT/VD). Started 2026-05-27. Used by `event_movers_index` SMA for `td_sh/gt/vd` sources. Meaningful signal quality ~late June (30+ days). |
| `event_listing_snapshot_daily` | growing (~3 rows/event/day since 2026-05-27) | **LIVE** — 3 slots/day (morning/midday/evening). Cross-source medians: EVO + SG + TD(SH/GT/VD). Feeds Market Carpet tabs + TD Markets tab + `event_movers_index` compute. |

### D0 tab option matrix — what surfaces are wired vs available

**Already shipped (PR #196 + #197 + 2026-05-27 UI rewire)**:
- `get_event_sg_listings_full(p_event_id, p_limit)` → SG listings from firehose, DISTINCT ON `sglid`, last 7d, cap 500
- `get_event_evo_listings_full(p_event_id, p_limit)` → TEvo listings, DISTINCT ON `tevo_ticket_group_id`, owned-first sort, cap 500
- `get_event_sg_sales_full(p_event_id, p_limit, p_window_days)` → SG broker sales, DISTINCT ON `sg_sale_id`, window 1-90d, cap 500
- **TD Markets tab** (event.html) → client queries `event_listing_snapshot_daily` directly (mig 20260527230000); KPI strip + history table (EVO/SG/SH/GT/VD medians + spreads)
- **Market Carpet tab** (performer.html + venue.html) → parallel client queries: `event_listing_snapshot_daily` + `event_movers_index` + `discovery_gap_alerts`; cross-source table with movers badges + gap badges per event
- **Movers v2 Index** (movers.html) → calls `/api/broker/movers?window_days=N&source=X` via `get_event_movers_v2` RPC; source/horizon/category selectors; 6 sources × 5 windows × 7 category filters
- **Discovery Gaps panel** (discovery.html) → client queries `discovery_gap_alerts` + `sg_events_canonical`; groups by gap_type with priority sort; 7 filter buttons

**Available next surfaces (D0 options — pattern: copy the v3 RPC mold, email-gated, REVOKE PUBLIC + GRANT anon/authenticated)**:

| Proposed tab | Source | Dimensions D0 could surface | Effort |
|---|---|---|---|
| **Our SG inventory** (`get_event_sg_seller_listings_full`) | `seatgeek_seller_listings` | section/row/seat range, cost, in_hand_date, eDelivery/instant. WHERE `tevo_event_id=p_event_id` — already 97% populated. | low — small table, just filter. |
| **Our SG sales** (`get_event_sg_orders_full`) | `seatgeek_orders` | sale_section/row, sale_price, sale_quantity, status, delivery, payment_fees, payment_total. | low — 186 distinct events, fast scan. |
| **Our TEvo orders** (`get_event_evo_orders_full`) | `evo_orders` + `evo_order_items` | total/subtotal/fees, buyer_brokerage, hold_expires_at, ticket_group section/row/seats, fraud_check_status. | low — already joined for inventory views. |
| **TickPick + Vivid combined** (`get_event_cross_broker_orders_full`) | `tickpick_orders` + `vivid_orders` (UNION) | per-broker section/row/qty/total, ordered_at, status. Useful for cross-marketplace deltas. | low — schemas mostly aligned. |
| **ESPN game snapshot timeline** (`get_event_espn_timeline`) | `espn_event_snapshots` (via performer→ESPN team xref) | score, status_short, attendance, win-prob over time on game day. | low — needs `performer_espn_team_xref` join through events.performer_id. |
| **Injury timeline** (`get_event_injuries`) | `espn_injuries_snapshots` (via team xref) | athlete_name, status, injury_type, return_date, short_comment — over time approaching event. | low — same join as ESPN timeline. |
| **Section-row roll-up tab** (`get_event_section_aggregates`) | `seatgeek_listings_snapshots` + `listings_snapshots` aggregated | per-section min/median/max/qty/listings_count — cross-source. Faster than fetching all rows. | medium — needs `GROUP BY section,row` over both firehoses. |
| **Velocity timeline** (`get_event_sales_velocity`) | `seatgeek_sales_snapshots` GROUP BY hour | sales/hour, avg price, min/max bracket — last N days. (View `v_event_sales_velocity` already exists; just wrap as RPC.) | low — wrapper RPC over existing view. |

**"SG broker sales" disambiguation**: the term in conversation could mean **either** (a) the SG marketplace firehose at 516K/24h = all broker sales on SG via the broker API (`seatgeek_sales_snapshots`) **or** (b) our office's SG SellerDirect sales pulled from our seller account (`seatgeek_orders`, 400/static). Most analytics work uses (a) since it has volume; (b) is for reconciliation of OUR account specifically. D0 can surface both as separate tabs.

**Retention policy** (per migration `20260512210000`):
- All 5 live firehoses + all order tables = **NEVER swept, forever retention**
- ESPN snapshots = retained (no prune cron)
- SeatData snapshots = retained but pipeline dormant
- `snapshots` (legacy) = retained but unused — do not write



Companion to `BOT_HIERARCHY.md` (which is *who* can push) and `MIGRATION_CONVENTIONS.md` (which is *how* to push). This doc is *what exists*.

Conventions:
- **Lane** = current owner per `BOT_HIERARCHY.md` (A1/B1/C1/D0/D1/D2/D3)
- **PR** = where the resource was created or last meaningfully changed. "pre-history" = predates the current PR numbering (migration timestamp in repo).
- Sizes in this doc are point-in-time snapshots; track real-time via Supabase dashboard.

## Latest deltas (2026-05-16 session)

| Resource | Delta | PR |
|---|---|---|
| Migration `20260516030000` | New view `_v_d0_event_index` + column `sg_event_priority_state.tevo_event_id` + `sg_classify_events` cancelled-filter | #146 |
| Migration `20260516040000` | Cron `listings_aq_backfill_overnight` activated | #146 |
| Migration `20260516050000` | New RPC `get_broker_event_page_v2` (7 new payload keys; 185ms typical) | #150 |
| Migration `20260516060000` | New indexes `idx_sg_sales_sg_event_id_time`, `idx_sg_listings_sg_event_id_time`, `idx_sg_event_metrics_sg_event_id_time` | #150 |
| Migration `20260516070000` | ESPN→TEvo→AQ→SG NFL bridge backfill (292 ESPN xrefs + 292 AQ rows + 3 SG xrefs) + v2 RPC fallback fix | #154 |
| Migration `20260516080000` | Multi-sport ESPN bridge (MLB 654 / MLS 42 / WNBA 12 / NBA 6 / NHL 1 ESPN xrefs; 365 SG xrefs after auto-matcher) | #154 |
| Migration `20260516090000` | `espn_scoreboard_queue` default 90d → 270d (captures full NFL season auto) | #157 |
| Doc `PROJECT_BIBLE.md` | NEW — operating playbook (rules + macros + landmines) | #155 |
| Migration `20260516100000` | `evo_orders` schema fix: ADD `tevo_event_id` + `aq_short_event_id` columns + backfill from `evo_order_items` (99.5% tevo / 88% aq populated post-apply) | #161 |
| Migration `20260516110000` | NEW RPC `refresh_sg_broker_sales_event_metrics(p_max_events)` — populates `seatgeek_event_metrics.sold_*` from `seatgeek_sales_snapshots` (DISTINCT ON sg_sale_id; 11× dedup). Hourly cron `sg_broker_sales_metrics_refresh_hourly` @ :17 with policy gate. | #161 |
| Migration `20260516120000` | NEW views: `v_event_sales_velocity` (sales/hour time series), `v_event_sales_metrics_filtered` (p99 outlier filter), `v_event_price_arbitrage` (TEvo retail vs SG cost vs SG sales realized per upcoming event) | #161 |
| Migration `20260516200000`+`200100` | D2 metrics swap (sg → sg_sales) + cron freshness swap | #163 |
| Migration `20260516210000`+`210100`+`210200` | SG SellerDirect WebSocket per-type tables + webhook secret + ingest RPCs | #164 |
| Migration `20260516220000`+`220100` | NEW views `v_sg_broker_sales_by_section` + `v_sg_broker_sales_by_event` (D2-authored, applied 2026-05-17) | #166 |
| Migration `20260516230000` | NEW RPC `sg_canonical_refresh_v2_pull(p_window_minutes)` + cron `sg_canonical_v2_pull_refresh_30min` @ :12,:42. Closes 99.5% NULL-population gap on `sg_events_canonical.last_v2_pull_at`. | #177 |
| Migration `20260516240000` | NEW table `cross_source_venue_map` (391 TEvo + 129 SG + 94 TickPick + 85 Vivid aliases) + RPC `cross_source_venue_resolve(name, city, state)` + RPC `refresh_cross_source_venue_map()` + RPC `sg_attempt_event_xref_v3` (matcher v3: ±24h tolerance + parking skip + venue map lookup) + RPC `auto_match_sg_canonical_v3()` | #177 |
| Migration `20260516250000` | NEW table `sg_tevo_search_attempts` (24h retry suppression for the TEvo /v9/events search bridge) + cron `sg_to_tevo_search_bridge_30min` @ :23,:53. Updated `cross_source_match_tick()` to also call v3 matcher. | #177 |
| Migration `20260516260000` | Drop dead 7-arg overload of `match_to_aq_event_id` (B1 OPS-HIGH #258 — `match_unmatched_orders_sweep_hourly` was failing every :22 with "function not unique"). | #177 |
| Migration `20260516270000` | `queue_performer_wiki_searches` orphan filter — `EXISTS performer_metadata` predicate. Fixes B1 OPS-MED #259 FK violation. | #177 |
| Migration `20260516280000` | **A1.1**: `seatgeek_sales_snapshots.tevo_event_id` backfill enablement. Dedup 32,627 duplicate rows + DROP CONSTRAINT `seatgeek_sales_dedup` (was `UNIQUE(tevo_event_id, sg_sale_id)`) + CREATE `seatgeek_sales_dedup_v2` (`UNIQUE(sg_event_id, sg_sale_id, pulled_at)`) + BEFORE INSERT trigger `trg_sg_sales_populate_tevo_event_id` (auto-populates from xref) + RPC `backfill_seatgeek_sales_tevo_event_id(p_chunk_size)`. Column 0.03% → 87.35% populated. | #178 |
| Migration `20260516290000` | D0 audit batch A1.2/A1.3/A1.4: Vivid event_date sentinel cleared (1 row) + Aces (`LA780EA` → tevo `56746`) + LAFC (`LA94425` → tevo `55771`, canonical name `'Los Angeles FC'`) + NEW column `aq_performer_map.aliases text[]` + GIN idx + alias arrays populated for Aces (`Aces, Vegas Aces, LV Aces`) and LAFC (`LAFC, Los Angeles Football Club`). | #179 |
| Migration `20260516290001` | A1.6: `get_broker_event_page_v2.freshness.weather_latest` falls back to forecast max-observed when no observations exist. | #179 |
| Migration `20260517000000` | Fix `listings_deltas_backfill_chunked` statement timeout cascade. `SET LOCAL statement_timeout='5min'` + first-row sentinel (COALESCE lag, current) + EXISTS-based remaining check + smallest-first ordering + drop pg_sleep + chunk 100→30. | #189 |
| Migration `20260517010000` | **D0 v3**: NEW RPC `get_broker_event_page_v3` (9 enrichment keys on top of v2: performer + velocity + sg_broker_sales + sg_listings_summary + competing_events + cross_source_orders + recent_listings + zone_deltas + performer_espn_context). Email-gated `@s4kent.com`. | #186 |
| Migration `20260517020000` (renamed from `010000` to break collision with v3) | Close 5 RLS gaps (C1 #272): `cross_source_venue_map`, `sg_tevo_search_attempts`, `sg_event_priority_state`, `sg_priority_policy`, `cron_pause_state_20260514` — all enabled with `admin_only` deny-all policy + REVOKE anon/auth + GRANT service_role. | #190 |
| Migration `20260517030000` | Hotfix v3 `sg_broker_sales`: inline scoped dedup (was timing out on `v_sg_broker_sales_by_event` view doing DISTINCT ON over 1.3M rows). | #191 |

**New tables added today (2026-05-16/17, 5 net-new in public schema)**:
- `cross_source_venue_map` (PR #177) — TEvo-anchored venue resolver with SG/TickPick/Vivid aliases.
- `sg_tevo_search_attempts` (PR #177) — 24h retry suppression for the TEvo /v9/events search bridge.
- `cron_pause_state_20260514` (pre-history, RLS added today)
- `sg_event_priority_state` (pre-history, RLS added today)
- `sg_priority_policy` (pre-history, RLS added today)

**New views added today**:
- `v_sg_broker_sales_by_section` (D2, applied via #166 today)
- `v_sg_broker_sales_by_event` (D2, applied via #166 today)
- `v_event_sales_velocity`, `v_event_sales_metrics_filtered`, `v_event_price_arbitrage` (already noted via #161)

**New RPCs added today**: `sg_canonical_refresh_v2_pull`, `cross_source_venue_resolve`, `refresh_cross_source_venue_map`, `sg_attempt_event_xref_v3`, `auto_match_sg_canonical_v3`, `cross_source_match_tick` (updated), `match_to_aq_event_id` (8-arg only, 7-arg dropped), `queue_performer_wiki_searches` (orphan filter), `backfill_seatgeek_sales_tevo_event_id`, `trg_sg_sales_populate_tevo_event_id` (trigger fn), `get_broker_event_page_v2` (weather fallback), `get_broker_event_page_v3` (9 enrichment keys), `listings_deltas_backfill_chunked` (perf rewrite).

**New crons added today**:
- `sg_canonical_v2_pull_refresh_30min` @ :12,:42 (PR #177)
- `sg_to_tevo_search_bridge_30min` @ :23,:53 (PR #177)

---

## 1. External services + integrations

| Service | Purpose | Lane that owns the integration | Where it lives | Secret in vault |
|---|---|---|---|---|
| **Supabase** (Postgres + Edge Functions + Vault + Storage + Auth) | Primary DB and runtime | A1 (DB) + D1 (storefront uses anon key) | `hzrizjeaxlqcxfrtczpq` | (anon + service_role keys, exposed via `/api/public/config`) |
| **Render** | Hosts `vibepass-storefront-test` (`app.py` + `static/store/*`). **Testing-unified runtime host (2026-05-16, PR #168)** — also mounts D2 dashboard `/api/d2/*` via `app.include_router`; D0 terminal static served from CDN (`vibepass-terminal-test`). See PROJECT_BIBLE.md §2 + CLAUDE.md §4 for the unified architecture + beta migration path. | **D1 (sole owner)** | service `srv-d8140bnaqgkc73al4asg` | env-side, not vault |
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
| `ticketsdata_listings_snapshots` | growing | Cross-platform listings snapshots: SH (StubHub), GT (GameTime), VD (VividSeats). `platform` + `event_id` + `snapshot_ts` + `listing_count`, `median_price`, `getin_price`. Collected by edge function, sweeps via `sweep_old_ticketsdata_snapshots`. Started 2026-05-27. | A1 | mig 20260527000000-20260527220000 |
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
| `event_listing_snapshot_daily` | growing | Per-event daily cross-source snapshot: `evo_owned_tickets`, `evo_tickets_count`, `evo_retail_median`, `sg_all_tickets`, `sg_all_median`, `td_sh/gt/vd_listings`, `td_sh/gt/vd_median`, `td_combined_median`. Key: `(event_id, snapshot_date, snapshot_slot)`. 3 slots/day (morning/midday/evening). TD columns started 2026-05-27. Queried directly from client for Market Carpet + TD Markets tabs. | A1 | mig 20260527230000 |

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

### 2.13 Signals / movers (mig 20260527250000)

| Table | Purpose | Owner | Notes |
|---|---|---|---|
| `event_movers_index` | Per-(source, window_days, category, event_id) signal index. 6 sources × 5 windows × 6 categories = up to 30 sub-indices, top 25 events each. PK: (source, window_days, category, event_id). Sources: `evo \| sg \| td_sh \| td_gt \| td_vd \| merged`. Windows: 7/15/30/180/365 (event HORIZON, not lookback). Categories: price_up/down, selling_fast, accumulating, value_gap, cross_gap. Upserted by `compute_event_movers_index_all()`, cron `35 13,19,3 * * *`. | A1 | mig 20260527250000 |
| `event_movers_index_history` | Composition audit trail — enter/exit/rank_change events per index slot. Used for turnover rate in `get_event_movers_index_summary`. Indexed on (source, window_days, category, event_id, recorded_at DESC). | A1 | mig 20260527250000 |
| `discovery_gap_alerts` | Active cross-platform gap signals (resolved_at IS NULL = active). 10 gap types: sg_no_evo, td_sh/gt/vd_no_evo, td_sh_no_gt, td_gt/vd_premium, evo_no_sg, value_gap_large, fill_rate_spike. ON CONFLICT (event_id, gap_type) DO UPDATE to refresh signal_score. Populated by `evo_sg_discovery_gaps()` cron (daily 9am UTC). Read by discovery.html Discovery Gaps panel. | A1 | mig 20260527250000 |

### 2.14 Pending / queue tables (the `*_pending` pattern)

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
- `/api/broker/watchlist-movers`, `/api/broker/movers` (v1: `?window_hours=N`; **v2: `?window_days=N&source=X&category=Y`** → `get_event_movers_v2` + `get_event_movers_index_summary` RPCs, mig 20260527260000), `/api/broker/news`, `/api/broker/leagues`
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
