-- ============================================================================
-- Migration 20260910230000 — retire the sub-worklist refresh cron (592)
--
-- Lane:     D0 (orders surface)
-- Touches:  cron.job row 's4kcs_sub_worklist_refresh_10min' -> active = false.
--           No table dropped, no function dropped, no data deleted.
-- Pre-reqs: none (guarded; the job is created by hand, not by a migration)
--
-- READ-ONLY upstream: no API call. RULE 2 untouched.
--
-- Operator direction 2026-09-10: the non-N2S orders "should just be mapped and
-- recorded similar to the other sales we record" — i.e. stop hunting sub
-- candidates for them. Retire 592, nothing else.
--
-- ── WHY THIS LOSES NOTHING ────────────────────────────────────────────────
-- Mapping and recording of those orders do NOT happen here. They are three
-- other crons, all still running:
--     578  s4kcs_orders_queue_10min     pulls the CRM order book
--     579  s4kcs_orders_process_10min   records it into s4kcs_orders
--     580  s4kcs_map_events_10min       maps to tevo_event_id (26,504 future
--                                        orders mapped across 8 methods)
-- 592 only ever computed s4kcs_sub_candidates() into s4kcs_sub_worklist. Its
-- sole consumer was the SUB QUEUE panel, removed the same day, so as of that
-- removal it refreshed a table nothing read.
--
-- ⚠ cron.alter_job(active := false), NOT a direct UPDATE and NOT unschedule.
-- cron.job is not writable by the migration role (42501 permission denied);
-- pg_cron exposes alter_job() as the supported way to change a job in place.
-- And NOT unschedule, because unscheduling deletes the job row, and
-- with it the exact command text — which is not in any migration, because this
-- job was scheduled by hand via MCP (20260910000000 only records it in a
-- comment). Re-enabling after an unschedule would mean reconstructing that
-- command from memory, and this session has already proved twice how that
-- goes. Deactivating keeps the definition and the run history, so turning it
-- back on is:
--     SELECT cron.alter_job(jobid, active := true)
--       FROM cron.job WHERE jobname = 's4kcs_sub_worklist_refresh_10min';
--
-- ⚠ THE TABLE, FUNCTION AND ROUTE ARE DELIBERATELY KEPT.
-- s4kcs_sub_worklist (25,802 rows), s4kcs_sub_worklist_refresh() and
-- /api/broker/sub-worklist all remain. Retiring the cron stops the work;
-- dropping the data would also destroy the answer, and re-deriving it later
-- costs a full rebuild. The table simply goes stale from now on — anything
-- reading it must treat refreshed_at as authoritative, which it always should
-- have.
--
-- ⚠ GUARDED BECAUSE A FRESH DATABASE HAS NO SUCH JOB. migrations-from-zero
-- replays this against an empty database where 592 was never scheduled, so an
-- unguarded alter_job would ERROR on a NULL jobid. The lookup-then-branch
-- makes both outcomes explicit and harmless.
-- ============================================================================

DO $retire$
DECLARE v_id bigint;
BEGIN
  -- Look the id up by NAME. 592 is this database's id, not a fact about the
  -- job; a rebuilt environment numbers it differently.
  SELECT jobid INTO v_id
    FROM cron.job
   WHERE jobname = 's4kcs_sub_worklist_refresh_10min' AND active;

  IF v_id IS NULL THEN
    -- Fresh database, or already retired. Both are fine — but say so rather
    -- than pretending work happened.
    RAISE NOTICE 'cron s4kcs_sub_worklist_refresh_10min not active here; nothing to retire';
  ELSE
    PERFORM cron.alter_job(v_id, active := false);
    RAISE NOTICE 'retired cron s4kcs_sub_worklist_refresh_10min (jobid %)', v_id;
  END IF;
END
$retire$;

COMMENT ON TABLE public.s4kcs_sub_worklist IS
  'Profit-swap candidates for our own future, mapped order book. ⚠ NO LONGER '
  'REFRESHED: cron 592 was retired 2026-09-10 when the SUB QUEUE panel that '
  'read it was removed. The rows are a frozen snapshot — treat refreshed_at as '
  'authoritative and assume the candidates are stale. The orders themselves '
  'are still pulled, recorded and mapped by crons 578/579/580. To resume: '
  'SELECT cron.alter_job(jobid, active := true) FROM cron.job WHERE jobname = '
  '''s4kcs_sub_worklist_refresh_10min''; See migration 20260910230000.';
