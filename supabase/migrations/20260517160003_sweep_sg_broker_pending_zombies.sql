-- ============================================================================
-- A1 cron-cascade fix (2026-05-17) — sg_broker_pending sweeper coverage.
--
-- Findings during P0 test (mig 20260517160000):
--   - 1,595 unresolved sg_broker_pending rows (scope=listings, oldest 04:03 UTC).
--   - Their request_id rows in net._http_response have been pruned (retention
--     window is ~6 hours; net._http_response oldest = 09:55 UTC).
--   - sweep_all_expired_pg_net_pending() iterates a hardcoded table list that
--     does NOT include sg_broker_pending. So zombies accumulated indefinitely.
--
-- Fix:
--   1. Add sg_broker_pending to the sweeper's table list.
--   2. One-shot UPDATE marking the existing 1,595 zombies as resolved
--      (rows_persisted = -1 to signal "response pruned, never persisted").
--
-- Sweeper now picks them up on next :20 fire (sweep_expired_pg_net_pending_hourly,
-- jobid 191).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sweep_all_expired_pg_net_pending(p_ttl_hours integer DEFAULT 12)
 RETURNS TABLE(queue text, swept integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r record;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sweep_all_expired_pg_net_pending: caller % not authorized', current_user;
  END IF;
  FOR r IN
    SELECT t.tbl FROM (VALUES
      ('nws_alert_pending'),('sg_seller_pending'),('sg_event_backfill_pending'),
      ('sg_listings_pending'),('espn_scoreboard_pending'),('espn_tournament_pending'),
      ('evo_orders_pending'),('evo_event_backfill_pending'),('performer_wiki_pending'),
      ('reddit_pending'),('weather_forecast_pending'),('venue_geocode_pending'),
      ('venue_nws_points_pending'),('tournament_category_pending'),
      ('tournament_search_pending'),('fred_pending'),
      ('sg_broker_pending')                                            -- A1 2026-05-17
    ) AS t(tbl)
    WHERE EXISTS (
      SELECT 1 FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name = t.tbl
    )
  LOOP
    queue := r.tbl;
    swept := sweep_expired_pg_net_pending(r.tbl::regclass, p_ttl_hours);
    RETURN NEXT;
  END LOOP;
END $function$;

-- One-shot drain of current zombies (request_id orphaned by net._http_response prune)
UPDATE public.sg_broker_pending
   SET resolved_at = now(),
       rows_persisted = -1
 WHERE resolved_at IS NULL
   AND fired_at < now() - interval '2 hours'
   AND NOT EXISTS (SELECT 1 FROM net._http_response h WHERE h.id = request_id);
