-- ============================================================================
-- Fix: sg_events_canonical.last_v2_pull_at / last_v2_listings_count /
--      last_v2_status / has_v2_listings_pulled are not being populated by the
--      SG v2 listings ingest path. As of 2026-05-16:
--          actual sg_events with v2 listing rows: 574
--          canonical flag set:                     25  (4.4%)
--      Sales / orders / seller_listings flags are healthy (98.7% / 100% / 100%),
--      so the bug is isolated to the v2 listings path.
--
-- Found by: A1 spot-check 2026-05-16 (5 random forward-dated events; 1 of 5 had
--   288 SG v2 listing rows + recent captures with NULL last_v2_pull_at).
--
-- Approach: reconciliation cron, not a per-INSERT trigger. The listings table
--   ingests at ~86K rows/day in bursts; per-row trigger overhead is not
--   warranted when a 5-min reconciliation pass keeps the column within an
--   acceptable freshness window for queue gating.
--
-- Changes:
--   1. CREATE FUNCTION sg_canonical_refresh_v2_pull(p_window_minutes integer)
--      Reconciles last_v2_pull_at + last_v2_listings_count + last_v2_status +
--      has_v2_listings_pulled from seatgeek_listings_snapshots for any
--      sg_event with rows captured in the last p_window_minutes (default 15).
--   2. CREATE cron job sg_canonical_v2_pull_refresh_5min @ :12,:17,:22,:27,...
--      (off-cycle from sg_broker_listings_queue/process at :02/:07/:32/:37)
--   3. One-shot full backfill from ALL historical listings rows (set window=NULL
--      to skip the time filter).
-- ============================================================================

-- 1. The reconciliation function
CREATE OR REPLACE FUNCTION public.sg_canonical_refresh_v2_pull(
  p_window_minutes integer DEFAULT 15
)
RETURNS TABLE(rows_updated integer, sg_events_touched integer, window_minutes integer)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_count int := 0;
  v_window text;
BEGIN
  v_window := CASE WHEN p_window_minutes IS NULL THEN 'ALL' ELSE p_window_minutes::text END;

  WITH last_pull AS (
    -- Most recent captured_at per sg_event in the reconciliation window
    SELECT sls.sg_event_id, max(sls.captured_at) AS last_captured
    FROM public.seatgeek_listings_snapshots sls
    WHERE p_window_minutes IS NULL
       OR sls.captured_at > now() - make_interval(mins => p_window_minutes)
    GROUP BY sls.sg_event_id
  ),
  agg AS (
    -- listings_count = distinct sglids in the latest pull burst (within 2 min
    -- of max captured_at — one /v2/listings pull writes all rows in one txn)
    SELECT
      lp.sg_event_id,
      lp.last_captured,
      count(DISTINCT sls.sglid) AS listing_cnt
    FROM last_pull lp
    JOIN public.seatgeek_listings_snapshots sls
      ON sls.sg_event_id = lp.sg_event_id
     AND sls.captured_at >= lp.last_captured - interval '2 minutes'
    GROUP BY lp.sg_event_id, lp.last_captured
  ),
  upd AS (
    UPDATE public.sg_events_canonical sec
    SET
      last_v2_pull_at         = GREATEST(COALESCE(sec.last_v2_pull_at, agg.last_captured), agg.last_captured),
      last_v2_listings_count  = agg.listing_cnt,
      last_v2_status          = 200,  -- HTTP status code; 200=OK (column is int4)
      has_v2_listings_pulled  = true,
      updated_at              = now()
    FROM agg
    WHERE sec.sg_event_id = agg.sg_event_id
      AND (
        sec.last_v2_pull_at IS NULL
        OR sec.last_v2_pull_at < agg.last_captured
        OR sec.last_v2_listings_count IS DISTINCT FROM agg.listing_cnt
        OR NOT sec.has_v2_listings_pulled
      )
    RETURNING sec.sg_event_id
  )
  SELECT count(*)::int INTO v_count FROM upd;

  RETURN QUERY SELECT v_count, v_count, p_window_minutes;
END $func$;

REVOKE EXECUTE ON FUNCTION public.sg_canonical_refresh_v2_pull(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_canonical_refresh_v2_pull(integer) TO service_role;

COMMENT ON FUNCTION public.sg_canonical_refresh_v2_pull(integer) IS
  'Reconciles sg_events_canonical v2-listings tracking columns from seatgeek_listings_snapshots. Called every 5 min off-cycle from the SG listings queue/process pair. Pass NULL window for full-history backfill.';

-- 2. One-shot full backfill (covers the 549 events missing the flag)
SELECT * FROM public.sg_canonical_refresh_v2_pull(NULL);

-- 3. Schedule reconciliation cron @ :12,:42 (off-cycle from queue :02,:32
--    and process :07,:37)
DO $body$
DECLARE
  v_jobid bigint;
BEGIN
  -- Unschedule any prior version
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sg_canonical_v2_pull_refresh_30min';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
  END IF;

  PERFORM cron.schedule(
    'sg_canonical_v2_pull_refresh_30min',
    '12,42 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_canonical_v2_pull_refresh_30min') THEN RETURN; END IF;
      PERFORM public.sg_canonical_refresh_v2_pull(60);
    END $cronbody$;$cron$
  );
END $body$;

-- 4. Cron policy entry (budget-capped, idle 48 daily max)
INSERT INTO public.cron_policy (
  jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
  daily_max_fires, enabled, notes
) VALUES (
  'sg_canonical_v2_pull_refresh_30min',
  '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
  30, 30, 48, true,
  'Reconciles sg_events_canonical v2-listings tracking from seatgeek_listings_snapshots. Fixes 95% population gap discovered in A1 spot-check 2026-05-16.'
)
ON CONFLICT (jobname) DO UPDATE SET
  notes = EXCLUDED.notes,
  enabled = EXCLUDED.enabled,
  updated_at = now();
