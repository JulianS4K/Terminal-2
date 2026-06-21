-- ============================================================================
-- Migration 20260621151000 — stop slow work-check from killing sweep cron
--
-- Lane:     A1 (data plane / cron gating)
-- Touches:  public.cron_should_fire (W, CREATE OR REPLACE),
--           public.cron_policy (W, one-row UPDATE)
-- Pre-reqs: cron_should_fire + cron_policy + evo_listings_poll_state exist
-- Apply:    PROPOSAL — authored under operator-directed automated-runs review;
--           apply is A1/operator-gated (CLAUDE.md §1; cron_policy DML too).
--
-- WHY:
--   `sweep_duplicate_listings_hourly` has failed EVERY hour for 12h+ (0/12 runs
--   succeeded, verified 2026-06-21), each dying on:
--     ERROR: canceling statement due to statement timeout
--     CONTEXT: SQL statement "SELECT EXISTS (SELECT 1 FROM public.unified_...)"
--   The timeout is NOT in the sweep itself — it's the per-job `work_check_sql`
--   gate run by cron_should_fire(). For this job the gate is
--     SELECT EXISTS (SELECT 1 FROM public.unified_listings WHERE aq_short_event_id IS NOT NULL ...)
--   which scans the 128M-row / 51GB listings_snapshots via the unified_listings
--   view and blows the 120s statement_timeout. (match_unmatched_orders_sweep_hourly
--   uses the same pattern over the far smaller unified_orders, so it survives.)
--
-- ROOT CAUSE / why the existing guard didn't save it:
--   cron_should_fire wraps the work-check EXECUTE in `EXCEPTION WHEN OTHERS`,
--   but statement_timeout consumes the WHOLE call's deadline — so even though
--   the cancel is caught, the next statement (the cron_gate_decisions INSERT)
--   is instantly re-canceled. The job fails regardless of the handler.
--
-- FIX (two parts):
--   1. Harden cron_should_fire: bound the work-check with a txn-local 8s
--      statement_timeout via set_config(..., is_local=true). On timeout the
--      EXCEPTION subtransaction rolls back, reverting the local timeout to the
--      outer value, so the function still has its full budget for the INSERT.
--      Net: a slow/broken work-check now fails OPEN (v_has_work := true) in
--      ≤8s instead of poisoning the job. Hardens the whole class, not just one.
--   2. Repoint this job's work_check_sql at the table the sweep actually loops
--      over (evo_listings_poll_state, last 6h) — tiny + indexed + instant —
--      instead of the 128M-row unified_listings view. Same intent ("is there
--      anything recent to dedupe?"), correct cost.
--
-- VERIFICATION (run after apply):
--   -- within ~1h, expect a fresh success:
--   SELECT status, return_message, start_time
--   FROM cron.job_run_details r JOIN cron.job j USING (jobid)
--   WHERE j.jobname='sweep_duplicate_listings_hourly'
--   ORDER BY start_time DESC LIMIT 3;
-- ============================================================================

-- ---- Part 1: harden the gate ------------------------------------------------
CREATE OR REPLACE FUNCTION public.cron_should_fire(p_jobname text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_policy        public.cron_policy%ROWTYPE;
  v_hour_et       int;
  v_in_peak       boolean;
  v_interval_min  int;
  v_last_fire     timestamptz;
  v_fires_today   int := NULL;
  v_has_work      boolean := true;
  v_decision      text;
  v_now           timestamptz := clock_timestamp();
BEGIN
  v_hour_et := EXTRACT(hour FROM (v_now AT TIME ZONE 'America/New_York'))::int;
  SELECT * INTO v_policy FROM public.cron_policy WHERE jobname = p_jobname;

  IF NOT FOUND THEN
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et)
      VALUES (p_jobname, v_now, 'fire_no_policy', v_hour_et);
    RETURN true;
  END IF;

  IF NOT v_policy.enabled THEN
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et)
      VALUES (p_jobname, v_now, 'disabled', v_hour_et);
    RETURN false;
  END IF;

  IF v_policy.daily_max_fires IS NOT NULL THEN
    SELECT count(*) INTO v_fires_today FROM public.cron_gate_decisions
      WHERE jobname = p_jobname AND decision = 'fire'
        AND decided_at >= date_trunc('day', v_now AT TIME ZONE 'UTC');
    IF v_fires_today >= v_policy.daily_max_fires THEN
      INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, fires_today)
        VALUES (p_jobname, v_now, 'skip_budget', v_hour_et, v_fires_today);
      RETURN false;
    END IF;
  END IF;

  SELECT max(decided_at) INTO v_last_fire
    FROM public.cron_gate_decisions
    WHERE jobname = p_jobname AND decision = 'fire';
  v_in_peak := v_hour_et = ANY(v_policy.peak_hours_et);
  v_interval_min := CASE WHEN v_in_peak THEN v_policy.peak_min_interval_min
                                        ELSE v_policy.offpeak_min_interval_min END;
  IF v_last_fire IS NOT NULL AND (v_now - v_last_fire) < make_interval(mins => v_interval_min) THEN
    v_decision := CASE WHEN v_in_peak THEN 'skip_interval' ELSE 'skip_offpeak' END;
    INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
      VALUES (p_jobname, v_now, v_decision, v_hour_et, v_last_fire, v_fires_today);
    RETURN false;
  END IF;

  IF v_policy.work_check_sql IS NOT NULL THEN
    BEGIN
      -- Bound the work-check so a slow/expensive probe can never burn the
      -- whole job's statement_timeout. is_local=true => reverts on subtxn
      -- rollback (the EXCEPTION path) AND at transaction end.
      PERFORM set_config('statement_timeout', '8000', true);
      EXECUTE v_policy.work_check_sql INTO v_has_work;
      PERFORM set_config('statement_timeout', '120000', true);  -- restore for remainder
    EXCEPTION WHEN OTHERS THEN
      -- Fail OPEN: if the work-check errors or times out, let the job run.
      v_has_work := true;
    END;
    IF NOT coalesce(v_has_work, false) THEN
      INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
        VALUES (p_jobname, v_now, 'skip_no_work', v_hour_et, v_last_fire, v_fires_today);
      RETURN false;
    END IF;
  END IF;

  INSERT INTO public.cron_gate_decisions(jobname, decided_at, decision, hour_et, last_fire_at, fires_today)
    VALUES (p_jobname, v_now, 'fire', v_hour_et, v_last_fire, v_fires_today);
  RETURN true;
END $function$;

-- ---- Part 2: repoint the offending work-check at the right (cheap) table ----
UPDATE public.cron_policy
SET work_check_sql =
  'SELECT EXISTS (SELECT 1 FROM public.evo_listings_poll_state '
  'WHERE last_polled_listings_at > now() - interval ''6 hours'')'
WHERE jobname = 'sweep_duplicate_listings_hourly';
