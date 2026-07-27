-- Migration 20260620155000 · level:2 · lane:A1 · operator-directed (2026-06-20)
-- Lane: A1 (data plane — analytics views, no new ingest/cron)
-- Touches W: CREATE VIEW public.v_event_price_index_daily,
--            CREATE VIEW public.v_event_price_index_latest
-- Touches R: public.event_listing_snapshot_daily, public.events, public.performer_metadata
-- Pre-reqs: event_listing_snapshot_daily (indefinite retention; cross-source amalgam medians)
-- Already applied to prod · via MCP 2026-06-20
--
-- ============================================================
-- LIVE EVENT PRICE INDEX  —  "S&P for live-event tickets"
--
-- event_listing_snapshot_daily is retained INDEFINITELY and carries cross-source amalgam
-- get-in / median per event per day (3 slots/day). This rolls it up into a per-category
-- daily index — a marketing/PR asset AND the settlement substrate for the future E1
-- ticket-price betting pool. Pure aggregation: no new ingest, no cron, no table.
--
-- Dedup: snapshot_daily writes ~3 slots/day/event; we take ONE row per (event_id,
-- snapshot_date) — the latest captured_at — so an event is weighted once per day.
-- Index is base-100 normalized to each category's first observed day (first_value window).
-- NOTE: the source table began 2026-05-27, so the series is short today and accrues forward.
--
-- SECURITY INVOKER — respects caller RLS. Granted to authenticated.
-- ============================================================

CREATE OR REPLACE VIEW public.v_event_price_index_daily
WITH (security_invoker = true) AS
WITH one_per_day AS (
  SELECT DISTINCT ON (d.event_id, d.snapshot_date)
    d.event_id, d.snapshot_date, d.amalgam_getin, d.amalgam_median
  FROM public.event_listing_snapshot_daily d
  WHERE d.amalgam_getin IS NOT NULL
  ORDER BY d.event_id, d.snapshot_date, d.captured_at DESC
),
tagged AS (
  SELECT
    coalesce(pm.top_category_name, 'Unknown') AS category,
    o.snapshot_date,
    o.amalgam_getin,
    o.amalgam_median
  FROM one_per_day o
  JOIN public.events e ON e.id = o.event_id
  LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
),
daily AS (
  SELECT
    category,
    snapshot_date,
    count(*)                                                                       AS n_events,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY amalgam_getin)::numeric, 2)  AS median_getin,
    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY amalgam_median)::numeric, 2) AS median_price,
    round(avg(amalgam_getin)::numeric, 2)                                          AS avg_getin
  FROM tagged
  GROUP BY category, snapshot_date
)
SELECT
  category,
  snapshot_date,
  n_events,
  median_getin,
  median_price,
  avg_getin,
  -- base-100 index vs the category's first observed day
  round(median_getin
    / NULLIF(first_value(median_getin) OVER (PARTITION BY category ORDER BY snapshot_date), 0)
    * 100, 1)                                                                       AS getin_index,
  -- day-over-day % change in median get-in
  round((median_getin - lag(median_getin) OVER (PARTITION BY category ORDER BY snapshot_date))
    / NULLIF(lag(median_getin) OVER (PARTITION BY category ORDER BY snapshot_date), 0)
    * 100, 1)                                                                       AS getin_dod_pct
FROM daily;

COMMENT ON VIEW public.v_event_price_index_daily IS
  'Per-category daily ticket price index from event_listing_snapshot_daily (one row/event/day). '
  'getin_index = base-100 vs first observed day; getin_dod_pct = day-over-day move. A1 · mig 20260620155000.';

-- Latest day per category + 7-day-ago comparison for a headline "this week" read.
CREATE OR REPLACE VIEW public.v_event_price_index_latest
WITH (security_invoker = true) AS
WITH ranked AS (
  SELECT *, row_number() OVER (PARTITION BY category ORDER BY snapshot_date DESC) AS rn
  FROM public.v_event_price_index_daily
)
SELECT
  cur.category,
  cur.snapshot_date,
  cur.n_events,
  cur.median_getin,
  cur.median_price,
  cur.getin_index,
  cur.getin_dod_pct,
  wk.median_getin AS median_getin_7d_ago,
  round((cur.median_getin - wk.median_getin) / NULLIF(wk.median_getin, 0) * 100, 1) AS getin_wow_pct
FROM ranked cur
LEFT JOIN public.v_event_price_index_daily wk
  ON wk.category = cur.category
 AND wk.snapshot_date = cur.snapshot_date - 7
WHERE cur.rn = 1;

COMMENT ON VIEW public.v_event_price_index_latest IS
  'Latest per-category price-index row + 7-day change (getin_wow_pct). A1 · mig 20260620155000.';

GRANT SELECT ON public.v_event_price_index_daily  TO authenticated, service_role;
GRANT SELECT ON public.v_event_price_index_latest TO authenticated, service_role;
