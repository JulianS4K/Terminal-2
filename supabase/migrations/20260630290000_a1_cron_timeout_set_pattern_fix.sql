-- ============================================================================
-- Migration 20260630290000 — cron statement_timeout: use the SET-then-SELECT pattern
--
-- Lane:     A1
-- Touches:  cron commands event_snapshot_{morning,midday,evening}, compute_alerts_tick_15min.
-- Pre-reqs: 20260630280000 (compute_alerts_tick MV repoint), compute_event_listing_snapshot, cron_should_fire.
--
-- WHY: 20260630280000 tried to raise these jobs' statement_timeout via `DO $$ … SET LOCAL
-- statement_timeout=… ; PERFORM heavy() … $$`. That is a NO-OP: statement_timeout is armed when the
-- top-level statement (the whole DO block) begins, and `SET LOCAL` inside does NOT re-arm the timer for
-- that same running statement — so the job stayed bound by the 120s default (observed: compute_alerts
-- failing at exactly 120s despite a '5min' SET LOCAL).
--   Correct pattern: a standalone `SET statement_timeout=…` as its OWN top-level statement, followed by a
-- SEPARATE statement, DOES apply to the next statement (verified: `SET statement_timeout='2s'; pg_sleep(4)`
-- is cancelled at 2s). So each cron command becomes:
--     SET statement_timeout='<budget>'; SELECT <fn>() WHERE public.cron_should_fire('<job>');
-- The WHERE-guard preserves the cron_should_fire gate without a DO wrapper (fn not evaluated when the
-- guard is false — zero qualifying rows).
--
-- Budgets: event_snapshot_* = 8min (daily, slot-hold acceptable); compute_alerts_tick_15min = 5min
-- (15-min cadence; now also reads mv_event_price_vol per 20260630280000, so should finish well under it).
--
-- Idempotent (cron.alter_job by name). Re-apply is a no-op.
-- ============================================================================

DO $do$
DECLARE rec RECORD; slot text;
BEGIN
  FOR rec IN SELECT jobid, jobname FROM cron.job
             WHERE jobname IN ('event_snapshot_morning','event_snapshot_midday','event_snapshot_evening')
  LOOP
    slot := replace(rec.jobname, 'event_snapshot_', '');
    PERFORM cron.alter_job(
      job_id  := rec.jobid,
      command := format(
        $cmd$SET statement_timeout='8min'; SELECT public.compute_event_listing_snapshot(%L) WHERE public.cron_should_fire(%L);$cmd$,
        slot, rec.jobname)
    );
  END LOOP;

  PERFORM cron.alter_job(
    job_id  := (SELECT jobid FROM cron.job WHERE jobname='compute_alerts_tick_15min'),
    command := $cmd$SET statement_timeout='5min'; SELECT public.compute_alerts_tick() WHERE public.cron_should_fire('compute_alerts_tick_15min');$cmd$
  );
END $do$;
