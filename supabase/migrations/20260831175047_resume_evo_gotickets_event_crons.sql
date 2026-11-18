-- Migration 20260831175047 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "resume_evo_gotickets_event_crons" (version 20260831175047) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

-- Migration 20260831130000 — resume EVO/TEvo + GoTickets event-data crons
-- Full rationale + EXCLUDED list: supabase/migrations/20260831130000_resume_evo_gotickets_event_crons.sql
DO $resume_evo_gt$
DECLARE
  v_names text[] := ARRAY[
    'evo_discover_new_events',
    'evo_listings_poll_2min',
    'tevo_blindspot_discovery_daily',
    'aq_to_tevo_search_bridge_13h',
    'aq_reschedule_sync_from_tevo_30min',
    'resolve-aq-tevo-from-sources-hourly',
    'sweep_tevo_ticket_groups_cache',
    'gt_catalog_sync_daily',
    'gt_catalog_drain_daily',
    'gt_listings_poll_2min',
    'gt_ingest_drain_1min',
    'gt_map_events_hourly',
    'gt_map_events_wide_daily',
    'gotickets_match_us_6h'
  ];
  r          record;
  v_resumed  int := 0;
  v_missing  text[];
  v_expected int := array_length(v_names, 1);
BEGIN
  SELECT array_agg(n) INTO v_missing
    FROM unnest(v_names) n
   WHERE NOT EXISTS (SELECT 1 FROM cron.job j WHERE j.jobname = n);

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'resume_evo_gt: unknown jobname(s) %', v_missing;
  END IF;

  FOR r IN
    SELECT jobid FROM cron.job WHERE jobname = ANY(v_names) AND NOT active
  LOOP
    PERFORM cron.alter_job(job_id := r.jobid, active := true);
    v_resumed := v_resumed + 1;
  END LOOP;

  RAISE NOTICE 'resume_evo_gt: resumed % of % listed jobs', v_resumed, v_expected;
END
$resume_evo_gt$;
;
