# Data sources audit — 2026-05-11

Produced by C1 (Data + Chat Bot, supervisor). Handoff target for git work: A1 (Primary/Audit/Push). Branch: `claude/audit-data-sources-b7EGu`.

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

## 4. Orphan / cleanup candidates

### Tables (5)

| table | created in | actual status |
|---|---|---|
| `seatgeek_listings_snapshots` | `20260507000004_product_separation_views.sql:53` | view artifact from product-separation refactor; only referenced inside the view layer, not by any edge function or frontend |
| `seatgeek_sales_snapshots` | same migration | same — view artifact, not actively consumed |
| `code_staging._readme` | `20260508120000_test_schemas_per_agent.sql` | **INTENTIONAL — keep.** Sandbox marker for A1's test schema (TEST SCHEMAS Option C, AGENTS.md:260) |
| `copilot_test._readme` | same | **INTENTIONAL — keep.** Sandbox marker for copilot lane |
| `design_test._readme` | same | **INTENTIONAL — keep.** Sandbox marker for design lane |

Net cleanup candidates: **2** (the two SeatGeek view artifacts). The three `_readme` tables are part of the multi-agent test-schema convention and must not be dropped.

### Edge functions — dormant (8 of 14)

These have no cron schedule. They run only on manual trigger or frontend invocation. Flag for review of intent (paused vs. accidentally unscheduled):

| function | invocation path |
|---|---|
| `collect` | manual / frontend |
| `collect-listings` | manual / frontend (see note below) |
| `bulk-add-watchlist` | frontend |
| `espn` | frontend |
| `espn-rosters` | manual only |
| `seed-home-venues` | manual only |
| `tevo-perf-find` | frontend |
| `wiki-collect` | manual only |

Cron-active (5): `backfill-event-configurations`, `crawl-venues-and-performers`, `crawl-espn-team-assets`, `espn-collect`, `chat`.

**Notable:** `wiki-collect` has a queue table (`performer_wiki_pending`) and async ingest pattern but no cron drains it on a schedule — items accumulate unless triggered.

**Note on `collect-listings`:** despite appearing "dormant" by static inspection, it is driven by the 5-tier TEvo cron lattice (AGENTS.md DATA FLOW: 20m / 1h / 4h / 12h / daily). Confirm whether cron lives in a separate scheduling migration before flagging.

### Data sources — under-pulled (3 of 11)

| source | wired? | scheduled? | recommendation |
|---|---|---|---|
| Open-Meteo | yes (schema + queue tables) | **no active cron** | C1 decision: schedule forecast pulls or document why deferred |
| Reddit RSS | yes (15 migrations, `reddit_pending` table) | **no direct cron** (only referenced in chat audit) | C1 decision: schedule or deprecate |
| OSM Nominatim | yes (used by weather geocode) | reactive only | likely correct — geocoding is event-driven, not scheduled |

## 5. Architecture drift — AGENTS.md stale

`AGENTS.md` ARCHITECTURE diagram (line 49) declares:

> **TWO data sources.** TEvo API + ESPN.

Reality: **11 sources wired**, 7 actively pulling on cron. The "two-source" framing was accurate through 2026-05-08; subsequent SeatGeek / SeatData / Wikipedia / NOAA / Open-Meteo / FRED / Reddit / Nominatim integrations (all timestamped 2026-05-09 in LOG) are not reflected in the diagram.

**Recommendation (A1):** refresh ARCHITECTURE diagram on next push to reflect the current 11-source data plane, or explicitly mark auxiliaries as "context overlays" if the diagram is meant to show only the running backbone.

## 6. Recommended next actions

### In C1 lane (no push needed)
1. Decide on Open-Meteo, Reddit RSS, Wikipedia (`wiki-collect`) cron scheduling — schedule, deprecate, or document as deferred.
2. Verify `collect-listings` cron lattice is intact (cross-check `cron.schedule` calls in migrations).

### Handoff to A1 (requires push)
1. Commit this audit doc + LOG entry under today's date.
2. Drop the 2 SeatGeek view artifacts (`seatgeek_listings_snapshots`, `seatgeek_sales_snapshots`) — preceded by a grep confirming no view/function still references them.
3. Refresh `AGENTS.md` ARCHITECTURE diagram from 2 → 11 sources (or annotate the two-source framing as "running backbone only").
4. Cascade orphan findings into S1's drift trigger system via `event_xref` (per bot-hierarchy chart).

### Handoff to B1 (audit views consumer)
This document is the drift report B1 receives from the S1 → B1 channel. No direct action required from B1 until S1 emits its derived view.

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
