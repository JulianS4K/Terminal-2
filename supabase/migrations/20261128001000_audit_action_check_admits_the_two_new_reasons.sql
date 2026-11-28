-- HOTFIX 1 of 2 for an outage I caused. axs_watch_audit.action is CHECK-constrained to
-- ('add','retire','short'). Mig 20261127240000 inserts audit rows from inside
-- axs_watch_settle_one with action 'non_transferable', which the constraint rejects. The
-- exception left the settle, axs_queue_ack answered HTTP 400, the read was never acked, its
-- lane orphaned, the reaper requeued it, and the loop repeated.
--
-- I did not read the constraint before writing the insert. The manual retirement I ran by hand
-- earlier in the same session used action 'retire', which is allowed, so the defect stayed
-- hidden until the settle itself tried to write one.

ALTER TABLE public.axs_watch_audit DROP CONSTRAINT axs_watch_audit_action_check;
ALTER TABLE public.axs_watch_audit ADD CONSTRAINT axs_watch_audit_action_check
  CHECK (action = ANY (ARRAY['add','retire','short','wrong_performance','non_transferable']));

DO $verify$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid='public.axs_watch_audit'::regclass
                    AND conname='axs_watch_audit_action_check'
                    AND pg_get_constraintdef(oid) LIKE '%wrong_performance%'
                    AND pg_get_constraintdef(oid) LIKE '%non_transferable%') THEN
    RAISE EXCEPTION 'the audit action check was not widened';
  END IF;
  INSERT INTO public.axs_watch_audit (run_id, action, axs_event_id, venue, note)
  VALUES (gen_random_uuid(), 'wrong_performance', '__selftest__', NULL, 'constraint self-test'),
         (gen_random_uuid(), 'non_transferable',  '__selftest__', NULL, 'constraint self-test');
  DELETE FROM public.axs_watch_audit WHERE axs_event_id = '__selftest__';
END $verify$;
