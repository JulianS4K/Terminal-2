# QUERY_COOKBOOK — ready-to-paste SQL for common UI needs

Every query here is `coworker_readonly`-safe (SELECT-only, no `net.http_*`
calls). Designed for Supabase MCP or psql; copy + adjust.

If a query you need isn't here, prototype in `design_test.*` and the
audit lane can promote it to a public view if it's reusable.

---

## Quick orientation

```sql
-- How big is everything?
SELECT
  (SELECT count(*) FROM events)                     AS events,
  (SELECT count(*) FROM events WHERE occurs_at_local::timestamptz BETWEEN now() AND now() + interval '60 days') AS upcoming_60d,
  (SELECT count(*) FROM listings_snapshots)         AS tevo_listings_total,
  (SELECT count(*) FROM listings_snapshots WHERE captured_at > now() - interval '24 hours') AS tevo_listings_24h,
  (SELECT count(*) FROM seatgeek_listings_snapshots) AS sg_listings_total,
  (SELECT count(*) FROM evo_orders)                  AS evo_orders,
  (SELECT count(*) FROM seatgeek_orders)             AS sg_orders,
  (SELECT count(*) FROM v_open_alerts)               AS open_alerts,
  (SELECT count(*) FROM cron.job WHERE active)       AS active_crons;
```

---

## Single-event AI/RAG bundle

```sql
-- Returns everything we know about an event in one JSON.
-- Pass any tevo_event_id from the events table.
SELECT jsonb_pretty(get_event_context(3345925));
```

Top-level keys: `event`, `pricing`, `espn`, `odds`, `performer`,
`weather`, `competitors`, `reddit`, `important_news`, `x_accounts_known`,
`our_orders`, `generated_at`.

---

## Upcoming events for the home page

```sql
SELECT
  e.id, e.name, e.occurs_at_local, e.venue_name,
  e.primary_performer_name, e.event_type,
  -- Are there fresh listings?
  EXISTS(SELECT 1 FROM listings_snapshots ls
         WHERE ls.event_id = e.id
           AND ls.captured_at > now() - interval '60 minutes') AS has_fresh_listings,
  -- Get-in price right now
  (SELECT min(retail_price) FROM listings_snapshots ls
    WHERE ls.event_id = e.id
      AND ls.captured_at = (SELECT max(captured_at) FROM listings_snapshots
                            WHERE event_id = e.id)) AS getin_now
FROM events e
WHERE e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '14 days'
ORDER BY e.occurs_at_local::timestamptz
LIMIT 50;
```

---

## Today's open alerts (for dashboards)

```sql
SELECT id, severity, rule_key, fired_at,
       tevo_event_id, event_name, occurs_at_local, message
FROM v_open_alerts
ORDER BY
  CASE severity WHEN 'critical' THEN 0 WHEN 'warn' THEN 1 ELSE 2 END,
  fired_at DESC
LIMIT 50;
```

---

## Pricing — section-level cross-source view

```sql
-- TEvo vs SG vs SG-seller vs SD pricing per section, per event.
SELECT *
FROM v_pricing_cross_source
WHERE tevo_event_id = 3344959  -- Thunder @ Lakers G3
ORDER BY section;
```

---

## Velocity — what's moving in the last hour / day

```sql
SELECT
  tevo_event_id, name, venue_name,
  tevo_getin_now, tevo_getin_d1h, tevo_getin_d1h_pct,
  tevo_getin_d24h, tevo_getin_d24h_pct,
  tevo_tix_now, tevo_tix_d1h, tevo_tix_d24h
FROM v_event_velocity_windows
WHERE tevo_getin_d1h_pct IS NOT NULL
ORDER BY abs(tevo_getin_d1h_pct) DESC
LIMIT 25;
```

---

## Our orders + portfolio rollup

```sql
-- Per-event book: gross + net of fees
SELECT * FROM our_orders_by_event_with_net
WHERE tevo_event_id = 3345925;

-- Every line item across TEvo + SG
SELECT source, source_order_id, canonical_status,
       gross_amount, net_amount, source_created_at
FROM our_orders_with_net
WHERE source_created_at > now() - interval '7 days'
ORDER BY source_created_at DESC;

-- SG-only sales detail per section/row
SELECT * FROM v_sg_sales_by_section
WHERE tevo_event_id = 3345925;
```

---

## Reddit — what's getting flagged as important news

```sql
-- Posts in last 48h matching news keywords (injury/trade/IL/etc.)
SELECT subreddit, title, author, created_utc,
       keyword_match->'hits' AS keywords,
       (keyword_match->>'total_weight')::numeric AS weight,
       url
FROM v_reddit_important_recent
ORDER BY weight DESC, created_utc DESC
LIMIT 25;

-- Activity per performer (post counts)
SELECT * FROM v_performer_reddit_pulse
WHERE posts_24h > 0
ORDER BY posts_24h DESC;
```

---

## Competing events for any event in our catalog

```sql
SELECT competitors_count, competitors
FROM event_competitors_snapshot
WHERE tevo_event_id = 3345925;
```

`competitors` is a jsonb array of `{tevo_event_id, name, venue_name,
distance_mi, hours_offset}`.

---

## Weather (works for indoor + outdoor, see mig 400000)

```sql
SELECT
  tevo_event_id, event_name, venue_name, days_to_event,
  weather_kind,    -- 'forecast_indoor' | 'forecast_outdoor' | etc.
  is_indoor,
  fcst_temp_f, fcst_precip_pct, fcst_wind_mph, fcst_summary
FROM v_event_weather_with_fallback
WHERE tevo_event_id = 3345925;
```

---

## ESPN game state + betting odds

```sql
-- Latest ESPN state for any sports event
SELECT
  x.tevo_event_id, x.espn_event_id,
  ee.captured_at, ee.state, ee.status_short,
  ee.home_score, ee.away_score, ee.spread, ee.over_under,
  ee.home_ml, ee.away_ml, ee.home_win_prob
FROM event_xref x
JOIN LATERAL (
  SELECT * FROM espn_event_snapshots
  WHERE espn_event_id = x.espn_event_id
  ORDER BY captured_at DESC LIMIT 1
) ee ON true
WHERE x.tevo_event_id = 3346855;

-- Line movement (1h / 24h)
SELECT * FROM v_event_line_movement
WHERE tevo_event_id = 3346855;
```

---

## Coverage scoreboard — which events have which sources

```sql
-- For any event, which sources have data?
WITH e AS (SELECT 3345925::bigint AS eid)
SELECT
  (SELECT count(*) FROM listings_snapshots WHERE event_id = e.eid)            AS tevo_listings,
  (SELECT count(*) FROM event_metrics WHERE event_id = e.eid)                  AS tevo_metric_rows,
  (SELECT count(*) FROM seatgeek_listings_snapshots WHERE tevo_event_id=e.eid) AS sg_listings,
  (SELECT count(*) FROM seatgeek_orders WHERE tevo_event_id = e.eid)           AS sg_orders,
  (SELECT count(*) FROM seatdata_sales_snapshots WHERE tevo_event_id = e.eid)  AS sd_sales,
  (SELECT count(*) FROM evo_order_items WHERE event_id = e.eid)                AS evo_items,
  (SELECT count(*) FROM espn_event_snapshots ee
     JOIN event_xref x ON x.espn_event_id = ee.espn_event_id
    WHERE x.tevo_event_id = e.eid)                                              AS espn_snapshots,
  (SELECT count(*) FROM reddit_posts rp
     JOIN performer_subreddits ps ON ps.subreddit = rp.subreddit
     JOIN events ev ON ev.primary_performer_id = ps.tevo_performer_id
    WHERE ev.id = e.eid AND rp.created_utc > now() - interval '7 days')         AS reddit_posts_7d
FROM e;
```

---

## Cron health (for the Data Quality Dashboard)

```sql
-- Last-24h success rate per cron (use in the dashboard)
SELECT
  j.jobname,
  count(*) AS runs_24h,
  count(*) FILTER (WHERE r.status = 'succeeded') AS ok,
  count(*) FILTER (WHERE r.status != 'succeeded') AS fail,
  round(100.0 * count(*) FILTER (WHERE r.status='succeeded') / NULLIF(count(*),0), 1) AS pct_ok,
  max(r.start_time) AS latest_run
FROM cron.job j
LEFT JOIN cron.job_run_details r
  ON r.jobid = j.jobid AND r.start_time > now() - interval '24 hours'
WHERE j.active
GROUP BY j.jobname
ORDER BY pct_ok ASC NULLS LAST, j.jobname;
```

> Note: `coworker_readonly` does NOT have access to `cron.*`. For the
> Data Quality Dashboard, the audit lane will provide a `v_cron_health`
> view in `public` that exposes the same data. Open an issue when you're
> ready to wire it.

---

## Sandbox example (design_test.*)

```sql
-- You can do anything you want in design_test
CREATE TABLE design_test.my_dashboard_proto (
  id serial PRIMARY KEY,
  name text NOT NULL,
  payload jsonb,
  created_at timestamptz DEFAULT now()
);
INSERT INTO design_test.my_dashboard_proto(name, payload)
VALUES ('test', '{"hello":"world"}');
SELECT * FROM design_test.my_dashboard_proto;
DROP TABLE design_test.my_dashboard_proto;
```

The sandbox doesn't run on any cron and isn't read by any production
view — it's truly your space.
