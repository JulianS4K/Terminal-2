-- Migration 20260901122152 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "a1_resume_espn_and_seatdata_crons" (version 20260901122152) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

DO $$
DECLARE
  v_job text;
  v_jobs text[] := ARRAY[
    -- ESPN (20)
    'crawl-espn-team-assets-3min','espn_injuries_sweep_daily','espn_scoreboard_process_5min',
    'espn_scoreboard_queue_4h','espn_tournament_process_after_queue','espn_tournament_queue_weekly',
    'espn-attendance-daily','espn-gameday-10min','espn-gamelog-10min','espn-live-score-poll',
    'espn-mma-daily','espn-news-5min','espn-racing-daily','espn-roster-10min','espn-rosters-daily',
    'espn-rosters-new-leagues-daily','espn-rosters-rotate','espn-stats-daily','espn-team-daily',
    'espn-transactions-5min',
    -- SeatData (2)
    'seatdata_poll_twice_daily','resolve-aq-seatdata-link-hourly'
  ];
  v_n int := 0;
BEGIN
  FOREACH v_job IN ARRAY v_jobs LOOP
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_job) THEN
      RAISE EXCEPTION 'resume aborted: job % not present in cron.job', v_job;
    END IF;
    PERFORM cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname = v_job), active := true);
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'resumed % ESPN/SeatData jobs', v_n;
END $$;

DO $$
DECLARE v_missing int; v_bad int;
BEGIN
  SELECT count(*) INTO v_missing FROM cron.job
   WHERE NOT active
     AND (jobname ~* '^(espn|crawl-espn)' OR jobname IN ('seatdata_poll_twice_daily','resolve-aq-seatdata-link-hourly'));
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'resume post-condition: % ESPN/SeatData job(s) still inactive', v_missing;
  END IF;

  SELECT count(*) INTO v_bad FROM cron.job
   WHERE active AND jobname IN (
     'td_match_fill_enqueue','td_match_drain','td_match_apply_cron',
     'auto_match_sg_canonical_v3_hourly','sg-match-map-tick',
     'td_sg_discover_daily','td_sg_discover_drain_daily');
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'resume post-condition: % prohibited job(s) active', v_bad;
  END IF;
END $$;
;
