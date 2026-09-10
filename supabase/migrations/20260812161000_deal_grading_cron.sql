-- Migration 20260812161000 · lane:D0/A1 (author) → applier (apply)
--   writes: deal_tracking_grade_daily cron
--   auth: cron runs evaluate_tracked_deals (service_role-guarded SECDEF) for every cohort
--
-- WHY (operator-directed 2026-08-12). Make the tracked-cohort grading self-running in-DB so the
-- grades accrue automatically as events mature — independent of any session/connector. Grades
-- every cohort in deal_tracking daily (12:00 UTC). The scheduled 2-week check-in session then just
-- READS the already-computed deal_tracking results.
--
-- ROLLBACK: SELECT cron.unschedule('deal_tracking_grade_daily');

SELECT cron.schedule('deal_tracking_grade_daily', '0 12 * * *', $cron$
  DO $c$
  DECLARE t text;
  BEGIN
    FOR t IN SELECT DISTINCT cohort_tag FROM public.deal_tracking LOOP
      PERFORM public.evaluate_tracked_deals(t);
    END LOOP;
  END $c$;
$cron$);