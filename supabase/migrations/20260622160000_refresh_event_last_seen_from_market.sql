-- ============================================================================
-- Migration 20260622xxxxxx — daily refresh of events.last_seen from market activity
--
-- Lane:     A1 (data plane — owns events freshness + crons)
-- Touches:  refresh_event_last_seen_from_market() (W, new fn)
--           events (W, UPDATE last_seen only — never moves backward)
--           cron.job (W, new daily schedule)
-- Pre-reqs: derive_event_lifecycle market-freshness guard (mig 20260622150000)
--
-- WHY: events.last_seen is only advanced by the EVO events-feed crawl, NOT by
--   the listings collectors. Seeded / actively-traded events (e.g. UFC 329) thus
--   decay to a stale last_seen even while fresh listings + metrics arrive daily,
--   which previously mislabeled them 'ghost_eliminated' (fixed read-side in
--   20260622150000). This closes the root cause: a daily job that advances
--   last_seen to the most recent market capture for any event with activity in
--   the trailing window, so freshness reflects reality everywhere last_seen is
--   consumed (lifecycle, dashboard ghost filter, freshness panels).
--
--   Market signal = event_metrics (EVO) — the same table the lifecycle guard
--   checks — so the two stay aligned. UPDATE is guarded (last_seen < new) so it
--   never regresses an event that the crawl saw more recently.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.refresh_event_last_seen_from_market(p_window interval DEFAULT '7 days'::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  WITH fresh AS (
    SELECT em.event_id, max(em.captured_at) AS mx
    FROM public.event_metrics em
    WHERE em.captured_at > now() - p_window
    GROUP BY em.event_id
  )
  UPDATE public.events e
     SET last_seen = f.mx
    FROM fresh f
   WHERE e.id = f.event_id
     AND (e.last_seen IS NULL OR e.last_seen < f.mx);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

-- Daily at 08:50 UTC. Idempotent re-schedule.
DO $mig$
DECLARE j bigint;
BEGIN
  FOR j IN SELECT jobid FROM cron.job WHERE jobname = 'refresh_event_last_seen_from_market_daily'
  LOOP PERFORM cron.unschedule(j); END LOOP;
END $mig$;

SELECT cron.schedule(
  'refresh_event_last_seen_from_market_daily', '50 8 * * *',
  $cmd$ DO $b$ BEGIN PERFORM public.refresh_event_last_seen_from_market(); END $b$; $cmd$
);
