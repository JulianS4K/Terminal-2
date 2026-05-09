# Query Catalog — what gives me X for an event?

Comprehensive index of every view + read-only function in `public.*`,
organized by intent. Use this as the lookup table when wiring a new
UI surface; you should rarely need to write a SELECT against raw
tables.

> **All listed surfaces are SELECT-safe with `coworker_readonly`.**
> If a view depends on a function not in your role's grants, the row
> will return NULL or empty rather than error.

---

## 1. Single-event detail (the AI/RAG bundle)

| Query | What it returns | When to use |
|---|---|---|
| **`SELECT get_event_context(:event_id)`** | One JSONB with **13 keys**: event basics + pricing + ESPN + odds + Wikipedia + weather + competitors + Reddit pulse + important_news + x_accounts_known + our_orders + classification | Default landing for any event-detail surface. One call → everything. |
| `get_broker_event_detail(:event_id)` | Tabular row: event basics + venue + map URLs + has_seating_chart flag + curated_zones_count | When you need just the broker-facing fields without the full bundle |
| `SELECT * FROM v_event_full_v2 WHERE tevo_event_id=:event_id` | Tabular: full canonical event with TEvo+SG+SD pricing nested + sg_event_metrics + sentiment | When you want pricing inline without function-call overhead |
| `SELECT * FROM v_event_full_sports WHERE tevo_event_id=:event_id` | Tabular: same but with ESPN team state, injuries, news, home/away, days_to_event | Sports-specific event detail |

**Tip:** `get_event_context` is the easiest path. It bundles every signal you'd otherwise need 8 queries to assemble.

---

## 2. Listing pricing (per event, per section, per zone)

| Query | What |
|---|---|
| **`get_event_listings_public(:event_id, :zone, :min_qty, :max_price, :limit, :include_all)`** | Per-listing rows: section, row, qty, retail_price, format, splits, instant/wheelchair flags, owned/provenance, resolved_zone |
| `get_event_zones_public(:event_id, :include_all)` | Zone-level rollup: zone_name, listings, total_tickets, cheapest, median, most_expensive |
| `get_event_zones_rollup(:event_id, :owned_only)` | Same shape, lighter — just zone, source, tickets, min/max retail |
| `SELECT * FROM v_pricing_cross_source WHERE tevo_event_id=:event_id` | Section-level pricing **across TEvo + SG + SG-seller + SD** with `sg_vs_tevo_pct` and `sd_sold_vs_tevo_listed_pct` |
| `SELECT * FROM latest_event_metrics WHERE event_id=:event_id` | TEvo event-level rollup: getin, percentiles, dispersion, owned_share |
| `SELECT * FROM retail_event_zones WHERE event_id=:event_id` | TEvo zone-level (lighter) |
| `SELECT * FROM retail_event_sections WHERE event_id=:event_id` | TEvo section-level |
| `SELECT * FROM seatgeek_event_latest WHERE tevo_event_id=:event_id` | Latest SG listings + SG sales for an event |
| `SELECT * FROM seatdata_event_latest WHERE tevo_event_id=:event_id` | Latest SD stats + sales (sparse — SD pull pipeline pending) |

---

## 3. Velocity / movement / trends

| Query | What |
|---|---|
| **`SELECT * FROM v_event_velocity_windows WHERE tevo_event_id=:event_id`** | 1h / 6h / 24h price + inventory deltas across TEvo + SG. Use `tevo_getin_d1h_pct`, `tevo_getin_d24h_pct` for "what moved" cards |
| `SELECT * FROM event_velocity WHERE id=:event_id` | Latest vs immediately-prior capture (legacy view; less precise) |
| `get_event_movers(:window_hours)` | Top movers across all events in window — for a "biggest movers" board |

---

## 4. Sales / orders / our book

| Query | What |
|---|---|
| **`SELECT * FROM our_orders_with_net WHERE tevo_event_id=:event_id`** | Per-order rows with **gross_amount + net_amount** (after `order_fee_schedule` per-source fees) |
| **`SELECT * FROM our_orders_by_event_with_net WHERE tevo_event_id=:event_id`** | Per-event rollup of our orders (gross_fulfilled + net_fulfilled + status counts) |
| `SELECT * FROM our_orders` | Same as our_orders_with_net minus the net column — TEvo + SG combined |
| `SELECT * FROM unified_orders_by_event WHERE tevo_event_id=:event_id` | TEvo + SG + **SeatData (market observations)** rollup; broader than our_orders which is OUR sales only |
| `SELECT * FROM v_sg_sales_by_section WHERE tevo_event_id=:event_id` | Per SG sale: section, row, qty, sale_price, total estimate, status, timestamps |
| `SELECT * FROM v_sg_sales_by_event WHERE tevo_event_id=:event_id` | SG event-level rollup with median/min/max sale_price + distinct_sections |
| `SELECT * FROM evo_orders_by_event WHERE tevo_event_id=:event_id` | TEvo-side per-event order rollup |
| `SELECT * FROM seatgeek_orders_by_event` | SG-side per-event |

---

## 5. Alerts (the "what should I look at" surface)

| Query | What |
|---|---|
| **`SELECT * FROM v_open_alerts ORDER BY severity DESC, fired_at DESC`** | Unacknowledged alerts. Use `severity` for color (`critical`/`warn`/`info`) |
| `SELECT * FROM v_open_alerts WHERE tevo_event_id=:event_id` | Alerts on a specific event |
| `SELECT count(*) FILTER (WHERE acknowledged_at IS NULL) FROM event_alerts` | Alert badge count |

7 active rules: `tevo_getin_drop_1h`, `tevo_getin_surge_1h`, `tevo_inventory_low_48h`, `arbitrage_opportunity`, `espn_status_change`, `competing_event_added`, `line_movement_24h`.

---

## 6. Cross-event signals (competitors, MLB series, tournaments, tours, residencies, Broadway)

| Query | Returns |
|---|---|
| **`SELECT * FROM v_competing_events WHERE tevo_event_id=:event_id`** | Events within ±24h × 20mi |
| `SELECT competitors FROM event_competitors_snapshot WHERE tevo_event_id=:event_id` | Same data pre-computed (faster) |
| **`SELECT * FROM v_mlb_game_series WHERE :event_id = ANY(tevo_event_ids)`** | MLB regular-season 3–4 game series for an event (with optional `branded_series_name` like "Subway Series") |
| `SELECT * FROM v_performer_tours WHERE primary_performer_id=:perf_id` | Tour: ≥2 venues over 12 months. Returns `venues[]`, `regions[]` |
| `SELECT * FROM v_performer_residencies WHERE venue_id=:venue_id` | Residencies at a venue (Sphere, Caesars, MSG runs) |
| `SELECT * FROM v_broadway_runs WHERE primary_performer_name ILIKE '%:show%'` | Broadway show runs at known Broadway theaters |
| `SELECT * FROM v_unmatched_events` | Events seen on SG/SD/EVO orders but missing event-table row |

---

## 7. ESPN / sports state

| Query | Returns |
|---|---|
| **`SELECT * FROM v_event_betting_odds_latest WHERE tevo_event_id=:event_id`** | Spread, OU, ML, win-prob (DraftKings via ESPN scoreboard) |
| `SELECT * FROM v_event_line_movement WHERE tevo_event_id=:event_id` | 1h / 24h line movement deltas |
| `SELECT * FROM v_espn_team_state WHERE espn_team_id=:team_id` | Team record, streak, win_pct |
| `SELECT * FROM v_espn_injuries_current WHERE espn_team_id=:team_id` | Active injuries per team |
| `SELECT * FROM v_espn_game_results WHERE espn_event_id=:eid` | Final scores + box for played games |
| `get_team_context(:performer_id)` | JSONB bundle of team state: record, last 5, injuries summary, recent news |
| `get_team_playoff_context(:performer_id)` | Playoff seeding + bracket position |
| `get_team_roster(:performer_id)` | Roster + key players |
| `get_player_info(:query, :limit)` | Player search across ESPN athletes |
| `get_recent_team_changes(:since, :limit)` | Trades, signings, injuries since a timestamp |

---

## 8. Weather (works for indoor + outdoor)

| Query | Returns |
|---|---|
| **`SELECT * FROM v_event_weather_with_fallback WHERE tevo_event_id=:event_id`** | Per-event: forecast within 16d → climatology fallback. **`weather_kind`** = `forecast_indoor` / `forecast_outdoor` / `climatology_indoor` / `climatology_outdoor` / `none` |
| `SELECT * FROM v_event_weather WHERE tevo_event_id=:event_id` | Forecast-only (no climatology fallback) |
| `SELECT * FROM v_venue_climatology WHERE tevo_venue_id=:venue_id AND month=...` | Historical climatology by venue + day-of-year |

---

## 9. Social / news context (for AI chatbot)

| Query | Returns |
|---|---|
| **`SELECT * FROM v_reddit_important_recent WHERE tevo_performer_id IN (SELECT performer_id FROM ...) ORDER BY created_utc DESC`** | 48h Reddit posts matching news keywords (injury / trade / signed / IL / etc.) with weighted hits |
| `SELECT * FROM v_performer_reddit_pulse WHERE tevo_performer_id=:perf_id` | Reddit posts_24h / posts_7d / score / latest_post_at per performer |
| `SELECT * FROM v_performer_news_sources WHERE tevo_performer_id=:perf_id` | All known X handles + subreddits for a performer (for chatbot prompt-building) |
| `SELECT * FROM v_x_accounts_unified WHERE sport=:sport OR team_name=:team` | X-account roster, filterable by sport/league/team/category |
| `SELECT * FROM v_subreddits_unified WHERE league=:league` | Reddit subs (performer-pinned + leaguewide) |
| `match_news_keywords(:text)` | Returns `{hits, categories, total_weight}` JSONB — useful for AI processing arbitrary text |
| `get_wiki_context(:performer_id)` | Wikipedia summary + extract for AI prompt |

---

## 10. Search / typeahead / discovery

| Query | What |
|---|---|
| **`get_broker_events_upcoming(:search, :performer_id, :venue_id, :days_ahead, :limit, :offset)`** | Filterable upcoming-events search with all the broker-relevant fields |
| `search_events_by_date(:date_from, :date_to, :performer_id, :city, :min_tickets, :limit)` | Date-range search |
| `search_performers_typeahead(:query, :limit)` | Typeahead suggestions for performer search |
| `get_events_by_performer_public(:performer_id, :days_ahead, :limit)` | All upcoming events for a performer |
| `get_events_by_venue_public(:venue_id, :days_ahead, :limit)` | All upcoming events at a venue |
| `get_chat_suggestion_chips(:count, :min_tickets)` | "Suggested events" surface |
| `get_performers_by_league(:league)` | Performers in a league with home/road event metrics |

---

## 11. Performer / venue assets

| Query | Returns |
|---|---|
| `get_performer_landing_public(:performer_id)` | Landing page bundle: name, slug, category, genre, home_venue, upcoming_first/last |
| `get_performer_assets_public(:performer_id)` | Logos, colors, image URLs |
| `get_event_assets_public(:event_id)` | Event-specific assets (seating chart URLs, banner images) |
| `get_venue_assets_public(:venue_id)` | Venue images, lat/lon, indoor flag |

---

## 12. Arbitrage / opportunity detection

| Query | What |
|---|---|
| **`SELECT * FROM v_arbitrage_opportunities WHERE abs(sg_vs_tevo_gap_pct) >= 15`** | Section-level TEvo↔SG price gaps with both sides ≥2 listings |

(Sparse today because SG xref coverage is naturally low; populates as overlap grows.)

---

## 13. Coverage / data-quality / status (for the Data Quality Dashboard)

| Query | What |
|---|---|
| `SELECT * FROM cross_source_coverage` | Per-entity sources-present matrix |
| `SELECT * FROM cross_source_event_audit` | Per-event source coverage |
| `SELECT * FROM v_canonical_coverage` | Performer-level source presence count |
| `SELECT * FROM v_unmatched_events` | Orphans across SG / SD / EVO |
| `SELECT * FROM data_source_field_map_audit WHERE NOT has_field_map_rows` | Tables without field-map rows (drift detector) |
| Pending queue counts (TEvo, SG, weather, wiki, reddit, etc.) | See `DATA_QUALITY_DASHBOARD.md` for the SQL |

`coworker_readonly` does **not** have access to `cron.*`. For cron-run history, use the `v_cron_health` view that the audit lane will provide on request (open an issue when you want it).

---

## 14. Utility helpers

| Query | What |
|---|---|
| `haversine_miles(:lat1, :lon1, :lat2, :lon2)` | Distance in miles between two points |
| `find_competing_events(:event_id, :radius_miles, :window_hours)` | Tunable competing-events search (different params than the snapshot view) |
| `find_similar_events(:event_id, :max)` | Similar events with similarity scoring |
| `is_north_america_venue(:location)` | Boolean — is this venue location in continental N.A.? |
| `external_ids_for_event(:tevo_event_id)` | All cross-source IDs for an event (ESPN, SG, SD, etc.) |
| `external_ids_for_performer(:tevo_performer_id)` | Same for performer |
| `external_ids_for_venue(:tevo_venue_id)` | Same for venue |

---

## 15. Useful aggregation patterns (copy/paste)

### "What kind of event is this?" classifier

```sql
WITH classified AS (
  SELECT
    EXISTS(SELECT 1 FROM v_performer_tours        WHERE :event_id = ANY(tevo_event_ids)) AS is_tour,
    EXISTS(SELECT 1 FROM v_performer_residencies  WHERE :event_id = ANY(tevo_event_ids)) AS is_residency,
    EXISTS(SELECT 1 FROM v_broadway_runs          WHERE :event_id = ANY(tevo_event_ids)) AS is_broadway,
    EXISTS(SELECT 1 FROM v_mlb_game_series        WHERE :event_id = ANY(tevo_event_ids)) AS is_mlb_series
)
SELECT * FROM classified;
```

### Best-bet upcoming-events list (homepage hero)

```sql
SELECT *
FROM get_broker_events_upcoming(
  p_search        => NULL,
  p_performer_id  => NULL,
  p_venue_id      => NULL,
  p_days_ahead    => 21,
  p_limit         => 50,
  p_offset        => 0
);
```

### Daily check on portfolio health

```sql
SELECT
  count(*) FILTER (WHERE canonical_status='fulfilled')                             AS sold_today,
  sum(net_amount)::int FILTER (WHERE canonical_status='fulfilled')                 AS net_today,
  count(*) FILTER (WHERE canonical_status='pending')                               AS pending_now,
  count(*) FILTER (WHERE canonical_status='cancelled')                             AS cancelled_today
FROM our_orders_with_net
WHERE source_created_at::date = current_date;
```

### Performers with rising Reddit buzz (new signal)

```sql
SELECT
  pm.performer_id, pm.name,
  rp.posts_24h, rp.posts_7d,
  -- buzz multiplier: today's pace vs week average
  ROUND( (rp.posts_24h::numeric / NULLIF(rp.posts_7d::numeric / 7.0, 0)), 2 ) AS buzz_multiplier
FROM performer_metadata pm
JOIN v_performer_reddit_pulse rp ON rp.tevo_performer_id = pm.performer_id
WHERE rp.posts_7d > 5
ORDER BY buzz_multiplier DESC NULLS LAST
LIMIT 25;
```

---

## Data shape conventions to remember

- All event ids are `bigint` and prefixed `tevo_event_id` in views; the
  raw `events` table column is just `id`.
- `occurs_at_local` is **text**, not timestamp. Cast: `occurs_at_local::timestamptz`.
- Money is `numeric`, never floats. Display with `(value)::int` for cents truncation if you want integer dollars.
- Many views filter to `event_type IS DISTINCT FROM 'game'` to exclude
  team sports — pay attention if you're querying both sports + concerts.
- Weather: prefer `v_event_weather_with_fallback` over the raw view —
  works for indoor + outdoor + far-future events.
- Sales: `our_orders_with_net` uses `payment_total` when present (TEvo),
  derives gross from `sale_price * sale_quantity` for SG (since SG API
  doesn't return payment_total).
