# Evo Terminal v2 — Listings-based pipeline with charts

Parallel pipeline. Does not touch the existing `collect` edge function or the
`snapshots` table. Adds raw listings capture + our own metrics + event history
chart.

## Files

| File | Where it goes | What it does |
|---|---|---|
| `20260424000000_listings_v2.sql` | Supabase SQL editor | Schema for new tables, views, retention sweeper; seeds playoff watchlist; removes Yankees |
| `edge_function_collect_listings.ts` | `supabase/functions/collect-listings/index.ts` | New edge function — pulls listings, writes raw + computed metrics |
| `cron_v2.sql` | Supabase SQL editor (AFTER manual test passes) | 5-tier schedule + nightly sweep |
| `app_py_patch.py` | Paste into `app.py` | Adds `/api/events/{id}/series` and `/sections/series` endpoints |
| `frontend_patch.html` | Reference — paste into `static/index.html` | Adds Chart.js + history panel to event detail |

## Sequence

### 1. Apply the schema migration

Supabase Dashboard → SQL Editor → paste `20260424000000_listings_v2.sql` → Run.

Creates: `listings_snapshots`, `event_metrics`, `section_metrics`, `event_series` view, `sweep_old_listings()` function. Seeds 7 playoff round performers. Removes Yankees row.

Verify:
```sql
select * from watchlist;
-- Should show 7 NBA playoff rounds, no Yankees
```

### 2. Deploy the new edge function

```powershell
cd C:\Users\jgrebe\Desktop\Terminal\1.0

# Create the folder for it (parallel to existing collect/)
mkdir supabase\functions\collect-listings

# Paste the TS into supabase/functions/collect-listings/index.ts
notepad supabase\functions\collect-listings\index.ts

# Deploy
supabase functions deploy collect-listings --no-verify-jwt
```

### 3. Manual test — one watchlist row, no window filter

Pick one playoff round, note its `id`:
```sql
select id, label from watchlist order by id;
```

Invoke:
```powershell
curl.exe -X POST "https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?watchlist_id=1" `
  -H "X-Cron-Secret: pick-any-random-string-and-save-it" `
  -H "Content-Type: application/json" -d "{}"
```

Expected: JSON with `events_collected > 0`, `listing_rows_written: <big number>`, `errors: 0`. May take 60-120s depending on round activity.

Verify data:
```sql
select count(*) from listings_snapshots;        -- should be thousands
select count(*) from event_metrics;             -- should equal events_collected
select count(*) from section_metrics;           -- should be much larger

-- Sample one event's metrics
select event_id, captured_at, tickets_count, retail_min, retail_median, retail_max, getin_price
from event_metrics order by captured_at desc limit 5;

-- Check the ancillary flagging worked
select count(*) filter (where is_ancillary) as ancillary_rows,
       count(*) filter (where not is_ancillary) as seat_rows
from listings_snapshots;
```

### 4. Cross-check against TEvo stats (sanity)

For one event, compare our computed `event_metrics` row with what TEvo's `/v9/events/:id/stats` reports (accessible via the `snapshots` table if the old `collect` ran, or by firing it manually).

Expect close matches on tickets_count, retail_min, retail_max, retail_sum. Our median/mean may differ slightly (ours are quantity-weighted; TEvo's may be group-weighted). That's expected and actually preferable — ours is more meaningful for trading.

### 5. Update the FastAPI app

Paste `app_py_patch.py`'s two endpoints into `app.py`. Then:
```powershell
railway up
```

Verify:
```powershell
curl "https://glorious-appreciation-production-a6ce.up.railway.app/api/events/<some_event_id>/series?days=7"
```

Should return `{"event_id": ..., "series": [...]}` with whatever snapshots exist.

### 6. Add the history chart to the frontend

In `static/index.html`:

**Add to `<head>`** (after the supabase-js script):
```html
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
```

**At the end of `renderEventDetail()`**, change this:
```js
    </div>`;
}
```

To this:
```js
    </div>
    ${HISTORY_PANEL_HTML}`;
  initHistoryPanelHandlers(ev.id);
}
```

And paste the full new-function block (`_historyChart`, `METRIC_OPTIONS`, `loadHistoryChart`, `HISTORY_PANEL_HTML`, `initHistoryPanelHandlers`, `formatMetricValue`) from `frontend_patch.html` into the main `<script>` block.

```powershell
railway up
```

Hard-refresh, click a playoff event, scroll down — you should see a "history" panel with an empty chart that says "no data yet" until the first collect run completes.

### 7. Schedule it

**Only after the manual test in step 3 succeeded cleanly**, apply `cron_v2.sql`:

1. Substitute `<PROJECT_REF>` with `hzrizjeaxlqcxfrtczpq`
2. Substitute `<CRON_SECRET>` with `pick-any-random-string-and-save-it`
3. Dashboard → SQL Editor → paste → Run

Check:
```sql
select jobname, schedule, active from cron.job order by jobname;
```

Should list 5 `collect-listings-*` jobs + `sweep-old-listings`.

### 8. Watch it run

```sql
-- Runs log
select id, started_at, finished_at, events_collected, stats_errors
from runs order by id desc limit 10;

-- Storage growth
select
  pg_size_pretty(pg_total_relation_size('listings_snapshots')) as listings_size,
  pg_size_pretty(pg_total_relation_size('event_metrics')) as metrics_size,
  pg_size_pretty(pg_total_relation_size('section_metrics')) as sections_size,
  count(*) as listings_rows from listings_snapshots;
```

After the next scheduled run hits the 0-24h window, refresh an event detail page — the chart should populate.

## Rollback

If anything goes sideways, the pipelines are isolated:

```sql
-- Unschedule the v2 cron jobs
select cron.unschedule(jobname) from cron.job where jobname like 'collect-listings-%' or jobname = 'sweep-old-listings';
```

The existing `collect` function + `snapshots` table keep running untouched.

To fully remove v2:
```sql
drop table listings_snapshots;
drop table event_metrics;
drop table section_metrics;
drop function sweep_old_listings;
drop view event_series;
```

And unlink / delete the `collect-listings` edge function from the Supabase dashboard.

## Metrics reference — what the chart lets you select

| Metric | Meaning | Unit |
|---|---|---|
| `retail_median` | Middle retail price, quantity-weighted | $ |
| `retail_mean` | Average retail price, quantity-weighted | $ |
| `getin_price` | Cheapest pair of seats available | $ |
| `retail_min/p25/p75/p90/max` | Distribution percentiles | $ |
| `wholesale_median/mean` | Broker-side (what you pay) | $ |
| `tickets_count` | Total seats available (non-ancillary) | count |
| `groups_count` | Distinct ticket listings | count |
| `sections_count` | Distinct sections with inventory | count |
| `top5_concentration` | % of tickets in most-stocked 5 sections | 0-1 |
| `bid_ask_proxy` | (retail_p25 - wholesale_p25) / retail_p25 | 0-1 |

Later (phase 2): derived metrics — price velocity (Δ/time), volatility, dispersion across a performer's slate, sell-through rate, listing churn.

## TEvo-specific notes

- `/v9/listings` returns up to 100 groups per page; we paginate up to 20 pages (2000 groups)
- Ancillary detection: section names matching `/parking|garage|lot|vip lounge|hospitality|premium lounge|club lounge/i`. Flagged in `listings_snapshots.is_ancillary`, excluded from seat price metrics.
- Playoff conditional games disappear from TEvo when unnecessary. Our collector handles this gracefully — event drops out of future `searchEvents` responses, we just stop snapshotting it. Existing snapshots stay in the DB as a historical record.
- Data retention: raw listings 60 days, computed metrics forever.
