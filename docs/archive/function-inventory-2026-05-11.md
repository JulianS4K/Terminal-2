# Function + RPC inventory audit — 2026-05-11 (continued)

Produced by C1 (Data + Chat Bot, supervisor). Continued audit pass post-handoff. Surfaces material findings that affect the `proposed-tables-2026-05-11.md` packet — A1 should read this before reviewing the proposals.

## Headline counts

| metric | value |
|---|---|
| Functions in `public.*` | **244** |
| pg_trgm extension functions | ~25 (installed, v1.6) |
| pg_net queue/process/sweep functions | ~30 |
| Cross-source sync triggers | ~15 |
| Custom business / RPC functions | ~170 |
| Materialized helpers | 0 (none) |

## Extension state (verified live)

| extension | installed? | version | purpose |
|---|---|---|---|
| `pg_trgm` | ✅ | 1.6 | fuzzy match — Layer 1 venue / Layer 2 performer |
| `pg_net` | ✅ | 0.20.0 | async HTTP for ingest pipelines |
| `pg_cron` | ✅ | 1.6.4 | 83 cron jobs |
| `unaccent` | ❌ | — | required by proposed `norm()` function |
| `postgis` | ❌ | — | not needed (haversine_miles function exists) |
| `vector` | ❌ | — | not needed |

## Major findings that change the proposed-tables packet

### F1. `trg_set_updated_at()` does NOT exist

- `MIGRATION_CONVENTIONS.md` §10 claims it does ("`trg_set_updated_at()` exists; if not, add it in the same migration")
- Live verification: `SELECT proname FROM pg_proc WHERE proname='trg_set_updated_at'` returns 0 rows
- **My `proposed-tables-2026-05-11.md` prescribes it 6 times** — every migration that references it would fail
- **Required action:** define `trg_set_updated_at()` in the first new-table migration (the canonical lane's `seatgeek_orders_resolved` is the right place since it's #1 in build order)

Suggested function body:
```sql
CREATE OR REPLACE FUNCTION trg_set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;
```

### F2. `unaccent` extension not installed

- Proposed `norm()` function uses `unaccent(s)`
- Without it, the `norm()` definition won't compile
- **Required action:** `CREATE EXTENSION IF NOT EXISTS unaccent;` in the migration that introduces `norm()`

### F3. `haversine_miles` exists but returns MILES, not meters

- Existing function signature: `haversine_miles(p_lat1, p_lon1, p_lat2, p_lon2) → numeric (miles)`
- Methodology says "≤ 100m strong match"
- **Required change:** Layer 1 venue match should use either:
  - `haversine_miles(...) <= 0.0625` (≈100 m in miles)
  - OR introduce a `haversine_meters` wrapper
- Both reasonable; reviewer should pick. Documentation update needed in `cross-source-entity-resolution-2026-05-11.md`.

### F4. Layer 3 Path A is largely already implemented

The canonical lane has built most of what my methodology proposed for Path A:

| existing function | what it does | my methodology layer |
|---|---|---|
| `sg_extract_performers(text) → text[]` | Parses SG event name into performer array | Layer 3 / Path B parsing step |
| `sg_match_event_by_venue_date(sg_event_id, name, date, venue) → bigint` | Returns matched `tevo_event_id` or NULL | Layer 3 Path A |
| `sg_attempt_event_xref(sg_event_id, name, date, venue) → (matched_id, method, confidence)` | Full attempt with audit fields | Layer 3 Path A |
| `auto_match_sg_canonical() → counts` | Bulk match driver | Layer 3 Path A driver |
| `auto_match_sg_canonical_relaxed()` | Relaxed-overlap variant | Layer 3 fuzzy tier |
| `cross_source_match_tick()` | Cross-source match cron tick | All layers, orchestration |
| `audit_cross_source_health() → jsonb` | Returns xref health report | Similar to proposed `v_pg_net_queue_health` |

**Live test confirmed correct behavior:**
- `sg_extract_performers('Los Angeles Angels at New York Yankees')` returns `['Los Angeles Angels','New York Yankees']` — exactly what my Path B parser would do
- `sg_attempt_event_xref(17022115, ...)` returns NULL — correct, since there's no TEvo event for 2025-06-17 Yankees

**Implication for proposals:**

- **Proposal #1 `seatgeek_orders_resolved` is STILL needed.** Path B (resolve venue + performers separately when no TEvo event exists) is genuinely new. Existing matchers all require a TEvo event row to point at.
- **Proposal #1 should REUSE `sg_extract_performers()` and `v_canonical_venue`/`v_canonical_performer`** rather than reimplementing parsing logic.
- **The 67.8% / 19.8% sample-fix accuracy from `cross-source-entity-resolution-2026-05-11.md` may already be exceeded** by `auto_match_sg_canonical_relaxed()` — A1 should benchmark before greenlight.

### F5. `audit_cross_source_health()` already exists

Returns `jsonb` health report. Reviewer should check whether it covers what my proposed `v_pg_net_queue_health` view would surface. If so, extend that function rather than building a parallel view.

## Function category breakdown (244 total)

### Public RPCs (consumer-facing, ~25)
Used by edge functions / chat / frontends:
`get_event_context`, `get_event_zones_public`, `get_event_listings_public`, `get_event_assets_public`, `get_cached_ticket_groups`, `get_chat_suggestion_chips`, `get_broker_events_upcoming`, `get_broker_event_detail`, `get_broker_event_movers`, `get_event_movers`, `get_events_by_performer_public`, `get_events_by_venue_public`, `get_performers_by_league`, `get_performer_assets_public`, `get_performer_landing_public`, `get_venue_assets_public`, `get_team_context`, `get_team_roster`, `get_player_info`, `get_wiki_context`, `search_events_by_date`, `search_performers_for_chat`, `search_performers_typeahead`, `submit_lead_public`, `broker_performer_dashboard`, `broker_recent_intel`.

### pg_net pipeline triples (queue + process + sweep, ~30)
Every external source pulls via this pattern. Examples:
- ESPN: `espn_scoreboard_{queue, process}`, `espn_tournament_{queue, process}`
- TEvo: `evo_orders_{queue, process}`, `evo_event_backfill_{queue, process}`
- SeatGeek: `sg_listings_{queue_window, process}`, `sg_seller_{listings_queue, orders_queue, process}`, `sg_event_backfill_{queue, process}`
- Weather: `weather_forecast_{queue, process}`, `weather_historical_{backfill, process, retry_throttled}`, `venue_geocode_{queue, process}`
- NWS: `nws_alerts_{queue, process}`, `nws_points_{queue, process}`
- Wiki: `queue_performer_wiki_searches`, `process_performer_wiki_searches`, `process_performer_wiki_summaries`, `performer_wiki_tick`, `wiki_pending_sweep`
- Reddit / FRED / Tournaments: similar pairs

### Cross-source sync triggers (~15)
Auto-maintain `canonical_external_ids` when xref tables change:
`trg_sync_cei__event_xref`, `trg_sync_cei__perf_espn_team_xref`, `trg_sync_cei__performer_external_ids`, `trg_sync_cei__sd_event_xref`, `trg_sync_cei__sd_venue_xref`, `trg_sync_cei__sg_event_xref`, `trg_sync_cei__sg_venue_xref`, `trg_sync_cei__venue_assets_espn`, `trg_sync_pei__sd_perf_xref`, `trg_sync_pei__sg_perf_xref`, `trg_sync_pei__wikipedia`, plus matching `trg_truncate_resync__*` for cascade behavior on truncate.

### Compute / metric backfill (~25)
`compute_event_section_metrics`, `compute_event_zone_metrics`, `compute_event_splits_metrics`, `compute_event_nonowned_median`, `compute_seatgeek_event_metrics`, `compute_alerts_tick`, `compute_event_breakdowns`, `compute_buyer_sentiment`, `compute_nws_impact_tier`; `backfill_*` variants of each; `refresh_*` for caches and baselines.

### Master orchestration / cron ticks (~10)
`master_cascade_2min`, `midnight_catchup_sweep`, `compute_alerts_tick`, `cross_source_match_tick`, `performer_wiki_tick`, `sg_canonical_auto_match_tick`, `match_events_to_espn_tick`, `auto_link_event_xref`, `tg_event_alerts_auto_ack_low_signal`.

### Classifiers (~10)
`classify_performer_categories`, `classify_playoff_stage`, `classify_tennis_tour`, `classify_tournament_sport`, `classify_zone_canonical`, `derive_event_lifecycle`, `derive_zone_fallback`, `map_tevo_category_to_genre`, `map_tevo_top_category`, `map_top_category_to_event_type`.

### Section / row / venue helpers (~10)
`_sec_norm`, `_sec_prefix`, `_sec_suffix`, `section_in_range`, `sg_section_kind`, `sg_section_number`, `sg_section_prefix`, `is_north_america_venue`, `haversine_miles`, `ugc_from_url`, `ugc_kind`, `ugc_state`.

**`_sec_norm` exists** — my proposed `section_norm()` helper duplicates it. Reviewer should check signature and reuse if compatible.

### Search / chat (~15)
`extract_chat_entities`, `tokenize_chat_text`, `match_news_keywords`, `match_performer_zone`, `audit_chat_message`, `check_chat_rate_limit`, `expand_user_zone_token_to_zones`, `refresh_chat_corpus`, `refresh_chat_term_freq_split`, `run_daily_chat_audit`, `mark_event_chat_tracked`, `event_has_s4k_inventory`, `extract_game_number`, `extract_opponent`, `is_rivalry_game`.

### pg_trgm extension (~25, not custom)
`similarity`, `strict_word_similarity`, `word_similarity`, `gin_*`, `gtrgm_*`, `show_limit`, `show_trgm`, `set_limit`, and op-class entries.

### Storage / caching (~5)
`get_cached_ticket_groups`, `put_cached_ticket_groups`, `sweep_tevo_ticket_groups_cache`, `sweep_old_bot_messages`, `sweep_old_listings`.

### Auth / secret (~3)
`get_app_secret`, `upsert_app_secret`, `tevo_sign_get`.

### Misc helpers
`canonical_order_status`, `get_or_authorize_pull`, `external_ids_for_event`, `external_ids_for_performer`, `external_ids_for_venue`, `next_performers_to_crawl`, `next_venues_to_crawl`, `tevo_event_id_for`, `tevo_performer_id_for`, `tevo_venue_id_for`, `resolve_tevo_performer_id`, `sd_xref_resolve`, etc.

## Updates needed to the proposed-tables packet

A1 should treat the proposed-tables doc as **needing one revision pass** before applying:

1. **First migration to land must include** `CREATE EXTENSION IF NOT EXISTS unaccent;` + `CREATE OR REPLACE FUNCTION trg_set_updated_at()` (see F1, F2)
2. **Proposal #1 (`seatgeek_orders_resolved`) implementation** should:
   - Reuse `sg_extract_performers()` instead of writing a new parser
   - Reuse `v_canonical_venue` + `v_canonical_performer` (proposal already does this)
   - Run `auto_match_sg_canonical_relaxed()` first, then fall through to Path B for what's still unmatched
3. **Proposal #2 (`v_pg_net_queue_health` view)** — compare against existing `audit_cross_source_health()` first; may be redundant or merge-able
4. **Proposal #3 (`event_section_row_snapshots`)** — `_sec_norm()` already exists; reuse it instead of declaring `section_norm()`
5. **Layer 1 venue match docs** in `cross-source-entity-resolution-2026-05-11.md` should update threshold from "≤ 100m" to "≤ 0.0625 miles" (F3)

## Function-layer health observations

- **No materialized helpers** — pure SQL/PLpgSQL throughout. No PostgreSQL functions written in C, Rust, or external languages. Good for portability; means everything is grep-able in migrations.
- **Heavy trigger automation** — 15+ sync triggers maintain `canonical_external_ids` automatically. Any new xref table needs to register with this trigger chain (`trg_sync_cei__*`) or its data won't propagate to the canonical layer.
- **Master cascade pattern** — `master_cascade_2min` is the top-level orchestration tick. New cron-driven work should consider chaining off this rather than introducing parallel master ticks.

## Hand-off

| owner | action |
|---|---|
| **C1** (in-lane) | This continuation doc closes the function inventory audit. |
| **A1** (push) | Read this BEFORE reviewing `proposed-tables-2026-05-11.md`. Revisions to that doc per the "Updates needed" section may be needed before greenlight. |
| **B1** (audit views) | `audit_cross_source_health()` already exists and emits jsonb — likely the better hand-off point than my proposed view. |
