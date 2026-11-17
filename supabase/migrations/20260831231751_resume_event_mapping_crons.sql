-- Migration 20260831231751 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "resume_event_mapping_crons" (version 20260831231751) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


DO $mig$
DECLARE
  v_target text[] := ARRAY[
    'match_listings_to_sg_30min',
    'pm_match_15min',
    'aq_maps_backfill_daily',
    'match_tournaments_daily',
    'td_gt_tm_enroll_from_match_hourly',
    'sg_to_tevo_search_bridge_30min',
    'axs_to_tevo_search_bridge_13h'
  ];
  v_name    text;
  v_resumed int := 0;
  v_missing text[] := '{}';
BEGIN
  FOREACH v_name IN ARRAY v_target LOOP
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_name) THEN
      v_missing := v_missing || v_name;
      CONTINUE;
    END IF;
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_name AND active) THEN
      CONTINUE;
    END IF;
    PERFORM cron.alter_job(
      (SELECT jobid FROM cron.job WHERE jobname = v_name), active := true);
    v_resumed := v_resumed + 1;
  END LOOP;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'resume_event_mapping_crons: job(s) not found: %',
      array_to_string(v_missing, ', ');
  END IF;

  RAISE NOTICE 'resume_event_mapping_crons: % job(s) resumed', v_resumed;
END $mig$;

DO $chk$
DECLARE v_off int;
BEGIN
  SELECT count(*) INTO v_off FROM cron.job
   WHERE jobname IN ('match_listings_to_sg_30min','pm_match_15min',
                     'aq_maps_backfill_daily','match_tournaments_daily',
                     'td_gt_tm_enroll_from_match_hourly',
                     'sg_to_tevo_search_bridge_30min','axs_to_tevo_search_bridge_13h')
     AND NOT active;
  IF v_off > 0 THEN
    RAISE EXCEPTION 'resume_event_mapping_crons: % targeted job(s) still inactive', v_off;
  END IF;
END $chk$;

DO $guard$
DECLARE v_on text[];
BEGIN
  SELECT array_agg(jobname) INTO v_on FROM cron.job
   WHERE jobname IN ('td_match_fill_enqueue','td_match_drain','td_match_apply_cron',
                     'auto_match_sg_canonical_v3_hourly')
     AND active;
  IF v_on IS NOT NULL THEN
    RAISE EXCEPTION 'resume_event_mapping_crons: § 3 forbids these being active: %',
      array_to_string(v_on, ', ');
  END IF;
END $guard$;
;
