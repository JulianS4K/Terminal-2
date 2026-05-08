# SCHEMA.md — Backend architecture lock

**Version**: `2026-05-09-v1`
**Last verified against prod**: 2026-05-09 ~00:30 UTC (Supabase project `hzrizjeaxlqcxfrtczpq`)
**Authority**: this file. Future agents should read SCHEMA.md before proposing backend changes.

This is a snapshot of every table, function, RPC, cron, and edge-function in
the Terminal-2 backend at the time of writing. **It is intended to drift** —
when it does, run the verification queries at the bottom and update this file
in the same commit as the schema change. The version label above is the
contract.

---

## Migration ledger (prod truth)

Last 8 applied migrations from `__sync_check_list_migrations()`:

```
20260508184642  20260508140000_espn_team_and_venue_assets
20260508181622  20260508130000_sync_check_helper_rpc
20260508180605  20260508120000_test_schemas_per_agent
20260508180202  20260508110000_storage_chat_bucket
20260508171714  20260508023700_simplify_submit_lead_drop_bot_messages_mirror
20260508171641  20260508023500_fix_get_event_zones_public_numeric_cast
20260508171559  20260508023000_leads_and_rest_wrappers
20260508170500  20260508022000_expand_user_zone_token_to_curated
```

**⚠️ Drift between prod and the migration ledger**: the following changes were
applied to prod via direct `execute_sql` (Supabase MCP) in this code-agent
session and are captured in git as migration files but **have not yet been
recorded in the prod `__sync_check_list_migrations()` table**:

```
20260508220000_auto_link_event_xref.sql
20260508230000_event_splits_metrics.sql
20260508240000_crawl_espn_assets_cron.sql
20260508250000_ensure_major_league_watchlist.sql
20260509000000_zone_metrics_backfill_cron.sql
```

These are real and active in prod (functions exist, crons schedule jobid 31-35),
but `bin/sync-check.sh` will report them as drift until copilot/code applies
them through the standard Supabase migration pipeline. **Action**: either
re-apply via the migration runner (will be no-ops thanks to `IF NOT EXISTS` /
`OR REPLACE` everywhere) or accept the drift report.

---

## The 10 data buckets (canonical taxonomy)

Every column we collect maps to one of these. Use these names when discussing
features so we have shared vocabulary.

| # | Bucket | Source tables | Cardinal columns |
|---|---|---|---|
| 1 | **Pricing** | event_metrics, zone_metrics, section_metrics | retail_min/p25/median/mean/p75/p90/max/sum, getin_price, wholesale_*, derived: IQR/range/CV/skew/tail |
| 2 | **Inventory volume** | event_metrics, zone_metrics, section_metrics, listings_snapshots | tickets_count, groups_count, sections_count, ancillary_tickets/groups, median_group_size, quantity |
| 3 | **Owned position (S4K)** | event_metrics, listings_snapshots (brokerage_id=1768) | owned_tickets_count, owned_groups_count, owned_share, owned_median_retail, is_owned |
| 4 | **Splits & format** | event_metrics splits_*, listings_snapshots | splits_min_q, splits_pct_pairs/singles, splits_listings_with_{1,2,3,4plus,no_split}, format, splits[], in_hand, eticket |
| 5 | **Market structure** | event_metrics | top5_concentration, price_dispersion, tail_premium, sections_active, retail_sum/notional |
| 6 | **Standings & form** | espn_team_snapshots, espn_event_snapshots | wins, losses, ties, win_pct, games_back, playoff_seed, conference_rank, division_rank, record_summary, streak |
| 7 | **Player health** | espn_injuries_snapshots, espn_athlete_team_history | status, injury_type, return_date, transaction_type (traded/released), is_baseline |
| 8 | **Game context** | espn_event_snapshots | state, status_short, home/away_score, odds_provider, spread, over_under, home_ml/away_ml, home_win_prob, attendance |
| 9 | **News & narrative** | espn_news, wiki_summary, wiki_rivalries, wiki_seasons, why_signals | headline, type, published_at, rivalry intensity, season records, weather/why signals |
| 10 | **Map / config / topology** | events, performer_zones (+ rules), zone_rules, venue_assets, performer_metadata | configuration_id/name, seating_chart URLs, fanvenues_key, zone defs, venue capacity/hero, logo_default_url |

---

## Tables (47)

Grouped by bucket. Row counts as of 2026-05-09 (`pg_stat_user_tables.n_live_tup` estimate).

### Bucket 1-5 (TEvo-derived)
- **events** (855 rows) — canonical TEvo event dimension. PK: id. Cols: name, occurs_at_local (text), state, venue_id, venue_name, venue_location, primary_performer_id, primary_performer_name, performer_ids[], last_seen, is_chat_tracked, chat_first_pinged_at, chat_last_pinged_at, chat_ping_count, configuration_id, configuration_name, seating_chart_medium, seating_chart_large, fanvenues_key, popularity_score, long_term_popularity_score, event_type
- **listings_snapshots** (7.84M) — raw per-ticket-group, 60d retention. PK: (event_id, captured_at, tevo_ticket_group_id). Cols: section, row, quantity, retail_price, wholesale_price, format, splits[], wheelchair, instant_delivery, eticket, is_ancillary, type, office_id, office_name, brokerage_id, brokerage_name, is_owned
- **event_metrics** (25.9k) — per-event aggregations, indefinite retention. PK: (event_id, captured_at). 36 cols including all retail/wholesale percentiles + owned aggregates + splits inventory
- **zone_metrics** (6k) — per-zone aggregations. PK: (event_id, captured_at, zone). 24 cols
- **section_metrics** (1.86M) — per-section aggregations. PK: (event_id, captured_at, section). 26 cols
- **snapshots** (223) — legacy per-event snapshot summary, not actively used; kept for backwards-compat
- **tevo_ticket_groups_cache** — 90s TTL cache for /api/broker/event/{id}/raw-tevo. Cols: event_id, payload jsonb, captured_at, expires_at
- **runs** (1.5k) — collect-listings cron run log
- **event_pulls** — per-pull audit trail. Cols: event_id, source, requester, requested_at, served_from (live|cache), snapshot_age_seconds, tevo_calls
- **pull_rate_limits** — rate-limit config per scope

### Bucket 6-9 (ESPN + wiki + signals)
- **espn_event_snapshots** — per-game state at capture time. Cols: espn_event_id, espn_league, captured_at, state, status_short, home_team_id, away_team_id, home_score, away_score, odds_provider, spread, over_under, home_ml, away_ml, home_win_prob, attendance, content_hash, last_seen_at, is_baseline
- **espn_team_snapshots** (320) — standings over time per team. Cols: espn_team_id, espn_league, captured_at, wins, losses, ties, win_pct, games_back, playoff_seed, conference_rank, division_rank, record_summary, standing_summary, streak, content_hash, last_seen_at, is_baseline
- **espn_injuries_snapshots** (2.85k) — injury rows over time. Cols: espn_team_id, espn_league, captured_at, athlete_id, athlete_name, position, status, injury_type, short_comment, long_comment, return_date, content_hash, last_seen_at, is_baseline
- **espn_news** (523) — per-team news headlines. Cols: espn_article_id, espn_team_id, espn_league, headline, description, published_at, url, image_url, type
- **espn_athletes** (857) — athlete dimension
- **espn_athlete_team_history** (857) — transactions (traded/released)
- **espn_runs** — espn-collect cron run log
- **wiki_summary** — performer wiki extracts
- **wiki_rivalries** — rivalry pairs with intensity score
- **wiki_seasons** — historical season records per performer
- **why_signals** — weather/news/etc signals

### Bucket 10 (Topology / external)
- **performer_metadata** (883) — performer dim + ESPN logos/colors. 30 cols including logo_default_url, color_primary, color_alternate, espn_team_url, etc.
- **performer_external_ids** (217) — performer ↔ ESPN/SeatGeek/etc mapping
- **performer_home_venues** (215) — home venue per (performer, league)
- **performer_zones** (179) — curated zone definitions per (performer, venue)
- **performer_zone_rules** (3.5k) — section-range rules tied to performer_zones
- **zone_rules** — global keyword fallback rules used by `derive_zone_fallback`
- **venue_assets** — venue images, capacity, indoor flag
- **event_xref** — TEvo event ↔ ESPN event linker
- **performer_crawl_state** — crawler queue state per performer
- **venue_crawl_state** — crawler queue state per venue
- **espn_asset_crawl_state** (169) — logo crawl queue, drained 2026-05-08

### Watchlist + retail
- **watchlist** (328) — 183 performers + 145 venues
- **watch_sources** (1.5k) — expanded watchlist → event_ids
- **leads** — retail web inquiries

### Chat (copilot's lane, listed for completeness)
- **chat_aliases** (3.3k) — performer/venue/zone alias mappings for the chat NLU
- **chat_corpus** — chat conversation history
- **chat_glossary_known** — known terms
- **chat_stopwords** — filtered terms
- **chat_term_frequency / chat_term_freq_in / chat_term_freq_out** — term frequency split
- **chat_audit_findings** — daily audit results
- **chat_rate_limits** — IP rate limit ledger
- **bot_messages** — channel I/O log
- **bot_users** — internal/external user table

### Settings
- **settings** — KV store for tokens, secrets, feature flags

---

## SQL functions / RPCs (73)

Grouped by purpose:

### Event-level metric computation
- `compute_event_zone_metrics(event_id, captured_at) → int` — full zone aggregation from listings_snapshots, UPSERT into zone_metrics. **Wrapped by** `backfill_stale_zone_metrics`.
- `compute_event_section_metrics(event_id, captured_at) → int` — per-section aggregation
- `compute_event_splits_metrics(event_id) → table` — splits aggregation, UPDATE event_metrics
- `compute_event_breakdowns(event_id, captured_at) → jsonb` — combined zone+section computation
- `backfill_event_splits_metrics(max) → table` — batch wrapper, called by cron
- `backfill_stale_zone_metrics(max) → table` — batch wrapper, called by cron

### Zone resolution (section → zone)
- `match_performer_zone(performer_id, venue_id, section, row) → text` — curated rule lookup
- `derive_zone_fallback(section, row) → text` — keyword + digit-prefix heuristic
- `classify_zone_canonical(zone) → text` — canonical zone name
- `_sec_norm(text) → text`, `_sec_prefix(text) → text`, `_sec_suffix(text) → int` — normalization helpers
- `expand_user_zone_token_to_zones(token) → table` — chat NLU helper
- `bulk_generate_system_placeholder_zones() → jsonb` / `generate_system_placeholder_zones(performer_id, venue_id) → int`

### Movers / dashboards / discovery
- `get_event_movers(window_hours) → table` — backs /api/broker/movers + /api/broker/watchlist-movers
- `get_event_zones_rollup(event_id, owned_only) → table` — slim per-zone rollup (5 cols)
- `get_event_zones_public(event_id) → table` — retail-safe variant for chatbot
- `get_broker_event_detail(event_id) → table` — backs /api/broker/event/{id}/overview event header
- `get_broker_events_upcoming() → table` — broker upcoming list
- `broker_performer_dashboard(performer_id) → jsonb`
- `broker_recent_intel() → jsonb`
- `get_performers_by_league(league) → table` — HOME vs ROAD aggregates per team
- `get_chat_suggestion_chips() → table`
- `search_events_by_date(date_text) → table`

### Public REST wrappers (retail safe — for chatbot + landing pages)
- `get_events_by_performer_public`, `get_events_by_venue_public`, `get_event_listings_public`, `get_event_assets_public`, `get_performer_assets_public`, `get_performer_landing_public`, `get_venue_assets_public`, `submit_lead_public`

### Crawl / maintenance
- `auto_link_event_xref() → table` — strict-date matcher TEvo ↔ ESPN events
- `ensure_major_league_watchlist_coverage() → table` — bulk-add performers + venues
- `next_performers_to_crawl() → table`, `next_venues_to_crawl() → table`
- `sweep_old_listings() → int`, `sweep_tevo_ticket_groups_cache() → int`, `sweep_old_bot_messages() → void`

### ESPN ingest helpers (used by espn-collect edge fn)
- `upsert_espn_event_snapshot(...) → table`
- `upsert_espn_injury(...) → table`
- `upsert_espn_team_snapshot(...) → table`
- `get_team_context(performer_id) → jsonb`
- `get_team_playoff_context(performer_id) → jsonb`
- `get_team_roster(espn_team_id) → jsonb`
- `get_recent_team_changes(espn_team_id) → jsonb`
- `get_player_info(espn_athlete_id) → jsonb`
- `get_wiki_context(performer_id) → jsonb`
- `is_rivalry_game(home_id, away_id) → jsonb`

### Chat NLU
- `extract_chat_entities(text) → jsonb`
- `tokenize_chat_text(text) → table`
- `audit_chat_message(...) → jsonb`
- `check_chat_rate_limit(ip) → boolean`
- `refresh_chat_corpus() → jsonb`
- `refresh_chat_term_freq_split() → jsonb`
- `run_daily_chat_audit() → jsonb`
- `search_performers_for_chat(q) → table`, `search_performers_typeahead(q) → table`
- `promote_performer_to_aliases() → int`, `promote_venue_to_aliases() → int`
- `mark_event_chat_tracked(event_id) → void`
- `classify_performer_categories(performer_id) → table`
- `map_tevo_category_to_genre(tevo_cat) → text`, `map_tevo_top_category(...) → text`, `map_top_category_to_event_type(...) → text`
- `extract_game_number(name) → int`, `extract_opponent(name, team) → text`, `classify_playoff_stage(name) → text`

### Cache
- `get_cached_ticket_groups(event_id) → jsonb`, `put_cached_ticket_groups(event_id, payload) → void`
- `get_or_authorize_pull(...) → jsonb`

### Sync helpers
- `__sync_check_list_migrations() → table` — drift detector RPC
- `event_has_s4k_inventory(event_id) → boolean`

---

## Active crons (21 jobs)

| jobid | name | schedule | what |
|---|---|---|---|
| 1-5 | collect-listings-{0-24h, 1-7d, 7-30d, 30-60d, 60d+} | tier-based (20 min → daily) | TEvo → listings_snapshots → event_metrics + zone_metrics + section_metrics |
| 6 | sweep-old-listings | daily 03:00 | listings_snapshots 60d retention |
| 18 | sweep-bot-messages | daily 04:10 | chat retention |
| 20 | sweep_tevo_ticket_groups_cache | hourly :15 | clear expired raw-tevo cache |
| 21 | refresh-chat-corpus | hourly :30 | chat NLU |
| 24 | espn-roster-10min | every 10 min | injuries + roster |
| 25 | espn-gameday-10min | every 10 min @ 5-59 | events ±24h scores+odds |
| 26 | espn-team-daily | daily 05:00 | standings + news |
| 27 | run-daily-chat-audit | daily 04:00 | chat audit |
| 28 | backfill-event-configurations-5min | every 5 min | events.configuration_id population |
| 29 | refresh-chat-term-freq-split-hourly | hourly :15 | chat NLU |
| 30 | crawl-venues-and-performers-3min | every 3 min | venue + performer discovery |
| 31 | auto-link-event-xref-15min | :05/:20/:35/:50 | TEvo ↔ ESPN event matcher |
| 32 | compute-event-splits-30min | :03/:33 | splits_* metrics backfill |
| 33 | crawl-espn-team-assets-3min | every 3 min | logos + colors crawl (queue drained 2026-05-08) |
| 34 | ensure-watchlist-coverage-daily | daily 06:00 | new ESPN teams → watchlist |
| 35 | backfill-zone-metrics-10min | :04/:14/:24/:34/:44/:54 | recompute zone_metrics for stale events |

---

## Edge functions (Supabase)

Source files in `supabase/functions/`. Currently deployed (verify via Supabase MCP `list_edge_functions`):

- **chat** (v27, copilot) — retail Find Tickets chatbot (Anthropic tool-use loop)
- **collect-listings** (v9, copilot) — TEvo → listings_snapshots ingest, called by 5 collect-listings crons
- **espn** (v2, code) — per-event ESPN aggregator, called by /api/broker/event/{id}/espn
- **espn-collect** (v6, code) — multi-scope ESPN ingest (roster/gameday/team_daily)
- **tevo-perf-find** (v2, code) — admin TEvo performer lookup
- **seed-home-venues** (v1, copilot) — bulk-seed performer_home_venues
- **bulk-add-watchlist** (v1, copilot) — bulk watchlist insert
- **probe-tevo-category** (v1, copilot) — diagnostic
- **probe-tevo-performer** (v2, copilot) — diagnostic
- **probe-tevo-events-by-venue** (v1, copilot) — venue event sweep helper
- **probe-seating-charts** (v1, copilot) — diagnostic
- **wiki-collect** (v1, copilot) — Wikipedia performer ingest
- **why-noaa-weather-alerts** (v1, copilot) — weather signals → why_signals
- **crawl-venues-and-performers** (v2, copilot) — discovery crawler
- **backfill-event-configurations** (v2, copilot) — events.configuration_id filler
- **espn-rosters** (v2, copilot) — roster fetcher
- **crawl-espn-team-assets** (v2, copilot) — logos/colors fetcher
- **probe-espn-data** (v1, code) — diagnostic
- **diag-ticket-groups** (v6, copilot) — diagnostic

---

## Backend API surface (FastAPI on Railway)

All routes under `https://glorious-appreciation-production-a6ce.up.railway.app/`, gated by Supabase Google OAuth (`@s4kent.com`).

### Public bootstrap
- `GET /api/public/config` — Supabase URL + anon key for browser auth init

### Auth-gated (all require Bearer token)
- `GET /api/config` — env summary
- `GET /api/events?q=` — TEvo event search
- `GET /api/events/{id}` — TEvo event detail
- `GET /api/events/{id}/series` — historical price series
- `GET /api/events/{id}/sections/series` — section-level series
- `GET /api/performers?q=` — TEvo performer search
- `GET /api/performers/{id}` — TEvo performer detail
- `GET /api/venues?q=` — TEvo venue search
- `GET /api/venues/{id}` — TEvo venue detail
- `GET /api/configurations` / `/api/configurations/{id}` — TEvo config browse
- `GET /api/portfolio?performer_id|venue_id|watchlist_only=` — aggregated portfolio with `is_home` flag for performer-filtered queries
- `GET /api/watchlist` (GET, POST, DELETE/{id}) — watchlist CRUD
- `GET /api/runs` — collect-listings cron history
- `GET /api/snapshots/latest` — latest_snapshots view
- `GET /api/snapshots/velocity` — event_velocity view
- `POST /api/collect/run` — manual collector trigger
- `POST /api/admin/seed-home-venues?league=` — admin home venue bulk-seed
- `GET /api/broker/leagues` — static league list for the league strip
- `GET /api/broker/performers/by-league/{league}` — HOME/ROAD aggregates per team
- `GET /api/broker/movers?window_hours=` — top winners/losers x12
- `GET /api/broker/watchlist-movers?window_hours=&sort=&limit=` — watchlist-filtered movers
- `GET /api/broker/news?limit=&league=&team_ids=&event_id=` — ESPN news feed (event_id resolves home/away team_ids automatically)
- `GET /api/broker/event/{id}/overview` — header + 28 metric KPIs with deltas + zones rollup + home/away assets
- `GET /api/broker/event/{id}/section-metrics` — per-section
- `GET /api/broker/event/{id}/section-zones` — section→zone resolution map
- `GET /api/broker/event/{id}/zones?include_parking=` — single-source zone breakdown (curated > fallback > unmapped)
- `GET /api/broker/event/{id}/raw-tevo?force=` — full ticket_groups payload (90s cache)
- `GET /api/broker/event/{id}/espn` — proxy to espn edge fn
- `GET /api/broker/event/{id}/chart-data?range=&hours=&days=` — full time-series for chart workbench
- `GET /api/broker/event/{id}/cadences` — per-section poll cadences
- `GET /api/broker/performer/{id}/espn` — ESPN context for performer
- `GET /api/broker/performer/{id}/assets` — logo + colors

### Page routes
- `GET /` — broker terminal (was `/terminal/v1`, promoted 2026-05-08)
- `GET /terminal/v1` — alias for `/`
- `GET /legacy` — pre-redesign terminal (preserved for watchlist add modal, configurations browse, snapshots, runs)
- `GET /chat` — retail Find Tickets chatbot
- `GET /event/{id}` — broker event detail (Stage 1+2 chart workbench)
- `GET /movers` — full movers report

---

## Data flow / cadence diagram

```
TEvo API ──┐
           ├──► collect-listings cron (5 tiers, 20m → daily)
           │     └──► listings_snapshots ────┐
           │            └──► event_metrics + zone_metrics + section_metrics
           │
           ├──► /api/broker/event/{id}/raw-tevo (90s cache)
           │     └──► tevo_ticket_groups_cache
           │
           └──► /api/events, /api/performers, /api/venues (live)

ESPN API ──┐
           ├──► espn-collect cron (3 scopes: roster/gameday/team_daily)
           │     └──► espn_team_snapshots, espn_injuries_snapshots, espn_event_snapshots
           ├──► espn-collect (news scope, daily)
           │     └──► espn_news
           ├──► crawl-espn-team-assets cron (3min)
           │     └──► performer_metadata (logos/colors)
           └──► espn fn (per-event aggregator)

Wiki ──────► wiki-collect fn → wiki_summary, wiki_rivalries, wiki_seasons
NOAA ──────► why-noaa-weather-alerts → why_signals

watchlist ──► watch_sources ──► collect-listings tracks all expanded events
ensure-watchlist-coverage-daily ──► watchlist (auto-add ESPN-mapped teams)

auto-link-event-xref-15min ──► event_xref (TEvo ↔ ESPN matcher)
backfill-zone-metrics-10min ──► zone_metrics (catches collect-listings gaps)
compute-event-splits-30min ──► event_metrics splits_* columns
```

---

## Verification queries (run before/after schema work)

```sql
-- 1. Full table inventory + col aggregation
SELECT t.table_name, string_agg(c.column_name || ' ' || c.data_type, ', ' ORDER BY c.ordinal_position)
FROM information_schema.tables t
JOIN information_schema.columns c ON c.table_schema=t.table_schema AND c.table_name=t.table_name
WHERE t.table_schema='public' AND t.table_type='BASE TABLE' GROUP BY t.table_name ORDER BY t.table_name;

-- 2. SQL functions
SELECT p.proname, pg_get_function_result(p.oid)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND p.prokind='f' ORDER BY p.proname;

-- 3. Active crons
SELECT jobid, jobname, schedule, active FROM cron.job ORDER BY jobid;

-- 4. Migration ledger
SELECT version, name FROM __sync_check_list_migrations() ORDER BY version DESC LIMIT 10;

-- 5. Approx row counts
SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='public' ORDER BY n_live_tup DESC LIMIT 25;
```

---

## Lock-down rules for future agents

1. **Read this file first** before proposing any backend change. The 10-bucket
   taxonomy is canonical — when adding new metrics, place them in the correct
   bucket and reference it in commit messages.
2. **Don't drop or rename columns** without bumping the SCHEMA.md version label
   and updating dependent endpoints in app.py + edge functions in the same
   commit.
3. **bid_ask_proxy is permanently dropped** (mig 20260428000001). Don't re-add.
4. **listings_snapshots has 60d retention** — anything older is gone (sweep-old-listings cron).
5. **occurs_at_local is text**, not timestamptz. Cast with `::timestamptz`.
   No `occurs_at` column exists.
6. **espn_team_id is league-scoped** — same id `"10"` exists across NHL/NBA/NFL/MLB
   for different teams. Always filter by `(espn_team_id, espn_league)` together.
7. **Migrations applied via execute_sql don't appear in `__sync_check_list_migrations()`**
   until run through the proper migration pipeline. Track drift via this file.
8. **collect-listings is copilot's lane**, broker SQL is code's lane, chat fn
   is copilot's, espn/espn-collect/tevo-perf-find are code's. Cross-lane
   changes need a WAIT note in AGENTS.md per RULE 11.
9. The 10 buckets are **the canonical UI organization** — chart pills, terminal
   view templates, and metric panels should align with them.

---

## Change log

- **2026-05-09-v1** (this version): initial lock. 47 tables, 73 functions,
  21 active crons. Drift flagged: 5 migrations applied via MCP not yet in
  prod migration ledger. Schema verified against prod 2026-05-09 ~00:30 UTC.
