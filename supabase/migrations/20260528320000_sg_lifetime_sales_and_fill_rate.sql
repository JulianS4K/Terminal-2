-- 20260528320000_sg_lifetime_sales_and_fill_rate.sql
--
-- Fixes two gaps in seatgeek_event_metrics:
--
-- Action C — refresh_sg_broker_sales_event_metrics uses a 24h window, discarding
--   7.5M rows of historical seatgeek_sales_snapshots data. New lifetime variant
--   aggregates all-time sales scoped to active seatgeek_event_xref events (avoids
--   full 7.5M-row scan). Scheduled daily at 04:05 UTC.
--
-- Action D — fill_rate stopped being populated after May 13 because neither
--   refresh_sg_broker_listings_event_metrics nor _sales writes it (they INSERT
--   separate rows). New compute_sg_fill_rate() UPDATE pass joins latest-sales-row
--   with latest-listings-row per event and writes fill_rate. Scheduled hourly at :53.
--
-- Immediate backfill at migration apply time:
--   1. refresh_sg_broker_sales_event_metrics_lifetime(500) — top-500 events by volume
--   2. compute_sg_fill_rate() — writes fill_rate on all rows that now have both metrics


-- ─── Part A: lifetime sales refresh function ──────────────────────────────────

CREATE OR REPLACE FUNCTION public.refresh_sg_broker_sales_event_metrics_lifetime(
  p_max_events integer DEFAULT 2000
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  v_now  timestamptz := now();
  v_count int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'refresh_sg_broker_sales_event_metrics_lifetime: caller % not authorized', current_user;
  END IF;

  -- Scope to events we actively track (seatgeek_event_xref) to avoid scanning
  -- all 7.5M rows. DISTINCT ON sg_sale_id deduplicates multi-pull snapshots.
  WITH active_sg_events AS (
    SELECT DISTINCT sg_event_id
    FROM   public.seatgeek_event_xref
    WHERE  sg_event_id IS NOT NULL
  ),
  deduped AS (
    SELECT DISTINCT ON (s.sg_sale_id)
      s.sg_event_id,
      s.tevo_event_id,
      s.sg_sale_id,
      s.broadcast_price,
      s.sale_at_utc
    FROM   public.seatgeek_sales_snapshots s
    JOIN   active_sg_events ase ON ase.sg_event_id = s.sg_event_id
    ORDER  BY s.sg_sale_id, s.pulled_at DESC
  ),
  agg AS (
    SELECT
      d.sg_event_id,
      COALESCE(
        MAX(d.tevo_event_id),
        (SELECT tevo_event_id FROM public.seatgeek_event_xref
         WHERE sg_event_id = d.sg_event_id LIMIT 1)
      )                                                                    AS tevo_event_id,
      COUNT(DISTINCT d.sg_sale_id)                                         AS sold_quantity,
      ROUND(SUM(d.broadcast_price)::numeric, 2)                            AS sold_gross,
      MIN(d.broadcast_price)                                               AS sold_price_min,
      PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY d.broadcast_price)::numeric AS sold_price_median,
      ROUND(AVG(d.broadcast_price)::numeric, 2)                            AS sold_price_mean,
      MAX(d.broadcast_price)                                               AS sold_price_max
    FROM deduped d
    GROUP  BY d.sg_event_id
    HAVING COUNT(DISTINCT d.sg_sale_id) > 0
    ORDER  BY COUNT(DISTINCT d.sg_sale_id) DESC
    LIMIT  p_max_events
  )
  INSERT INTO public.seatgeek_event_metrics (
    sg_event_id, tevo_event_id, captured_at,
    sold_quantity, sold_gross,
    sold_price_min, sold_price_median, sold_price_mean, sold_price_max
  )
  SELECT
    sg_event_id, tevo_event_id, v_now,
    sold_quantity, sold_gross,
    sold_price_min, sold_price_median, sold_price_mean, sold_price_max
  FROM agg
  WHERE tevo_event_id IS NOT NULL;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


-- ─── Part B: fill_rate compute function ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.compute_sg_fill_rate()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  v_count int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'compute_sg_fill_rate: caller % not authorized', current_user;
  END IF;

  -- For each event: join most-recent sold_quantity row with most-recent
  -- listings_all_tickets row and write fill_rate onto the sales row.
  -- fill_rate = sold_qty / (sold_qty + listings_tickets)
  WITH latest_sales AS (
    SELECT DISTINCT ON (sg_event_id)
      id, sg_event_id, sold_quantity
    FROM   public.seatgeek_event_metrics
    WHERE  sold_quantity IS NOT NULL
    ORDER  BY sg_event_id, captured_at DESC
  ),
  latest_listings AS (
    SELECT DISTINCT ON (sg_event_id)
      sg_event_id, listings_all_tickets
    FROM   public.seatgeek_event_metrics
    WHERE  listings_all_tickets IS NOT NULL
    ORDER  BY sg_event_id, captured_at DESC
  )
  UPDATE public.seatgeek_event_metrics m
  SET    fill_rate = ls.sold_quantity::numeric
                    / NULLIF(ls.sold_quantity + ll.listings_all_tickets, 0)
  FROM   latest_sales ls
  JOIN   latest_listings ll ON ll.sg_event_id = ls.sg_event_id
  WHERE  m.id = ls.id
    AND  ll.listings_all_tickets > 0;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


-- ─── Part C: cron schedules ───────────────────────────────────────────────────

-- fill_rate: hourly at :53 (after listings :47 + sales :17)
SELECT cron.schedule(
  'sg_fill_rate_hourly',
  '53 * * * *',
  $$DO $body$
    BEGIN
      IF NOT public.cron_should_fire('sg_fill_rate_hourly') THEN RETURN; END IF;
      PERFORM public.compute_sg_fill_rate();
    END $body$;$$
);

-- lifetime sales: daily at 04:05 UTC (off-peak, after nightly snapshot)
SELECT cron.schedule(
  'sg_lifetime_sales_daily',
  '5 4 * * *',
  $$DO $body$
    BEGIN
      IF NOT public.cron_should_fire('sg_lifetime_sales_daily') THEN RETURN; END IF;
      PERFORM public.refresh_sg_broker_sales_event_metrics_lifetime(2000);
      PERFORM public.compute_sg_fill_rate();
    END $body$;$$
);

-- Register policies so cron_should_fire gate is aware of them
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min)
VALUES
  ('sg_fill_rate_hourly',    '{}'::int[], 50,   50),
  ('sg_lifetime_sales_daily', '{}'::int[], 1200, 1200)
ON CONFLICT (jobname) DO UPDATE SET
  peak_hours_et            = EXCLUDED.peak_hours_et,
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min;


-- ─── Part D: immediate backfill ───────────────────────────────────────────────

DO $$
DECLARE
  v_sales int;
  v_fr    int;
BEGIN
  -- Top-500 events by all-time sales volume
  v_sales := public.refresh_sg_broker_sales_event_metrics_lifetime(500);

  -- Write fill_rate on all events that now have both sold_quantity + listings
  v_fr := public.compute_sg_fill_rate();

  PERFORM public.bot_chat_log(
    'data-collection', 'D0', 'status',
    format('mig 320000: lifetime sales backfill=%s events; fill_rate written=%s rows', v_sales, v_fr)
  );
END $$;
