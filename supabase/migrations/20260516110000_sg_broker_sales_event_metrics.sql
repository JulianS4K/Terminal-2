-- Migration 20260516110000 · admin · SG broker sales event metrics · pre:20260516100000
--
-- Operator directive 2026-05-16: "compute seatgeek broker sale metrics for an event same
-- way we do listings and evo sales data".
--
-- Investigation: `seatgeek_event_metrics.sold_*` columns (sold_quantity, sold_gross,
-- sold_price_min/median/mean/max) EXIST but are EMPTY (0 of 2,099 rows populated in 24h).
-- Root cause: the legacy `compute_seatgeek_event_metrics()` tries to populate them from
-- `seatgeek_orders` with a status filter that doesn't match live data shape. The actual
-- sales firehose is `seatgeek_sales_snapshots` (1.2M rows, 441K/24h ingest, 11× dup factor
-- on sg_sale_id — must DISTINCT ON for accurate counts).
--
-- This migration:
-- 1. New fn `refresh_sg_broker_sales_event_metrics(p_max_events int)` aggregates from
--    `seatgeek_sales_snapshots` (DISTINCT ON sg_sale_id) into per-event snapshot rows
--    on `seatgeek_event_metrics`. Mirrors event_metrics shape for TEvo listings.
-- 2. Cron `sg_broker_sales_metrics_refresh_hourly` @ :17 hourly (off-cycle from
--    sg_broker_sales_process at :07/:37). Wraps with `cron_should_fire` gate.
-- 3. cron_policy row capping at hourly + work_check_sql to skip when no new sales.
--
-- ## Already applied to prod  Applied via MCP 2026-05-16.

CREATE OR REPLACE FUNCTION public.refresh_sg_broker_sales_event_metrics(
  p_max_events integer DEFAULT 200
)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_now timestamptz := now();
  v_count int := 0;
BEGIN
  -- Aggregate per sg_event_id from deduped sales (last 24h window)
  -- Insert new snapshot rows in seatgeek_event_metrics with the sold_* columns populated.
  -- Uses INSERT (not UPSERT) so each refresh creates a time-series point — same pattern
  -- as event_metrics for TEvo listings.
  WITH deduped AS (
    SELECT DISTINCT ON (sg_sale_id)
      sg_event_id, tevo_event_id, sg_sale_id, broadcast_price, sale_at_utc
    FROM public.seatgeek_sales_snapshots
    WHERE sale_at_utc > v_now - interval '24 hours'
    ORDER BY sg_sale_id, pulled_at DESC
  ),
  agg AS (
    SELECT
      d.sg_event_id,
      -- Prefer tevo_event_id from xref when sales row has it null
      coalesce(
        max(d.tevo_event_id),
        (SELECT tevo_event_id FROM public.seatgeek_event_xref WHERE sg_event_id = d.sg_event_id LIMIT 1)
      ) AS tevo_event_id,
      count(DISTINCT d.sg_sale_id) AS sold_quantity,
      round(sum(d.broadcast_price)::numeric, 2) AS sold_gross,
      min(d.broadcast_price) AS sold_price_min,
      percentile_cont(0.50) WITHIN GROUP (ORDER BY d.broadcast_price)::numeric AS sold_price_median,
      round(avg(d.broadcast_price)::numeric, 2) AS sold_price_mean,
      max(d.broadcast_price) AS sold_price_max
    FROM deduped d
    GROUP BY d.sg_event_id
    HAVING count(DISTINCT d.sg_sale_id) > 0
    LIMIT p_max_events
  )
  INSERT INTO public.seatgeek_event_metrics (
    sg_event_id, tevo_event_id, captured_at,
    sold_quantity, sold_gross, sold_price_min, sold_price_median, sold_price_mean, sold_price_max
  )
  SELECT sg_event_id, tevo_event_id, v_now,
         sold_quantity, sold_gross, sold_price_min, sold_price_median, sold_price_mean, sold_price_max
  FROM agg
  WHERE tevo_event_id IS NOT NULL;  -- seatgeek_event_metrics.tevo_event_id is NOT NULL

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $func$;

REVOKE ALL ON FUNCTION public.refresh_sg_broker_sales_event_metrics(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_sg_broker_sales_event_metrics(integer) TO service_role;

COMMENT ON FUNCTION public.refresh_sg_broker_sales_event_metrics(integer) IS
  'Aggregates deduped (DISTINCT ON sg_sale_id) SG sales last 24h into per-event sold_* metrics in seatgeek_event_metrics. New snapshot row per refresh = time series. Cron @ :17 hourly.';

-- Schedule the cron with policy gate
SELECT cron.schedule(
  'sg_broker_sales_metrics_refresh_hourly',
  '17 * * * *',
  $cron$DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_broker_sales_metrics_refresh_hourly') THEN RETURN; END IF;
    PERFORM public.refresh_sg_broker_sales_event_metrics(200);
  END $body$;$cron$
);

-- Policy row: hourly cap; work-check skips when no new sales in last hour
INSERT INTO public.cron_policy (
  jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
  daily_max_fires, work_check_sql, enabled, notes
) VALUES (
  'sg_broker_sales_metrics_refresh_hourly',
  '{9,10,11,12,13,14,15,16,17,18,19,20,21,22,23}'::int[],
  60, 60, 24,
  'SELECT EXISTS(SELECT 1 FROM public.seatgeek_sales_snapshots WHERE pulled_at > now() - interval ''65 minutes'' LIMIT 1)',
  true,
  'Aggregates deduped SG sales (last 24h) into per-event sold_* metrics. Skips when no recent ingest.'
) ON CONFLICT (jobname) DO UPDATE SET
  work_check_sql = EXCLUDED.work_check_sql,
  notes = EXCLUDED.notes,
  updated_at = now();
