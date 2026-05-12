# Data sources audit — 2026-05-11

Produced by C1 (Data + Chat Bot, supervisor). Handoff target for git work: A1 (Primary/Audit/Push). Branch: `claude/audit-data-sources-b7EGu`.

> **2026-05-11 revision:** initial audit over-counted orphans by ~5. See "Corrections" section at top before reading the orphan analysis below. Verified false positives are crossed out in place.

## Corrections (post sample-fix testing)

After running validation queries against the live DB, several orphan findings were withdrawn:

| original flag | reality | reference |
|---|---|---|
| `seatgeek_listings_snapshots` orphan | **Live table** — created in `20260509090000_seatgeek_broker_rebuild.sql:99`, INSERT'd by cron, read by dashboard views in `20260510020000` + `20260510040000` | not an orphan |
| `seatgeek_sales_snapshots` orphan | **Live table** — same migration, same usage pattern | not an orphan |
| `wiki-collect` edge function dormant | **Intentional manual admin tool** — targeted single-performer refresh + rivalries refresh that the SQL+pg_net pipeline doesn't cover | not an orphan |
| Open-Meteo under-pulled | **Already cron-scheduled** — 4 jobs at `20260509260000_weather_integration.sql:355-358` (geocode + forecast, both at 5min and 30min cadences) | not orphan |
| Reddit RSS under-pulled | **Already cron-scheduled** — 3 jobs at `20260509410000_betting_odds_and_reddit_signals.sql:477-491` | not orphan |
| OSM Nominatim reactive-only | **Already cron-scheduled** — same weather migration handles venue geocoding queue | not orphan |
| `sg_event_backfill_pending` queue stalled | **Has dedicated processor** — `20260509360000_orphan_event_auto_backfill.sql` provisions queue + 3 crons to drain it via SeatGeek brokerdata API | not orphan |

**Net real orphan count after corrections:** 0 tables, 0 functions, 0 data sources. The data plane has more sophisticated orphan-handling than initially credited.

**Real findings that survive:**
1. `seatgeek_event_xref` matches 11 SG events, **none of which appear in `seatgeek_orders`** — the listings-time matcher (`auto_seller_inline_v2`) catches the wrong slice
2. 400 SG orders with NULL `tevo_event_id` — historical 2018-2025 sales with no TEvo event row to match against (TEvo events table doesn't retain history)
3. AGENTS.md ARCHITECTURE diagram says "TWO data sources" — actual count is 11

These three are tracked in `docs/cross-source-entity-resolution-2026-05-11.md` Finding 1-3.

## Headline counts

| metric | count |
|---|---|
| Distinct external data sources wired | **11** |
| Total endpoints across sources | **~70+** |
| Storage buckets (Supabase Storage) | **1** |
| DB tables (`public.*`, excl. test schemas) | **~120** |
| Logical table categories | **11** |
| Orphan/cleanup-candidate tables | **5** (3 of which are intentional) |
| Edge functions total / cron-active / dormant | **14 / 5 / 9** |
| Cron jobs scheduled | **84+** |
| Data sources actively pulling on schedule | **7/11** |

## 1. Data sources

| # | source | endpoints | role | primary tables | auth |
|---|---|---|---|---|---|
| 1 | **Ticket Evolution (TEvo)** | 50+ v9 | inventory, listings, orders, events, performers, venues | `listings_snapshots`, `event_metrics`, `section_metrics`, `tevo_ticket_groups_cache` | HMAC-SHA256 |
| 2 | **ESPN** | 10+ across 6 sports / 217+ teams | scores, leaders, odds, injuries, plays, rosters, standings, news | `espn_event_snapshots`, `espn_athletes`, `espn_injuries_snapshots`, `espn_news` | none |
| 3 | **SeatGeek (Public + SellerDirect)** | 5+ | cross-validation, images, taxonomies, broker listings, orders | `seatgeek_events`, `seatgeek_listings`, `seatgeek_orders`, `seatgeek_historic_sales`, `cross_source_entity_maps` | client_id / token |
| 4 | **SeatData** | 3 | sold-listing history, cross-marketplace fill rates | `seatdata_sales_snapshots`, `seatdata_listings_snapshots`, `seatdata_event_stats`, `seatdata_pull_log` | API key (Vault) |
| 5 | **Wikipedia** | 2 (opensearch + page summary) | performer/team context, rivalries | `wiki_summary`, `wiki_rivalries`, `performer_wikipedia` | none |
| 6 | **NOAA / NWS** | 1 (`/alerts/active`) | severe weather alerts → why-signals | `why_signals` (signal_kind='weather_alert') | none |
| 7 | **Open-Meteo** | 2 (forecast + archive) | temp/precip/wind/humidity per venue | `weather_observations`, `venue_assets` (lat/lon) | none |
| 8 | **FRED** | 1 (extensible series catalog) | macro indicators (UMCSENT seeded) | `macro_indicators`, `macro_series_config` | API key |
| 9 | **Reddit (old.reddit RSS)** | 1 | team-subreddit sentiment | `reddit_posts`, `reddit_pending` | none |
| 10 | **Anthropic Claude API** | n/a (LLM) | chat tool-use loop | `bot_messages`, `chat_tracked_events` | API key (Vault) |
| 11 | **OSM Nominatim** | 1 | venue geocoding for weather pipeline | `venue_assets.latitude/longitude` | none (UA header) |

## 2. Storage buckets

| bucket | size cap | access | purpose | migration |
|---|---|---|---|---|
| `chat` | 5 MB | public read | chatbot assets (images, audio, PDFs, SVGs); subfolders `default/`, `broker/`, `support/`, `sales/`, `_shared/` | `supabase/migrations/20260508110000_storage_chat_bucket.sql:35` |

## 3. Table categories (11 buckets, ~120 tables)

| # | category | count | examples |
|---|---|---|---|
| 1 | Raw ingest | 18 | `evo_orders`, `espn_athletes`, `seatgeek_seller_listings`, `reddit_pending`, `nws_alert_pending`, `weather_forecast_pending`, `performer_wiki_pending`, `fred_pending` |
| 2 | Snapshots / historical | 8 | `listings_snapshots`, `seatdata_sales_snapshots`, `seatgeek_historic_sales`, `event_competitors_snapshot` |
| 3 | Canonical / normalized | 9 | `espn_teams_canonical`, `sg_events_canonical`, `performer_baselines`, `venue_baselines`, `venue_assets` |
| 4 | Metrics / analytics | 20 | `event_metrics`, `section_metrics`, `zone_metrics`, `event_alerts`, `seatgeek_event_metrics` |
| 5 | Queues / pending | 9 | `venue_geocode_pending`, `sg_listings_pending`, `sg_sales_pending`, `tournament_search_pending` |
| 6 | Signals / why-engine | 2 | `why_signals`, `event_sentiment` |
| 7 | Audit / logs | 1 | `chat_audit_findings` |
| 8 | Mappings / xref | 7 | `event_xref`, `cross_source_entity_maps`, `matchup_xref`, `performer_external_ids`, `performer_espn_team_xref`, `taxonomy_xref` |
| 9 | Cache | 1 | `tevo_ticket_groups_cache` (hourly sweep `15 * * * *`) |
| 10 | Chat / bot | 8 | `bot_messages`, `chat_corpus`, `chat_aliases`, `chat_glossary_known`, `chat_stopwords`, `chat_term_frequency` |
| 11 | Config / master | 31 | `data_sources`, `sporting_rivalries`, `holidays`, `macro_series_config`, `news_keywords`, `performer_subreddits`, `order_fee_schedule` |

## 4. Orphan / cleanup candidates — **see Corrections section at top of doc**

### Tables — **WITHDRAWN**

The 2 SG view-artifact claims were wrong. `seatgeek_listings_snapshots` and `seatgeek_sales_snapshots` are live tables with cron writers and dashboard readers. See Corrections.

The 3 `_readme` markers remain **intentional** per TEST SCHEMAS Option C (AGENTS.md:260).

**Net cleanup candidates: 0 tables.**

### Edge functions — **mostly intentional, not orphans**

The 8 "dormant" functions are intentionally manual or frontend-invoked:
- `collect`, `collect-listings` — driven by the TEvo cron lattice via separate scheduling migrations
- `bulk-add-watchlist`, `seed-home-venues`, `tevo-perf-find` — frontend-triggered admin
- `espn`, `espn-rosters` — frontend / on-demand
- `wiki-collect` — intentional manual admin tool (targeted refresh + rivalries; unique vs SQL+pg_net pipeline)

Cron-active (5 named in original audit; many more SQL-driven crons via pg_net pattern, ~84 total scheduled jobs across the migrations).

### Data sources — **all 11 are scheduled**

| source | scheduled? | reference |
|---|---|---|
| TEvo (collect-listings) | yes | 5-tier cron lattice |
| ESPN (collect) | yes | `20260507000021_espn_collect_cron_schedules.sql` |
| SeatGeek | yes | multi-migration cron chain incl. `20260509360000` orphan auto-backfill |
| SeatData | yes (budget-capped) | `20260509060000_seatdata_integration.sql` |
| Wikipedia | yes | `20260509170000_performer_wikipedia_enrichment.sql:235-249` (3 crons) |
| NOAA / NWS | yes | `20260509560000_nws_active_weather_alerts.sql:792-809` (4 crons) |
| Open-Meteo | yes | `20260509260000_weather_integration.sql:357-358` |
| FRED | yes | `20260510130000_fred_macro_indicators_umcsent.sql:264-268` |
| Reddit RSS | yes | `20260509410000_betting_odds_and_reddit_signals.sql:477-491` |
| Anthropic Claude API | n/a (LLM, request-driven) | edge function `chat` |
| OSM Nominatim | yes | `20260509260000_weather_integration.sql:355-356` |

## 5. Architecture drift — AGENTS.md stale

`AGENTS.md` ARCHITECTURE diagram (line 49) declares:

> **TWO data sources.** TEvo API + ESPN.

Reality: **11 sources wired**, 7 actively pulling on cron. The "two-source" framing was accurate through 2026-05-08; subsequent SeatGeek / SeatData / Wikipedia / NOAA / Open-Meteo / FRED / Reddit / Nominatim integrations (all timestamped 2026-05-09 in LOG) are not reflected in the diagram.

**Recommendation (A1):** refresh ARCHITECTURE diagram on next push to reflect the current 11-source data plane, or explicitly mark auxiliaries as "context overlays" if the diagram is meant to show only the running backbone.

## 6. Recommended next actions (post-correction)

The original recommendations are mostly retracted. Updated list:

### In C1 lane (no push needed)
1. None. All 11 data sources are scheduled. The `wiki-collect` edge function is intentionally manual.

### Handoff to A1 (requires push)
1. **Real fix needed:** `seatgeek_event_xref` matching pipeline runs at listing-ingest time only. Add an order-side matcher that walks `seatgeek_orders.sg_event_id` and creates xref rows for SG events that have orders. (Methodology in `docs/cross-source-entity-resolution-2026-05-11.md` Layer 3 Path A.)
2. **Real fix needed:** Path B for the 400 historical SG orders (no TEvo event row available) — resolve `tevo_venue_id` + `tevo_performer_ids` directly on each order. Methodology validated at 19.8% full match / 67.8% venue with exact-name only.
3. **Doc refresh:** AGENTS.md ARCHITECTURE diagram says "TWO data sources." Reality is 11. Refresh on next push.
4. **No table drops needed.** The earlier recommendation to drop 2 SG view-artifact tables was based on a misread of migration history.

### Handoff to B1 (audit views consumer)
Corrected drift report. The earlier "5 orphan tables / 8 dormant functions / 3 under-pulled sources" framing was wrong. Real drift signal is now limited to (a) `seatgeek_event_xref` covering 0/186 sg_event_ids with orders, and (b) AGENTS.md ARCHITECTURE staleness.

## Appendix — file references

| topic | file:line |
|---|---|
| TEvo client | `supabase/functions/collect/index.ts:16`, `collect-listings/index.ts:27` |
| ESPN ingest | `supabase/functions/espn/index.ts:43`, `espn-rosters/index.ts:7` |
| SeatGeek integration | `supabase/migrations/20260509080000_seatgeek_integration.sql` |
| SeatData integration | `supabase/migrations/20260509060000_seatdata_integration.sql` |
| Wikipedia ingest | `supabase/functions/wiki-collect/index.ts:14`, `supabase/migrations/20260509170000_performer_wikipedia_enrichment.sql` |
| NOAA alerts | `supabase/functions/why-noaa-weather-alerts/index.ts:7` |
| Open-Meteo + Nominatim | `supabase/migrations/20260509260000_weather_integration.sql` |
| FRED | `supabase/migrations/20260510130000_fred_macro_indicators_umcsent.sql` |
| Reddit RSS | `supabase/migrations/20260509410000_betting_odds_and_reddit_signals.sql` |
| Storage bucket | `supabase/migrations/20260508110000_storage_chat_bucket.sql:35` |
| Test schemas (Option C) | `supabase/migrations/20260508120000_test_schemas_per_agent.sql`; AGENTS.md:260 |
| Stale arch diagram | `AGENTS.md:49` |
