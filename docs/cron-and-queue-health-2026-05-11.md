# Cron schedule + queue health audit — 2026-05-11

Produced by C1 (Data + Chat Bot, supervisor). Companion to `docs/data-sources-audit-2026-05-11.md` (corrected) and `docs/cross-source-entity-resolution-2026-05-11.md`. Branch: `claude/audit-data-sources-b7EGu`.

## Headline

| metric | value |
|---|---|
| Total distinct `cron.schedule` jobs | **83** |
| Distinct pg_net async pipelines | **~15** |
| `*_pending` queue tables surveyed | **16** |
| Queues with 0 unresolved work | **14** |
| Queues with backlog | **2** |
| **Real bug found** | NWS alert pipeline loses items to pg_net retention TTL |

## 1. Cron schedule inventory

83 distinct cron jobs grouped by domain (counts approximate; some jobs are tier-specific):

### TEvo inventory
- `collect-listings-{0-24h, 1-7d, 7-30d, 30-60d}` — 5-tier cadence (20m / 1h / 4h / 12h / daily)
- `evo_orders_{queue, process}_{10min, 30min}` — 4 jobs
- `sweep_tevo_ticket_groups_cache` — 1 job

### ESPN
- `espn-{gameday, roster}-10min`, `espn-team-daily` — 3 jobs
- `espn_scoreboard_{queue_4h, process_5min}` — 2 jobs
- `espn_tournament_{queue_weekly, process_5min, process_after_queue}` — 3 jobs
- `crawl-espn-team-assets-3min`, `match_events_to_espn_10min`, `match_tournaments_daily` — 3 jobs

### SeatGeek
- `sg_listings_{0-24h, 1-7d, 7-30d, 30-60d}` + `sg_listings_process_5min` — 5 jobs
- `sg_seller_{listings_queue_30min, orders_queue_30min, process_30min}` — 3 jobs
- `sg_sales_{queue_daily, process_daily}`, `seatgeek_historic_sales_daily` — 3 jobs
- `sg_canonical_auto_match_30min`, `cross_source_match_tick_30min` — 2 jobs
- `orphan_event_backfill_{queue_15min, process_15min}`, `orphan_backfill_sweep_daily` — 3 jobs

### Weather / NOAA / OSM
- `weather_forecast_{queue_30min, process_30min}`, `weather_climatology_weekly` — 3 jobs
- `venue_geocode_{queue_5min, process_5min}` — 2 jobs (Nominatim)
- `nws_alerts_{queue_10min, queue_30min, process_5min, process_aligned}` — 4 jobs
- `nws_points_{queue_daily, process_5min, process_after_queue}` — 3 jobs

### Wikipedia
- `performer_wiki_{queue_searches_5min, process_searches_5min, process_summaries_5min}` — 3 jobs
- `wiki_pageviews_{queue_daily, process_daily}` — 2 jobs
- `wiki_pending_sweep_daily` — 1 job

### Reddit / FRED
- `reddit_{queue_30min, process_30min, pending_sweep_daily}` — 3 jobs
- `fred_{queue_daily, process_5min}` — 2 jobs

### Compute / dashboards / xref
- `backfill-zone-metrics-10min`, `backfill-event-configurations-5min` — 2 jobs
- `compute-event-{nonowned, splits}-30min`, `compute_alerts_tick_15min` — 3 jobs
- `event_competitors_refresh_hourly`, `auto-link-event-xref-15min`, `zone-backfill-isolated-10min` — 3 jobs
- `dashboard_writes_24h_refresh_60s` — 1 job
- `auto_ack_stale_alerts_30min`, `ensure-watchlist-coverage-daily` — 2 jobs

### Master / housekeeping
- `master-cascade-2min`, `midnight-catchup-sweep` — 2 jobs
- `crawl-venues-and-performers-3min` — 1 job
- `sweep-bot-messages` — 1 job

### Venue / tournament discovery
- `venue_pull_{queue_weekly, process_weekly}` — 2 jobs
- `tournament_pull_{queue_weekly, process_weekly}`, `tournament_search_{queue_weekly, process_weekly, pending_sweep_weekly}` — 5 jobs

## 2. pg_net async pipeline pattern

22 migrations use `net.http_get`/`net.http_post`. The dominant pattern across ~15 distinct pipelines:

```
1. *_pending table  ← stores (request_id, fired_at, resolved_at, http_status, error, ...)
2. queue function   ← inserts into _pending, calls net.http_get, stores request_id
3. process function ← JOIN _pending p ON net._http_response h WHERE p.resolved_at IS NULL
4. sweep function   ← deletes resolved rows older than X days
5. 3 crons schedule it: queue every Nmin, process Nmin+1 offset, sweep daily
```

**Used by:** weather forecasts, venue geocoding, NOAA alerts, NOAA points, FRED indicators, Reddit RSS, Wikipedia (search + summary + pageviews), evo_orders, evo_event_backfill, ESPN scoreboard, ESPN tournaments, SG seller listings, SG seller orders, SG listings tiers, SG sales, SG orphan event backfill, venue_pull discovery, tournament_search discovery.

**Strengths:**
- Decouples API rate-limit pacing from DB transaction time
- Idempotent retries via `ON CONFLICT (request_id) DO UPDATE`
- Audit trail in `_pending` after `resolved_at` is set

**Failure mode discovered (see Section 4):** if a queued request isn't processed before pg_net GCs the response, the row becomes permanently stuck because the JOIN to `net._http_response` returns empty.

## 3. Queue health audit (live data, 2026-05-11)

| queue | unresolved | status |
|---|---|---|
| `espn_scoreboard_pending` | 0 | clean |
| `espn_tournament_pending` | 0 | clean |
| `evo_orders_pending` | 0 | clean |
| `evo_event_backfill_pending` | 0 | clean |
| `performer_wiki_pending` | 0 | clean |
| `reddit_pending` | 0 | clean |
| `weather_forecast_pending` | 0 | clean |
| `venue_geocode_pending` | 0 | clean |
| `venue_nws_points_pending` | 0 | clean |
| `sg_event_backfill_pending` | 0 | clean |
| `sg_listings_pending` | 0 | clean |
| `tournament_category_pending` | 0 | clean |
| `tournament_search_pending` | 0 | clean |
| **`nws_alert_pending`** | **94** | **STUCK — pg_net responses GC'd** |
| `sg_seller_pending` | 11 | partial — newest is from today (likely in-flight) |

(`fred_pending`, `sg_sales_pending`, `performer_wiki_pageviews_pending` referenced in migrations but don't exist as tables in current schema — naming variations or were renamed.)

## 4. Real bug: NWS alert queue loses items to pg_net retention

### Symptom
- 94 rows in `nws_alert_pending` with `resolved_at IS NULL`
- All 94 have `http_status`, `alerts_count`, `error` all NULL — process never touched them
- Oldest queued 2026-05-10 02:20 UTC (28+ hours ago); newest 07:00 UTC today
- 92 of 94 are over 1 day stale

### Root cause
The process function (`nws_alerts_process`, line 411 of `20260509560000_nws_active_weather_alerts.sql`) does:

```sql
FOR r IN
  SELECT p.id AS pending_id, p.state_code, h.content, h.status_code
  FROM nws_alert_pending p
  JOIN net._http_response h ON h.id = p.request_id
  WHERE p.resolved_at IS NULL
LOOP ...
```

The `JOIN` to `net._http_response` is the failure point. Supabase pg_net retains http responses for ~6 hours by default; older responses are pruned. If `nws_alerts_process_5min` doesn't fire successfully within that window (or hits an error that skips a row), the pending row's `request_id` becomes dangling and the JOIN returns no rows for it — **forever**.

Live verification: `JOIN net._http_response ON h.id = p.request_id` against the 94 unresolved rows returns **0 matches**. The responses are gone.

### Why the items pile up at specific times
The 94 stuck rows cluster around midnight, 3 AM, and queue boundary moments — likely overlap windows where the queue function fires faster than the process function drains. The NWS pipeline has 4 crons (10min + 30min queue, 5min + aligned process), which can interleave and contention can push individual responses past the pg_net TTL.

### Comparison with sg_seller_pending (11 unresolved)
Same root cause likely, but smaller scale and recent items (newest 2026-05-11 17:02 UTC) are probably still in-flight, not permanently stuck. Worth re-checking in 24 hours to distinguish.

### Fix proposal (no implementation yet — per pause directive)

Two-pronged:

1. **Sweep stuck rows**: extend `nws_alert_pending` (and other `*_pending` tables using the same pattern) with a periodic sweep that marks rows as terminal failures when:
   - `resolved_at IS NULL`
   - AND `fired_at < now() - interval '12 hours'`
   - AND no matching row in `net._http_response`
   
   Set `resolved_at = now()`, `error = 'pg_net response expired before processing'`. This stops the count from growing indefinitely.

2. **Reduce overlap risk**: align the 4 NWS crons to non-conflicting offsets. Current `nws_alerts_queue_10min` + `nws_alerts_queue_30min` both fire at minute 0, then process at minute 5. Consolidate to a single queue or stagger explicitly.

Migration sketch (not applied):
```sql
CREATE OR REPLACE FUNCTION sweep_expired_pg_net_pending(p_table regclass, p_ttl_hours int DEFAULT 12)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int;
BEGIN
  EXECUTE format($f$
    WITH expired AS (
      SELECT p.id FROM %s p
      LEFT JOIN net._http_response h ON h.id = p.request_id
      WHERE p.resolved_at IS NULL
        AND p.fired_at < now() - interval '%s hours'
        AND h.id IS NULL
    )
    UPDATE %s SET resolved_at = now(), error = 'pg_net response expired'
    WHERE id IN (SELECT id FROM expired)
  $f$, p_table, p_ttl_hours, p_table);
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
```

Schedule per affected pipeline:
```sql
SELECT cron.schedule('nws_alert_expired_sweep_hourly', '17 * * * *',
  $$ SELECT sweep_expired_pg_net_pending('nws_alert_pending'::regclass, 12); $$);
```

## 5. What surprised me (notes for the next bot)

- **The data plane has more orchestration than my first audit credited.** 83 cron jobs, ~15 pg_net pipelines, 14/16 queues running clean. The system is in much healthier shape than "X dormant edge functions, Y under-pulled sources" suggested.
- **Edge functions are the minority pattern.** Most ingest happens via SQL functions + pg_net + cron. The "dormant edge functions" from the first audit were mostly intentional admin tools or duplicates of SQL pipelines.
- **The real failure modes are at the seams** — pg_net response TTL, cron overlap windows, JOIN-vs-no-row patterns where you assume the response exists. The NWS stuck-row bug is a class, not a one-off — every pg_net `*_pending` table is at risk and `sg_seller_pending` may be next.

## Handoff

| owner | action |
|---|---|
| **C1** (in-lane) | This doc. No further audit work needed for the cron + queue layer. |
| **A1** (push) | Land the `sweep_expired_pg_net_pending()` function + per-pipeline cron schedules. Single migration applies to all `*_pending` tables. |
| **B1** (audit views) | Drift signal: monitor `*_pending` unresolved counts as a recurring health view. Recommend a `v_pg_net_queue_health` aggregating across all 16 queues with thresholds (warning > 25, critical > 100). |
