-- Migration 20260901043749 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "resume_event_mapping_crons_second" (version 20260901043749) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

DO $$
DECLARE
  v_job  text;
  v_jobs text[] := ARRAY[
    'match_listings_to_sg_30min',
    'pm_match_15min',
    'aq_maps_backfill_daily',
    'match_tournaments_daily',
    'td_gt_tm_enroll_from_match_hourly',
    'sg_to_tevo_search_bridge_30min',
    'axs_to_tevo_search_bridge_13h'
  ];
  v_missing text[] := ARRAY[]::text[];
BEGIN
  FOREACH v_job IN ARRAY v_jobs LOOP
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_job) THEN
      v_missing := v_missing || v_job;
    END IF;
  END LOOP;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'resume aborted: job(s) % not present in cron.job', v_missing;
  END IF;

  FOREACH v_job IN ARRAY v_jobs LOOP
    PERFORM cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname = v_job),
                           active := true);
  END LOOP;
END $$;

DO $$
DECLARE v_bad int;
BEGIN
  SELECT count(*) INTO v_bad FROM cron.job
   WHERE active
     AND jobname IN ('td_match_fill_enqueue','td_match_drain','td_match_apply_cron',
                     'auto_match_sg_canonical_v3_hourly','sg-match-map-tick',
                     'td_sg_discover_daily','td_sg_discover_drain_daily');
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'resume post-condition failed: % prohibited job(s) are active', v_bad;
  END IF;
END $$;
;
