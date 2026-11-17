-- Migration 20260901045159 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_align_cron_fleet_to_evo_sg_gotickets_scope" (version 20260901045159) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

DO $$
DECLARE v_job text; v_jobs text[] := ARRAY[
  'gt_catalog_sync_daily','gt_catalog_drain_daily',
  'gt_map_events_wide_daily','gotickets_match_us_6h'];
BEGIN
  FOREACH v_job IN ARRAY v_jobs LOOP
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_job) THEN
      RAISE EXCEPTION 'scope-align aborted: job % not present', v_job;
    END IF;
    PERFORM cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname = v_job), active := true);
  END LOOP;
END $$;

DO $$
DECLARE v_job text; v_jobs text[] := ARRAY[
  'axs_to_tevo_search_bridge_13h','pm_match_15min',
  'match_tournaments_daily','td_gt_tm_enroll_from_match_hourly'];
BEGIN
  FOREACH v_job IN ARRAY v_jobs LOOP
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_job) THEN
      RAISE EXCEPTION 'scope-align aborted: job % not present', v_job;
    END IF;
    PERFORM cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname = v_job), active := false);
  END LOOP;
END $$;

SELECT cron.schedule(
  'evo_map_gotickets_daily',
  '10 9 * * *',
  $cron$DO $b$
BEGIN
  IF NOT public.cron_should_fire('evo_map_gotickets_daily') THEN RETURN; END IF;
  PERFORM public.evo_map_events_to_gotickets(5000, true);
END $b$;$cron$
);

DO $$
DECLARE v_missing int; v_extra int;
BEGIN
  SELECT count(*) INTO v_missing FROM (VALUES
    ('sg_to_tevo_search_bridge_30min'),('match_listings_to_sg_30min'),('aq_maps_backfill_daily'),
    ('gt_catalog_sync_daily'),('gt_catalog_drain_daily'),('gt_map_events_wide_daily'),
    ('gotickets_match_us_6h'),('evo_map_gotickets_daily')) w(j)
   WHERE NOT EXISTS (SELECT 1 FROM cron.job c WHERE c.jobname = w.j AND c.active);
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'scope-align post-condition: % in-scope job(s) not active', v_missing;
  END IF;

  SELECT count(*) INTO v_extra FROM cron.job
   WHERE active AND jobname IN (
     'axs_to_tevo_search_bridge_13h','pm_match_15min','match_tournaments_daily',
     'td_gt_tm_enroll_from_match_hourly','td_match_fill_enqueue','td_match_drain',
     'td_match_apply_cron','auto_match_sg_canonical_v3_hourly','sg-match-map-tick',
     'td_sg_discover_daily','td_sg_discover_drain_daily');
  IF v_extra > 0 THEN
    RAISE EXCEPTION 'scope-align post-condition: % off-scope/prohibited job(s) active', v_extra;
  END IF;
END $$;
;
