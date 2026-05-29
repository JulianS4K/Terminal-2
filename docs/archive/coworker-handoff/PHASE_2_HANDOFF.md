# Phase 2 Handoff — Audit + Open Issues

**Date written**: 2026-05-09
**Author**: Claude (Phase 1 build) → Coworker (Phase 2)
**Live audit run against**: `phase1-baseline = ba97203`

---

## TL;DR — pick one of these and it'll move the needle

1. **Fix `event_type` classification** — 58.6% of upcoming events (1,845 / 3,146) have `event_type IS NULL`. They're mostly Broadway / concerts / tours. Any view filtered on `event_type` silently excludes them.
2. **Expand `venue_assets` coverage** — 256 of 344 distinct upcoming venues (74%) have NO entry in `venue_assets`. Those events get **no weather, no NWS alerts, no climatology, no UGC, nothing spatial**.
3. **Fix the TEvo listings pull coverage** — even at the tightest cron tier (0-24h, every 20min), only 45.7% of events have a listings pull within the last 24h. Drops to 10.3% for the 7-30d window.

These three items together gate the value of every context dimension we built in Phase 1.

---

## Phase 1 status (what was built)

| # | Item | PR | Status |
|---|---|---|---|
| #1 | Holiday + school calendar (US/CA/MX, federal+state+city) | #34 | ✅ shipped |
| #1.5 | State/city precision + district school breaks | #35 | ✅ shipped |
| #2 | NWS active weather alerts (api.weather.gov) | #36 | ✅ shipped |
| #6 | ESPN injuries overlay | #37 | ✅ shipped |
| #3 | Spotify popularity | — | ⏸️ pending dev account |
| #3-alt | Billboard charts | — | ❌ skipped |
| #4 | TSA passenger throughput | — | ❌ skipped |
| #5 | Local competing events | — | ❌ skipped |
| #7 | OpenTable | — | ❌ skipped |
| #8 | Hotel occupancy | — | ❌ skipped |
| #9 | City subreddits | — | ❌ skipped |
| #10 | FOMC dates | — | ❌ skipped |
| #11 | Spotify Charts / Netflix / Nielsen | — | ❌ skipped |
| #12 | DK / FanDuel handle | — | ❌ skipped |

`get_event_context(p_event_id)` now returns **17 keys**:
> `event` · `pricing` · `espn` · `odds` · `performer` · `weather` · **`weather_alerts`** · **`injuries`** · `competitors` · `reddit` · `important_news` · `x_accounts_known` · `rivalry` · **`calendar`** · `our_orders` · `tevo_event_id` · `generated_at`

Bold = added during Phase 1 context build.

---

## Audit findings — coverage gaps (ranked by leverage)

### 1. `event_type` is NULL for 58.6% of upcoming events 🔴 **critical**

```
evt_type   upcoming  distinct_venues  sample
<null>     1845      280              "& Juliet" (Broadway)
game       1148       91              MLB / NBA / NFL / NHL games
concert     125       10              "2026 USA Summer Tour - Liverpool vs Wrexham" *
show         27        2              "Joe Turner's Come and Gone" (Broadway)
comedy        1        1              "We Them Ones Comedy Tour"
```
\* note the misclassification — soccer match labeled "concert"

**Why this matters**: Every view we filter on `event_type='game'` (e.g. `v_event_injuries`) silently excludes those 1,845 events. Sports-only filters work but anything wanting "all music events" or "all Broadway" is flying blind.

**Fix path**: backfill `event_type` from TEvo's category data. The TEvo source tracks `tevo_top_category` and `tevo_event_type` but our `events` table doesn't surface them — we wedged them down to the simple `event_type` column. Either (a) re-derive from `tevo_top_category` on insert, or (b) add a parallel `event_classification` column with finer grain.

### 2. `venue_assets` coverage gap 🔴 **critical**

| Metric | Count | % |
|---|---|---|
| Total `venue_assets` entries | 111 | — |
| With lat/lon | 105 | 95% |
| With NWS UGC | 99 | 89% (US-only; Canadian venues excluded) |
| Distinct venues in upcoming events | 344 | — |
| **Upcoming venues missing `venue_assets`** | **256** | **74%** |
| Upcoming events affected | 1,694 | 53% of all upcoming |

Of the missing 256 venues, **248 are unclassified events** (event_type NULL — Broadway/concerts/tours). Only 8 missing venues are sports games (small fix), 2 are concerts, 2 are shows.

**Impact**: events at those venues get no weather, no NWS alerts, no climatology, no NWS UGC backfill, no `is_indoor` flag.

**Fix path**: either
- **Auto-mode**: extend the `crawl-venues-and-performers` cron to insert any venue seen in `events` into `venue_assets` with NULL fields, then trigger geocode + NWS-points backfill chain we already built
- **Manual seed**: top-50 concert venues (MSG, Forum, Hollywood Bowl, Ryman, Beacon, Apollo, Radio City, the major amphitheaters) + ~40 Broadway theaters. ~1 day of curation work, fits the same pattern as `holidays` / `sporting_rivalries`

### 3. TEvo listings pull coverage by date bucket 🔴 **critical**

| Bucket | Upcoming events | With recent listings (24h) | % |
|---|---|---|---|
| 0-24h (cron every 20 min) | 92 | 42 | **45.7%** |
| 1-7d (cron every 1 hr) | 328 | 66 | 20.1% |
| 7-30d (cron every 4 hr) | 1,150 | 119 | 10.3% |
| 30-60d (cron every 12 hr) | 513 | 100 | 19.5% |
| 60d+ (cron daily 02:20) | 1,063 | 138 | 13.0% |

Even at the tightest tier (0-24h, every 20 min) only 46% of events get a listings refresh. Either:
- (a) `collect-listings` edge function is throttled (TEvo rate limit / batch size)
- (b) Events have no available listings (zero supply on broker tier)
- (c) The function is filtering events out unintentionally

**Investigation needed** in `supabase/functions/collect-listings/`. Check the `min_age_seconds` thresholds and whether the loop is hitting batch limits.

### 4. Cross-source xref coverage 🟡 **medium**

| Xref | Upcoming events matched | % |
|---|---|---|
| ESPN xref (games only, n=1,148) | 408 | **35.5%** |
| SeatGeek xref | 3 | ≈0% |
| SeatData xref | 1 | ≈0% |

ESPN at 35.5% is the binding constraint for the new injury overlay (#6). 740 games have no ESPN match → no injuries flow → no rivalry detection from ESPN side.

The `cross_source_match_tick_30min` cron is supposed to grow this. Check whether:
- It's stuck on legacy backlog
- Match criteria are too strict
- TEvo events for non-major leagues don't have ESPN equivalents at all

SeatGeek and SeatData xrefs are essentially dormant — entire pipelines could be deactivated until inventory grows.

### 5. Performer coverage gaps 🟡 **medium**

| Metric | Active perfs upcoming | Covered |
|---|---|---|
| Total active performers | 312 | — |
| With Wikipedia bio | 312 | **100%** ✅ |
| With subreddit mapping | 113 | 36% |
| In `performer_metadata` | 177 | 57% |

`performer_metadata` has 888 total entries but only 177 match active performers — **80% noise** (inactive / past performers). Either prune or accept and live with it.

**Subreddit gap**: only 113/312 (36%). The 157 seeded subreddits cover major-league teams almost exhaustively, but tour/concert performers don't have one in the seed.

**Fix path**: extend `performer_subreddits` seed with concert-performer subs where they exist (r/taylorswift, r/billieeilish, r/eras_tour, etc.). Maybe 40-50 marquee acts.

### 6. ESPN athlete table is stale 🟡 **medium**

| Table | Last update | Cron | Status |
|---|---|---|---|
| `espn_injuries_snapshots` | 2026-05-10 00:24 | every 3 min | ✅ fresh |
| `espn_event_snapshots` | 2026-05-10 00:24 | every 3 min | ✅ fresh |
| `espn_athletes` | 2026-05-07 21:18 | daily 05:00 | ⚠️ ~3d stale |

The daily refresh seems to have fallen behind. Check `espn-team-daily` cron logs.

### 7. Empty / dormant tables that bloat the schema 🟢 **low** (cleanup)

| Table | Rows | Action |
|---|---|---|
| `seatdata_listings_snapshots` | 0 | Drop or activate the SeatData pipeline |
| `seatdata_event_stats`, `seatdata_event_xref`, `seatdata_performer_xref`, `seatdata_venue_xref`, `seatdata_section_xref`, `seatdata_zone_xref`, `seatdata_pull_log`, `seatdata_pull_budget`, `seatdata_sales_snapshots` | 0 | Same call — entire SeatData integration is dormant |
| `leads` | 0 | Sales/CRM table? Probably should not be in this DB |
| `canonical_external_ids` | 0 | Designed but unused |
| `seatgeek_order_tickets` | 0 | Order-detail expansion never populated |
| `tevo_ticket_groups_cache` | 0 | Cache hasn't warmed |
| `event_pulls` | 1 | Abandoned pattern? |
| `tournament_categories` | 7 | Undersized seed |
| `taxonomy_xref` | 12 | Mostly stub |

### 8. Schema docs gap 🟢 **low** (good housekeeping)

**92 tables have no `COMMENT ON TABLE`**. Includes core tables: `events`, `listings_snapshots`, `weather_observations`, `venue_assets`, `espn_*`, `seatgeek_*`, `holidays`, `school_break_windows`, `sporting_rivalries`, all the `nws_*` tables, etc.

The views we shipped in Phase 1 *do* have comments. Tables don't.

**Fix path**: in a maintenance migration, add `COMMENT ON TABLE x IS '...';` for every active table. ~2 hours of work; pays back forever in onboarding.

---

## Healthy data sources (no action needed)

| Source | Last update | Volume | Status |
|---|---|---|---|
| TEvo `events` | continuous | 3,337 events | ✅ |
| TEvo `listings_snapshots` | <5 min ago | 8.79M rows | ✅ flowing (but coverage gap above) |
| Open-Meteo `weather_observations` | <5 min ago | 153,024 obs+forecasts | ✅ |
| NWS `nws_alerts` | <8 min ago | 109 active | ✅ (newly added Phase 1) |
| ESPN `espn_injuries_snapshots` | <3 min ago | 4,494 rows / 5 leagues | ✅ |
| ESPN `espn_event_snapshots` | <3 min ago | 791 rows | ✅ |
| Reddit `reddit_posts` | <5 min ago | 2,202 posts / 85 subs | ✅ |
| Wikipedia `performer_wikipedia` | rolling | 340 perfs (100% active coverage) | ✅ |

Reference data hand-seeded (no API; bump as needed):
- `holidays` (98), `school_break_windows` (35), `sporting_rivalries` (67), `important_x_accounts`, `performer_subreddits` (157), `mlb_branded_series`

---

## Proposed Phase 2 priorities (in order)

### Tier A — coverage unblocks (do these first)

1. **Backfill `event_type`** for the 1,845 NULL upcoming events. Investigate the TEvo classification pipeline and either re-run on existing rows or add a backfill function. This unblocks all event-type-filtered views.
2. **Expand `venue_assets`** to cover Broadway + concert venues. Either auto-insert from new events seen in `crawl-venues-and-performers`, or hand-seed top-50 concert + 40 Broadway venues. Trigger NWS UGC + geocode backfill chain after.
3. **Investigate listings pull coverage** in `collect-listings` edge function. Why only 46% in 0-24h tier? Likely batch size + throttle.

### Tier B — quality / cleanup

4. **Audit ESPN xref matcher**. Go from 35.5% → 70%+ for upcoming games.
5. **Decide on SeatData**. Either re-activate the pipeline (new credentials? revisit business value?) or drop the empty tables.
6. **`espn_athletes` daily refresh** — 3 days stale. Check cron logs.

### Tier C — maintenance

7. **Add `COMMENT ON TABLE`** for the 92 undocumented core tables.
8. **Prune `performer_metadata`** of inactive entries (or accept the 80% noise rate).
9. **Drop dormant tables** (`leads`, `canonical_external_ids`, etc.) if confirmed unused.

### Tier D — only if Phase 1 user comes back asking

10. **Spotify** (#3) — once dev app registered. Plan in conversation transcript; lean popularity-only fetch parallel to NWS pattern.
11. **Player roster expansion** — to enable surface-level player names in injury overlay. ESPN `/teams/{id}/athletes/full-roster` endpoint exists.

---

## Source catalog reference (for new context dimensions)

Catalogued in `data_sources` table (8 entries). Each has a clear pattern:
- `auth_method`: `public`, `api_key_header`, `token_qs`, `hmac_sha256`
- `kind`: `pricing`, `enrichment`
- `read_only`: all true (RULE 2 enforcement)

`data_sources` row missing for: NWS, Reddit, holidays_seed, school_breaks_seed, sporting_rivalries_seed, OSM (geocode partial coverage). Update the catalog.

---

## How the new Phase 1 surfaces are used

`get_event_context(event_id)` returns one big jsonb. Pull selectively:

```sql
-- The whole context for one event
SELECT jsonb_pretty(get_event_context(3092714));

-- Just one dimension
SELECT get_event_context(3092714) -> 'injuries' AS injuries;
SELECT get_event_context(3092714) -> 'weather_alerts' AS alerts;
SELECT get_event_context(3092714) -> 'calendar' AS cal;

-- Summary across all upcoming games (slow but works)
SELECT
  e.id, e.name,
  jsonb_array_length(get_event_context(e.id) -> 'weather_alerts') AS n_alerts,
  (get_event_context(e.id) -> 'injuries' ->> 'total')::int       AS n_injuries
FROM events e
WHERE e.occurs_at_local::timestamptz > now()
  AND e.event_type = 'game'
ORDER BY e.occurs_at_local
LIMIT 20;
```

Direct view access (faster than calling `get_event_context()` if you only need one dimension):
- `v_event_calendar_context` — holidays + school breaks (state/city aware)
- `v_event_active_weather_alerts` — NWS alerts joined to event venues
- `v_event_local_signals` — composite calendar + weather + rivalry + pricing per event
- `v_event_injuries` — ESPN injuries split by side (home/away) + impact tier
- `v_upcoming_rivalry_games` — calendar of upcoming rivalry games with pricing-at-a-glance
- `v_event_weather_with_fallback` — forecast → climatology fallback + alerts overlay

---

## Open invariants Phase 2 should not break

1. **RULE 2 (read-only)**: every external pull is read-only. `coworker_readonly` role enforces it at the DB level. Don't add a `write` integration without explicit user sign-off.
2. **`get_event_context()` is the single entry point** for cross-source context. Add a key, not a new function.
3. **Idempotent upserts everywhere**. New persisting code should respect `ON CONFLICT DO UPDATE` patterns.
4. **No StubHub-affiliated tools**. Per directive 2026-05-09: "Fanvenues got bought by StubHub so no go there." Same applies to anything in their orbit.
5. **Events / performers / venues from TEvo are canonical**. Other sources xref into these; never rename or re-key.

---

## Files added in Phase 1 (reference)

```
supabase/migrations/20260509540000_holiday_school_calendar.sql              (#1)
supabase/migrations/20260509550000_holiday_school_calendar_localized.sql    (#1.5)
supabase/migrations/20260509560000_nws_active_weather_alerts.sql            (#2)
supabase/migrations/20260510000000_event_injuries_overlay.sql               (#6)
docs/coworker-handoff/QUERY_CATALOG.md                                      (updated)
docs/interactive-venue-maps-options.md                                      (revised — Fanvenues dropped)
```

`phase1-baseline = ba97203` is the snapshot to branch Phase 2 from.
