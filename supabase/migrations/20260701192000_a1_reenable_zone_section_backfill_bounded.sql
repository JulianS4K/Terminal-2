-- ============================================================================
-- Migration 20260701192000 — re-enable zone+section metrics backfill (bounded) for D0
--
-- Lane:     A1
-- Touches:  cron job 'zone-backfill-isolated-10min' (command + active). No function change.
-- Pre-reqs: backfill_stale_zone_metrics (bounded, mig 20260701190000), cron_should_fire.
--
-- WHY (operator 2026-07-01 "make EVO near-perfect: pull listings + generate metrics for D0"):
--   The D0 terminal event page reads precomputed zone_metrics + section_metrics (per-zone /
--   per-section price + inventory breakdown). Both are produced ONLY by backfill_stale_zone_metrics
--   (it calls compute_event_zone_metrics AND compute_event_section_metrics per event). That cron
--   ('zone-backfill-isolated-10min') was DISABLED as a wedge risk, so zone/section metrics went
--   stale (~30 min+ lag, 0 refreshes in 10 min) while event-level event_metrics stayed real-time.
--
--   Now SAFE to re-enable: backfill_stale_zone_metrics carries a 90s loop wall-clock budget
--   (mig 20260701190000); the cron command uses the effective SET-prefix statement_timeout (verified
--   on this DB to hard-cap nested calls, unlike the no-op SET LOCAL); the durable scheduler watchdog
--   (mig 20260701182336) is the backstop. Batch raised 3 -> 20 (the fn orders by freshest-listings-but-
--   stalest-zones, i.e. active events first) + adds the cron_should_fire gate + lock_timeout.
--
--   NOTE: zone/section compute is heavier than event_metrics (per-event PERCENTILE_CONT), so it stays
--   a rolling stalest-first backfill (~120 events/hr), not per-pull-real-time. Event-level metrics
--   remain real-time; zone/section trend toward fresh for active events. Deeper option (cheapen
--   compute_event_zone_metrics' generate_series(1,quantity) expansion) deferred.
--
-- Idempotent: cron.alter_job by name. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

DO $do$
DECLARE v_jobid int;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname='zone-backfill-isolated-10min';
  PERFORM cron.alter_job(
    job_id  := v_jobid,
    command := $cmd$SET statement_timeout='90s'; SET lock_timeout='10s'; SELECT public.backfill_stale_zone_metrics(20) WHERE public.cron_should_fire('zone-backfill-isolated-10min');$cmd$,
    active  := true
  );
END $do$;
