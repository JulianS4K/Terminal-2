-- 20260526040000_tevo_blindspot_movers_matview.sql
--
-- A1-5 (D0 handoff, 2026-05-26): materialize v_tevo_blindspot_movers.
--
-- PROBLEM: get_blind_spots_tevo_selling() reads v_tevo_blindspot_movers, which
--   does a correlated subquery against listings_snapshots for each event + joins
--   v_event_velocity_windows. Cold open of the Discovery page TEvo panel exceeds
--   8s PostgREST timeout (measured >8s cold; ~1.1s warm). Same architectural root
--   cause as the SG blindspot timeout fixed in 20260524120000_sg_blindspot_movers_matview.
--
-- FIX: mirror that migration exactly — materialize the view into
--   mv_tevo_blindspot_movers, repoint the RPC, add a gated 10-min cron.
--
-- CAVEAT (D0 handoff): the TEvo panel also returns 0 rows because
--   v_tevo_blindspot_movers INNER JOINs latest_event_metrics which covers only
--   ~1.4% of upcoming non-major-sport events. This matview makes the RPC fast
--   but the 0-row issue persists until LEM coverage extends to the long tail
--   (separate data pipeline work). Materializing is still worthwhile — prevents
--   the timeout from masking whatever signal does exist.
--
-- ROLLBACK: repoint RPC FROM back to v_tevo_blindspot_movers,
--   cron.unschedule('tevo_blindspot_mv_refresh'),
--   DROP MATERIALIZED VIEW public.mv_tevo_blindspot_movers,
--   DELETE FROM cron_policy WHERE jobname = 'tevo_blindspot_mv_refresh'.

SET statement_timeout = '300s';  -- initial WITH DATA scan (correlated subquery, but only ~16 LEM rows)

-- 1) Materialize the view -------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS public.mv_tevo_blindspot_movers AS
  SELECT * FROM public.v_tevo_blindspot_movers
WITH DATA;

-- Unique index → enables REFRESH CONCURRENTLY (non-blocking) + fast PK lookup
CREATE UNIQUE INDEX IF NOT EXISTS mv_tevo_blindspot_movers_pk
  ON public.mv_tevo_blindspot_movers (tevo_event_id);

-- Score filter index
CREATE INDEX IF NOT EXISTS mv_tevo_blindspot_movers_score_idx
  ON public.mv_tevo_blindspot_movers (selling_score DESC);

-- Secure: no direct anon/authenticated PostgREST surface (preempts B1 audit class)
REVOKE ALL ON public.mv_tevo_blindspot_movers FROM anon, authenticated;

-- 2) Repoint the RPC at the matview -------------------------------------------
--    Body is byte-identical to prior version except FROM v_tevo_blindspot_movers
--    → FROM mv_tevo_blindspot_movers.
CREATE OR REPLACE FUNCTION public.get_blind_spots_tevo_selling(
  p_min_confidence numeric DEFAULT 0.5,
  p_horizon_days   integer DEFAULT 365,
  p_limit          integer DEFAULT 25,
  p_venue_pattern  text    DEFAULT NULL,
  p_mode           text    DEFAULT 'selling',
  p_band           text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_email  text;
  v_result jsonb;
BEGIN
  v_email := nullif((select auth.jwt())->>'email', '');
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'email required' USING errcode = '42501';
  END IF;

  IF p_mode NOT IN ('selling', 'tracking', 'spike_only') THEN
    RAISE EXCEPTION 'p_mode must be selling|tracking|spike_only' USING errcode = '22023';
  END IF;
  IF p_band IS NOT NULL AND p_band NOT IN ('imminent_31_60','near_61_180','far_181_365') THEN
    RAISE EXCEPTION 'p_band must be imminent_31_60|near_61_180|far_181_365|null' USING errcode = '22023';
  END IF;

  SELECT coalesce(jsonb_agg(row_to_json(m) ORDER BY
                              m.confidence_score DESC NULLS LAST,
                              m.occurs_at_local ASC), '[]'::jsonb)
    INTO v_result
  FROM (
    SELECT
      tevo_event_id, event_name, occurs_at_local,
      venue_id, venue_name, venue_location,
      primary_performer_id, primary_performer_name,
      tickets_count, retail_min, retail_median, getin_no_parking,
      tevo_tix_d24h, tevo_tix_d24h_pct, tevo_getin_d24h_pct,
      tevo_getin_now, tevo_median_now,
      signal_listings_drop, signal_listings_spike, signal_price_rise,
      selling_score, tracking_score, confidence_score,
      days_to_event, days_to_event_band
    FROM public.mv_tevo_blindspot_movers             -- ← was v_tevo_blindspot_movers
    WHERE occurs_at_local::date <= CURRENT_DATE + (p_horizon_days || ' days')::interval
      AND (p_venue_pattern IS NULL OR venue_location ILIKE p_venue_pattern)
      AND (p_band          IS NULL OR days_to_event_band = p_band)
      AND confidence_score >= p_min_confidence
      AND (
        (p_mode = 'selling'    AND selling_score  >= 1)   OR
        (p_mode = 'tracking'   AND tracking_score >= 1)   OR
        (p_mode = 'spike_only' AND signal_listings_spike  = true)
      )
    LIMIT p_limit
  ) m;

  RETURN v_result;
END;
$function$;

-- 3) Cron policy + gated refresh cron -----------------------------------------
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('tevo_blindspot_mv_refresh',
   ARRAY[7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   10, 30, 120, true,
   'Refresh mv_tevo_blindspot_movers (materializes v_tevo_blindspot_movers). 10-min peak / 30-min offpeak; mirrors sg_blindspot_mv_refresh pattern. Added A1-5 (D0 handoff 2026-05-26).')
ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et            = EXCLUDED.peak_hours_et,
      peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires          = EXCLUDED.daily_max_fires,
      enabled                  = true,
      notes                    = EXCLUDED.notes,
      updated_at               = now();

-- Offset to :7 so it doesn't fire simultaneously with sg_blindspot_mv_refresh (:3)
SELECT cron.schedule(
  'tevo_blindspot_mv_refresh',
  '7-59/10 * * * *',
  $$SET statement_timeout = '10min'; DO $body$ BEGIN IF NOT public.cron_should_fire('tevo_blindspot_mv_refresh') THEN RETURN; END IF; REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_tevo_blindspot_movers; END $body$;$$
);
