-- Migration 20260901051610 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "resume_evo_gotickets_polling" (version 20260901051610) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

DO $$
DECLARE
  v_job text;
  v_jobs text[] := ARRAY[
    'evo_listings_poll_2min',
    'sweep_tevo_ticket_groups_cache',
    'aq_to_tevo_search_bridge_13h',
    'resolve-aq-tevo-from-sources-hourly',
    'gt_listings_poll_2min',
    'gt_ingest_drain_1min',
    'gt_map_events_hourly'
  ];
BEGIN
  FOREACH v_job IN ARRAY v_jobs LOOP
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_job) THEN
      RAISE EXCEPTION 'resume aborted: job % not present in cron.job', v_job;
    END IF;
    PERFORM cron.alter_job(job_id := (SELECT jobid FROM cron.job WHERE jobname = v_job), active := true);
  END LOOP;
END $$;

DO $$
DECLARE v_missing int; v_bad int;
BEGIN
  SELECT count(*) INTO v_missing FROM (VALUES
    ('evo_discover_new_events'),('evo_listings_poll_2min'),('tevo_blindspot_discovery_daily'),
    ('aq_to_tevo_search_bridge_13h'),('aq_reschedule_sync_from_tevo_30min'),
    ('resolve-aq-tevo-from-sources-hourly'),('sweep_tevo_ticket_groups_cache'),
    ('gt_catalog_sync_daily'),('gt_catalog_drain_daily'),('gt_listings_poll_2min'),
    ('gt_ingest_drain_1min'),('gt_map_events_hourly'),('gt_map_events_wide_daily'),
    ('gotickets_match_us_6h')) w(j)
   WHERE NOT EXISTS (SELECT 1 FROM cron.job c WHERE c.jobname = w.j AND c.active);
  IF v_missing > 0 THEN
    RAISE EXCEPTION 'resume post-condition: % EVO/GT job(s) not active', v_missing;
  END IF;

  SELECT count(*) INTO v_bad FROM cron.job
   WHERE active AND jobname IN (
     'td_match_fill_enqueue','td_match_drain','td_match_apply_cron',
     'auto_match_sg_canonical_v3_hourly','sg-match-map-tick',
     'td_sg_discover_daily','td_sg_discover_drain_daily',
     'td_gt_discover','td_gt_discover_drain');
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'resume post-condition: % prohibited job(s) active', v_bad;
  END IF;
END $$;
;
