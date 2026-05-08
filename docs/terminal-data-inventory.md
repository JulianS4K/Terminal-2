# Terminal Data Inventory — what we have vs what the UI can use

Audit run 2026-05-08. Maps every relevant table/RPC to UI panels in
`static/_proposals/terminal-v1.html` (4-level hierarchy: Home → Venue LP →
Performer LP → Event LP). Anything used as fact in the mockup must trace
back to a column listed here.

**Sales not assumed.** No precomputed "sold" deltas exist. Volume changes
in `listings_snapshots` reflect listings added / removed / repriced — not
necessarily sold. A listing dropping out could be a sale OR a delisting.
Sales source will plug in later.

**Cost basis not used.** No `cost_basis` table. Skip P&L panels until
source plugged in.

**Real venue/configuration IDs for Knicks (audit fix 2026-05-08):**
Earlier mockup placeholder values were wrong. Correct values from DB:
- MSG TEvo `venue_id` = **896** (NOT 5725 — 5725 is Yankee Stadium)
- 76ers home venue: Xfinity Mobile Arena, TEvo `venue_id` = **499**
  (was Wells Fargo Center, renamed in TEvo)
- Knicks G5 (event 3345925) seating chart `configuration_id` = **3845**
  (NOT 5188 which was a generic mock value)
- Real seating chart URL pattern: `s3.amazonaws.com/media.ticketevolution.com/configurations/static_maps/{config_id}/large.jpg?{cache_buster}`
  — note `static_maps` segment is required, mockup placeholder omitted it.
- ESPN venue heroes (real, crawled into venue_assets):
  - MSG: `a.espncdn.com/i/venues/nba/day/1830.jpg`
  - Xfinity Mobile Arena: `a.espncdn.com/i/venues/nba/day/1845.jpg`
- Real ESPN logos used in mockup CSS classes:
  - `.lg-nyk` → `a.espncdn.com/i/teamlogos/nba/500/ny.png`
  - `.lg-phi` → `a.espncdn.com/i/teamlogos/nba/500/phi.png`
  - (full set in `static/_proposals/terminal-v1.html` `<style>` block)

## 4-tier data ranking — show first, last, or stash

Per Julian: track and chart everything, but surface in priority order. UI
real estate goes to TIER 1; TIER 4 is searchable but never on screen.

### TIER 1 — PRIMARY (always visible, drives every decision)

The price + ownership signal. Watchlist row content, KPI strip, every panel header.

| Source | What it gives |
|---|---|
| `event_metrics.retail_median` | Last (the IBKR "last" price) |
| `event_metrics.getin_price` | Cheapest available (IBKR "ask") |
| `event_metrics.retail_min` / `retail_max` | Day's range |
| `event_metrics.tickets_count` (net of `ancillary_tickets`) | Volume on market |
| `event_metrics.groups_count` | Listings count (more truthful than tix) |
| `event_metrics.owned_tickets_count` / `owned_groups_count` | Our position |
| `event_metrics.owned_share` | "We are the market" flag (≥ 0.30 = amber) |
| `event_metrics.owned_median_retail` | Our median ask vs market median |
| `event_metrics.captured_at` | Snapshot freshness |
| `get_event_movers(24)` | 24h price Δ + volume Δ (cur vs prev) |
| `listings_snapshots` (latest snap, by section) | Live order book |
| `zone_metrics` (latest, per zone) | Zone ladder min/med/max + owned_share |
| `venue_assets.hero_image_url` / `map_image_url` | Hero photos |
| `performer_metadata.{logo_default_url, color_primary, color_alternate}` | Branding |
| `events.{seating_chart_medium, seating_chart_large}` | TEvo seat map |

### TIER 2 — MARKET STRUCTURE (one click deeper, look every hour)

Distribution + flow + depth. The "why is the price moving" detail.

| Source | What it gives |
|---|---|
| `event_metrics.retail_p25` / `p75` / `p90` | Price distribution (box-plot per row) |
| `event_metrics.retail_mean` | Mean vs median (skew indicator) |
| `event_metrics.top5_concentration` | Float thinness (high = top sections dominate) |
| `event_metrics.price_dispersion` | Spread of the distribution |
| `event_metrics.tail_premium` | Premium on the long tail |
| `event_metrics.median_group_size` | Listing fragmentation |
| `event_metrics.{wholesale_min, wholesale_median, wholesale_mean, wholesale_max}` | Broker-side bid context (real bid for bid/ask spread) |
| `event_metrics` time series | Price + volume chart (history per event) |
| `zone_metrics` time series | Zone-level price trend over time |
| `section_metrics` time series | Section-level percentile distribution per snap |
| `listings_snapshots` deltas | Listing flow (add / remove / reprice events) — see #118 |
| `event_pulls` | Snapshot freshness audit |
| `runs` / `espn_runs` | Cron health |

### TIER 3 — CONTEXT (sidebar, refresh hourly to daily)

The narrative. Why prices are where they are.

| Source | What it gives |
|---|---|
| `espn_team_snapshots.{conference_rank, division_rank, playoff_seed, win_pct, games_back, streak, record_summary, standing_summary}` | Standings overlay (live · 116 teams) |
| `espn_event_snapshots.{spread, over_under, home_ml, away_ml, home_win_prob, attendance}` | Betting context (sparse — 20/91 with spread) |
| `espn_injuries_snapshots.{status, injury_type, return_date, short_comment, long_comment}` | Injury history with timestamps (2,414/7d) |
| `espn_news.{headline, description, image_url, type, published_at}` | News cards (355/7d) |
| `espn_athletes` + `espn_athlete_team_history` | Roster + trades feed |
| `wiki_summary.{championships, founded_year, thumbnail_url, extract}` | Performer hero context |
| `wiki_rivalries.{intensity, all_time_summary, notable_moments}` | Rivalry chip + history |
| `events.{popularity_score, long_term_popularity_score}` | TEvo's own demand metric |
| `events.chat_ping_count` + `chat_first_pinged_at` / `chat_last_pinged_at` | Retail chat demand signal |
| `bot_messages` | Recent chat traffic per event |
| `why_signals.{signal_kind, signal_label, weight, expires_at}` | NOAA weather + future hunters (#94-#101) |
| `event_xref` | TEvo↔ESPN event bridge (joins it all) |
| `get_team_playoff_context(performer_id)` | Series state for sports |

### TIER 4 — REFERENCE (search index, rarely on screen)

Dictionary / metadata / pipeline state. Powers search, navigation, ingestion.

| Source | What it gives |
|---|---|
| `chat_aliases` (3,318) | Search dictionary (13 alias kinds) |
| `chat_corpus` / `chat_term_freq_in` / `chat_term_freq_out` | Term frequency for NLU |
| `chat_stopwords` (88) | Filtered tokens |
| `performer_external_ids` (217) | TEvo↔ESPN team bridge |
| `performer_zones` (179) + `performer_zone_rules` (3,553) | Zone classification rules |
| `venue_crawl_state` / `espn_asset_crawl_state` / `performer_crawl_state` | Pipeline state |
| `watch_sources` | Provenance — why this event is tracked |
| `watchlist` | User-saved entries |
| `snapshots` (legacy v1, 223 rows) | Backfill source only |
| `runs` / `espn_runs` | Operational telemetry |
| `event_pulls` | Cache hit/miss audit |
| `bot_users` / `chat_rate_limits` | Chatbot ops |

**Rule for charting:** every tier-1 and tier-2 metric gets a time series in
`event_metrics` / `zone_metrics` / `section_metrics`. Charts can pivot between
event / zone / section granularity. RPC #120 builds the unified history
endpoint.

## TL;DR — coverage reality

- **Pricing snapshots are deep.** 7.18M `listings_snapshots` (1.3GB), 1.8M `section_metrics`, 24,881 `event_metrics`, 4,974 `zone_metrics`. We capture full retail + wholesale percentile distributions per snap (min, p25, median, mean, p75, p90, max, sum), plus owned share, getin price, dispersion, tail premium, top-5 concentration. **Far richer than the mockup currently shows.**
- **ESPN team standings already exist** — `espn_team_snapshots` 320 rows, 116 teams, captures `conference_rank` / `division_rank` / `playoff_seed` / `wins/losses/win_pct` / `streak` / `games_back`. Daily cron running. The standings overlay we drew is hookable today (task #114 demoted to a wiring job).
- **ESPN injuries 2,414 in last 7d, news 355 in last 7d.** Real and current. The hardcoded "Brunson Q" badges should be live.
- **Betting odds: thin.** 91 `espn_event_snapshots`, only 20 with spread, 4 with win-prob, 4 with attendance. Code agent should backfill. (task #116)
- **Competitive brokerage intel: very thin.** Only 1 non-S4K brokerage seen in 24h of `listings_snapshots`. Either we're not surfacing competitor inventory or the field rarely populates — needs investigation. (task #117)
- **Cost basis: missing entirely.** Nothing in DB tracks our actual purchase price per ticket. `wholesale_median` is broker-wide proxy, not ours. The P&L panel needs a new `cost_basis` table. (task #119)
- **WHY signals: 0 active.** The 3 NOAA alerts expired. WHY hunter pipes (#94-#101) all queued.

## The metrics canon (what `event_metrics` actually holds, per-snap)

```
event_id, captured_at,
tickets_count, groups_count, sections_count, median_group_size,
ancillary_groups, ancillary_tickets,
retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90, retail_max, retail_sum,
wholesale_min, wholesale_median, wholesale_mean, wholesale_max,
getin_price,
top5_concentration, price_dispersion, tail_premium,
owned_groups_count, owned_tickets_count, owned_share, owned_median_retail
```

Same shape on `zone_metrics` and `section_metrics` (with `zone` / `section` keys). Means we can compute IBKR-style depth at every granularity.

## Panel → real data map

### Home page

| Panel                         | Real source                                                                                          | Status            |
|-------------------------------|------------------------------------------------------------------------------------------------------|-------------------|
| KPI: owned tickets            | `event_metrics.owned_tickets_count` summed across latest snap per event                              | live              |
| KPI: total exposure $          | `sum(owned_tickets_count * owned_median_retail)` across latest snaps                                  | live              |
| KPI: mkts ≥ 30% ours          | `count(*) where owned_share >= 0.3` — already filtered on Event Movers v3                            | live              |
| KPI: top mover 24h            | `get_event_movers(24)` order by `(cur_market_med - prev_market_med)/prev_market_med desc`            | live              |
| KPI: stale snaps              | events with no `event_metrics` row in 48h (matches ghost filter)                                     | live              |
| Watchlist table               | `watchlist` (kind/ext_id) joined to latest `event_metrics`                                            | live · 11 entries |
| Price Movers gainers/losers   | `get_event_movers(24)` ordered by %Δ both directions                                                  | live              |
| P&L Winners/Losers            | needs `cost_basis` table (#119); show wholesale_median as proxy until then                           | **gap**           |
| ESPN News feed                | `espn_news` ordered by `published_at desc` filtered to tracked teams                                  | live · 355/7d     |

### Venue LP

| Panel                          | Real source                                                                          | Status                |
|--------------------------------|--------------------------------------------------------------------------------------|-----------------------|
| Hero photo                     | `venue_assets.hero_image_url`                                                        | live (new this round) |
| Venue map (default config)     | `events.seating_chart_large` for any event at venue, modal lists configurations      | live                  |
| KPI strip (med, vol, owned, share) | aggregated `event_metrics` across all upcoming events at `venue_id`              | live                  |
| Aggregate price chart 30d      | weighted median of latest `event_metrics.retail_median` per event, daily window      | live (need RPC)       |
| Market-making positions        | `get_event_movers` filtered by venue_id where `cur_owned_share >= 0.20`              | live (RPC #115)       |
| Upcoming events table          | `get_events_by_venue_public` already exists                                          | live                  |

### Performer LP

| Panel                                | Real source                                                                                             | Status                  |
|--------------------------------------|---------------------------------------------------------------------------------------------------------|-------------------------|
| Hero logos + colors                  | `performer_metadata.{logo_default_url, color_primary, color_alternate, espn_team_url}`                  | live (new this round)   |
| Hero record / standing               | `espn_team_snapshots.{record_summary, conference_rank, division_rank, playoff_seed, streak}` latest      | live · cron daily       |
| Hero venue map                       | `venue_assets.hero_image_url` for performer's home venue                                                | live                    |
| KPI: HOME / ROAD avg                 | `get_performers_by_league` already returns home_market_med + road_market_med + tix counts               | live                    |
| KPI: conf rank Δ                     | `espn_team_snapshots` latest vs 30d-ago `conference_rank`                                                | live · need RPC #114    |
| Price + standings overlay chart      | `event_metrics.retail_median` time series + `espn_team_snapshots.conference_rank` series joined         | live · need RPC #114    |
| ESPN context (W-L / form / injuries) | `espn_team_snapshots` + `espn_injuries_snapshots` latest grouped by team                                | live · 2,414 injuries/7d|
| Rivalries panel                      | `wiki_rivalries.{intensity, all_time_summary, notable_moments}`                                          | live · 25 seeded        |
| Market-making positions (HOME/ROAD)  | `get_event_movers` filtered by performer_id, split is_home, where share ≥ 0.20                          | live · RPC #115         |
| Upcoming events table                | `get_events_by_performer_public` already exists                                                          | live                    |

### Event LP

| Panel                                | Real source                                                                                             | Status                  |
|--------------------------------------|---------------------------------------------------------------------------------------------------------|-------------------------|
| Hero matchup logos                   | `performer_metadata` for primary + secondary performer (need away-team resolution)                       | live · need parser      |
| Hero venue + accent bar              | `venue_assets.hero_image_url` + `performer_metadata.color_primary`                                       | live                    |
| KPI: Last + Δ + %Δ                  | `event_metrics.retail_median` latest vs 24h-prior                                                        | live                    |
| KPI: Volume + new tix                | `event_metrics.tickets_count` (net of `ancillary_tickets`); new tix = delta of `groups_count`           | live · delta needs #118 |
| KPI: getin price                     | `event_metrics.getin_price`                                                                              | live · **missed in v1** |
| KPI: dispersion / tail premium / top5 | `event_metrics.{price_dispersion, tail_premium, top5_concentration}`                                    | live · **missed in v1** |
| KPI: bid/ask                         | wholesale_median (bid) vs retail_median (ask); spread = (ask − bid)/median                              | live · **was synthetic, now real** |
| KPI: S4K share                       | `event_metrics.owned_share`                                                                              | live                    |
| Price chart + actions                | `event_metrics` time series + listing-flow events from `listings_snapshots` deltas (#118)                | partial · need #118     |
| Seating chart                        | `events.seating_chart_large` (filter literal "null")                                                     | live                    |
| Zone ladder                          | `get_event_zones_public` already returns per-zone min/med/max/qty/owned_share                           | live                    |
| **Section ladder (zoom into zones)** | `section_metrics` per-snap with full retail/wholesale percentile distribution + owned_share             | live · **missed in v1** |
| ESPN context (records, last5, OUTs)  | `espn_team_snapshots` + `espn_injuries_snapshots` for both home and away teams                          | live                    |
| **Betting context (spread/ML/wp)**   | `espn_event_snapshots` joined via `event_xref.tevo_event_id`                                            | live · 20/91 events have spread · #116 |
| Series state                         | `get_team_playoff_context(performer_id)`                                                                 | live                    |
| Order Book / Time & Sales            | `listings_snapshots` filtered by event_id, latest snap window, with `is_owned` + `brokerage_name`       | live · #118 for delta   |
| **Brokerage competition**            | `listings_snapshots` count + share by brokerage_id where is_owned=false                                 | live · **only 1 competitor seen 24h** · #117 |
| Raw data block                       | `event_metrics` latest as JSON                                                                           | live                    |

## Things in the mockup with NO data backing

1. **P&L vs cost basis** — there is no `cost_basis` table. Every "+$92k" / "−$3.9k" P&L number was made up. Either (a) build the table sourced from S4K's TEvo orders or accounting export (#119), or (b) downgrade the panel to a "wholesale-vs-retail spread × owned_qty" proxy with a clearly-labelled caveat.
2. **"+44 new listings 24h" / "12 ours sold"** — derivable from `listings_snapshots` delta but no precomputed field. RPC #118 fixes.
3. **Cron health "9 crons · 83% chart coverage"** — coverage % is real (compute from `events.seating_chart_medium` not null, filtering "null" string). Cron count is real (16 scheduled, see `cron.job`). Trivial to wire.

## Things we have that the mockup doesn't yet show

These are easy wins — just add to the panels:

1. **`getin_price`** — IBKR's "ask" equivalent. Add as a KPI tile on Event LP and a column on every price table.
2. **Full percentile distribution** (p25/p75/p90 already computed) — render a tiny box-plot or 4-tick bar in each watchlist row showing the price distribution.
3. **`top5_concentration` + `price_dispersion` + `tail_premium`** — adds a "Market Structure" mini-block on Event LP. High concentration = thin float. High tail premium = scalper opportunity.
4. **`wholesale_median`** — actual broker-side bid. Use as the bid in the bid/ask spread (was synthetic in v1).
5. **`espn_event_snapshots.spread/over_under/home_ml/away_ml/home_win_prob`** — betting odds row on Event LP (where covered).
6. **`espn_event_snapshots.attendance`** — sold-out signal on completed games; trend across same-matchup history.
7. **`espn_injuries_snapshots`** — full injury history with `return_date` and `short_comment`. Show "since" timestamp and projected return.
8. **`espn_news.image_url`** — news cards with thumbnails.
9. **`bot_messages` + `events.chat_ping_count`** — "demand from retail chat" signal per event. Internal early indicator.
10. **`event_pulls`** — snapshot-freshness audit (when was this event last polled, served from cache vs live, how many TEvo calls). Shows in the corner of the Event LP as a freshness chip.
11. **`watch_sources`** — why this event is being tracked (auto-tracked from chat ping vs manual add vs performer watchlist). Shown as provenance badge on Watchlist.
12. **`wiki_summary.{championships, founded_year, thumbnail_url}`** — extra performer hero context.
13. **`wiki_rivalries.notable_moments`** — actual highlights instead of mock copy.
14. **`zone_metrics` historic** — zone-level price chart over time. Critical for trade-thesis on Courtside vs Lower vs Upper trends.
15. **`section_metrics` zone tag** — every section already classified into a `zone` (curated or system_placeholder). Group order book by zone for free.
16. **`espn_runs` + `runs`** — operational telemetry (errors, throughput) for the status bar.

## Net mockup edits to make

Cut from v1: P&L numbers (replace with proxy or hide), invented "competitor share" claims.

Add to v1:
- Event LP: `getin_price`, `wholesale_median`, `dispersion`/`tail_premium`/`top5_concentration` mini-block, betting odds row, brokerage competition panel, listing flow time-and-sales fed from real `listings_snapshots`.
- Performer LP: standings overlay actually plotted from `espn_team_snapshots.conference_rank` series, real injury list with `since` + `return_date`, real news cards.
- Venue LP: aggregate chart powered by `event_metrics` weighted median across venue events.
- Home: replace mock news with real `espn_news` query, replace mock P&L with proxy + warning badge.

## RPCs needed (none of these exist yet)

```sql
get_performer_standings_history(p_performer_id bigint, p_days int) -- task #114
get_event_full_intel(p_event_id bigint)                            -- task #116 (joins event_xref → espn_event_snapshots)
get_brokerage_competition(p_event_id bigint)                       -- task #117
get_event_listing_flow(p_event_id bigint, p_since timestamptz)     -- task #118
get_market_making_events(p_scope text, p_scope_id bigint, p_min_share numeric) -- task #115
get_position_pl(p_performer_id bigint)                             -- gated on #119 (cost_basis table)
get_venue_aggregate_price_history(p_venue_id bigint, p_days int)   -- new
get_performer_aggregate_price_history(p_performer_id bigint, p_days int, p_home_or_road text) -- new
```

The first 5 are tracked tasks. The last 2 are trivial — add to the same migration as the standings RPC.
