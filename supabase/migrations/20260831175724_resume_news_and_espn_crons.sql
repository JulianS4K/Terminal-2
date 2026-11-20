-- Migration 20260831175724 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "resume_news_and_espn_crons" (version 20260831175724) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

-- Migration 20260831150000 — resume all news + all ESPN crons
-- Full rationale + notes: supabase/migrations/20260831150000_resume_news_and_espn_crons.sql
DO $resume_news_espn$
DECLARE
  v_restore text[] := ARRAY[
    'espn-news-5min','espn-live-score-poll','espn-gameday-10min','espn-gamelog-10min',
    'espn-transactions-5min','espn-roster-10min','espn-rosters-daily',
    'espn-rosters-new-leagues-daily','espn-rosters-rotate','espn-stats-daily',
    'espn-team-daily','espn-attendance-daily','espn-mma-daily','espn-racing-daily',
    'espn_injuries_sweep_daily','espn_scoreboard_queue_4h','espn_scoreboard_process_5min',
    'espn_tournament_queue_weekly','espn_tournament_process_after_queue',
    'crawl-espn-team-assets-3min','match_events_to_espn_10min',
    'x_news_queue_1min','x_news_process_1min','reddit_news_sweep_30min',
    'wa_news_queue_10min','wa_news_process_5min'
  ];
  -- ACTIVATION (were already inactive before the pause), not restoration:
  v_activate text[] := ARRAY['reddit_news_queue_1min','reddit_news_process_1min'];
  v_names    text[] := v_restore || v_activate;
  r          record;
  v_done     int := 0;
  v_missing  text[];
BEGIN
  SELECT array_agg(n) INTO v_missing
    FROM unnest(v_names) n
   WHERE NOT EXISTS (SELECT 1 FROM cron.job j WHERE j.jobname = n);

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'resume_news_espn: unknown jobname(s) %', v_missing;
  END IF;

  FOR r IN SELECT jobid FROM cron.job WHERE jobname = ANY(v_names) AND NOT active
  LOOP
    PERFORM cron.alter_job(job_id := r.jobid, active := true);
    v_done := v_done + 1;
  END LOOP;

  RAISE NOTICE 'resume_news_espn: resumed % of % listed jobs', v_done, array_length(v_names, 1);
END
$resume_news_espn$;
;
