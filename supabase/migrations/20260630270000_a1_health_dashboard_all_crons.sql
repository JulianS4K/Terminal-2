-- ============================================================================
-- Migration 20260630270000 — get_health_dashboard(): add full cron roster
--
-- Lane:     A1 (RPC consumed by the D0 health page)
-- Touches:  get_health_dashboard() (CREATE OR REPLACE — add a 'crons' key).
-- Pre-reqs: 20260617010000 (get_health_dashboard), cron.job + cron.job_run_details.
--
-- WHY (operator 2026-06-30 "all crons to health html"): the health dashboard only showed
-- release_health_check() snapshots; surface EVERY scheduled cron job (active + inactive) with its 24h
-- run health. Adds a 'crons' array — one row per cron.job — with schedule, active flag, 24h run/ok/fail
-- counts, pct_ok, latest_run, latest failure message, and a derived status:
--   off  = job inactive
--   idle = active but 0 runs in 24h (e.g. daily/weekly job that hasn't fired) — neutral, not an alarm
--   ok   = ran, zero failures
--   warn = some failures but >=90% ok
--   fail = <90% ok in 24h
-- Mirrors the existing v_cron_health rollup but covers inactive jobs too and ships inside the one gated
-- RPC the page already calls (no new anon surface). @s4kent.com gate + SECURITY DEFINER unchanged.
--
-- Idempotent (CREATE OR REPLACE). Re-apply is a no-op.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_health_dashboard()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_latest timestamptz; v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT max(captured_at) INTO v_latest FROM public.health_check_history;

  WITH latest AS (
    SELECT DISTINCT ON (check_class, check_name)
           check_class, check_name, status, metric, detail, captured_at
    FROM public.health_check_history
    ORDER BY check_class, check_name, captured_at DESC
  ),
  up24 AS (
    SELECT check_class, check_name,
           round(100.0 * count(*) FILTER (WHERE status IN ('ok','up')) / nullif(count(*),0), 2) AS ok_24h,
           count(*) AS samples_24h
    FROM public.health_check_history WHERE captured_at > now() - interval '24 hours'
    GROUP BY check_class, check_name
  ),
  up7 AS (
    SELECT check_class, check_name,
           round(100.0 * count(*) FILTER (WHERE status IN ('ok','up')) / nullif(count(*),0), 2) AS ok_7d
    FROM public.health_check_history WHERE captured_at > now() - interval '7 days'
    GROUP BY check_class, check_name
  ),
  merged AS (
    SELECT l.*, u.ok_24h, u.samples_24h, u7.ok_7d
    FROM latest l
    LEFT JOIN up24 u USING (check_class, check_name)
    LEFT JOIN up7  u7 USING (check_class, check_name)
  )
  SELECT jsonb_build_object(
    'generated_at',        now(),
    'latest_snapshot_at',  v_latest,
    'overall', (SELECT jsonb_build_object(
        'status', CASE WHEN count(*) FILTER (WHERE status IN ('fail','down')) > 0 THEN 'fail'
                       WHEN count(*) FILTER (WHERE status = 'warn') > 0           THEN 'warn'
                       ELSE 'ok' END,
        'checks_total', count(*),
        'failing',      count(*) FILTER (WHERE status IN ('fail','down')),
        'warning',      count(*) FILTER (WHERE status = 'warn'),
        'uptime_24h',   round(avg(ok_24h), 2),
        'uptime_7d',    round(avg(ok_7d), 2)
      ) FROM merged),
    'checks', (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY
                  CASE m.status WHEN 'fail' THEN 0 WHEN 'down' THEN 0 WHEN 'warn' THEN 1 ELSE 2 END,
                  m.check_class, m.check_name), '[]'::jsonb)
               FROM merged m WHERE m.check_class <> 'web'),
    'web', (SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.check_name), '[]'::jsonb)
            FROM merged m WHERE m.check_class = 'web'),
    'timeline', (SELECT coalesce(jsonb_agg(jsonb_build_object('t', captured_at, 'status', ov) ORDER BY captured_at), '[]'::jsonb)
                 FROM (
                   SELECT captured_at,
                          CASE WHEN count(*) FILTER (WHERE status IN ('fail','down')) > 0 THEN 'fail'
                               WHEN count(*) FILTER (WHERE status = 'warn') > 0           THEN 'warn'
                               ELSE 'ok' END AS ov
                   FROM public.health_check_history
                   WHERE captured_at > now() - interval '24 hours'
                   GROUP BY captured_at ORDER BY captured_at DESC LIMIT 288
                 ) tl),
    'crons', (SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY
                  CASE c.cron_status WHEN 'fail' THEN 0 WHEN 'warn' THEN 1 WHEN 'idle' THEN 2
                                     WHEN 'ok' THEN 3 ELSE 4 END,
                  c.jobname), '[]'::jsonb)
               FROM (
                 SELECT j.jobname, j.schedule, j.active,
                        count(d.runid)                                       AS runs_24h,
                        count(d.runid) FILTER (WHERE d.status='succeeded')   AS ok_24h,
                        count(d.runid) FILTER (WHERE d.status='failed')      AS fail_24h,
                        CASE WHEN count(d.runid) > 0
                             THEN round(100.0 * count(d.runid) FILTER (WHERE d.status='succeeded')
                                              / count(d.runid), 1) END       AS pct_ok,
                        max(d.start_time)                                    AS latest_run,
                        (SELECT d2.return_message FROM cron.job_run_details d2
                          WHERE d2.jobid = j.jobid AND d2.status='failed'
                            AND d2.start_time > now() - interval '24 hours'
                          ORDER BY d2.start_time DESC LIMIT 1)               AS latest_error,
                        CASE
                          WHEN NOT j.active THEN 'off'
                          WHEN count(d.runid) = 0 THEN 'idle'
                          WHEN count(d.runid) FILTER (WHERE d.status='failed') = 0 THEN 'ok'
                          WHEN round(100.0 * count(d.runid) FILTER (WHERE d.status='succeeded')
                                           / count(d.runid), 1) >= 90 THEN 'warn'
                          ELSE 'fail'
                        END                                                  AS cron_status
                 FROM cron.job j
                 LEFT JOIN cron.job_run_details d
                   ON d.jobid = j.jobid AND d.start_time > now() - interval '24 hours'
                 GROUP BY j.jobid, j.jobname, j.schedule, j.active
               ) c)
  ) INTO v_result;

  RETURN coalesce(v_result, jsonb_build_object('generated_at', now(), 'latest_snapshot_at', NULL,
                  'overall', NULL, 'checks', '[]'::jsonb, 'web', '[]'::jsonb, 'timeline', '[]'::jsonb,
                  'crons', '[]'::jsonb));
END $function$;
