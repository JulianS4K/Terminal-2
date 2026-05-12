# View dependency + RLS coverage audit — 2026-05-11 (continued)

Produced by C1 (Data + Chat Bot, supervisor). Continued audit after PR #57 merge (security wave). Surfaces two material findings A1 and B1 should both see.

## Headline

| metric | value |
|---|---|
| Tables with RLS enabled | **20 of 120** (16.7%) |
| Tables with RLS DISABLED | **100 of 120** (83.3%) |
| Top-dependency table (`events`) | **39 dependent views** |
| Total view layer | 136 views + 1 matview |
| View stacking observed | yes — `v_event_base` has 10 dependent views |

## 1. View dependency map (top 20 tables)

The tables most "load-bearing" for the view layer. Any column-shape change here has wide blast radius:

| underlying table | dependent views | blast radius |
|---|---|---|
| `events` | **39** | catastrophic — any column rename breaks 39 views |
| `listings_snapshots` | 13 | high — touched by storage-growth fix concerns |
| `event_xref` | 12 | high — canonical lane writes; audit lane bumps |
| `seatgeek_orders` | 11 | high — proposed `seatgeek_orders_resolved` FK target |
| `sg_events_canonical` | 11 | high — canonical layer |
| `v_event_base` | 10 | **view-on-view** — view stacking depth ≥ 2 |
| `espn_event_snapshots` | 9 | medium |
| `performer_metadata` | 9 | medium |
| `evo_orders` | 9 | medium |
| `seatgeek_listings_snapshots` | 9 | medium — the table I mistakenly flagged as orphan in initial audit |
| `seatgeek_seller_listings` | 8 | medium |
| `evo_order_items` | 8 | medium |
| `venue_assets` | 8 | medium |
| `seatdata_sales_snapshots` | 7 | medium |
| `seatgeek_event_xref` | 6 | medium |
| `seatdata_event_xref` | 6 | medium |
| `event_metrics` | 6 | medium |
| `weather_observations` | 6 | medium |
| `performer_external_ids` | 5 | low |
| `reddit_posts` | 5 | low |

### Architectural implication

The original audit doc flagged "136 views > 120 tables" as a high-blast-radius pattern. **Confirmed.** `events` alone backs 39 views — touching it requires updating all 39, plus any downstream view-on-view chains. View dependency mapping must precede any column rename / type change on the top-7 tables.

**View stacking is real.** `v_event_base` has 10 dependent views, meaning the system has at least 2-level view hierarchies. Recursive dependency mapping is needed to catch full impact before schema-shape changes.

## 2. RLS coverage gap — 100 of 120 tables uncovered

PR #57 (merged 18:56 UTC) added RLS rollout migrations:
- `20260511000300` — RLS on operational tables (applied — accounts for the 20 RLS-on tables)
- `20260511000400` — RLS on domain tables (**DRAFT in PR #57**, requires §C verification before apply)

**The DRAFT migration has not yet been applied.** Result: 100 of 120 tables (83.3%) are without RLS.

### Tables WITH RLS (20) — operational tier from `000300`

`bot_messages`, `bot_users`, `chat_rate_limits`, `espn_event_snapshots`, `espn_injuries_snapshots`, `espn_news`, `espn_runs`, `espn_team_snapshots`, `event_metrics`, `event_pulls`, `event_xref`, `leads`, `listings_snapshots`, `performer_zone_rules`, `performer_zones`, `pull_rate_limits`, `section_metrics`, `settings`, `venue_assets`, `zone_rules`

### Tables WITHOUT RLS (100) — gap

Categorized for B1's runbook:

| category | examples | risk level |
|---|---|---|
| **SeatGeek raw data** | `seatgeek_orders`, `seatgeek_listings_snapshots`, `seatgeek_sales_snapshots`, `seatgeek_seller_listings`, `seatgeek_historic_sales`, `seatgeek_order_tickets`, `seatgeek_pull_log`, `seatgeek_seller_pull_log` | HIGH — broker order data |
| **SeatData** | `seatdata_event_stats`, `seatdata_listings_snapshots`, `seatdata_sales_snapshots`, `seatdata_pull_budget`, `seatdata_pull_log` | HIGH — paid data + budget |
| **TEvo orders** | `evo_orders`, `evo_order_items`, `evo_orders_pending`, `evo_event_backfill_pending` | HIGH — broker order PII |
| **Chat infra** | `chat_aliases`, `chat_audit_findings`, `chat_corpus`, `chat_glossary_known`, `chat_stopwords`, `chat_term_freq_in`, `chat_term_freq_out`, `chat_term_frequency` | MEDIUM — user query data |
| **All `*_pending` queues** (16) | `nws_alert_pending`, `weather_forecast_pending`, `reddit_pending`, etc. | MEDIUM — operational metadata |
| **Cross-source xref** | `canonical_external_ids`, `matchup_xref`, `order_status_xref`, `taxonomy_xref`, `performer_external_ids`, `performer_espn_team_xref`, `seatdata_*_xref` (5), `seatgeek_*_xref` (3) | MEDIUM — mapping data |
| **Canonical / metrics** | `sg_events_canonical`, `seatgeek_event_metrics`, `zone_metrics`, `event_alerts`, `event_match_attempts`, `event_competitors_snapshot`, `event_sentiment` | MEDIUM |
| **Performer / venue context** | `performer_baselines`, `performer_crawl_state`, `performer_home_venues`, `performer_metadata`, `performer_subreddits`, `performer_wikipedia`, `performer_wiki_pending`, `venue_baselines`, `venue_crawl_state` | MEDIUM |
| **NWS / weather** | `nws_alerts`, `nws_alert_references`, `nws_alert_zones`, `weather_observations` | LOW — public data |
| **ESPN** | `espn_athletes`, `espn_athlete_team_history`, `espn_teams_canonical`, `espn_asset_crawl_state`, `espn_event_date_lookup`, `espn_tournament_events`, `espn_tournament_pending`, `espn_scoreboard_pending` | LOW — public data |
| **Reference / config** | `data_sources`, `data_source_field_map`, `holidays`, `major_event_calendar`, `mlb_branded_series`, `news_keywords`, `order_fee_schedule`, `school_break_windows`, `sporting_rivalries`, `important_x_accounts`, `general_subreddits`, `watch_sources`, `watchlist` | LOW |
| **Other** | `events`, `snapshots`, `runs`, `tevo_ticket_groups_cache`, `tournament_categories`, `tournament_search_queries`, `tournament_search_pending`, `tournament_category_pending`, `venue_pulls`, `venue_geocode_pending`, `venue_nws_points_pending`, `why_signals`, `reddit_posts` | varies |

### Risk assessment for B1

**The HIGH-risk gap is broker-side order data** — TEvo + SeatGeek + SeatData orders + listings + budget tables are all RLS-OFF. Service role + JWT auth still protect via app layer, but no defense-in-depth at DB layer. This is exactly what `20260511000400` was designed to close.

**Recommendation:** B1 should complete the `20260511000400` verification + apply per #57's §C procedure. Once applied, expected RLS coverage rises from 20 → ~100+ tables, leaving only a handful (config, pure reference) intentionally open.

### Impact on the proposed-tables packet (#58)

All 7 proposed tables would land into a partial-RLS world. Two options for A1:

1. **Wait for `20260511000400` to apply first**, then each new table includes RLS from day one in its own migration
2. **Add RLS to each new-table migration regardless** of when `000400` lands

Recommend option 2 — every new-table migration enables RLS + adds policies for `service_role` (write) and `coworker_readonly` (select). This way, new work doesn't widen the gap regardless of `000400` timing.

## 3. Findings summary for upchain

### For A1 (review)
- View dependency map shows `events` is load-bearing for 39 views; any schema change must be view-impact-mapped first
- `v_event_base` has 10 dependent views (view stacking ≥ 2 levels)
- Proposed-tables migrations should each include their own `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + policies, not assume `000400` applies first

### For B1 (security)
- RLS coverage is 20/120 (16.7%) post-#57 merge
- `20260511000400` (domain RLS) is DRAFT — needs §C verification + apply
- HIGH-risk gap: broker order data (TEvo + SG + SeatData orders/listings/budgets) all RLS-OFF
- Once `000400` applied, expect coverage to jump to ~100/120; remaining gap is intentional (config + pure reference tables)

## Hand-off

| owner | action |
|---|---|
| **C1** (in-lane) | This continuation closes the view-dependency + RLS-coverage audit slice. |
| **A1** (push) | Adjust proposed-tables migrations to include per-table RLS + policies; review against view-dependency blast-radius before any column rename. |
| **B1** (security) | Apply `20260511000400` after §C verification. RLS coverage tracking should be ongoing. |
