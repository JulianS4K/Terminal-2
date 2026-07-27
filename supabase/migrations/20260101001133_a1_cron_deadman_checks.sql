-- ============================================================================
-- Migration 20260701235000 — cron deadman checks on the health dashboard
--
-- Lane:     A1
-- Touches:  new fn public.record_cron_deadman(); cron 'health_monitor_5min' command (third PERFORM).
-- Pre-reqs: health_check_history; 20260701221500 (source-freshness monitor, same pattern).
--
-- WHY (operator 2026-07-01 fleet analysis — "what can we add"): the 2026-07-01 scheduler wedge
-- silently SWALLOWED scheduled runs — discovery_gap_refresh and espn-rosters-daily each missed a
-- day, event_snapshot_morning missed two, and nothing surfaced it (a job that never runs produces
-- no failure rows). Every 5 min this compares hours-since-last-SUCCESSFUL-run against per-job
-- warn/fail gaps for a curated list of daily/12h jobs and records a 'cron_deadman' check row —
-- rendered on the D0 health page with uptime %, tripping the overall banner on a missed day.
-- Job inactive/unscheduled -> 'off' (listings_deltas_backfill_overnight self-unschedules when
-- its backlog drains — 'off' is its success terminal state).
--
-- First live snapshot (23:4x): morning snapshot 58.3h FAIL, movers_agg 52.5h FAIL, sg_lifetime
-- 67.7h FAIL, listings_deltas never-succeeded FAIL, gap-refresh + rosters-daily 39h WARN —
-- an accurate retro-view of the wedge-day damage; all expected to self-clear overnight.
--
-- NOTE (same analysis): venue_pull_process_weekly calling tournament_pull_process() is NOT a bug —
-- venue_pull_queue enqueues into the shared tournament_category_pending with category_id =
-- -tevo_venue_id; the "tournament" processor drains both. Misleading name only.
--
-- Idempotent: CREATE OR REPLACE + cron.alter_job by name; seed INSERT re-runs harmlessly.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

CREATE OR REPLACE FUNCTION public.record_cron_deadman()
RETURNS integer
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  WITH watch(jobname, warn_h, fail_h) AS (VALUES
    ('sg_lifetime_sales_daily',            26.0, 50.0),
    ('listings_deltas_backfill_overnight', 26.0, 50.0),
    ('refresh_movers_agg',                 14.0, 26.0),
    ('discovery_gap_refresh',              26.0, 50.0),
    ('event_snapshot_morning',             26.0, 50.0),
    ('event_snapshot_midday',              26.0, 50.0),
    ('event_snapshot_evening',             26.0, 50.0),
    ('espn-rosters-daily',                 26.0, 50.0)
  ),
  state AS (
    SELECT w.jobname, w.warn_h, w.fail_h,
           j.jobid, COALESCE(j.active, false) AS active,
           (SELECT max(d.start_time) FROM cron.job_run_details d
             WHERE d.jobid = j.jobid AND d.status = 'succeeded') AS last_ok
    FROM watch w LEFT JOIN cron.job j ON j.jobname = w.jobname
  )
  INSERT INTO health_check_history (captured_at, check_class, check_name, status, metric, detail)
  SELECT now(), 'cron_deadman', s.jobname,
         CASE
           WHEN s.jobid IS NULL OR NOT s.active THEN 'off'
           WHEN s.last_ok IS NULL THEN 'fail'
           WHEN now() - s.last_ok < make_interval(hours => s.warn_h::int) THEN 'ok'
           WHEN now() - s.last_ok < make_interval(hours => s.fail_h::int) THEN 'warn'
           ELSE 'fail'
         END,
         round((extract(epoch FROM now() - s.last_ok)/3600.0)::numeric, 1),
         'last success ' || COALESCE(to_char(s.last_ok, 'MM-DD HH24:MI'), 'never')
           || ' · gap ' || COALESCE(round((extract(epoch FROM now()-s.last_ok)/3600.0)::numeric,1)::text,'—')
           || 'h · SLA warn ' || s.warn_h::int || 'h / fail ' || s.fail_h::int || 'h'
           || CASE WHEN s.jobid IS NULL OR NOT s.active THEN ' · job OFF/unscheduled' ELSE '' END
  FROM state s;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

DO $do$
BEGIN
  PERFORM cron.alter_job(
    (SELECT jobid FROM cron.job WHERE jobname='health_monitor_5min'),
    command := $cmd$ DO $b$ BEGIN IF NOT public.cron_should_fire('health_monitor_5min') THEN RETURN; END IF; PERFORM public.health_tick(); PERFORM public.record_source_freshness(); PERFORM public.record_cron_deadman(); END $b$; $cmd$);
END $do$;

SELECT public.record_cron_deadman();
