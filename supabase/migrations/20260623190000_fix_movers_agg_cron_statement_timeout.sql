-- ============================================================================
-- Migration 20260623190000 — fix refresh_movers_agg: statement_timeout never armed
--
-- Lane:     A1 (crons / data plane)
-- Touches:  cron.job 'refresh_movers_agg' (W, re-schedule). No table/function DDL.
-- Pre-reqs: 20260601140000 (two-tier agg cache + refresh_event_movers_agg),
--           20260608031000 (prior — INEFFECTIVE — per-window timeout attempt).
-- Apply:    NOT APPLIED. A1/operator to apply. See post-apply bootstrap below.
--
-- ── SYMPTOM ─────────────────────────────────────────────────────────────────
--   release_health_check() → cron.failed_jobs_90min = warn, every run of
--   'refresh_movers_agg' FAILS at exactly 120s with:
--     ERROR: canceling statement due to statement timeout
--     CONTEXT: SQL statement "INSERT INTO public.event_movers_agg ..."
--   Downstream: event_movers_agg cache frozen since 2026-06-08, and
--   event_movers_index frozen since 2026-06-03 (the 18h-staleness guard in
--   compute_event_movers_index makes Tier-2 a no-op once the cache is stale).
--   Net effect: the terminal MOVERS rail has served ~20-day-old data.
--
-- ── ROOT CAUSE ──────────────────────────────────────────────────────────────
--   pg_cron runs the whole job command as a sequence of top-level statements.
--   The 06-08 version put ALL five windows inside ONE `DO` block and tried to
--   widen the budget with `PERFORM set_config('statement_timeout','480000',true)`
--   INSIDE that block. statement_timeout is armed by the backend when a
--   top-level statement BEGINS; changing the GUC *inside* an already-running
--   statement does NOT re-arm the timer for that statement. So the entire DO ran
--   under the role default (120s) and was cancelled — exactly the trap the
--   06-01 header documented ("a function-local statement_timeout does NOT re-arm
--   the cron's already-running outer statement"), reintroduced by 06-08.
--   The `EXCEPTION WHEN OTHERS` could not rescue it either: once the deadline
--   has passed, every subsequent operation re-cancels at the next interrupt.
--
-- ── FIX ─────────────────────────────────────────────────────────────────────
--   Issue `SET statement_timeout` as its OWN top-level statement BEFORE the work.
--   In a multi-statement command each statement's timer is armed fresh from the
--   *current* GUC value when that statement starts, so the following DO block now
--   runs under 900s (15 min — ample for the ~68s historical batch + growth, and
--   harmless at a twice-daily cadence). The inner, ineffective set_config is
--   removed. The per-window EXCEPTION savepoints are KEPT so a single bad window
--   (e.g. a genuine error, not a timeout) can't roll back the others.
-- ============================================================================

SELECT cron.schedule('refresh_movers_agg', '20 7,19 * * *', $cron$
  SET statement_timeout = '900000';   -- 15 min, armed for the DO statement below
  DO $g$
  DECLARE w int;
  BEGIN
    IF NOT public.cron_should_fire('refresh_movers_agg') THEN RETURN; END IF;
    FOREACH w IN ARRAY ARRAY[7,15,30,180,365] LOOP
      BEGIN
        PERFORM public.refresh_event_movers_agg(w);
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'refresh_event_movers_agg(%) skipped: %', w, SQLERRM;
      END;
    END LOOP;
  END $g$;
$cron$);

-- ── POST-APPLY BOOTSTRAP (A1 runs manually; don't wait for the next 07:20/19:20)
--   Refresh each window in its own statement under a widened timeout, then drive
--   Tier-2 so the MOVERS index recovers immediately:
--     SET statement_timeout = '900000';
--     SELECT public.refresh_event_movers_agg(w) FROM unnest(ARRAY[7,15,30,180,365]) w;
--     SELECT public.compute_event_movers_index_all();
--
-- ── VERIFICATION (next scheduled run) ───────────────────────────────────────
--   SELECT status, start_time, return_message FROM cron.job_run_details d
--     JOIN cron.job j ON j.jobid=d.jobid WHERE j.jobname='refresh_movers_agg'
--     ORDER BY start_time DESC LIMIT 2;            -- expect status='succeeded'
--   SELECT max(computed_at) FROM public.event_movers_agg;        -- ~now()
--   SELECT max(last_computed_at) FROM public.event_movers_index; -- ~now()
--
-- ── FOLLOW-UP (separate task, not this migration) ───────────────────────────
--   The 180/365d windows re-percentile the raw ticketsdata firehose (1.7M-3.25M
--   rows). Source them from event_listing_snapshot_daily (pre-aggregated daily
--   medians, ~100x fewer rows) so even a 15-min budget is never approached.
-- ============================================================================
