-- Migration 20261122024000 · level:platform · lane:A1 (operator-routed: "Investigate stalls and fix") · writes:build_venue_section_map_run,cron.job(394,638,167,415,636,690) · reads:venue_section_map_build_state,seatmap_manifest,events · pre:none
--
-- Stop the database from doing ~89 hours a day of work it then throws away.
--
-- What was found (2026-11-22, read-only):
--   The database is disk-bound (most active backends wait on IO:DataFileRead). Since Nov 17-18 the
--   heavy refresh jobs take longer than the 900 s statement timeout most of the time. A cancelled run
--   rolls back everything it did, including the 'fire' row cron_should_fire() wrote (PROJECT_BIBLE §3,
--   pg_cron row (e)), so the gate thinks the job has not run and pg_cron starts it again at its next
--   slot; a run due while one is still going is queued and starts as soon as it ends. These jobs
--   therefore run back to back, all day, and most of their reads are wasted:
--     job (last 24 h)                      finished  cancelled at 900 s
--     venue_section_map_refresh                  1        92
--     sg_classify_events_5min                   29        69
--     latest_event_metrics_refresh_5min         28        63
--     mv_event_price_vol_refresh                28        47
--     tevo_blindspot_mv_refresh                 26        34
--     axs_catalog_refresh_hourly                 4        19
--   Every other job waits behind them (n2s_pipeline_tick max 437 s, minute-boundary "job startup
--   timeout": pg_cron cannot open its connection within its start deadline).
--
-- 1. venue_section_map_refresh: no batch has been saved since 2026-11-21 07:05. The batch runs as ONE
--    transaction; the first pairs it picks (17 venue x platform pairs never tried, then venues 70748,
--    882 and 896 - 409 events, 29 layouts, ~165k EVO listing rows in 3 days) do not finish inside
--    900 s, the cancel rolls back the batch and its build_state stamps, and the next run picks the same
--    pairs. New procedure build_venue_section_map_run() does the same work (same candidate order, same
--    build_venue_section_map() call, same 45 s budget) but commits the gate decision first and each pair
--    on its own, stamping last_attempt_at BEFORE building it: a pair that is cancelled has still been
--    counted and goes to the back of the queue, and every pair before it is kept. Same pattern as
--    sub_finder_settle_each() (20261113260000), which pg_cron already runs as CALL every 15 s.
--    build_venue_section_map_batch() is left as it is (md5 6813a7bdda81a5debe042f2ee3ee4873).
-- 2. The five other jobs above: fewer, staggered slots, so at most one or two of them run at once and
--    each can finish. Today each finishes about once every 50 minutes; the new schedules ask for a run
--    every 30 minutes (axs_catalog_refresh every 3 hours), at different minutes. Only the schedule
--    changes; commands, cron_policy rows and job names stay. A job whose schedule is not the one this
--    migration expects is left alone (NOTICE).
--
-- VERIFY:
--   SELECT jobname, schedule, command FROM cron.job WHERE jobid IN (394, 638, 167, 415, 636, 690);
--   SELECT j.jobname, r.status, count(*), round(avg(extract(epoch FROM r.end_time - r.start_time)))
--     FROM cron.job_run_details r JOIN cron.job j USING (jobid)
--    WHERE j.jobid IN (394, 638, 167, 415, 636, 690) AND r.start_time > now() - interval '3 hours'
--    GROUP BY 1, 2 ORDER BY 1, 2;
--   SELECT max(last_attempt_at) FROM venue_section_map_build_state;   -- moves again after the next run
-- ROLLBACK:
--   SELECT cron.alter_job(jobid, command := $c$ DO $body$ BEGIN IF NOT public.cron_should_fire('venue_section_map_refresh') THEN RETURN; END IF; PERFORM public.build_venue_section_map_batch(25); END $body$; $c$)
--     FROM cron.job WHERE jobid = 394;
--   SELECT cron.alter_job(jobid, schedule := s) FROM cron.job JOIN (VALUES
--     ('sg_classify_events_5min', '1-59/5 * * * *'), ('latest_event_metrics_refresh_5min', '2-59/10 * * * *'),
--     ('mv_event_price_vol_refresh', '8-59/15 * * * *'), ('tevo_blindspot_mv_refresh', '9-59/10 * * * *'),
--     ('axs_catalog_refresh_hourly', '37 * * * *')) v(n, s) ON v.n = jobname;
--   DROP PROCEDURE public.build_venue_section_map_run(integer, interval, interval);

-- 1. The venue section map, committed pair by pair.
--    No SECURITY DEFINER and no SET clause: a procedure with either cannot COMMIT. pg_cron runs it as
--    postgres; nobody else may call it.
CREATE OR REPLACE PROCEDURE public.build_venue_section_map_run(
  p_batch  integer  DEFAULT 25,
  p_window interval DEFAULT '3 days',
  p_budget interval DEFAULT '45 seconds')
 LANGUAGE plpgsql
AS $proc$
DECLARE
  v_start  timestamptz := clock_timestamp();
  v_venues bigint[];
  v_plats  text[];
  v_rows   integer;
  i        integer;
BEGIN
  IF NOT public.cron_should_fire('venue_section_map_refresh') THEN RETURN; END IF;
  COMMIT;                     -- keep the 'fire' row even if this run is cancelled later

  -- same candidates and order as build_venue_section_map_batch(): pairs never tried first, then the
  -- oldest attempt
  SELECT array_agg(q.venue_id ORDER BY q.ord), array_agg(q.platform ORDER BY q.ord)
    INTO v_venues, v_plats
    FROM (
      SELECT c.venue_id, c.platform,
             row_number() OVER (ORDER BY st.last_attempt_at ASC NULLS FIRST, c.venue_id) AS ord
        FROM (SELECT v.venue_id, p.platform
                FROM (SELECT DISTINCT sm.venue_id FROM public.seatmap_manifest sm
                       WHERE sm.has_map AND EXISTS (SELECT 1 FROM public.events e WHERE e.venue_id = sm.venue_id)) v
               CROSS JOIN (VALUES ('evo'), ('sg'), ('tp'), ('vd'), ('sh'), ('gt'), ('tm')) p(platform)) c
        LEFT JOIN public.venue_section_map_build_state st
          ON st.tevo_venue_id = c.venue_id AND st.platform = c.platform
       ORDER BY st.last_attempt_at ASC NULLS FIRST, c.venue_id
       LIMIT p_batch) q;

  FOR i IN 1 .. coalesce(array_length(v_venues, 1), 0) LOOP
    EXIT WHEN clock_timestamp() - v_start > p_budget;
    -- count the attempt first, and commit it: a pair cancelled below goes to the back of the queue,
    -- with last_rows NULL (an attempt that did not finish), as a failed build already leaves it
    INSERT INTO public.venue_section_map_build_state AS s (tevo_venue_id, platform, last_attempt_at, last_rows)
    VALUES (v_venues[i], v_plats[i], clock_timestamp(), NULL)
    ON CONFLICT (tevo_venue_id, platform) DO UPDATE SET last_attempt_at = excluded.last_attempt_at, last_rows = NULL;
    COMMIT;
    BEGIN
      v_rows := public.build_venue_section_map(v_venues[i], v_plats[i], p_window);
    EXCEPTION WHEN OTHERS THEN
      v_rows := NULL;
      RAISE WARNING 'build_venue_section_map_run: skipped venue % platform %: %', v_venues[i], v_plats[i], SQLERRM;
    END;
    UPDATE public.venue_section_map_build_state SET last_rows = v_rows
     WHERE tevo_venue_id = v_venues[i] AND platform = v_plats[i];
    COMMIT;
  END LOOP;
END
$proc$;
REVOKE ALL ON PROCEDURE public.build_venue_section_map_run(integer, interval, interval) FROM PUBLIC, anon, authenticated;
COMMENT ON PROCEDURE public.build_venue_section_map_run(integer, interval, interval) IS
  'What venue_section_map_refresh runs: build_venue_section_map_batch() committed pair by pair, each attempt stamped before it is built, so one pair that outlasts the statement timeout no longer rolls back the batch and blocks the queue. 20261122024000.';

-- 2. Point the job at it, and give the heavy refreshers fewer, staggered slots.
DO $cron$
DECLARE
  r     record;
  v_cur text;
BEGIN
  IF to_regclass('cron.job') IS NULL THEN RETURN; END IF;                     -- no pg_cron here (local / CI)

  EXECUTE $q$
    SELECT cron.alter_job(jobid, command := 'CALL public.build_venue_section_map_run();')
      FROM cron.job WHERE jobname = 'venue_section_map_refresh'
  $q$;

  FOR r IN SELECT * FROM (VALUES
      ('sg_classify_events_5min',           '1-59/5 * * * *',  '1,31 * * * *'),
      ('latest_event_metrics_refresh_5min', '2-59/10 * * * *', '9,39 * * * *'),
      ('mv_event_price_vol_refresh',        '8-59/15 * * * *', '16,46 * * * *'),
      ('tevo_blindspot_mv_refresh',         '9-59/10 * * * *', '23,53 * * * *'),
      ('axs_catalog_refresh_hourly',        '37 * * * *',      '37 */3 * * *')) v(jobname, old_schedule, new_schedule)
  LOOP
    EXECUTE 'SELECT schedule FROM cron.job WHERE jobname = $1' INTO v_cur USING r.jobname;
    IF v_cur IS DISTINCT FROM r.old_schedule THEN
      RAISE NOTICE '%: schedule is %, expected %; left as it is', r.jobname, coalesce(v_cur, '(no job)'), r.old_schedule;
      CONTINUE;
    END IF;
    EXECUTE 'SELECT cron.alter_job(jobid, schedule := $2) FROM cron.job WHERE jobname = $1'
      USING r.jobname, r.new_schedule;
  END LOOP;
END
$cron$;
