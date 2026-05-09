# SCHEMA.md — Backend architecture lock

**Version**: `2026-05-09-v12`
**Last verified against prod**: 2026-05-09 ~04:00 UTC (Supabase project `hzrizjeaxlqcxfrtczpq`)
**Authority**: this file. Future agents should read SCHEMA.md before proposing backend changes.

> **Process discipline (RULE 0)**: Any time we add new data — new table,
> new column, new external feed, new ingest source, new derived metric,
> new price source — it MUST be categorized into a bucket here, with a
> new bucket created if no existing one fits. **Including all price data
> sources** (TEvo, future SeatGeek, future Ticketmaster, etc.).
> Bumping the version label below + appending to the change log is part
> of the same commit as the schema change. SCHEMA.md is the canonical
> source of truth; if it disagrees with prod, this file is wrong and
> needs an update PR.

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

### Additional ML-training buckets (non-duplicated, audited 2026-05-09)

These are signals we already collect that don't fit cleanly in the 10 core
buckets but matter for predictive models (price/demand forecasting, sell-through
likelihood, mispricing detection, etc.). Future ML pipeline should use these
as feature groups.

| # | Bucket | Source tables | Cardinal columns / signals |
|---|---|---|---|
| **11** | **Temporal & calendar** | events.occurs_at_local (text, ISO), event_metrics.captured_at | event_date, event_dow (day-of-week), event_hour (local), days_to_event (computed at request time), is_weekend, is_evening, season tag (winter/spring/summer/fall), holiday window flag (computed) |
| **12** | **Demand & popularity** | performer_metadata, events, watchlist, watch_sources | popularity_score (TEvo), long_term_popularity_score (TEvo), s4k_popularity_boost (manual), is_chat_tracked, chat_ping_count, chat_first_pinged_at (interest signal from retail), upcoming_first / upcoming_last (performer activity window) |
| **13** | **Historical / narrative depth** | wiki_summary, wiki_seasons, wiki_rivalries | wiki extract, founded_year, championships count, season records (wins/losses/finish/postseason), rivalry intensity 0-10, rivalry_name, all_time_summary, notable_moments[], notable_players[] |
| **14** | **External signals (non-ESPN)** | why_signals | scope (event/performer/venue), signal_kind (weather/news/etc), signal_value, weight, source, expires_at — currently NOAA weather alerts via why-noaa-weather-alerts fn; extensible to traffic/news/social |
| **15** | **Brokerage microstructure** | listings_snapshots aggregated | distinct office_id count per event, distinct brokerage_id count, S4K share vs everyone-else, owned/non-owned price spread, brokerage diversity index (HHI on share). NOT yet aggregated into a metrics table — feature would need a SQL view or dedicated columns. |
| **16** | **Classification / taxonomy** *(already documented below)* | performer_metadata, events | top_category_name, parent_category_name, category_name, what_event_type (game/concert/comedy/show), genre, event_type. See "TEvo classification taxonomy" section below. |
| **17** | **Major event calendar (curated)** | major_event_calendar | event_class (F1/NASCAR/Tennis_Major/Golf_Major/Olympics/etc), event_name, venue_name, venue_city, venue_country, tevo_venue_id, window_start/end, recurrence. Tracks non-team-sport events that don't have a TEvo team performer to watchlist. |

### Implementation status of buckets 11-16 for ML

| Bucket | Already collected? | Already aggregated for ML access? |
|---|---|---|
| 11 Temporal | ✅ raw timestamp | ❌ — needs computed feature columns (dow/hour/days_to/season). Recommend a SQL view `event_temporal_features(event_id) → row` |
| 12 Demand | ✅ all fields populated | ⚠️ partially — chat_ping_count is on events, popularity_score on performer_metadata; not joined into a single feature row yet |
| 13 Historical | ✅ wiki_* tables populated by wiki-collect fn | ⚠️ — fields exist but not surfaced in any broker endpoint; chat fn uses them via `get_wiki_context` and `is_rivalry_game` |
| 14 External | ✅ why_signals populated by why-noaa-weather-alerts | ❌ — not yet surfaced in event page or chart workbench. Could be overlay markers on chart |
| 15 Brokerage microstructure | ⚠️ partial — listings_snapshots has office_id/brokerage_id; no rollup | ❌ — needs new `event_brokerage_metrics` table or columns on event_metrics |
| 16 Classification | ✅ all fields populated | ✅ used for HOME/AWAY gate, ESPN context gate, watchlist coverage |

### Recommended ML feature derivation (out of scope to build now, documented for future)

For a price/demand model, the feature row per (event_id, captured_at) would be:

```
# Bucket 1 (target / current price)
retail_median, retail_p25, retail_p75, getin_price, retail_sum

# Bucket 2 (current inventory)
tickets_count, groups_count, sections_count, ancillary_tickets

# Bucket 3 (S4K position)
owned_share, owned_tickets_count, owned_median_retail_premium

# Bucket 4 (splits / format)
splits_pct_pairs, splits_pct_singles, splits_min_q

# Bucket 5 (microstructure)
top5_concentration, price_dispersion, tail_premium

# Bucket 6 (standings — needs xref join)
home_win_pct, home_seed, home_streak_int, away_win_pct, away_seed, away_streak_int

# Bucket 7 (health)
home_active_injuries, away_active_injuries, home_starter_out_count

# Bucket 8 (game context)
spread, over_under, home_ml, home_win_prob, is_playoff, series_state

# Bucket 9 (news / narrative)
home_news_24h_count, away_news_24h_count, rivalry_intensity

# Bucket 10 (config)
venue_capacity, has_seating_chart (bool), zone_curated_count

# Bucket 11 (temporal)
days_to_event, event_dow, event_hour_local, is_weekend, is_evening

# Bucket 12 (demand)
performer_popularity, performer_long_term_popularity, chat_ping_count_30d

# Bucket 13 (historical)
performer_championships, all_time_record_pct, wiki_extract_length (proxy for fame)

# Bucket 14 (external)
weather_severity, weather_kind (rain/snow/clear), traffic_alert_active

# Bucket 15 (brokerage)
distinct_brokerages, brokerage_HHI, s4k_premium_vs_market

# Bucket 16 (classification)
top_category_idx (one-hot), parent_category_idx, league_idx, genre_idx, what_event_type_idx
```

**Open work** to make this feature row constructible:

1. Bucket 11 view: `CREATE VIEW event_temporal_features AS SELECT event_id, occurs_at_local::timestamptz - NOW() AS days_to_event, EXTRACT(DOW FROM occurs_at_local::timestamptz), ...`
2. Bucket 13 join: surface wiki via `/api/broker/event/{id}/wiki` (cheap — wiki_summary is small)
3. Bucket 14 overlay: add why_signals to chart-data overlay payload, render as markers
4. Bucket 15 rollup: new SQL fn `compute_event_brokerage_metrics(event_id)` aggregating listings_snapshots by brokerage_id. Add columns to event_metrics: `distinct_brokerages`, `brokerage_hhi`, `non_s4k_share`
5. Reference / target: `/api/broker/ml-feature-row?event_id=N&captured_at=T` returning the joined row above

These are all incremental additions on top of the existing schema — no breaking changes needed.

### Major event calendar workflow (Bucket 17)

For events that don't have a "team performer" in TEvo (F1 races, NASCAR
crown jewels, tennis & golf majors, Olympics), use `major_event_calendar`
as the source of truth.

**Current seed** (mig 20260509010000_major_event_calendar):

| event_class | count | examples |
|---|---|---|
| F1 | 4 | Miami GP (May), Canadian GP (June), US GP / COTA (Oct), Las Vegas GP (Nov) |
| NASCAR | 5 | Daytona 500 (Feb), Coca-Cola 600 (May), Brickyard 400 (Aug), Bristol Night Race (Sep), Talladega 500 (Apr) |
| Tennis_Major | 1 | US Open Tennis (Aug 24 – Sep 6, 14-day window) |
| Golf_Major | 4 | The Masters (Apr), PGA Championship (May), US Open Golf (June), The Players (March) |

**Manual workflow per event** (to bring it into the broker terminal):

1. Look up the venue in TEvo via `/api/venues?q=<venue_name>` and find the
   `tevo_venue_id`. Update `major_event_calendar.tevo_venue_id` in place.
2. Add a watchlist row: `INSERT INTO watchlist (kind, ext_id, label) VALUES ('venue', tevo_venue_id, venue_name)`. The next collect-listings cron tick will pull events at the venue.
3. The expanded `watch_sources` rows then drive listings_snapshots / event_metrics / zone_metrics population for every TEvo event at that venue (including non-target events at the same venue — filter UI by date window if needed).
4. ESPN context will NOT apply (no ESPN team xref); the event page falls back to "External context: ESPN coverage not applicable" — by design.

**Future automation (NEXT for copilot)**: extend collect-listings or write a
new `discover-major-events` edge fn that scans TEvo by venue + date window
in a single pass, auto-populates `major_event_calendar.tevo_venue_id`, and
inserts watchlist rows. Single source of truth = this table.

**Schema bump rule for new event classes**: if a new event class (Olympics,
PWHL playoffs, NCAA tournaments, etc.) is added to this table, no schema
change is needed. If a new field is added to the table itself (e.g.
`broadcast_partner`, `prize_money_tier`), bump SCHEMA.md.

---

### Non-big-6 ESPN coverage gap (recommended next)

User asked to "MAP F1 FACING TO ESPN F1 AND ALL OTHER ESPN PERFORMERS TO THEIR
TEVO PERFORMERS." Audit (2026-05-09) showed:

- **No F1, NASCAR, IndyCar, golf, tennis, or Olympics performers exist in
  TEvo's category tree right now.** The Auto Racing parent has only 4
  Monster Trucks performers. Nothing to map until TEvo adds these.

- **Non-big-6 sports without any ESPN coverage** (despite TEvo having performers):
  - NCAA Football (53 perfs) — ESPN has /college-football API
  - NWSL (12), USL Championship (11), MiLB (10), EPL (8), Bundesliga (4),
    NCAA Hockey (1), AHL (1), CEBL (3), PWHL (2), Intl Hockey (2)
  - MMA (6 individual fighters), Boxing (2), Wrestling (4 NCAA), WWE (5)
  - Cricket (7), Rodeo (8), Volleyball (5), Rugby (2), Lacrosse (1)

- **Big-6 partial gaps** (NFL 32/36, NBA 8/15, NHL 9/17, MLB 30/30, MLS 29/33,
  WNBA 15/18) — most uncovered are **placeholder performers** like
  "NBA Finals", "WNBA All Star Game", "NBA Eastern Conference Finals" which
  shouldn't have a single-team ESPN xref. Current behavior is correct.

**Recommended roadmap** (not implemented in this session):

1. Extend `espn-collect` v6 with new scopes:
   `?scope=ncaa-football` (uses /college-football endpoint, 53 teams)
   `?scope=ncaa-basketball` (when March Madness performers appear)
   `?scope=racing` (when F1/NASCAR appear)
   `?scope=fighting` (UFC, boxing — different shape, fighter-by-fighter)

2. Extend `performer_external_ids` schema: currently keyed `(performer_id,
   source)`. For sports with single performers (UFC fighter, F1 driver), the
   `external_id` is a person id, not a team id. Schema works, just needs
   convention `meta.individual_sport=true` flag.

3. Extend `auto_link_event_xref()` to handle non-team sports — for racing,
   match on race date + circuit name; for fighting, match on event card name.

4. Each new scope = a new bulk-mapping migration. Pattern from
   `20260507000015_espn_world_cup_team_mapping.sql` shows the shape.

This is copilot/code lane work; estimate 1 week per league family.

---

## TEvo classification taxonomy (audited 2026-05-09)

TEvo pushes us a 3-level category tree per performer plus 2 derived
classifications. Inventory of distinct values currently in
`performer_metadata` (883 perfs, 826 with classification):

### `top_category_name` (4 values)

| Value | Count | What it is |
|---|---|---|
| **Concerts** | 441 | Music acts |
| **Sports** | 343 | Teams, leagues, tournaments |
| **Comedy** | 24 | Stand-up, comedy shows |
| **Theater** | 18 | Musicals, plays, ballet, movies |

### Sports subtree (`parent_category_name` → `category_name`)

| Parent | Leaves | Counts |
|---|---|---|
| **Football** (97) | NCAA Football (53), NFL (36), IFL (6), UFL (1), USFL (1) | |
| **Soccer** (81) | MLS (33), NWSL (12), USL Championship (11), World Cup (10), EPL (8), Bundesliga (4), Mexico FMF (1), USL One (1), FA Cup (1) | |
| **Baseball** (44) | MLB (30), MiLB (10), Independent League (4) | |
| **Sports** (41) | generic catch-all (Soccer/Rodeo/Cricket/Volleyball/Football/Rugby/Lacrosse/Fighting/Hockey/Misc) | |
| **Basketball** (36) | WNBA (18), NBA (15), CEBL (3) | |
| **Hockey** (23) | NHL (17), International (2), PWHL (2), NCAA Men's (1), AHL (1) | |
| **Fighting** (17) | MMA (6), WWE (5), Wrestling (4), Boxing (2) | |
| **Auto Racing** (4) | Monster Trucks (4) | |

### Concerts subtree (genres)

Rock & Pop (124), Country & Folk (79), Alt Rock (43), R&B/Urban Soul (37),
Rap & Hip-Hop (36), Hard Rock/Metal (27), Latin (20), Indie (17),
Dance/Electronic (13), New Age (8), World (7), Misc (7), K-Pop (5),
Festivals (4), Classical (4), Family (3), Reggae (2), Jazz (2), DJ (1).

### Theater subtree

Musicals (8), Entertainment Shows (5), Plays (2), Movies (1), Ballet & Dance (1).

### Derived classifications (computed by SQL fns from the leaf category)

**`performer_metadata.what_event_type`** (4 values, rolls up the tree):
- `game` (343) — every Sports performer
- `concert` (441) — every Concerts performer
- `comedy` (24) — every Comedy performer
- `show` (18) — every Theater performer

**`performer_metadata.genre`** (~13 values for non-game performers): rock,
rnb, metal, comedy, latin, family, broadway, k-pop, classical, festival,
theater, folk-world, etc. NULL for `game` performers.

**`events.event_type`** (per-event, derived from primary_performer):
- `game` (612), `concert` (130), `comedy` (1), `show` (1)

### Behavior rules driven by classification

| Feature | Rule | Why |
|---|---|---|
| HOME/AWAY badges + row tints | only when `what_event_type='game'` AND performer has `performer_home_venues` rows | Concerts/comedy/theater have no "home" — Taylor Swift at MSG isn't home, the venue just hosts |
| ESPN context (standings, injuries, news) | only when `what_event_type='game'` AND performer has `performer_external_ids source='espn'` | ESPN doesn't track concerts |
| Watchlist auto-coverage cron | only insert teams with `performer_external_ids source='espn'` AND `league IN (NFL,NBA,NHL,MLB,MLS,WNBA)` | Big-6 sports leagues only |
| Zone curation eligibility | sports OR repeat-venue residencies (Pearl Jam at MSG, Phish at MSG) | Curated zones are venue-specific patterns |

### League → ESPN-tracked map (4-layer matrix, audited 2026-05-09)

ESPN coverage is layered. A "team mapping" is sufficient for performer pages
(standings, season record), but event pages need event-level snapshots +
xref to surface live game state. These are two separate ingestion paths
(espn-collect's `team_daily` vs `gameday` scopes).

| TEvo leaf | Performer mapping (`performer_external_ids`) | Team standings (`espn_team_snapshots`) | Game-day snapshots (`espn_event_snapshots`) | Event xref (`event_xref`) | Where coverage applies |
|---|---|---|---|---|---|
| **NBA** | ✅ 30 | ✅ 30 | ✅ 18 | ✅ 27 | full pipeline — performer + event pages get ESPN |
| **MLB** | ✅ 30 | ✅ 30 | ✅ 56 | ✅ 96 | full pipeline — performer + event pages get ESPN |
| **NFL** | ✅ 32 | ✅ 32 | ❌ | ❌ | performer page only — standings / record show; no live game data |
| **NHL** | ✅ 32 | ✅ 32 | ❌ | ❌ | performer page only |
| **MLS** | ✅ 30 | ✅ 30 | ❌ | ❌ | performer page only — `/api/broker/performer/{id}/espn` returns standings; event page falls back to "ESPN coverage not applicable" since no event xref |
| **WNBA** | ✅ 15 | ✅ 15 | ❌ | ❌ | performer page only |
| **World Cup** | ✅ 48 | ✅ 48 | ❌ | ❌ | performer page only |
| NCAA Football, MiLB, USL, NWSL, EPL, Bundesliga, etc. | ❌ | ❌ | ❌ | ❌ | none — no ESPN ingest |
| Fighting (MMA/Boxing/WWE/Wrestling) | ❌ | ❌ | ❌ | ❌ | none — single-fighter format, ESPN endpoint structure differs |

**Key gap (copilot lane)**: `espn-collect.gameday` scope only pulls NBA + MLB
events. To get game-day snapshots + auto-link xref for MLS/NHL/NFL/WNBA/WC,
extend the `gameday` scope to iterate those leagues' `events?league=...`
endpoints. Same change unlocks all 5 leagues since the underlying
`upsert_espn_event_snapshot()` RPC is league-agnostic.

**`watchlist_auto_coverage_daily`** (jobid 34) adds performer-mapped teams
across all 7 leagues regardless of game-day coverage, since standings still
populate and the watchlist drives TEvo collect-listings (which doesn't
need ESPN at all).

---

## ESPN injury / standings auto-assignment rules

> Locked rules that apply to **every query against the espn_* tables**.
> If you find yourself writing a new query and don't see filters following
> these rules, stop and re-check.

### The cross-league rule (RULE 1)

**ESPN team_id is league-scoped.** `espn_team_id="18"` is simultaneously
NBA Knicks AND MLB Pirates AND NFL Saints AND NHL #18 AND WNBA #18. Same
for every team_id 1-48. Every query against the following tables MUST
filter by `(espn_team_id, espn_league)` together:

| Table | Required filter |
|---|---|
| `espn_team_snapshots` | `WHERE espn_team_id = ? AND espn_league = ?` |
| `espn_injuries_snapshots` | same |
| `espn_news` | same |
| `espn_event_snapshots` | `WHERE (home_team_id = ? OR away_team_id = ?) AND espn_league = ?` |
| `espn_athletes` | `WHERE espn_athlete_id = ? AND espn_league = ?` |
| `espn_athlete_team_history` | `WHERE espn_team_id = ? AND espn_league = ?` |

**Failure mode**: omitting the league filter for Knicks G5 (team_ids
18+20) returned **229 rows where 12 are real** — 95% phantom data from
MLB Pirates, NFL Saints, NHL, WNBA. Caught + fixed in commit `bbd18ed`
(2026-05-09). The `_news_series` and `_injury_load_series` helpers in
`chart-data` were already correct and serve as the canonical template
to follow.

### `espn_injuries_snapshots` schema

```
column            type           notes
─────────────────────────────────────────────────────────────────────────
id                bigint         PK
espn_team_id      text           1-48 per league — combine with espn_league
espn_league       text           NBA | MLB | NFL | NHL | MLS | WNBA | 'World Cup'
captured_at       timestamptz    cron tick when this row was captured
athlete_id        text           ESPN athlete id (sometimes null on league-injury endpoint)
athlete_name      text           player display name
position          text           POS abbr
status            text           'Out' | 'Day-To-Day' | 'Active' | 'Suspended' | etc.
injury_type       text           normalized to lowercase enum
short_comment     text           brief reporter quote
long_comment      text           full reporter context
return_date       timestamptz    expected return date if known
meta              jsonb          raw ESPN row
content_hash      text           used by upsert_espn_injury for change-only ingest
last_seen_at      timestamptz    bumped on every observation (even when nothing changed)
is_baseline       boolean        false = real status flip; true = baseline observation
```

### `is_baseline` semantics + known bug

`is_baseline` is intended to distinguish:
- `true` = an injury captured during initial roster ingest or with no detected change since the prior snapshot (carrier rows)
- `false` = an actual status flip detected via `content_hash` comparison

**Known bug** (espn-collect lane — now code lane during solo phase):
the `is_baseline` detection only fires correctly for **MLB and NHL**. For
NBA / NFL / MLS / WNBA / World Cup, every row is currently `is_baseline=true`,
which means a strict `WHERE is_baseline = false` filter returns 0 rows and
the chart's injury overlay is empty for those leagues despite having
real injury data.

**Frontend mitigation** (already shipped in `0f1924c`): `chart-data`
includes baseline rows and tags each with `is_change` so the UI can
color-code them differently if needed.

**Backend fix needed** (NEXT for code-lane during solo phase):
`upsert_espn_injury` RPC needs the same content_hash comparison logic
the MLB/NHL paths use, applied uniformly across all 5 leagues. After
that fix, the chart could re-tighten the filter to "real flips only"
without losing data.

### `espn_team_snapshots` schema

```
column            type           notes
─────────────────────────────────────────────────────────────────────────
espn_team_id      text           league-scoped (RULE 1)
espn_league       text
captured_at       timestamptz
wins              integer
losses            integer
ties              integer
win_pct           numeric
games_back        numeric
playoff_seed      integer
conference_rank   integer
division_rank    integer
record_summary    text           e.g. "53-29"
standing_summary  text           "1st in Atlantic"
streak            text           "W3", "L1"
content_hash      text           change-only ingest key
last_seen_at      timestamptz
is_baseline       boolean        same semantics + same league bug as injuries
```

### Auto-assignment hooks (where these rules are enforced today)

| Endpoint / RPC | Tables it touches | League-filtered? |
|---|---|---|
| `/api/broker/performer/{id}/espn` | team_snapshots, injuries, news, recent (RPC) | ✅ resolved league via `performer_external_ids.league` then filtered |
| `/api/broker/event/{id}/espn` | proxies espn fn (resolves via event_xref) | ✅ league from xref |
| `/api/broker/event/{id}/chart-data` | 6 ESPN queries: standings × 2, injuries, last5 × 2, roster_moves, news_series × 2, injury_load × 2 | ✅ all 6 filter `(team_id, league)` after `bbd18ed` |
| `/api/broker/news` | espn_news | ✅ accepts league or event_id (resolves to league + team_ids) |
| `auto_link_event_xref()` cron | matches by `(home_team_id OR away_team_id, league, status_short M/D)` | ✅ requires league match |

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

## Active crons (17 jobs as of v8)

**Cascading freshness model (2026-05-09-v8)**: 6 individual freshness crons (espn-roster, espn-gameday, auto-link, splits, zone-backfill, nonowned) collapsed into a single `master-cascade-2min` (jobid 38) that fires every 2 min and runs each stage in dependency order with per-stage try/except. ESPN ingest is async (`pg_net.http_post`); SQL backfills are sync. Zone backfill kept separate (jobid 39) due to a pre-existing 120s-timeout bug in `match_performer_zone` — see "Known issues" callout below.

| jobid | name | schedule | what |
|---|---|---|---|
| 1-5 | collect-listings-{0-24h, 1-7d, 7-30d, 30-60d, 60d+} | tier-based (20 min → daily) | TEvo → listings_snapshots → event_metrics + zone_metrics + section_metrics |
| 6 | sweep-old-listings | daily 03:00 | listings_snapshots 60d retention |
| 18 | sweep-bot-messages | daily 04:10 | chat retention |
| 20 | sweep_tevo_ticket_groups_cache | hourly :15 | clear expired raw-tevo cache |
| 21 | refresh-chat-corpus | hourly :30 | chat NLU |
| 26 | espn-team-daily | daily 05:00 | standings + news |
| 27 | run-daily-chat-audit | daily 04:00 | chat audit |
| 28 | backfill-event-configurations-5min | every 5 min | events.configuration_id population |
| 29 | refresh-chat-term-freq-split-hourly | hourly :15 | chat NLU |
| 30 | crawl-venues-and-performers-3min | every 3 min | venue + performer discovery |
| 33 | crawl-espn-team-assets-3min | every 3 min | logos + colors crawl (queue drained 2026-05-08) |
| 34 | ensure-watchlist-coverage-daily | daily 06:00 | new ESPN teams → watchlist |
| 36 | midnight-catchup-sweep | daily 00:00 | safety-net pass running all idempotent backfills |
| **38** | **master-cascade-2min** | **every 2 min** | **ESPN roster+gameday HTTP (async) → auto_link → splits → nonowned (sync chain)** |
| 39 | zone-backfill-isolated-10min | :04/:14/:24/:34/:44/:54 | `backfill_stale_zone_metrics(5)` — split out from cascade, batch reduced |

**Master cascade per-tick stages** (function `master_cascade_2min`, returns JSONB summary):

| stage | what runs | error mode | typical runtime |
|---|---|---|---|
| 1a | `net.http_post(.../espn-collect?scope=roster)` | per-stage try/except, returns `espn_roster_request_id` or `..._error` | <1ms (fire-and-forget; HTTP work async) |
| 1b | `net.http_post(.../espn-collect?scope=gameday)` | same | <1ms |
| 2a | `auto_link_event_xref()` | per-stage try/except, returns `auto_link_count` or `auto_link_error` | <50ms |
| 2b | `backfill_event_splits_metrics(50)` | same, returns `splits_count` | ~50ms |
| 2c | `backfill_event_nonowned_median(50)` | same, returns `nonowned_count` | ~80ms |

End-to-end cascade tick: ~150-200ms typical (well under the 2-min cycle and the 120s cron statement_timeout). Per-stage isolation means a single bad stage logs an error in the JSONB return and the rest still run.

**Known issues**:
- `match_performer_zone`-driven `compute_event_zone_metrics` consistently exceeded 120s on `backfill_stale_zone_metrics(50)` pre-cascade (jobid 35 was failing every run for hours). Zone backfill kept on its own slower cron with batch=5 + isolation budget. Fix-the-cause NEXT: investigate the LATERAL match cost and add an index on `listings_snapshots(event_id, captured_at, is_ancillary)` if not present.
- `auto_link_event_xref` had a NOT NULL violation on `event_xref.espn_slug` pre-v8 (silently failing on jobid 31). Fixed in mig 20260509040000 with a hardcoded league→slug CASE; NEXT is to replace with a `league_slug` lookup table.

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

- **2026-05-09-v12**: **(a) Vault-backed API keys**, **(b) SeatData↔TEvo
  cross-source mapping**, **(c) EVO orders integration + 10-min cron**,
  **(d) Bucket 18: S4K Order Book**.

  **(a) Supabase Vault for app secrets**: `SEATDATA_API_KEY` is now stored
  in `vault.secrets` and accessed via the new `public.get_app_secret(name)`
  RPC (SECURITY DEFINER, whitelist-gated). seatdata_client loads the key
  via the RPC before falling through to the env-var override. New keys
  get added by extending the whitelist in the function definition AND
  calling `vault.create_secret()`. Single rotation point per key. Whitelist
  currently: `SEATDATA_API_KEY`, `TEVO_API_TOKEN`, `TEVO_SECRET`.

  **(b) SeatData↔TEvo cross-source mapping**: TEvo and SeatData use
  totally different ids for events / venues / performers / zones / sections.
  New tables capture mappings:
    - `seatdata_venue_xref(tevo_venue_id, sd_std_venue_id, ...)`
    - `seatdata_performer_xref(tevo_performer_id, sd_std_event_id, ...)`
    - `seatdata_zone_xref(tevo_event_id, sd_zone, tevo_zone, ...)` — per-event
    - `seatdata_section_xref(tevo_event_id, sd_section, tevo_section, tevo_zone, ...)` — per-event
  Function `normalize_sd_listing(event_id, sd_zone, sd_section, sd_row)`
  resolves any SeatData listing to canonical (zone, section) using lookup
  priority: section_xref → zone_xref → derive_zone_fallback() → unmapped.
  New view `sd_sales_normalized` exposes sales rows with canonical zone
  attached AND fixes the SeatData **quantity-null caveat** (server returns
  `quantity=0` to mean "unknown", not literally zero — view exposes as
  NULL with a `quantity_unknown` flag).

  **(c) EVO orders integration**: TEvo `/v9/orders` gives us the brokerage's
  own order book (pending / accepted / rejected / completed / pending_substitution).
  Different from listings_snapshots (which is the general market). New tables:
    - `evo_orders` — order header (state, totals, buyer/seller/client, timestamps)
    - `evo_order_items` — line items with `event_id` mapped from `ticket_group.event.id`
    - `evo_orders_by_event` view — rollup per event
  Pulled by `POST /api/admin/collect-orders` (cron-secret OR auth-gated). Cron
  `evo-orders-collect-10min` (jobid 40) hits the route every 10 min via
  pg_net. Pagination capped to 50 pages × 10 = 500 orders/tick (TEvo enforces
  per_page≤10 server-side). Read by frontend via `GET /api/broker/event/{id}/orders`.
  EvoClient gained `list_orders`, `iter_orders`, `get_order` methods.

  **(d) Bucket 18: S4K Order Book** added to the canonical 17-bucket
  taxonomy (now 18 buckets):
    - `evo_orders` / `evo_order_items` — order rows
    - `evo_orders_by_event` view — per-event rollup
    - Aggregates: pending_orders, accepted_orders, completed_orders,
      tickets_sold, gross_sold (per event)
    - Use cases: realized PnL, fulfillment urgency, sale velocity,
      ask-vs-sold spread, e-ticket alerts. Documented in
      `docs/data-sources-terminal-uses.md` for design + future copilot.

  **API surface added** (under `/api/seatdata/*` and `/api/admin/*`):
    - `POST /api/admin/collect-orders` — driven by 10-min cron
    - `GET  /api/broker/event/{id}/orders` — read persisted orders + summary

  **Migration `20260509070000`** captures all the above. **Wall**: EVO orders
  + SeatData sales are broker-only. Buyer/seller/client identity NEVER
  leaves the broker product surface (RULE: product wall).

- **2026-05-09-v11**: **SeatData integration** — second pricing source
  alongside TEvo. TEvo gives us live asks; SeatData adds two complementary
  primitives:
  1. **Sold-listings history** (`/v0.3/salesdata/get`) — actual transacted
     prices over time, which TEvo doesn't expose directly.
  2. **Cross-market fill rate + multi-marketplace get-in** (`/v1/events/
     {id}/stats`) — useful as a cross-check on TEvo-only signals.

  Hard-capped to BASIC plan budget: **100 paid pulls/day, 2000/month**,
  enforced at the DB level via `seatdata_pull_budget` table + RPC
  `seatdata_check_budget()`. Going over those caps requires bumping BOTH
  the DB defaults (in mig 20260509060000) AND the constants in
  `seatdata_client.py` — two-key change so accidental overage is unlikely.

  Per RULE 0: SeatData is the second documented price source.

  **Migration `20260509060000`** adds:
    - `seatdata_event_xref` — TEvo↔SeatData event_id mapping
    - `seatdata_pull_budget` — daily counter + cap, monthly aggregate
    - `seatdata_sales_snapshots` — sold-listing history (deduped via content_hash)
    - `seatdata_listings_snapshots` — live listing snapshots
    - `seatdata_event_stats` — pricing time series (avg/median/get-in/fill_rate)
    - `seatdata_pull_log` — audit trail of every call
    - `seatdata_event_latest` view — latest stats + sales counts per linked event
    - functions `seatdata_check_budget(p_endpoint)` + `seatdata_increment_budget(p_endpoint, was_charged)`

  **Client**: `seatdata_client.py` (new at repo root) wraps all SeatData
  endpoints. Free endpoints: `/v1/account`, `/v1/usage`, `/v1/events/search`,
  `/v0.4/events/event-request-add`, `/v0.4/events/event-request-status/{id}`,
  `/v0.5/daily-csv/download`. Paid endpoints (with budget check): `/v0.3/
  salesdata/get`, `/v0.1.1/listings/get`, `/v1/events/{id}/stats`. Handles
  gzip-encoded responses, 429 backoff with Retry-After respect, atomic
  budget increment, full pull-log persistence.

  **API routes added** (under `/api/seatdata/*`):
    - `GET  /account` — diagnostic (free)
    - `GET  /usage`   — billing-period totals from SeatData (free)
    - `GET  /budget`  — our DB-tracked pull budget
    - `GET  /event/{tevo_event_id}` — xref + persisted snapshot status (free)
    - `GET  /event/{tevo_event_id}/sales` — read persisted sales rows (free)
    - `POST /event/{tevo_event_id}/link?sd_event_id=` — manual xref link (free)
    - `POST /event/{tevo_event_id}/auto-search` — search by date+venue and link (free)
    - `POST /event/{tevo_event_id}/sync-sales`  — pull + persist (PAID, 1 pull)

  **Auth**: requires `SEATDATA_API_KEY` env var on Railway. Routes return
  503 with a setup hint if the key is missing rather than crashing.

  **Live test result**: Knicks G5 (TEvo 3345925, 2026-05-12 vs 76ers @ MSG)
  matched to SeatData sd_event_id=1247184 via auto-search. `/v0.3/salesdata/get`
  returned **254 historical sales over a 42-day window** (3/28 → 5/9). Median
  sale price $668, average $773, range $378-$3,756. 519 tickets sold across
  8 zones / 50 sections. All persisted to `seatdata_sales_snapshots`.

- **2026-05-09-v10**: **Event lifecycle classifier** — sort ghost playoff
  brackets, completed events, postponed/cancelled out of "live" surfaces.
  User reported Toronto Raptors and Boston Celtics events showing in the
  terminal even though those teams were eliminated from the playoffs.
  Audit found **203 ghost future events out of 1134 (~18% pollution)**.
  - Migration `20260509050000`: function `derive_event_lifecycle(event_id)`
    + view `event_lifecycle` (bulk classification across all events).
  - Status enum: `active | ghost_eliminated | completed | postponed |
    cancelled | unknown`. Returns confidence + reasons[] + ghost_score.
  - Strongest signal: TEvo `last_seen` staleness. Live Knicks events
    avg 1.0h since last refresh (max 1.1h); ghost playoff brackets
    avg 133h (min 121h) — **zero overlap**. Combined with
    `event_type='game' AND name ILIKE '%TBD%'` for the placeholder
    bracket pattern, classifier hits 0.95 confidence on ghosts.
  - **Distribution as of 2026-05-09**: 1045 active / 95 completed /
    89 ghost_eliminated / 2 postponed / 1 cancelled.
  - **API integration**:
    - `/api/broker/event/{id}/overview` — adds `lifecycle: {status,
      confidence, reasons, is_active, hrs_since_seen, hrs_to_event,
      ghost_score}` block. Frontend renders status badge from this.
    - `/api/broker/movers?include_inactive=` — defaults `false`, ghost
      events excluded from winners/losers lists.
    - `/api/portfolio?include_inactive=` — defaults `false`, ghost
      events excluded from aggregate sums; per-event rows get
      `lifecycle` block + response includes `inactive_excluded_count`.
    - `/api/broker/performers/by-league/{league}?include_inactive=` —
      flag passthrough only for now; the underlying SQL RPC still
      aggregates over all events. NEXT (code) tracked in KANBAN to
      update `get_performers_by_league` to JOIN against the lifecycle
      view.
  - Clients that want to see EVERYTHING (including ghosts) opt in with
    `?include_inactive=true`.

- **2026-05-09-v9**: **`range_meta` in `/api/broker/event/{id}/chart-data`
  response** + lane re-split. The chart-data endpoint now returns
  `range_meta: { range, hours, since, until }` alongside `series` and
  `zone_series`. The frontend uses these bounds to pin Chart.js's time
  x-axis explicitly to the requested window — without it, Chart.js
  auto-fit to the union of populated datasets and 30d views collapsed
  to ~24h whenever a newer column (e.g. `nonowned_median_retail`,
  `splits_min_q`) lacked backfill history. Time `unit` and `stepSize`
  also auto-derived from `hours`. No backend schema change beyond the
  response shape. **Lane re-split**: backend + audit + git push
  consolidated under code; a fresh **design** coworker takes the
  terminal frontend with no git-push and no prod-write privileges
  (uses `design_test.*` for sandboxing). Hand-off via the shared
  `KANBAN.md` board; full contract in `COWORKER_ONBOARDING.md`.

- **2026-05-09-v8**: **Cascading cron model** + ESPN injury/trade freshness
  bumped from every-10-min to every-2-min. Migration `20260509040000`:
  - Unscheduled 6 individual freshness crons (espn-roster-10min,
    espn-gameday-10min, auto-link-event-xref-15min, compute-event-splits-30min,
    backfill-zone-metrics-10min, compute-event-nonowned-30min).
  - Created `master_cascade_2min()` function — single chain that fires
    ESPN roster+gameday HTTP (async via `pg_net`) and runs auto_link →
    splits → nonowned in dependency order with per-stage try/except.
    Returns JSONB summary so prod logs show `splits_count`, `nonowned_count`,
    `auto_link_count`, ESPN request IDs, `duration_ms`, plus per-stage
    errors when they occur.
  - Scheduled `master-cascade-2min` (jobid 38) at `*/2 * * * *`.
    First-tick verified runtime ~150-200ms.
  - **Why ESPN runs async**: `pg_net.http_post` returns a request_id
    immediately; HTTP work happens in a background worker. Stage 1
    overlaps with Stage 2's SQL — total wall time = max(ESPN, SQL),
    not sum.
  - **Worst-case staleness collapsed**: a brand-new event used to wait
    up to ~50 min for full ESPN xref + splits + nonowned coverage
    (15+30+10 min worst-case fan-out across 3 separate schedules).
    Now ~2 min.
  - **Zone backfill kept SEPARATE** (`zone-backfill-isolated-10min`,
    jobid 39, batch=5) due to pre-existing 120s timeout bug in
    `match_performer_zone` — jobid 35 had been failing every run for
    hours pre-cascade. Splitting it out keeps the cascade reliable.
    Fix-the-cause NEXT: investigate LATERAL cost and the
    `listings_snapshots(event_id, captured_at, is_ancillary)` index.
  - **Side fix**: `auto_link_event_xref` was inserting into `event_xref`
    without populating `espn_slug` (NOT NULL), so jobid 31 was silently
    failing pre-v8. Cascade caught it via per-stage error reporter.
    Added a hardcoded league→slug CASE for the 7 leagues (NBA, WNBA,
    MLB, NHL, NFL, MLS, World Cup). NEXT: replace with a `league_slug`
    lookup table.
  - **Cron count**: 22 → 17 (6 dropped, 1 cascade added — net -5).
  - **midnight-catchup-sweep** (jobid 36) remains as the daily
    safety net — re-runs all idempotent backfills at 00:00 UTC so
    no event goes >24h without a complete pass even if ticks fail.

- **2026-05-09-v7**: New event_metrics column **`nonowned_median_retail`**
  (mig 20260509030000) — median retail across non-S4K listings only
  (is_owned=false). Used by chart's "MARKET NOT US" default series.
  Median-of-subset can't be derived from medians-of-whole + complement,
  so requires direct aggregation from listings_snapshots. Backfilled by
  `compute_event_nonowned_median(event_id)` and cron-driven by
  `compute-event-nonowned-30min` (jobid 37) + the midnight sweep.
  Verified Knicks G5: market $988 / S4K $1,117 / market-not-us $950.
  Chart catalog updated: GET-IN, market-all median, S4K-owned median,
  market-not-us median, splits-min-q, and counts-market all on by
  default per user spec. Counts render as **bars** (semi-transparent
  fill, thin border), money series stay as lines. ESPN win % no
  longer default-on (toggle when game is relevant). localStorage key
  bumped `evt_chart_visible_v2` → `_v3` so existing users get the new
  defaults on first load.

- **2026-05-09-v6**: Added a dedicated **"ESPN injury / standings
  auto-assignment rules"** section after the league coverage matrix.
  Documents:
  - **RULE 1 (cross-league)**: every query against the espn_* tables
    MUST filter by `(espn_team_id, espn_league)` together — id "18" is
    NBA Knicks AND MLB Pirates AND NFL Saints AND NHL #18 AND WNBA #18.
    Failure mode: 229 rows pulled when 12 are real. Caught + fixed in
    `bbd18ed`. Listed every endpoint that touches espn_* tables and
    confirmed each filters correctly post-fix.
  - **`espn_injuries_snapshots` schema**: full column-by-column
    documentation including `is_baseline` semantics
  - **`is_baseline` known bug**: detection only fires correctly for
    MLB+NHL; NBA/NFL/MLS/WNBA/WC always come back true. Documented as
    code-lane NEXT for solo phase.
  - **`espn_team_snapshots` schema**: same column-by-column treatment
  - **Auto-assignment hooks table**: every endpoint/RPC that touches
    espn_* tables, with confirmation of league filtering
  Added new cron **`midnight-catchup-sweep`** (jobid 36, mig
  20260509020000) — daily 00:00 UTC pass that runs all 4 idempotent
  backfills (auto_link_event_xref, backfill_stale_zone_metrics,
  backfill_event_splits_metrics, ensure_major_league_watchlist_coverage)
  in one coordinated sweep. First fire 2026-05-10 00:00 UTC. Component
  fns are idempotent so re-running after intra-day crons is safe.

- **2026-05-09-v5**: Replaced the single-checkmark "League → ESPN-tracked
  map" with a 4-layer matrix (performer mapping / team standings /
  game-day snapshots / event xref), audited live against prod.
  Reality vs prior doc:
  - **MLS** has 30 teams mapped + 30 team-standings rows but **0 game-day
    snapshots and 0 event xrefs**. Performer page works (standings show);
    event page falls back to "ESPN coverage not applicable" by design.
  - Same partial coverage for **NFL, NHL, WNBA, World Cup**: full at
    performer level, empty at event level.
  - Only **NBA + MLB** have full pipeline (gameday + xref).
  Root cause: `espn-collect.gameday` scope (jobid 25) only iterates NBA +
  MLB events. Extending it to MLS/NHL/NFL/WNBA/WC = ~80% of the gap.
  Logged as copilot-lane NEXT in the matrix's "Key gap" callout.
  No code or schema change in v5 — just doc accuracy fix.

- **2026-05-09-v4**: Added **Bucket 17 (Major event calendar)** + new
  table `major_event_calendar` (mig 20260509010000) seeded with 14
  curated entries: 4 F1 races (Miami/Canadian/US/Las Vegas), 5 NASCAR
  crown jewels (Daytona 500, Coca-Cola 600, Brickyard 400, Bristol Night,
  Talladega 500), US Open Tennis, 4 Golf majors (Masters, PGA, US Open,
  The Players). Pattern: store venue + date window per major event;
  manual TEvo lookup populates tevo_venue_id; watchlist (kind=venue)
  drives the existing collect-listings pipeline; ESPN context auto-hides
  per v3 gating since no team xref. New section "Major event calendar
  workflow" documents the manual workflow and future automation NEXT
  for copilot.
  Added **RULE 0 (Process discipline)** at the top of the doc making it
  explicit: any new data — table, column, external feed, derived metric,
  or **price source** — must be categorized into a bucket here in the
  same commit, with a new bucket added if no existing one fits.

- **2026-05-09-v3**: Added 6 ML-training feature buckets (11 Temporal,
  12 Demand, 13 Historical, 14 External, 15 Brokerage microstructure,
  16 Classification — already in v2 but now formalized as bucket #16),
  with implementation status per bucket and a recommended ML feature row
  spanning all 16 buckets. Added "Non-big-6 ESPN coverage gap" section
  documenting that F1/NASCAR/golf/tennis don't exist in TEvo yet (so
  there's nothing to map), plus the 100+ non-big-6 sports performers that
  don't have ESPN coverage (NCAA Football, MiLB, NWSL, etc.) with a
  recommended roadmap for extending espn-collect. Frontend: ESPN Context
  + Related News panels on event page now hide when neither home nor
  away performer has an ESPN xref — replaced with single concise
  "External context: ESPN coverage not applicable" panel.

- **2026-05-09-v2**: Added TEvo classification taxonomy — full 3-level
  category tree (top_category_name → parent_category_name → category_name)
  with current counts per leaf, plus the two derived classifications
  (`what_event_type`, `genre`, `event_type`) and the league→ESPN-tracked
  map. New "Behavior rules driven by classification" table makes explicit
  that HOME/AWAY UI, ESPN context, and watchlist coverage cron all gate
  on `what_event_type='game'`. Backend `/api/portfolio?performer_id=` now
  enforces the gate: returns `is_sports_performer` + `performer_classification`
  alongside per-event `is_home`. is_home is null for non-sports performers.
  No new tables/functions/crons.

- **2026-05-09-v1**: initial lock. 47 tables, 73 functions, 21 active
  crons. Drift flagged: 5 migrations applied via MCP not yet in prod
  migration ledger. Schema verified against prod 2026-05-09 ~00:30 UTC.
