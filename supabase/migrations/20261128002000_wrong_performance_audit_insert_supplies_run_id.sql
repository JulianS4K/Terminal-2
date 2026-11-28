-- HOTFIX 2 of 2. The wrong_performance audit insert added by mig 20261127230000 omits run_id,
-- which is NOT NULL on axs_watch_audit. This is the FIRST of the two defects chronologically:
-- the first failing ack appears at ~23:38Z, when 20261127230000 was applied; the action CHECK
-- violation from 20261127240000 followed at ~23:40Z and made it total.
--
-- Combined effect: AXS reads degraded from 23:38Z and stopped completely from 00:00Z to
-- 00:28Z, 29 minutes, 204 events overdue at the trough. No data was lost or corrupted -- the
-- settle is atomic, so a failed ack rolled back whole and the read was simply re-queued.
--
-- I hit this same NOT NULL error on a manual insert earlier in the session, fixed it there,
-- and failed to carry the fix into the migration.

DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
  old_ins CONSTANT text :=
    '      INSERT INTO public.axs_watch_audit (action, axs_event_id, venue, note)' || E'\n' ||
    '      VALUES (''wrong_performance'', p_event_id,';
  new_ins CONSTANT text :=
    '      INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)' || E'\n' ||
    '      VALUES (gen_random_uuid(), ''wrong_performance'', p_event_id,';
  n int;
BEGIN
  n := (length(src) - length(replace(src, old_ins, ''))) / length(old_ins);
  IF n <> 1 THEN
    RAISE EXCEPTION 'wrong_performance insert anchor matched % times, expected 1', n;
  END IF;
  EXECUTE replace(src, old_ins, new_ins);
END $surgery$;

DO $verify$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
BEGIN
  IF position('(run_id, action, axs_event_id, venue, note)' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the wrong_performance insert still omits run_id';
  END IF;
  IF position('INSERT INTO public.axs_watch_audit (action,' in src) > 0 THEN
    RAISE EXCEPTION 'read-back: an audit insert without run_id remains in the settle';
  END IF;
  INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
  VALUES (gen_random_uuid(), 'wrong_performance', '__selftest2__', NULL, 'self-test'),
         (gen_random_uuid(), 'non_transferable',  '__selftest2__', NULL, 'self-test');
  DELETE FROM public.axs_watch_audit WHERE axs_event_id = '__selftest2__';
END $verify$;
