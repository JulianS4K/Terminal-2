-- ============================================================================
-- Migration 20260701182336 — scheduler watchdog: SECURITY DEFINER kill RPC
--
-- Lane:     A1
-- Touches:  new fn public.scheduler_watchdog_kill_stale_backends(int,int); grants.
-- Pre-reqs: cron.job_run_details (pg_cron); pg_stat_activity.
--
-- WHY (scheduler-wedge self-heal, operator 2026-07-01):
--   With cron.use_background_workers=off, ONE cron job that runs unbounded holds
--   an open transaction that blocks cron_should_fire()/the launcher -> the WHOLE
--   pg_cron scheduler freezes (observed 3x on 2026-07-01, ~13h degraded). Neither
--   a pg_cron watchdog (freezes with everything) nor a Claude-session cron (dies on
--   reconnect) can self-heal it. The durable watchdog is an asyncio loop in the
--   always-on FastAPI web service (server.py _scheduler_watchdog_loop), which is the
--   one place that survives a DB-side scheduler freeze. This RPC is its DB-side arm.
--
--   The RPC is the single source of truth for "is the scheduler wedged":
--     - reads max(start_time) FROM cron.job_run_details;
--     - if fresh (< greatest(p_stale_minutes,2) old) returns {wedged:false} — no-op;
--     - else terminates every state='active' client backend whose query_start is
--       older than greatest(p_min_active_seconds,60)s (excluding itself + the
--       watchdog call), which frees the launcher, and returns the killed pids.
--
--   Security: service_role cannot call pg_terminate_backend directly, hence
--   SECURITY DEFINER + a current_user allowlist assert (postgres/service_role/
--   supabase_admin only) + REVOKE from public/anon/authenticated. search_path pinned.
--
-- Idempotent: CREATE OR REPLACE + idempotent REVOKE/GRANT. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

CREATE OR REPLACE FUNCTION public.scheduler_watchdog_kill_stale_backends(
    p_stale_minutes integer DEFAULT 6, p_min_active_seconds integer DEFAULT 300)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_killed int := 0; v_detail jsonb := '[]'::jsonb; v_last timestamptz;
BEGIN
  IF current_user NOT IN ('postgres','service_role','supabase_admin') THEN
    RAISE EXCEPTION 'scheduler_watchdog_kill_stale_backends: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  SELECT max(start_time) INTO v_last FROM cron.job_run_details;
  -- Guard: only act when the scheduler is actually frozen.
  IF v_last IS NOT NULL AND v_last > now() - make_interval(mins => greatest(p_stale_minutes, 2)) THEN
    RETURN jsonb_build_object('wedged', false, 'last_cron_run', v_last, 'killed', 0);
  END IF;

  FOR r IN
    SELECT pid, now() - query_start AS age, left(regexp_replace(query, '\s+', ' ', 'g'), 200) AS q
    FROM pg_stat_activity
    WHERE datname = current_database()
      AND state = 'active'
      AND pid <> pg_backend_pid()
      AND backend_type = 'client backend'
      AND query_start < now() - make_interval(secs => greatest(p_min_active_seconds, 60))
      AND query NOT ILIKE '%scheduler_watchdog%'      -- never target the watchdog / this call
  LOOP
    PERFORM pg_terminate_backend(r.pid);
    v_killed := v_killed + 1;
    v_detail := v_detail || jsonb_build_object('pid', r.pid,
                   'age_s', round(extract(epoch FROM r.age)), 'query', r.q);
  END LOOP;

  RETURN jsonb_build_object('wedged', true, 'last_cron_run', v_last, 'killed', v_killed, 'terminated', v_detail);
END $function$;

REVOKE ALL ON FUNCTION public.scheduler_watchdog_kill_stale_backends(int,int) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.scheduler_watchdog_kill_stale_backends(int,int) TO service_role;
