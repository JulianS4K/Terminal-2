-- ============================================================================
-- Migration 20260701160000 — heavy-cron fixes: broker-sales per-event rewrite + matcher timeout
--
-- Lane:     A1
-- Touches:  refresh_sg_broker_sales_event_metrics() (rewrite), cron commands
--           cross_source_match_tick_30min + sg_broker_sales_metrics_refresh_hourly (effective timeout).
-- Pre-reqs: idx_sg_sales_sg_event_id_time on seatgeek_sales_snapshots(sg_event_id, sale_at_utc DESC),
--           sg_events_canonical, seatgeek_event_xref.
--
-- WHY (operator 2026-07-01 "investigate + fix the heavy failing crons"):
--   refresh_sg_broker_sales_event_metrics (100% fail) filtered `seatgeek_sales_snapshots WHERE
--   sale_at_utc > now()-24h` with no matching index (indexes lead with event_id), so it SEQ-SCANNED the
--   13.2M-row / 7.8GB table every hour and always hit the 120s timeout. Rewritten to drive from the small
--   sg_events_canonical catalog (events with sg_datetime_utc > now-2d) and probe each event's 24h sales via
--   idx_sg_sales_sg_event_id_time — thousands of tiny index range scans instead of one giant seq-scan
--   (verified: completes in well under a second vs a 120s timeout). Aggregation/output semantics preserved.
--
--   cross_source_match_tick (27% fail) is 4 pure-SQL resolvers with NO timeout override (stuck at the 120s
--   default). Its cron now gets a real 5min budget via the correct SET-then-SELECT pattern (safe: pure SQL,
--   interruptible, no HTTP — unlike the orphan_backfill job that wedged the scheduler). Broker-sales cron
--   also gets a 5min belt-and-suspenders.
--
-- NOTE: sg_classify_events (heavy 2x DISTINCT ON over event_metrics) is deferred to a supervised
-- optimization pass (materialize latest metrics) — raising its timeout won't help a 5-min-cadence job.
--
-- Idempotent (CREATE OR REPLACE + cron.alter_job by name). Re-apply is a no-op.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.refresh_sg_broker_sales_event_metrics(p_max_events integer DEFAULT 200)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_now timestamptz := now();
  v_count int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'refresh_sg_broker_sales_event_metrics: caller % not authorized', current_user;
  END IF;

  WITH ev AS (
    SELECT DISTINCT c.sg_event_id
    FROM public.sg_events_canonical c
    WHERE c.sg_datetime_utc > v_now - interval '2 days'
  ),
  sales AS (
    SELECT s.sg_event_id, s.tevo_event_id, s.sg_sale_id, s.broadcast_price, s.pulled_at
    FROM ev
    JOIN LATERAL (
      SELECT ss.sg_event_id, ss.tevo_event_id, ss.sg_sale_id, ss.broadcast_price, ss.pulled_at
      FROM public.seatgeek_sales_snapshots ss
      WHERE ss.sg_event_id = ev.sg_event_id
        AND ss.sale_at_utc > v_now - interval '24 hours'
    ) s ON true
  ),
  deduped AS (
    SELECT DISTINCT ON (sg_event_id, sg_sale_id)
      sg_event_id, tevo_event_id, sg_sale_id, broadcast_price
    FROM sales
    ORDER BY sg_event_id, sg_sale_id, pulled_at DESC
  ),
  agg AS (
    SELECT
      d.sg_event_id,
      coalesce(max(d.tevo_event_id),
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
  WHERE tevo_event_id IS NOT NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END
$function$;

DO $do$
BEGIN
  PERFORM cron.alter_job(
    (SELECT jobid FROM cron.job WHERE jobname='cross_source_match_tick_30min'),
    command := $cmd$SET statement_timeout='5min'; SELECT public.cross_source_match_tick() WHERE public.cron_should_fire('cross_source_match_tick_30min');$cmd$);

  PERFORM cron.alter_job(
    (SELECT jobid FROM cron.job WHERE jobname='sg_broker_sales_metrics_refresh_hourly'),
    command := $cmd$SET statement_timeout='5min'; SELECT public.refresh_sg_broker_sales_event_metrics(200) WHERE public.cron_should_fire('sg_broker_sales_metrics_refresh_hourly');$cmd$);
END $do$;
