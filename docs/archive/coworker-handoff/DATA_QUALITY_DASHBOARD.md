# DATA_QUALITY_DASHBOARD — first kanban card

This is your first build. Goal: a UI that answers, at a glance,
"is the data plane healthy today?" — and surfaces any silent
failure within the cycle (not weeks later, when the audit catches
it manually).

---

## Why this card first

Every silent failure I've caught manually so far cost something:
- SeatData pull pipeline missing for weeks → no historical comps
- `sg_listings_process` cron failing 49% → 10K listings backlogged
- SG API not returning `payment_total` → all orders showing $0 gross
- MSG weather pull stuck on a 429 → no forecast for the Knicks game

A dashboard catches these the day they happen. Audit time goes from
"I'll get to it next week" to "the banner is red, check it now."

---

## What the dashboard shows

A single page with these signals, top-to-bottom:

### 1. Headline — overall data plane health (0–100%)

A computed score combining all check buckets. Three states with color:
- **Green** ≥ 95
- **Yellow** 80–94
- **Red** < 80

Display: big number + status word + last-refreshed timestamp.

### 2. Pull pipeline freshness (per source)

For each source, when did the most recent data land?

| Source | Expected freshness | Query basis |
|---|---|---|
| TEvo listings | <30 min | `max(captured_at)` from `listings_snapshots` for upcoming events |
| SeatGeek listings | <30 min | `max(captured_at)` from `seatgeek_listings_snapshots` |
| EVO orders | <1h | `max(pulled_at)` from `evo_orders` |
| SG seller orders | <1h | `max(pulled_at)` from `seatgeek_orders` |
| ESPN snapshots | <10 min (game-day) / <24h (off-day) | `max(captured_at)` from `espn_event_snapshots` |
| Wikipedia enrichment | <24h | `max(last_refreshed_at)` from `performer_wikipedia` |
| Weather forecast | <60 min | `max(observed_at)` from `weather_observations` where `is_forecast` |
| Reddit RSS | <60 min | `max(pulled_at)` from `reddit_posts` |

Show each as a row with: source, last update, age, status (green/yellow/red).

### 3. Cron health (last 24h)

Top-level: "47/48 crons ran cleanly in the last 24h" with drill-down
table for any failing crons.

> **Note:** `coworker_readonly` does NOT have access to `cron.*`.
> The audit lane will create a `v_cron_health` view in `public`
> exposing per-cron stats. Open an issue in `Terminal-2` when you're
> ready for it; provided shape will be:
> `(jobname text, runs_24h int, ok_24h int, fail_24h int, pct_ok numeric, latest_run timestamptz, latest_error text)`

### 4. Pending queue depths

Each pull pipeline has a `*_pending` queue. Stale unresolved rows mean
something's stuck. Show counts:

```sql
SELECT 'evo_orders_pending'         AS queue, count(*) FILTER (WHERE resolved_at IS NULL) AS stuck FROM evo_orders_pending
UNION ALL SELECT 'sg_listings_pending',     count(*) FILTER (WHERE resolved_at IS NULL) FROM sg_listings_pending
UNION ALL SELECT 'sg_seller_pending',       count(*) FILTER (WHERE resolved_at IS NULL) FROM sg_seller_pending
UNION ALL SELECT 'weather_forecast_pending',count(*) FILTER (WHERE resolved_at IS NULL) FROM weather_forecast_pending
UNION ALL SELECT 'performer_wiki_pending',  count(*) FILTER (WHERE resolved_at IS NULL) FROM performer_wiki_pending
UNION ALL SELECT 'reddit_pending',          count(*) FILTER (WHERE resolved_at IS NULL) FROM reddit_pending
UNION ALL SELECT 'evo_event_backfill_pending', count(*) FILTER (WHERE resolved_at IS NULL) FROM evo_event_backfill_pending
UNION ALL SELECT 'sg_event_backfill_pending',  count(*) FILTER (WHERE resolved_at IS NULL) FROM sg_event_backfill_pending;
```

Threshold: any queue >50 unresolved is yellow; >200 is red. (Tune
after a week of observation.)

### 5. Cross-source coverage scoreboard

For upcoming sports events in the next 30 days:
- % with TEvo listings <60min old
- % with ESPN xref'd
- % with Wikipedia enrichment
- % with weather observation (events ≤16d only)
- % of SG-canonical events with `tevo_event_id` mapped (currently low; see below)

Use these as drift detectors. Sudden drop in % = something broke.

### 6. Open alerts (5 newest)

Pull from `v_open_alerts` ordered by severity desc, fired_at desc.
Show event name, rule, message, fired-at-relative-time.

### 7. Today's writes

Number of new rows in last 24h per major table:
`listings_snapshots`, `seatgeek_listings_snapshots`, `evo_orders`,
`seatgeek_orders`, `espn_event_snapshots`, `reddit_posts`,
`weather_observations`. If any of these are 0, that source is silent.

---

## Specific queries you'll need

The QUERY_COOKBOOK has the patterns. Here's the freshness check
one explicitly:

```sql
SELECT
  'tevo_listings' AS source,
  max(captured_at) AS latest,
  EXTRACT(epoch FROM now() - max(captured_at))/60 AS age_minutes
FROM listings_snapshots
UNION ALL
SELECT 'seatgeek_listings', max(captured_at), EXTRACT(epoch FROM now() - max(captured_at))/60
FROM seatgeek_listings_snapshots
UNION ALL
SELECT 'evo_orders', max(pulled_at), EXTRACT(epoch FROM now() - max(pulled_at))/60
FROM evo_orders
UNION ALL
SELECT 'sg_orders', max(pulled_at), EXTRACT(epoch FROM now() - max(pulled_at))/60
FROM seatgeek_orders
UNION ALL
SELECT 'espn_snapshots', max(captured_at), EXTRACT(epoch FROM now() - max(captured_at))/60
FROM espn_event_snapshots
UNION ALL
SELECT 'wikipedia', max(last_refreshed_at), EXTRACT(epoch FROM now() - max(last_refreshed_at))/60
FROM performer_wikipedia
UNION ALL
SELECT 'weather_forecast', max(observed_at), EXTRACT(epoch FROM now() - max(observed_at))/60
FROM weather_observations WHERE is_forecast
UNION ALL
SELECT 'reddit', max(pulled_at), EXTRACT(epoch FROM now() - max(pulled_at))/60
FROM reddit_posts
ORDER BY age_minutes DESC NULLS LAST;
```

---

## Stack-agnostic shape

Whatever framework you pick, the dashboard wants:
- A backend route or direct DB call returning a single jsonb / json blob
  with all the numbers (~50 KB max)
- A 60-second auto-refresh on the page (or websocket if you go that way)
- Mobile-readable layout (Julian checks this on phone during games)
- One-click drill-down on any red row → full table of that signal's
  history

You can either:
- Call Terminal-2's `/api/*` and add a new route (open issue), or
- Connect directly to Supabase via `coworker_readonly` and run queries
  client-side (faster iteration, no backend coordination)

For the prototype, **direct Supabase via supabase-js / postgrest** is
probably easiest. We can add a backend route later if performance
demands it.

---

## Done criteria

1. The page renders all 7 sections from real live data
2. All thresholds (fresh/yellow/red) are documented inline so they can
   be tuned without code changes (config object at top of file)
3. Mobile + desktop both work
4. Auto-refresh works
5. PR is in `Terminal-2-ui` with a screenshot in the description
6. Audit lane reviews + merges
