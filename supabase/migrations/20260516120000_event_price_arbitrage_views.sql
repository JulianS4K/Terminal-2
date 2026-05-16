-- Migration 20260516120000 · admin · 3 bonus analytics views · pre:20260516110000
--
-- Operator asked for "other suggestions" alongside SG sales metrics. 3 views ship here:
--
-- 1. `v_event_sales_velocity` — hourly sales count + price summary per event-hour.
--    Time-series for D0 to chart "sales/hour" curves pre-event.
-- 2. `v_event_sales_metrics_filtered` — p99-outlier-filtered averages. The $101K+ suite-
--    package seat prices skew naive averages; this view drops top 1% for clean reads
--    while preserving the raw max separately.
-- 3. `v_event_price_arbitrage` — cross-source price comparison per event: TEvo retail
--    median vs SG cost median vs SG sales realized median. Surface where we're under-
--    pricing (sale_minus_retail_median > 0) vs over-pricing.
--
-- All 3 views are SECURITY INVOKER (default) so they respect the caller's RLS.
-- Granted to `authenticated` for D0 use.
--
-- ## Already applied to prod  Applied via MCP 2026-05-16.

-- View 1: Sales velocity per event per hour
CREATE OR REPLACE VIEW public.v_event_sales_velocity
WITH (security_invoker = true) AS
WITH deduped AS (
  SELECT DISTINCT ON (sg_sale_id)
    sg_event_id, tevo_event_id, sg_sale_id, broadcast_price, sale_at_utc
  FROM public.seatgeek_sales_snapshots
  WHERE sale_at_utc > now() - interval '30 days'
  ORDER BY sg_sale_id, pulled_at DESC
)
SELECT
  d.sg_event_id,
  coalesce(d.tevo_event_id,
    (SELECT tevo_event_id FROM public.seatgeek_event_xref WHERE sg_event_id = d.sg_event_id LIMIT 1)
  ) AS tevo_event_id,
  date_trunc('hour', d.sale_at_utc) AS hour_utc,
  count(DISTINCT d.sg_sale_id) AS unique_sales,
  round(avg(d.broadcast_price)::numeric, 2) AS avg_px,
  min(d.broadcast_price) AS min_px,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY d.broadcast_price)::numeric AS median_px,
  max(d.broadcast_price) AS max_px,
  round((count(DISTINCT d.sg_sale_id) * avg(d.broadcast_price))::numeric, 0) AS approx_gross
FROM deduped d
GROUP BY 1, 2, 3;

COMMENT ON VIEW public.v_event_sales_velocity IS
  'Sales velocity per event per hour (last 30d). Deduped on sg_sale_id (11x dup factor in raw). Use unique_sales for "real" sale count, not raw row count.';

GRANT SELECT ON public.v_event_sales_velocity TO authenticated, anon;

-- View 2: Outlier-filtered sales metrics per event
CREATE OR REPLACE VIEW public.v_event_sales_metrics_filtered
WITH (security_invoker = true) AS
WITH deduped AS (
  SELECT DISTINCT ON (sg_sale_id)
    sg_event_id, sg_sale_id, broadcast_price
  FROM public.seatgeek_sales_snapshots
  WHERE sale_at_utc > now() - interval '30 days'
  ORDER BY sg_sale_id, pulled_at DESC
),
event_p99 AS (
  SELECT sg_event_id,
         percentile_cont(0.99) WITHIN GROUP (ORDER BY broadcast_price)::numeric AS p99
  FROM deduped
  GROUP BY sg_event_id
  HAVING count(*) >= 10  -- p99 meaningful only above ~10 rows
)
SELECT
  d.sg_event_id,
  count(DISTINCT d.sg_sale_id) AS total_sales,
  count(DISTINCT d.sg_sale_id) FILTER (WHERE d.broadcast_price <= p.p99) AS sales_within_p99,
  count(*) FILTER (WHERE d.broadcast_price > p.p99) AS outlier_rows_excluded,
  round(avg(d.broadcast_price) FILTER (WHERE d.broadcast_price <= p.p99)::numeric, 2) AS clean_avg_px,
  min(d.broadcast_price) AS min_px,
  percentile_cont(0.50) WITHIN GROUP (ORDER BY d.broadcast_price)::numeric AS median_px,
  max(d.broadcast_price) FILTER (WHERE d.broadcast_price <= p.p99) AS p99_max_px,
  max(d.broadcast_price) AS raw_max_px,
  round(p.p99, 2) AS p99_threshold
FROM deduped d
JOIN event_p99 p ON p.sg_event_id = d.sg_event_id
GROUP BY d.sg_event_id, p.p99;

COMMENT ON VIEW public.v_event_sales_metrics_filtered IS
  'p99-outlier-filtered sales metrics per event (last 30d). clean_avg_px drops top 1% (suite packages). raw_max_px retained for visibility. Requires >=10 sales for p99 to be meaningful.';

GRANT SELECT ON public.v_event_sales_metrics_filtered TO authenticated, anon;

-- View 3: Cross-source price arbitrage per upcoming event
CREATE OR REPLACE VIEW public.v_event_price_arbitrage
WITH (security_invoker = true) AS
SELECT
  e.id AS tevo_event_id,
  e.name AS event_name,
  e.venue_name,
  e.occurs_at_local,
  sgx.sg_event_id,
  -- TEvo retail (from latest event_metrics for this event)
  em.retail_median   AS tevo_retail_median,
  em.retail_min      AS tevo_retail_min,
  em.tickets_count   AS tevo_listings_count,
  em.owned_tickets_count,
  -- SG listings cost (from latest seatgeek_event_metrics)
  sgm.cost_median    AS sg_cost_median,
  sgm.cost_min       AS sg_cost_min,
  sgm.listings_count AS sg_listings_count,
  -- SG sales realized (from new sold_* columns populated by 20260516110000)
  sgm.sold_price_median AS sg_sale_median_realized,
  sgm.sold_price_mean   AS sg_sale_mean_realized,
  sgm.sold_quantity     AS sg_sales_count,
  -- Arbitrage deltas
  (sgm.sold_price_median - em.retail_median) AS sale_minus_retail_median,
  (sgm.cost_median       - em.retail_median) AS sg_cost_minus_retail_median,
  -- Freshness chips
  em.captured_at  AS tevo_metrics_at,
  sgm.captured_at AS sg_metrics_at
FROM public.events e
LEFT JOIN public.latest_event_metrics em ON em.event_id = e.id
LEFT JOIN public.seatgeek_event_xref sgx ON sgx.tevo_event_id = e.id
LEFT JOIN LATERAL (
  SELECT * FROM public.seatgeek_event_metrics
  WHERE tevo_event_id = e.id
  ORDER BY captured_at DESC
  LIMIT 1
) sgm ON true
WHERE e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
  AND e.occurs_at_local::timestamptz > now()
  AND e.occurs_at_local::timestamptz < now() + interval '180 days';

COMMENT ON VIEW public.v_event_price_arbitrage IS
  'Per upcoming event: TEvo retail vs SG cost vs SG sales realized. sale_minus_retail_median > 0 = we are underpricing vs market. Window: next 180 days.';

GRANT SELECT ON public.v_event_price_arbitrage TO authenticated, anon;
