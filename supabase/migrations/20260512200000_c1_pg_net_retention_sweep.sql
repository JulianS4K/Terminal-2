-- Migration 20260512200000 · level:supervisor · lane:canonical · writes:sweep_expired_pg_net_pending,sweep_all_expired_pg_net_pending,cron(sweep_expired_pg_net_pending_hourly) · reads:net._http_response,all_pending_tables · pre:none

-- Fix for the pg_net retention class bug surfaced in audit:
-- net._http_response GCs responses after ~6h; if a *_pending row's processor
-- doesn't drain in time, the JOIN to net._http_response returns empty forever
-- and the row stays unresolved permanently. nws_alert_pending currently has
-- 120 such stuck rows (was 94 at audit time, bleeding +26 in 24h).
--
-- Fix: hourly sweep that marks rows as terminally resolved when
--   (a) older than p_ttl_hours, and
--   (b) no matching net._http_response row exists.
-- The sweep doesn't lose data — it acknowledges the response is unrecoverable
-- and stops the queue from accumulating dead weight.

CREATE OR REPLACE FUNCTION sweep_expired_pg_net_pending(p_table regclass, p_ttl_hours int DEFAULT 12)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE n int; has_request_id boolean;
BEGIN
  -- Defense-in-depth: only service_role / postgres / supabase admin may invoke.
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sweep_expired_pg_net_pending: caller % not authorized', current_user;
  END IF;
  -- *_pending shapes vary: most have (id, request_id, fired_at, resolved_at);
  -- some lack id (use UPDATE alias) or request_id (fall back to TTL-only sweep).
  SELECT EXISTS(
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = (SELECT relname FROM pg_class WHERE oid = p_table)
      AND column_name = 'request_id'
  ) INTO has_request_id;
  IF has_request_id THEN
    EXECUTE format(
      'UPDATE %1$s p SET resolved_at = now()
       WHERE p.resolved_at IS NULL
         AND p.fired_at < now() - interval %2$L
         AND NOT EXISTS (SELECT 1 FROM net._http_response h WHERE h.id = p.request_id)',
      p_table, (p_ttl_hours || ' hours')
    );
  ELSE
    EXECUTE format(
      'UPDATE %1$s p SET resolved_at = now()
       WHERE p.resolved_at IS NULL
         AND p.fired_at < now() - interval %2$L',
      p_table, (p_ttl_hours || ' hours')
    );
  END IF;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

COMMENT ON FUNCTION sweep_expired_pg_net_pending(regclass, int) IS
  'Marks *_pending rows terminally-resolved when older than TTL hours and net._http_response has been GCd. Per-table caller; use sweep_all_expired_pg_net_pending for the orchestrator.';

CREATE OR REPLACE FUNCTION sweep_all_expired_pg_net_pending(p_ttl_hours int DEFAULT 12)
RETURNS TABLE(queue text, swept int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE r record;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sweep_all_expired_pg_net_pending: caller % not authorized', current_user;
  END IF;
  FOR r IN
    SELECT t.tbl FROM (VALUES
      ('nws_alert_pending'),
      ('sg_seller_pending'),
      ('sg_event_backfill_pending'),
      ('sg_listings_pending'),
      ('espn_scoreboard_pending'),
      ('espn_tournament_pending'),
      ('evo_orders_pending'),
      ('evo_event_backfill_pending'),
      ('performer_wiki_pending'),
      ('reddit_pending'),
      ('weather_forecast_pending'),
      ('venue_geocode_pending'),
      ('venue_nws_points_pending'),
      ('tournament_category_pending'),
      ('tournament_search_pending'),
      ('fred_pending')
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
END $$;

COMMENT ON FUNCTION sweep_all_expired_pg_net_pending(int) IS
  'Orchestrator: sweeps expired pg_net pending rows across all 16 known *_pending tables (skips non-existent). Returns per-queue counts. Used by sweep_expired_pg_net_pending_hourly cron.';

GRANT EXECUTE ON FUNCTION sweep_expired_pg_net_pending(regclass, int) TO service_role;
GRANT EXECUTE ON FUNCTION sweep_all_expired_pg_net_pending(int) TO service_role;

-- Schedule hourly at :17 (offset from the queue/process cron windows that fire at :00/:05/:10/:30)
SELECT cron.schedule(
  'sweep_expired_pg_net_pending_hourly',
  '17 * * * *',
  $$ SELECT sweep_all_expired_pg_net_pending(12); $$
);
