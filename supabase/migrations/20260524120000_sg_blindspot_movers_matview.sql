-- 20260524120000_sg_blindspot_movers_matview.sql
--
-- ## Already applied to prod — applied via MCP apply_migration 2026-05-24.
--   Post-apply verified: get_blind_spots_sg_selling(2) = 4.989ms (was >11,000ms);
--   mv_sg_blindspot_movers = 43 rows; cron 'sg_blindspot_mv_refresh' scheduled.
--   A1: please push this file to main (sole-pusher) so repo↔prod stay in sync.
--
-- D0 (operator-directed; crosses into A1's migration domain via the bot_chat
-- override path — "fix and test", 2026-05-24).
--
-- PROBLEM (audit 2026-05-24): get_blind_spots_sg_selling() reads
--   public.v_sg_blindspot_movers, which does per-event correlated-subquery
--   anchoring (t0/t48) + percentile_cont medians + DISTINCT-ON sales dedup over
--   the 7.46M-row seatgeek_listings_snapshots firehose for 2,932 TRACK_BLINDSPOT
--   events — every call, synchronously. Measured >11s. PostgREST caps
--   authenticated calls at 8s, so the SG blind-spots panel on the Home and
--   Movers terminal pages TIMES OUT on every load (renders
--   "error: canceling statement due to statement timeout").
--
-- FIX: materialize the heavy view into mv_sg_blindspot_movers (the scan runs
--   off-request on a cron), repoint the RPC at the matview (sub-second indexed
--   read), and refresh on a gated 10-min cron. Mirrors the latest_event_metrics
--   matview pattern (PROJECT_BIBLE §3: "use the matview, don't scan the firehose").
--   The RPC body is byte-identical to the prior version except the FROM target.
--
-- ROLLBACK: repoint the RPC's FROM back to public.v_sg_blindspot_movers,
--   cron.unschedule('sg_blindspot_mv_refresh'), DROP MATERIALIZED VIEW
--   public.mv_sg_blindspot_movers, DELETE the cron_policy row.

SET statement_timeout = '120s';  -- CREATE ... WITH DATA runs the heavy scan once

-- 1) Materialized snapshot of the heavy view -------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS public.mv_sg_blindspot_movers AS
  SELECT * FROM public.v_sg_blindspot_movers
WITH DATA;

-- unique index → enables REFRESH ... CONCURRENTLY (non-blocking) + fast PK lookup
CREATE UNIQUE INDEX IF NOT EXISTS mv_sg_blindspot_movers_pk
  ON public.mv_sg_blindspot_movers (sg_event_id);
-- supports the RPC's `WHERE selling_score >= p_min_score` filter
CREATE INDEX IF NOT EXISTS mv_sg_blindspot_movers_score_idx
  ON public.mv_sg_blindspot_movers (selling_score DESC);

-- secure-by-default: only the SECURITY DEFINER RPC (owner) reads the matview;
-- no direct anon/authenticated PostgREST surface (preempts B1-NEXT-55 class).
REVOKE ALL ON public.mv_sg_blindspot_movers FROM anon, authenticated;

-- 2) Repoint the RPC at the matview ----------------------------------------
--    (identical to prior definition except FROM v_... -> FROM mv_...)
CREATE OR REPLACE FUNCTION public.get_blind_spots_sg_selling(p_min_score integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  RETURN coalesce((
    SELECT jsonb_agg(jsonb_build_object(
             'sg_event_id', m.sg_event_id, 'tevo_event_id', c.tevo_event_id,
             'sg_event_name', c.sg_event_name, 'sg_venue_name', c.sg_venue_name,
             'sg_venue_city', c.sg_venue_city, 'sg_venue_state', c.sg_venue_state,
             'sg_datetime_utc', to_char(c.sg_datetime_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
             'listings_now', m.listings_now, 'listings_prior', m.listings_prior,
             'listings_pct_delta', m.listings_pct_delta,
             'median_now', round(m.median_now, 2), 'median_prior', round(m.median_prior, 2),
             'price_pct_delta', m.price_pct_delta,
             'sales_24h_count', m.sales_24h_count, 'sales_prior_24h_count', m.sales_prior_24h_count,
             'sales_velocity_pct', m.sales_velocity_pct,
             'median_sale_24h', m.median_sale_24h, 'sale_vs_listing_pct', m.sale_vs_listing_pct,
             'clearing_ratio', m.clearing_ratio,
             'signal_listings_drop', m.signal_listings_drop,
             'signal_price_rise', m.signal_price_rise,
             'signal_sales_accel', m.signal_sales_accel,
             'signal_sales_above_ask', m.signal_sales_above_ask,
             'selling_score', m.selling_score, 'selling_pressure', m.selling_pressure
           ) ORDER BY m.selling_score DESC,
                     coalesce(m.sales_velocity_pct, 0) DESC,
                     abs(coalesce(m.price_pct_delta, 0)) DESC)
    FROM public.mv_sg_blindspot_movers m
    JOIN public.sg_events_canonical c ON c.sg_event_id = m.sg_event_id
    WHERE m.selling_score >= p_min_score
      AND c.sg_datetime_utc > now()
  ), '[]'::jsonb);
END
$function$;

-- 3) Gated refresh cron -----------------------------------------------------
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sg_blindspot_mv_refresh',
   ARRAY[7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   10, 30, 120, true,
   'Refresh mv_sg_blindspot_movers (materializes v_sg_blindspot_movers). Underlying SG blindspot poll runs UTC 4-10/16-22; 10-min peak / 30-min offpeak refresh keeps the matview fresh. Added by D0 fixing get_blind_spots_sg_selling 8s timeout (audit 2026-05-24).')
ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et = EXCLUDED.peak_hours_et,
      peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = true,
      notes = EXCLUDED.notes,
      updated_at = now();

SELECT cron.schedule('sg_blindspot_mv_refresh', '3-59/10 * * * *', $cron$
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_blindspot_mv_refresh') THEN RETURN; END IF;
    SET LOCAL statement_timeout = '5min';
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_sg_blindspot_movers;
  END $body$;
$cron$);
