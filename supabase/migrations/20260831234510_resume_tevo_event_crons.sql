-- Migration 20260831234510 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "resume_tevo_event_crons" (version 20260831234510) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration — resume the Ticket Evolution EVENT crons, at real cadence
--
-- Lane:     xref+macro
-- Touches:  cron.job (W, via cron.alter_job), cron_policy (W)
-- Pre-reqs: 20260831232704 (the full pause this partially reverses)
--
-- Operator directive: bring the Ticket Evolution event crons online per their
-- polling cadences. First staged resume after the 23:29 full pause; everything
-- else stays paused.
--
-- SCOPE — the TEvo EVENT-CATALOGUE set, not listings and not orders:
--   evo_discover_new_events             0 8 * * *      discovers new TEvo events
--   aq_reschedule_sync_from_tevo_30min  13,43 * * * *  syncs date/time reschedules
--   tevo_blindspot_discovery_daily      0 7 * * *      finds events we are blind to
--   evo_only_autotag_daily              45 8 * * *     tags evo_only events
--   tevo_blindspot_metrics_refresh_12h  0 6,18 * * *   blindspot metrics  (support)
--   tevo_blindspot_mv_refresh           7-59/10        blindspot matview  (support)
--
-- Deliberately excluded: evo_listings_poll_2min (listings), evo_orders_queue /
-- _process_30min (orders), sweep_tevo_ticket_groups_cache (listings cache), and
-- the mapping jobs (backfill/resolve/search bridges). Those are separate
-- pipelines and separate tests.
--
-- CADENCE FIX — why this migration also touches cron_policy
-- cron_should_fire() gates on a strict comparison:
--     (now - last_fire) < make_interval(mins => interval_min)  -> skip
-- Four of these six carry a min_interval EQUAL to their schedule period, so the
-- elapsed time between consecutive fires lands on the boundary and whether the
-- job runs depends on millisecond jitter. For a daily job firing at the same
-- wall-clock minute every day, elapsed is ~24h +/- tens of milliseconds -- an
-- effective coin flip each day. Resuming them unchanged would NOT give the
-- configured cadence, which is exactly what this test is meant to observe.
--
-- The interval is not what limits these jobs anyway -- daily_max_fires already
-- does (1/day for both discovery jobs, 2/day for the 12h refresh, 120 for the
-- matview). So the interval is given headroom and the real cap is untouched:
--     evo_discover_new_events             1440 -> 1380   (cap stays 1/day)
--     tevo_blindspot_discovery_daily      1440 -> 1380   (cap stays 1/day)
--     tevo_blindspot_metrics_refresh_12h   720 ->  690   (cap stays 2/day)
--     tevo_blindspot_mv_refresh  peak       10 ->    9   (cap stays 120/day)
-- Offpeak 30 on the matview is left alone -- there the 30 > 10 spacing is
-- deliberate throttling, not a collision.
--
-- This can only ever UNBLOCK a fire the cron schedule already permits; the
-- schedule remains the hard ceiling. evo_only_autotag_daily needs no change
-- (600 min interval vs a 24h schedule -- no collision).
-- ============================================================================

-- 1. Give the gate headroom so the configured cadence is the real cadence.
UPDATE public.cron_policy SET peak_min_interval_min = 1380, offpeak_min_interval_min = 1380
 WHERE jobname IN ('evo_discover_new_events','tevo_blindspot_discovery_daily');

UPDATE public.cron_policy SET peak_min_interval_min = 690, offpeak_min_interval_min = 690
 WHERE jobname = 'tevo_blindspot_metrics_refresh_12h';

UPDATE public.cron_policy SET peak_min_interval_min = 9
 WHERE jobname = 'tevo_blindspot_mv_refresh';

-- 2. Resume the set.
DO $mig$
DECLARE
  v_target text[] := ARRAY[
    'evo_discover_new_events',
    'aq_reschedule_sync_from_tevo_30min',
    'tevo_blindspot_discovery_daily',
    'evo_only_autotag_daily',
    'tevo_blindspot_metrics_refresh_12h',
    'tevo_blindspot_mv_refresh'
  ];
  v_name text; v_resumed int := 0; v_missing text[] := '{}';
BEGIN
  FOREACH v_name IN ARRAY v_target LOOP
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_name) THEN
      v_missing := v_missing || v_name; CONTINUE;
    END IF;
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_name AND active) THEN CONTINUE; END IF;
    PERFORM cron.alter_job(
      (SELECT jobid FROM cron.job WHERE jobname = v_name), active := true);
    v_resumed := v_resumed + 1;
  END LOOP;

  IF array_length(v_missing, 1) IS NOT NULL THEN
    RAISE EXCEPTION 'resume_tevo_event_crons: job(s) not found: %',
      array_to_string(v_missing, ', ');
  END IF;
  RAISE NOTICE 'resume_tevo_event_crons: % job(s) resumed', v_resumed;
END $mig$;

-- 3. Post-conditions.
DO $chk$
DECLARE v_off int; v_extra int;
BEGIN
  SELECT count(*) INTO v_off FROM cron.job
   WHERE jobname IN ('evo_discover_new_events','aq_reschedule_sync_from_tevo_30min',
                     'tevo_blindspot_discovery_daily','evo_only_autotag_daily',
                     'tevo_blindspot_metrics_refresh_12h','tevo_blindspot_mv_refresh')
     AND NOT active;
  IF v_off > 0 THEN
    RAISE EXCEPTION 'resume_tevo_event_crons: % targeted job(s) still inactive', v_off;
  END IF;

  -- nothing outside the intended set may have come back on
  SELECT count(*) INTO v_extra FROM cron.job
   WHERE active
     AND jobname NOT IN ('evo_discover_new_events','aq_reschedule_sync_from_tevo_30min',
                         'tevo_blindspot_discovery_daily','evo_only_autotag_daily',
                         'tevo_blindspot_metrics_refresh_12h','tevo_blindspot_mv_refresh');
  IF v_extra > 0 THEN
    RAISE EXCEPTION 'resume_tevo_event_crons: % unexpected job(s) active', v_extra;
  END IF;

  -- no resumed job may still sit on a schedule == interval collision
  IF EXISTS (SELECT 1 FROM public.cron_policy
              WHERE jobname = 'evo_discover_new_events' AND offpeak_min_interval_min >= 1440) THEN
    RAISE EXCEPTION 'resume_tevo_event_crons: cadence headroom not applied';
  END IF;
END $chk$;
;
