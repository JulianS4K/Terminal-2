-- Migration 20260515380000 · admin · Cluster B-2 fixes (orphan event backfill) · pre:20260515370000
-- 2 of 3 Cluster B-2 bugs fixed here. midnight-catchup-sweep deferred (needs deeper investigation).
--
-- BUG 1: orphan_event_backfill_process_15min — "query has no destination for result data"
--   Root: cron command had `SELECT * FROM sg_event_backfill_process()` inside DO block.
--         PL/pgSQL requires PERFORM (or INTO) for SELECTs whose results are discarded.
--   Fix: replace SELECT with PERFORM in cron command.
--
-- BUG 2: orphan_event_backfill_queue_15min — FK violation on evo_event_backfill_pending_tevo_event_id_fkey
--   Root: FK requires tevo_event_id to exist in events(id), but this pending table's PURPOSE
--         is to register orphan event_ids that DON'T exist locally yet (so we can backfill them).
--         FK + table purpose are contradictory.
--   Fix: drop the FK.

-- Fix 1: cron command — SELECT → PERFORM
SELECT cron.alter_job(
  job_id := (SELECT jobid FROM cron.job WHERE jobname='orphan_event_backfill_process_15min'),
  command := $cmd$DO $body$ BEGIN IF NOT public.cron_should_fire('orphan_event_backfill_process_15min') THEN RETURN; END IF; PERFORM evo_event_backfill_process(); PERFORM sg_event_backfill_process(); END $body$;$cmd$
);

-- Fix 2: drop FK that prevents the queue from registering orphan events
ALTER TABLE public.evo_event_backfill_pending
  DROP CONSTRAINT IF EXISTS evo_event_backfill_pending_tevo_event_id_fkey;

COMMENT ON COLUMN public.evo_event_backfill_pending.tevo_event_id IS
  'TEvo event_id that may NOT yet exist in public.events — the whole point of this table is to register orphans for async backfill. FK previously here was contradictory and dropped 2026-05-15 (mig 20260515380000).';
