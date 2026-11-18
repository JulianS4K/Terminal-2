-- Migration 20260901052916 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "a1_schedule_s4k_orders_poll" (version 20260901052916) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

SELECT cron.schedule(
  's4k_orders_queue_hourly',
  '26 * * * *',
  $cron$DO $b$
BEGIN
  IF NOT public.cron_should_fire('s4k_orders_queue_hourly') THEN RETURN; END IF;
  PERFORM public.s4k_orders_queue();
END $b$;$cron$
);

SELECT cron.schedule(
  's4k_orders_drain_10min',
  '3-59/10 * * * *',
  $cron$DO $b$
BEGIN
  IF NOT public.cron_should_fire('s4k_orders_drain_10min') THEN RETURN; END IF;
  PERFORM public.s4k_orders_drain();
END $b$;$cron$
);

DO $$
DECLARE v_missing int;
BEGIN
  SELECT count(*) INTO v_missing FROM (VALUES
    ('s4k_orders_queue_hourly'),('s4k_orders_drain_10min')) w(j)
   WHERE NOT EXISTS (SELECT 1 FROM cron.job c WHERE c.jobname = w.j AND c.active);
  IF v_missing > 0 THEN
    RAISE EXCEPTION 's4k poll post-condition: % job(s) not active', v_missing;
  END IF;
END $$;
;
