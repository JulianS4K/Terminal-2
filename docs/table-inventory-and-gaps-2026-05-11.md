# Table inventory + proposed new tables — 2026-05-11

Produced by C1 (Data + Chat Bot, supervisor). Companion to data-sources, cross-source-entity-resolution, and cron-and-queue-health audits. Branch: `claude/audit-data-sources-b7EGu`.

## Headline counts

| object | count |
|---|---|
| Base tables in `public.*` | **120** |
| Views | **136** |
| Materialized views | **1** |
| Top table by size | `listings_snapshots` — **2,318 MB** |
| **Storage growth in 3 days** | listings_snapshots: 1,876 MB → 2,318 MB (**+23.6%**) despite change-only-ingest recommendation in `docs/storage-audit-2026-05-08.md` |

## 1. Inventory by category

### 1a. Top tables by size

| table | size | rows (n_live_tup) | notes |
|---|---|---|---|
| `listings_snapshots` | 2,318 MB | 373,855 | n_live_tup likely stale post-VACUUM; was 7.18M 3 days ago. Heap bloat suspected. |
| `section_metrics` | 460 MB | 80,499 | |
| `weather_observations` | 54 MB | 1,608 | |
| `seatgeek_listings_snapshots` | 50 MB | 63,390 | |
| `event_metrics` | 12 MB | 31,737 | |
| `zone_metrics` | 11 MB | 31,193 | |
| `espn_injuries_snapshots` | 6 MB | 5,379 | |
| `nws_alerts` | 4 MB | 583 | |
| `events` | 1.9 MB | 3,405 | core entity |
| (everything else) | < 4 MB each | | |

**listings_snapshots + section_metrics = 2.77 GB ≈ 95% of DB storage.**

### 1b. Raw external ingest (≈42 tables)

**TEvo** (8): `evo_orders`, `evo_order_items`, `evo_orders_pending`, `evo_event_backfill_pending`, `listings_snapshots`, `tevo_ticket_groups_cache`, `event_pulls`, `venue_pulls`.

**SeatGeek** (12): `seatgeek_orders`, `seatgeek_seller_listings`, `seatgeek_order_tickets`, `seatgeek_historic_sales`, `seatgeek_listings_snapshots`, `seatgeek_sales_snapshots`, `seatgeek_seller_pull_log`, `seatgeek_pull_log`, `sg_event_backfill_pending`, `sg_event_match_pending`, `sg_listings_pending`, `sg_seller_pending`.

**ESPN** (10): `espn_event_snapshots`, `espn_team_snapshots`, `espn_injuries_snapshots`, `espn_news`, `espn_athletes`, `espn_athlete_team_history`, `espn_scoreboard_pending`, `espn_tournament_pending`, `espn_tournament_events`, `espn_runs`.

**SeatData** (5): `seatdata_event_stats`, `seatdata_listings_snapshots`, `seatdata_sales_snapshots`, `seatdata_pull_budget`, `seatdata_pull_log`.

**Reddit / Wikipedia / Weather / NOAA / Tournaments** (≈7): `reddit_posts`, `reddit_pending`, `performer_wikipedia`, `performer_wiki_pending`, `weather_observations`, `weather_forecast_pending`, `nws_alerts`, `nws_alert_pending`, `nws_alert_references`, `nws_alert_zones`, `venue_nws_points_pending`, `tournament_categories`, `tournament_category_pending`, `tournament_search_pending`, `tournament_search_queries`, `venue_geocode_pending`.

### 1c. Cross-source xref (15)

`canonical_external_ids`, `event_xref`, `matchup_xref`, `order_status_xref`, `taxonomy_xref`, `performer_external_ids`, `performer_espn_team_xref`, `seatdata_event_xref`, `seatdata_performer_xref`, `seatdata_section_xref`, `seatdata_venue_xref`, `seatdata_zone_xref`, `seatgeek_event_xref`, `seatgeek_performer_xref`, `seatgeek_venue_xref`.

**Coverage gaps known:** `seatgeek_event_xref` covers 0/186 sg_event_ids in `seatgeek_orders`; `seatgeek_orders.tevo_event_id` is 0% backfilled.

### 1d. Metrics / analytics / canonical (≈12)

`event_metrics`, `section_metrics`, `zone_metrics`, `event_alerts`, `event_match_attempts`, `event_competitors_snapshot`, `event_sentiment`, `seatgeek_event_metrics`, `sg_events_canonical`, `espn_teams_canonical`, `espn_event_date_lookup`, `snapshots`, `runs`.

### 1e. Performer / venue context (≈14)

`performer_baselines`, `performer_crawl_state`, `performer_home_venues`, `performer_metadata`, `performer_subreddits`, `performer_zones`, `performer_zone_rules`, `performer_external_ids` (also in xref), `venue_assets`, `venue_baselines`, `venue_crawl_state`, `general_subreddits`, `sporting_rivalries`, `important_x_accounts`, `holidays`.

### 1f. Reference / config (≈12)

`data_sources`, `data_source_field_map`, `order_fee_schedule`, `major_event_calendar`, `mlb_branded_series`, `school_break_windows`, `news_keywords`, `watch_sources`, `watchlist`, `pull_rate_limits`, `zone_rules`, `settings`, `leads`.

### 1g. Chat / bot (10)

`bot_messages`, `bot_users`, `chat_aliases`, `chat_audit_findings`, `chat_corpus`, `chat_glossary_known`, `chat_rate_limits`, `chat_stopwords`, `chat_term_freq_in`, `chat_term_freq_out`, `chat_term_frequency`.

### 1h. Signals / cache (2)

`why_signals`, `tevo_ticket_groups_cache`.

### 1i. ESPN asset state (1)

`espn_asset_crawl_state`.

## 2. View layer (136 views)

Significant view ecosystem (more views than tables). Key already-built canonical views:
- `v_canonical_venue` — TEvo + SeatData + SeatGeek + ESPN venue unified (used in cross-source-entity-resolution Path B sample fix)
- `v_canonical_performer` — same for performers
- `v_event_active_weather_alerts`
- `v_event_weather_with_fallback`
- `evo_orders_by_event`

Most views exist for the broker terminal + retail surfaces. The audit doesn't enumerate them; they're stable until table-shape changes invalidate them.

## 3. What we should create

Each proposal lists: *table name, justification (with reference to a finding from this audit batch), and rough shape.*

### 3a. `seatgeek_orders_resolved` — Path B output (HIGH PRIORITY)

**Justification:** 400 SG orders span 2018–2025; 0 have `tevo_event_id` backfilled because TEvo's events table doesn't retain historical events. Path B resolves venue + performer IDs directly on the order, bypassing the missing event row. Validated at 19.8% full / 67.8% venue match with exact-name only (`docs/cross-source-entity-resolution-2026-05-11.md` Finding 6).

```sql
CREATE TABLE seatgeek_orders_resolved (
  sg_order_id           text PRIMARY KEY REFERENCES seatgeek_orders(sg_order_id),
  tevo_venue_id         bigint,
  venue_confidence      numeric(3,2),
  tevo_performer_ids    bigint[] NOT NULL DEFAULT '{}',
  performer_confidences numeric(3,2)[] NOT NULL DEFAULT '{}',
  occurs_at_resolved    timestamptz,
  resolved_at           timestamptz NOT NULL DEFAULT now(),
  resolution_method     text NOT NULL,
  notes                 text
);
CREATE INDEX ON seatgeek_orders_resolved (tevo_venue_id);
CREATE INDEX ON seatgeek_orders_resolved USING GIN (tevo_performer_ids);
```

### 3b. `event_section_row_snapshots` — section/row/qty tracking

**Justification:** User asked for section/row/qty-per-performance tracking. `listings_snapshots` already has per-listing rows but no rollup at `(event, section, row)` grain. Test confirmed 100% non-null section/row data and meaningful 20-min snapshot deltas (death 829→104 tix in 140 min on event 3345912).

```sql
CREATE TABLE event_section_row_snapshots (
  event_id        bigint NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  source          text   NOT NULL,             -- 'tevo' | 'seatgeek'
  captured_at     timestamptz NOT NULL,
  section_norm    text   NOT NULL,
  row             text   NOT NULL,
  quantity        int    NOT NULL,
  listings_count  int    NOT NULL,
  min_price       numeric(10,2),
  median_price    numeric(10,2),
  max_price       numeric(10,2),
  owned_quantity  int    NOT NULL DEFAULT 0,
  content_hash    text   NOT NULL,             -- change-only insert key
  PRIMARY KEY (event_id, source, captured_at, section_norm, row)
);
CREATE INDEX ON event_section_row_snapshots (event_id, section_norm, row, captured_at DESC);
```

Source-tagged so cross-marketplace data never silently aggregates. Change-only insert keeps storage manageable.

### 3c. `broker_xref` — Layer 2.5 from methodology

**Justification:** When listings lack seat numbers (most TEvo `listings_snapshots` rows), broker identity is the strongest cross-source key for Layer 4 listing match. No broker xref exists in current schema.

```sql
CREATE TABLE broker_xref (
  tevo_brokerage_id   bigint NOT NULL,
  sg_seller_id        text   NOT NULL,
  confidence          numeric(3,2) NOT NULL,
  match_method        text   NOT NULL,
  matched_at          timestamptz NOT NULL DEFAULT now(),
  notes               text,
  PRIMARY KEY (tevo_brokerage_id, sg_seller_id)
);
```

### 3d. `listing_xref` — Layer 4 from methodology

**Justification:** Cross-marketplace listing dedup unlocks arbitrage detection + accurate inventory rollups. Seat-array intersection logic prevents the false-dup pattern we found in SeatGeek's 15 "soft dups."

```sql
CREATE TABLE listing_xref (
  tevo_ticket_group_id  bigint NOT NULL,
  sg_listing_id         text   NOT NULL,
  captured_at_tevo      timestamptz NOT NULL,
  captured_at_sg        timestamptz NOT NULL,
  confidence            numeric(3,2) NOT NULL,
  match_method          text   NOT NULL,          -- 'seat_array' | 'broker_section_row_qty' | 'inconclusive'
  price_spread_pct      numeric(5,2),             -- observability column, NOT a match key
  matched_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON listing_xref (tevo_ticket_group_id, captured_at_tevo DESC);
CREATE INDEX ON listing_xref (sg_listing_id, captured_at_sg DESC);
```

Not unique on `(tevo_ticket_group_id, sg_listing_id)` — re-listings over time are legitimate sequences of new matches.

### 3e. `entity_xref_overrides` + `entity_xref_conflicts` — governance

**Justification:** Methodology requires manual overrides + conflict logging to be reproducible. Currently no table beats auto-matches; conflicts get silently resolved or ambiguously matched.

```sql
CREATE TABLE entity_xref_overrides (
  layer       text NOT NULL,           -- 'venue' | 'performer' | 'broker' | 'event' | 'listing'
  tevo_id     text NOT NULL,
  sg_id       text NOT NULL,
  reason      text,
  set_by      text NOT NULL,
  set_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (layer, tevo_id)
);

CREATE TABLE entity_xref_conflicts (
  id                   bigserial PRIMARY KEY,
  layer                text NOT NULL,
  tevo_id              text NOT NULL,
  candidate_sg_ids     text[] NOT NULL,
  confidence_scores    numeric(3,2)[] NOT NULL,
  status               text NOT NULL DEFAULT 'needs_review',
  logged_at            timestamptz NOT NULL DEFAULT now(),
  resolved_at          timestamptz,
  resolution_note      text
);
```

### 3f. `v_pg_net_queue_health` — operational monitoring view

**Justification:** Cron+queue audit found `nws_alert_pending` stuck with 94 rows for >24h due to pg_net retention. A monitoring view aggregating across all 16 `*_pending` tables surfaces this class of bug proactively.

```sql
CREATE VIEW v_pg_net_queue_health AS
SELECT 'nws_alert_pending'::text AS queue,
       COUNT(*) FILTER (WHERE resolved_at IS NULL) AS unresolved,
       COUNT(*) FILTER (WHERE resolved_at IS NULL AND fired_at < now() - interval '12 hours') AS stale_12h,
       MIN(fired_at) FILTER (WHERE resolved_at IS NULL) AS oldest_unresolved
FROM nws_alert_pending
UNION ALL
-- ...repeat for all *_pending tables
;
```

Output joins to a status enum: `clean` (0 unresolved), `monitoring` (1-25), `warning` (26-100), `critical` (>100).

### 3g. `tevo_event_archive` — history retention (LOWER PRIORITY)

**Justification:** TEvo's `events` table only retains 293 past events vs 400 SG historical orders, with 0 date overlap. Path B works around this, but a permanent archive lets Layer 3 Path A apply retroactively if we ever want it. Acts as a snapshot, not a primary write target.

```sql
CREATE TABLE tevo_event_archive (
  tevo_event_id   bigint PRIMARY KEY,
  name            text NOT NULL,
  occurs_at       timestamptz NOT NULL,
  venue_id        bigint,
  venue_name      text,
  primary_performer_id bigint,
  primary_performer_name text,
  raw             jsonb,
  archived_at     timestamptz NOT NULL DEFAULT now()
);
```

Backfill via `/v9/events?occurs_at.gte=...&occurs_at.lte=...` for date ranges with SG orders.

### 3h. `data_freshness` view — per-source last-pulled-at

**Justification:** Cron audit shows 83 jobs but no single place to see "is each source up to date." Useful for the data quality dashboard the Phase 2 UI is building.

```sql
CREATE VIEW v_data_freshness AS
SELECT 'tevo_listings'::text AS source, MAX(captured_at) AS latest_pull FROM listings_snapshots
UNION ALL SELECT 'evo_orders', MAX(evo_updated_at) FROM evo_orders
UNION ALL SELECT 'seatgeek_orders', MAX(created_at_sg) FROM seatgeek_orders
UNION ALL SELECT 'espn_events', MAX(captured_at) FROM espn_event_snapshots
-- ...etc
;
```

## 4. Audit continuation findings

### 4a. listings_snapshots heap bloat or stale stats

Two possibilities:
1. **Heap bloat from change-only ingest not being deployed**: storage audit recommended it 3 days ago; either it wasn't applied, was applied but isn't being picked by `collect-listings`, or change-only catches don't compress already-bloated history.
2. **Stale `n_live_tup`**: post-VACUUM the row count would drop dramatically as dead tuples get reclaimed; the 7.18M → 373,855 drop is roughly the right scale.

Probably a mix. Either way: **the table will breach Supabase tier limits soon if growth continues at ~150 MB/day.** A real `VACUUM FULL` or partition strategy is needed.

### 4b. View layer is larger than table layer

136 views vs 120 tables. Significant abstraction. The pattern is healthy (read paths shielded from table shape changes) but means schema-change ripple effects are higher than the table count suggests. Worth documenting view dependencies before any DROP TABLE operation.

### 4c. Two SG "view artifact" tables ARE in use

Originally flagged as orphans in `docs/data-sources-audit-2026-05-11.md` (now corrected). Live evidence: `seatgeek_listings_snapshots` is 50 MB / 63,390 rows. Actively populated.

### 4d. `sg_seller_pending` recent timestamp

Audit saw newest `sg_seller_pending` row at 2026-05-11 17:02 UTC — recent enough that 11 unresolved may resolve themselves on next cron tick. Re-check in 24h to confirm vs nws_alert_pending pattern.

## 5. Build priority recommendation

| priority | proposal | why |
|---|---|---|
| 1 | `seatgeek_orders_resolved` (Path B) | Highest impact — unlocks 67.8% of 400 historical orders for cross-source analytics with no new dependencies |
| 2 | `v_pg_net_queue_health` view | Operational visibility for the bug class we discovered |
| 3 | `event_section_row_snapshots` | Direct response to user's request, methodology validated |
| 4 | `entity_xref_overrides` + `entity_xref_conflicts` | Governance precondition for Layer 1–4 builds; small migration |
| 5 | `broker_xref` (Layer 2.5) | Enables Layer 4 fallback path; small |
| 6 | `listing_xref` (Layer 4) | Largest scope; deserves own design pass after 1-5 land |
| 7 | `tevo_event_archive` | Defer; only if SG historical cross-source becomes high-value enough |

## Handoff

| owner | action |
|---|---|
| **C1** (in-lane) | This doc closes the audit pass. |
| **A1** (push) | When implementation resumes: land priority 1 + 2 in a single migration on a new feature branch (do not bundle on the audit branch). Priorities 3-6 follow in separate migrations. |
| **B1** (audit views) | The `v_pg_net_queue_health` view is the operational hand-off for ongoing drift detection. |
