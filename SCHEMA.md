# SCHEMA.md — Backend architecture lock

**Version**: `2026-05-09-v19`
**Last verified against prod**: 2026-05-09 ~04:30 UTC (Supabase project `hzrizjeaxlqcxfrtczpq`)
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

### The read-only external API rule (RULE 2)

**TEvo, SeatGeek (broker + seller-direct), TickPick, and Vivid Seats
integrations are strictly READ-ONLY.** We pull data (orders, sales,
listings) — we never POST/PUT/PATCH/DELETE. TickPick and Vivid orders
sit in the same bucket as the Evo `/v9/orders` and SG `/sales` feeds:
they're our sales data, ingested only.

This rule is enforced in **three layers** so that no human and no AI session
(this one or future ones) can ship a write without flipping a tracked file:

#### Layer 1 — Runtime guards inside each client

| Module | Guard | Allowed methods |
|---|---|---|
| `evo_client.py` | `_assert_readonly_method()` raises `EvoReadOnlyError` | `frozenset({"GET"})` |
| `seatgeek_client.py` | `_assert_readonly_method()` raises `SeatGeekError` | `frozenset({"GET"})` |
| `tickpick_client.py` | `_assert_readonly_method()` raises `TickPickReadOnlyError` | `frozenset({"GET"})` |
| `vivid_client.py` | `_assert_readonly_method()` raises `VividReadOnlyError` | `frozenset({"GET"})` |
| `seatdata_client.py` | `_assert_readonly_method()` | GET + the single `POST /v0.4/events/event-request-add` (metadata only — asks SD to add an event to their catalog; no S4K data) |

Each guard is called inside the transport method (`_get`, `_get_seller`,
`_request`) **before** the HTTP request is constructed. If anyone adds a
non-GET wrapper or passes a write method through, the assertion raises
before a network call is made. The `ALLOWED_HTTP_METHODS` constant is a
module-level `frozenset` so it can't be silently mutated.

#### Layer 2 — Static analysis (`scripts/check_readonly.py`)

Repo-wide grep that fails (exit 1) if it finds:
- `requests.(post|put|patch|delete)` / `httpx.(post|put|patch|delete)` /
  `session.(post|put|patch|delete)` in any Python file with a forbidden
  host string nearby
- `fetch(URL, { method: "POST" | "PUT" | "PATCH" | "DELETE" })` in any
  TS/JS file where `URL` resolves (literally or via tracked variable
  bindings) to a forbidden host
- A client module missing `_assert_readonly_method` /
  `ALLOWED_HTTP_METHODS` / `frozenset({"GET"})` tokens

Run as part of CI / pre-commit:
```bash
python scripts/check_readonly.py
```
Exits 0 with `RULE 2 clean`, or 1 with itemized violations.

#### Layer 3 — Unit tests (`tests/test_readonly_guards.py`)

12 pytest cases assert:
- Each client's `_assert_readonly_method` raises on POST/PUT/PATCH/DELETE
- Each client's `ALLOWED_HTTP_METHODS` constant equals `frozenset({"GET"})`
- The audit script passes against the clean tree
- The audit script catches a synthesized Python POST to TEvo
- The audit script catches a synthesized TS POST to SG via host-var binding
- The audit script fails when a runtime guard is removed from a client

Run with:
```bash
pytest tests/test_readonly_guards.py
```

#### Why three layers

- **Layer 1** stops accidental writes at runtime, even if Layers 2/3 are
  bypassed (e.g. someone runs in a stripped CI image without pytest).
- **Layer 2** stops new write paths at code-review time before they merge.
- **Layer 3** stops the guards themselves from being silently removed —
  if a future PR strips out `_assert_readonly_method`, the test fails.

#### When adding a new external API

1. Copy the `_assert_readonly_method` + `ALLOWED_HTTP_METHODS` pattern from
   `evo_client.py` or `seatgeek_client.py`.
2. Add the new module to `CLIENT_FILES` in `scripts/check_readonly.py`.
3. Add unit tests mirroring `tests/test_readonly_guards.py` for the new
   client.
4. List the integration in this section.

#### Why this matters

Writes to TEvo's `/orders` would create real orders against the brokerage.
Writes to SG's broker endpoints could change inventory state. RULE 2 makes
accidental damage from a coding error (or a misguided AI suggestion)
structurally impossible — flipping the rule requires editing three tracked
files (the client, the audit script, and the tests), each of which is
visible in any code review or git diff.

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

- **2026-05-09-v19**: **Cross-source order status mapping** — 3 sale
  sources (EVO TEvo, SG seller-direct, SeatData) now speak one
  vocabulary. Mig `20260509140000`.

  **Canonical state machine (6 states)**:
  - `pending` — order received, no seller action yet
  - `accepted` — seller acknowledged, working on fulfillment
  - `substitution` — fulfilling broker rejected, awaiting substitute
  - `rejected` — seller rejected outright
  - `cancelled` — cancelled by either side
  - `fulfilled` — sale finalized and delivered

  Plus 2 boolean flags carried alongside:
  - `is_terminal` — state will not transition again
  - `is_sale_succeeded` — sale completed in our favor (only `fulfilled`)

  **Source-status → canonical mapping (13 rows seeded)**:

  | source | source_status | canonical | terminal | succeeded |
  |---|---|---|---|---|
  | evo | pending | pending | ❌ | ❌ |
  | evo | accepted | accepted | ❌ | ❌ |
  | evo | rejected | rejected | ✅ | ❌ |
  | evo | completed | fulfilled | ✅ | ✅ |
  | evo | pending_substitution | substitution | ❌ | ❌ |
  | seatgeek | open | pending | ❌ | ❌ |
  | seatgeek | pending | pending | ❌ | ❌ |
  | seatgeek | confirmed | accepted | ❌ | ❌ |
  | seatgeek | fulfilled | fulfilled | ✅ | ✅ |
  | seatgeek | delivered | fulfilled | ✅ | ✅ |
  | seatgeek | cancelled | cancelled | ✅ | ❌ |
  | seatgeek | pending_substitution | substitution | ❌ | ❌ |
  | seatdata | sold (synthesized) | fulfilled | ✅ | ✅ |

  **Schema**:
  - `order_status_xref` — the rosetta stone table; query by `(source, source_status)` or `WHERE canonical_status = X`.
  - `canonical_order_status(source, source_status) → jsonb` helper RPC.
  - `unified_orders` — single rowset across `evo_orders` + `seatgeek_orders`
    + `seatdata_sales_snapshots`. Each row has source + canonical_status +
    flags + tevo_event_id (resolved). Cross-source queries become trivial.
  - `unified_orders_by_event` — per-event-per-source rollup with state
    histogram + gross_sold + tickets_sold.
  - `order_status_coverage` — diagnostic of (source, canonical_status)
    counts + window + avg qty + sum gross.

  **Live coverage as of v19**:

  | source | canonical_status | rows | window | gross |
  |---|---|---:|---|---:|
  | seatdata | fulfilled | 254 | 2026-03 → 2026-05 | $397,558 |
  | seatgeek | accepted | 200 | 2019-10 → 2026-05 | n/a |
  | seatgeek | fulfilled | 200 | 2018-09 → 2026-05 | n/a |
  | evo | (any) | 0 | — | — |

  (EVO is 0 because Railway `CRON_SECRET` env var still needs to be
  set to unblock jobid 40. Once unblocked, EVO orders flow into the
  same `unified_orders` view automatically.)

  **Why this matters**: any analytical query that wants "all sales
  this event has had across any source" or "all in-flight orders
  across all sources" or "fill rate per event" now writes against
  `unified_orders` / `unified_orders_by_event` instead of building
  per-source CASE statements.

  **Future sources** (TickPick, Vivid Seats, etc.): when added, just
  insert their status mappings into `order_status_xref` and add them
  to the `unified_orders` view's UNION. No downstream query changes.

- **2026-05-09-v18**: **Matchup index, buyer-sentiment composite,
  performer + venue baselines, similar-event finder**. Operationalizes
  the strategy memo at `docs/historical-data-and-multi-view-strategy-2026-05-09.md`.
  Mig `20260509130000`.

  **Tables**:
  - `matchup_xref` — unordered (team_a_id, team_b_id) pair → matchup_id.
    Seeded with **445 matchups** from existing events (top: Yankees-Orioles
    13, Yankees-Blue Jays 13, Red Sox-Yankees 11, Knicks-76ers 7).
  - `event_sentiment` — per (event_id, captured_at) buyer-sentiment composite
    in [-100, +100] with 4 decomposed components (tix_per_hour,
    getin_per_hour, owned_share_change, pairs_change_per_hour).
  - `performer_baselines` — per-performer rolling median retail / getin /
    tix / owned tix / owned_share / owned_premium_pct / total_book_notional.
    Refreshed daily.
  - `venue_baselines` — per-venue rolling baseline.

  **Views**:
  - `matchup_history` — events joined to their latest event_metrics rolled
    up per matchup.

  **Functions**:
  - `backfill_matchup_xref()` — seeds matchup_xref from events.
  - `compute_buyer_sentiment(event_id)` — composite formula:
    `−10·tix_per_hour + 4·getin_pct_per_hour + −50·owned_share_change + −2·pairs_change_per_hour`
    clamped to [−100, +100]. Live test: Pistons-Cavs G3 +100, Knicks G5 +54,
    Wolves-Spurs G5 (ghost) −34.
  - `backfill_event_sentiment(max_events)` — cascade-friendly batch.
  - `refresh_performer_baselines()` / `refresh_venue_baselines()` — daily.
  - `find_similar_events(event_id, max_n)` — scores comparable events:
    same matchup (1.0) + same primary performer (0.6) + same venue (0.4).
    Live test on Knicks G5: returns G7/G2/G1 (2.0 score), G6/G4/G3 (1.6),
    NBA Finals games (1.0) — perfectly ranked.

  **Findings backed by live data**:
  - Knicks-76ers played-game retail decay = **50-65% from initial listing
    to gametime** ($1,110→$560, $1,274→$464, $643→$250). That's the
    playbook number.
  - Sentiment composite separates strong-buying events (Pistons-Cavs G3
    +100, absorbing -32 tix/hr) from weak/bearish events (Wolves-Spurs G5
    -34, gaining +3 tix/hr).
  - Matchup level enables "last 5 Knicks-76ers" comparison; performer
    level enables "Yankees home games typically settle at $X"; venue
    level enables section-premium curves.

  **Open future work**:
  - Multi-year history (2026 is our first reference season; 2027 unlocks YoY).
  - Add sentiment + similar-events backfills to `master_cascade_2min`
    (already designed; defer to next migration to avoid bloating this one).
  - Add `/api/broker/event/{id}/sentiment` and `/api/broker/event/{id}/similar`
    routes (specced in memo §6.2).
  - Venue capacity ingestion for "% sold" aggregates (requires manual seed).

- **2026-05-09-v17**: **Cross-source entity maps** — single way to
  translate any source's id to all other sources' ids. TEvo is the hub.
  Mig `20260509120000`.

  **3 hub views** (one per entity type):
    - `entity_event_map` — TEvo event_id → { espn_event_id+league+slug,
      sd_event_id, sg_event_id+name+location, lifecycle_status,
      sources_count, external_ids JSONB }
    - `entity_performer_map` — TEvo performer_id → { espn_team_id+league,
      home_venue_ids[], sd_performer_id, sg_performer_name, performer
      classification (genre/category), sources_count, external_ids }
    - `entity_venue_map` — TEvo venue_id → { sd_venue_id+slug+city+state,
      sg_venue_name, sources_count, external_ids } (ESPN doesn't expose
      venue ids cleanly so it's not in the venue map)

  **6 translation functions** for both directions:
    - `tevo_event_id_for(source, external_id) → bigint`
    - `tevo_performer_id_for(source, external_id) → bigint`
      (espn supports `'NBA:18'` syntax to disambiguate league-scoped ids)
    - `tevo_venue_id_for(source, external_id) → bigint`
    - `external_ids_for_event(tevo_event_id) → jsonb`
    - `external_ids_for_performer(tevo_performer_id) → jsonb`
    - `external_ids_for_venue(tevo_venue_id) → jsonb`

  **`taxonomy_xref` table** for the "fixed variables" — TEvo event_type
  ↔ ESPN league ↔ SG event_type ↔ SeatData event_type. Seeded with
  12 known mappings: NBA, WNBA, NFL, NHL, MLB, MLS, NCAA-FB, NCAA-MBB,
  Concert, Comedy, Theater, Parking. Extended on a per-need basis.

  **`cross_source_coverage` view** (diagnostic): for each entity_type
  (event/performer/venue) reports total + per-source linked + multi-
  source linked counts. Drives backfill prioritization.

  **Live coverage as of v17**:

  | entity    | total | ESPN | SeatData | SG | multi-source |
  |-----------|-------|------|----------|----|--------------|
  | event     | 1,233 | 269  | 1        | 1  | 1            |
  | performer | 182   | 217¹ | 0        | 39 | 37           |
  | venue     | 124   | n/a  | 0        | 21 | 0            |

  ¹ ESPN performer xref count exceeds total because some performers
  have multiple (team_id, league) pairs (e.g., a "soccer team" performer
  matched in both MLS and another league). RULE 1 always disambiguates.

  All translations verified live: round-trip TEvo → external → TEvo,
  cross-source name lookups (SG name → TEvo id), all return the correct
  hub id. The single doubly-linked event (TEvo 3345925 + 3346856 share
  ESPN id 401871162) is the documented G5 vs G3 data bug from earlier;
  not a new issue.

- **2026-05-09-v16**: **SG metrics + xref + categorization + RULE 2 +
  cascade integration**. Mig `20260509110000`.

  **(a) New schema**:
    - `seatgeek_performer_xref` (lighter re-introduction): TEvo
      performer_id ↔ SG performer name string. Auto-extracts from
      seller_listings + orders by splitting "Away at Home" event names.
      102 performers auto-linked on first run.
    - `seatgeek_venue_xref`: TEvo venue_id ↔ SG venue name. 21 venues
      auto-linked.
    - `seatgeek_event_metrics`: parallel to `event_metrics` (TEvo) and
      `seatdata_event_stats`. 28 columns covering listings aggregates
      (count, tickets, cost percentiles, sections, edelivery_share,
      instant_share), orders state buckets (open/pending/confirmed/
      fulfilled/delivered/cancelled), sold metrics (qty, gross, price
      stats), and a fill_rate proxy (sold / (sold + active)).
    - `seatgeek_categorized_listings` view: latest snapshot per event
      grouped by (sg_event_name, sg_venue, sg_event_date) — answers
      "all our SG inventory for X at Y".
    - `cross_source_event_audit` view: for any TEvo event, returns
      ESPN id, SeatData sales count, SG event_id, SG seller listing
      count, SG seller active tickets, SG order count, EVO order count,
      lifecycle status. One JOIN-free query for the full picture.

  **(b) Smart event-xref matcher fix**: prior `sg_attempt_event_xref`
  matched only on (date, venue_LIKE) and incorrectly linked Lynx
  game on 5/17 to a "TBD at Minnesota Timberwolves" ghost event at
  Target Center on 5/17. New version requires:
    - performer name overlap (split SG name on " at ", check both
      halves against TEvo `primary_performer_name` + `name`)
    - prefer non-ghost events (lifecycle.is_active=true)
    - exact venue match before LIKE prefix
  Re-ran on 219 known SG events — exactly 1 valid auto-link
  (Rockies @ Diamondbacks 5/22 → TEvo 3092720). Ghost reject worked.

  **(c) RULE 2 (Read-only external APIs)**: documented + enforced.
  See "The read-only external API rule (RULE 2)" section above.

  **(d) Cascade integration**: `master_cascade_2min` now includes two
  new stages — SG performer + venue auto-xref, SG metrics backfill (50
  events/tick). Total runtime ~1.7s, well under 2-min budget.

  **(e) Cross-source audit**: ran live; richest event in our system
  is **Knicks G5** (TEvo 3345925) with TEvo + ESPN + SeatData
  coverage (3 sources, 254 SeatData sales pulled, 2,869 active TEvo
  tix at $987 retail median, 940 owned tix). SG hasn't matched it yet
  because page-1 listings only covered ~25 events out of 157,846; the
  10-min cron will keep filling.

- **2026-05-09-v15**: **SeatGeek Seller Direct API integration** —
  read-only ingest from `sellerdirect-api.seatgeek.com`. SECOND broker
  host alongside `brokerdata.seatgeek.com` (v14). Same partner token,
  different API surface.

  **Live probe results** (mig `20260509100000`):

  | endpoint | status | findings |
  |---|---|---|
  | `GET /listings` | 200 | **157,846** active S4K listings catalog. Each row carries `event_id` + `event` name + `venue` + `event_date` inline. |
  | `GET /listings?event_id=N` | 200 | filter works — direct event lookup |
  | `GET /listings?per_page=N` | 200 | works |
  | `GET /listings?page=N` | 400 | **deprecated** — use `?page_cursor=` |
  | `GET /orders?status=confirmed` | 200 | **6,074** confirmed lifetime orders |
  | `GET /orders?status=fulfilled` | 200 | **496,413** fulfilled lifetime orders |
  | `GET /orders?status=open\|pending\|cancelled\|delivered` | 200 | shape valid, currently 0 each |
  | `GET /order?order_id=X` | 200 / 404 | single-order detail (Apps Script's primary call) |

  **Discovery model**: the inline `event` block on every listing and
  order makes manual mapping obsolete for events we have inventory or
  orders on. Fuzzy match `(occurs_at_local::date, venue_name)` between
  TEvo `events` and SG metadata, auto-upsert into `seatgeek_event_xref`.
  Verified live: 2 SG events auto-linked from page 1 of /listings alone
  (Chicago Sky @ Lynx 5/17 → TEvo 3345789; Rockies @ Diamondbacks 5/22 →
  TEvo 3092720). Cron will keep it converging.

  **Migration `20260509100000`** adds:
    - `seatgeek_seller_listings` — full catalog snapshot per pull;
      18 fields per listing including `tevo_event_id` backfilled via
      `sg_attempt_event_xref()`. content_hash dedup.
    - `seatgeek_orders` — order header (id, status, event inline,
      listing inline, payment summary, tevo_event_id auto-backfilled)
    - `seatgeek_order_tickets` — per-seat detail (barcodes, mobile passes)
    - `seatgeek_seller_pull_log` — audit trail with `total_reported`
    - `sg_attempt_event_xref(sg_event_id, name, date, venue) RETURNS bigint` —
      idempotent xref helper, fuzzy matches TEvo events on date+venue
      with case-insensitive trim + LIKE prefix fallback. Returns
      matched tevo_event_id (or NULL when no TEvo match).
    - `seatgeek_orders_by_event` view — rollup per (TEvo) event:
      open/pending/confirmed/fulfilled/delivered/cancelled counts +
      tickets_sold + gross_sold

  **Client extension (`seatgeek_client.py`)**: 4 new methods —
  `seller_listings(event_id, per_page, page_cursor)`,
  `iter_seller_listings(max_pages, per_page)` (cursor pagination),
  `seller_orders(status, page)`, `iter_seller_orders(status)`,
  `seller_order(order_id)`, plus `store_seller_listings()` and
  `store_seller_orders()` helpers that auto-call `sg_attempt_event_xref()`
  and report `events_seen` + `events_linked` counts.

  **API routes**:
    - `POST /api/admin/collect-sg-seller?statuses=open,pending,confirmed,fulfilled&pull_listings=true` —
      cron-driven, X-Cron-Secret gated. Pulls 5 pages of /listings × 200
      = 1000 listings/tick, then iterates orders by status filter.
    - `GET /api/seatgeek/event/{tevo_id}/seller-listings?latest_only=true` —
      read persisted with summary
    - `GET /api/seatgeek/event/{tevo_id}/seller-orders` — read persisted
      with summary (by_status, tickets_sold, gross_sold)
    - `GET /api/seatgeek/seller-status` — diagnostic: distinct SG events
      seen, auto-link rate, recent pulls

  **Cron**: `seatgeek-seller-collect-10min` (jobid 41) every 10 min via
  pg_net → Railway. Convergence-style: cumulative pulls keep adding
  fresh inventory + filling xref over time.

- **2026-05-09-v14**: **SeatGeek BROKER DATA API rebuild**. The v13
  integration assumed the public discovery API at `api.seatgeek.com/2`
  with `?client_id=` auth. Our partner token is actually for
  `brokerdata.seatgeek.com` (Seller Direct Broker Data API) with
  `?token=` auth. Different host, different endpoints, different shape.
  Live diagnostics: token returned 400 "No event found" on `/listings`
  + `/sales` (auth accepted, just need real event_id), and 401 on
  `/purchases` (token lacks that scope; we use TEvo `/v9/orders` for
  our own purchases anyway).

  **Migration `20260509090000`** drops the prior public-API tables
  (`seatgeek_taxonomies`, `seatgeek_event_sections`, `seatgeek_recommendations`,
  `seatgeek_venue_xref`, `seatgeek_performer_xref`) and rebuilds around
  the broker API:
    - `seatgeek_event_xref` — simpler: TEvo↔SG event mapping with
      cached event metadata from broker responses (name, type, location,
      start_data, visible_until)
    - `seatgeek_listings_snapshots` — broker inventory (v1=`/listings`,
      v2=`/v2/listings` for full marketplace). 18 listing fields plus
      `sglid` (canonical SG Listing ID) for dedup. content_hash dedup
      so re-pulls only insert when something changed.
    - `seatgeek_sales_snapshots` — transacted sales. Broker side returns
      only broadcast (wholesale) price, not retail.
    - `seatgeek_pull_log` — audit trail with cache_hit + refreshed_at_utc
      from response envelope.
    - `seatgeek_event_latest` view — rollup per linked event:
      active_listings, active_tickets, broker_owned_listings, sales_count,
      last_sale_at.

  **Client `seatgeek_client.py`** rewritten. Three methods: `listings`,
  `sales`, `purchases` (raises typed `SeatGeekScopeError` on 401 since
  token lacks purchases scope). Vault-loaded auth, content_hash dedup
  for listings, dedup-by-uuid for sales, full pull_log persistence.

  **API routes added** (under `/api/seatgeek/*`):
    - `GET  /event/{tevo_id}` — xref + latest snapshot rollup (free)
    - `POST /event/{tevo_id}/link?sg_event_id=N` — manual xref (no
      search endpoint exists, so matching is always manual)
    - `POST /event/{tevo_id}/sync-listings?v2=true|false` — pull + persist
    - `POST /event/{tevo_id}/sync-sales` — pull + persist
    - `GET  /event/{tevo_id}/listings?latest_only=true&limit=1000` —
      read with summary (median/min/max retail_all_in, broker-owned count)
    - `GET  /event/{tevo_id}/sales?limit=1000` — read with summary
      (median/min/max broadcast_price, first/last sale times)

  **`/api/cross-source/event/{id}`** updated: SG block now returns
  `sg_event_name`, `sg_event_type`, `sg_event_location`,
  `last_listings_at`, `last_sales_at` (the prior v13 fields like
  `sg_url`, `sg_short_title` no longer exist).

  **Auth**: Same `SEATGEEK_API_TOKEN` in vault. Wire format is
  `?token=<TOKEN>` (not `?client_id=` like the public API). Verified
  working against prod broker host with status 400 "event not found"
  on a bogus event_id (auth-pass), so the token is good.

  **Manual matching workflow**: SG broker API has no `/search` endpoint.
  To link a TEvo event to its SG counterpart: open SG broker portal
  (or any SG website URL with the event), grab the numeric event_id,
  POST `/api/seatgeek/event/{tevo_id}/link?sg_event_id=N`. From there
  sync-listings + sync-sales work off the xref.

- **2026-05-09-v13**: **SeatGeek integration** — third data source. Metadata
  + discovery only; SG public API does NOT expose pricing or transacted
  sales (those are TEvo + SeatData jobs). What SG adds beyond what we have:
  1. **Section info per venue** — `/events/section_info/{id}` returns a
     `{section_name: [row_label, row_label, ...]}` map. Goldmine for our
     zone/section mapping (cross-validate against TEvo + SeatData).
  2. **Recommendations** — affinity-scored related events + performers,
     better than our string-similarity heuristic. Seed by event_id or
     performer_id; great for "what should we add to watchlist next".
  3. **Performer images** in 4 sizes (huge / large / medium / small) for
     backfilling our metadata.
  4. **Cross-validation** of event/venue/performer naming + lat/lng +
     SG taxonomy tree (independent of TEvo classification).

  **Migration `20260509080000`** adds:
    - `upsert_app_secret(name, value)` — writer RPC for Vault, whitelist-gated
    - `get_app_secret()` whitelist extended to include SEATGEEK_API_TOKEN
    - `seatgeek_event_xref` (TEvo event_id ↔ SG event_id + cached metadata)
    - `seatgeek_venue_xref`
    - `seatgeek_performer_xref` (with 4-size images)
    - `seatgeek_taxonomies` (full tree cache, refresh monthly+)
    - `seatgeek_event_sections` (sections + rows per event, cache aggressive)
    - `seatgeek_recommendations` (affinity-scored, seed_type ∈ {event,performer})
    - `seatgeek_pull_log` (audit trail of every call)

  **Client**: `seatgeek_client.py` (new at repo root) wraps all 9 endpoints:
    - `list_events`, `iter_events`, `get_event`, `get_event_sections`
    - `list_performers`, `get_performer`
    - `list_venues`, `get_venue`
    - `list_taxonomies`
    - `recommend_events`, `recommend_performers`
  Auth via Vault (`SEATGEEK_API_TOKEN`) with env var override. 429 backoff with Retry-After respect. Persistence
  helpers for all xref + cache tables.

  **API routes added** (under `/api/seatgeek/*`):
    - `GET  /event/{tevo_event_id}` — xref + sections + rec count (free)
    - `POST /event/{tevo_event_id}/auto-search` — search by date+venue, link if matched
    - `POST /event/{tevo_event_id}/sync-sections` — pull + cache section info
    - `POST /event/{tevo_event_id}/sync-recommendations` — pull + cache event recs
    - `POST /sync-taxonomies` — refresh full taxonomy tree
    - `GET  /recommendations/by-event/{event_id}` — read cached recs

  **Auth**: Vault-stored credentials. Use `SELECT public.upsert_app_secret(
  'SEATGEEK_API_TOKEN', '<token>')` to set. Routes return 503 with setup
  hint if missing.

  **Rate limits**: SG doesn't publish hard numbers; observed ~1000 req/hour
  for public endpoints. Client respects 429 with exponential backoff. No
  DB budget table since calls are free.

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
