-- ============================================================================
-- Migration 20260708042000 — cron_should_fire: restore caller statement_timeout
--
-- Lane:     A1
-- Touches:  public.cron_should_fire(text) (CREATE OR REPLACE — W);
--           reads cron_policy, writes cron_gate_decisions (both unchanged).
-- Pre-reqs: 20260702075500 (movers 840s prefix), 20260701213000 (900s role cap).
--
-- WHY (refresh_movers_agg cron_deadman FAIL root-caused, 2026-07-08):
--   A pg_cron command runs as ONE implicit transaction (simple protocol), and
--   cron_should_fire()'s work-check wrapper ended with
--       PERFORM set_config('statement_timeout', '120000', true);
--   i.e. it "restored" a HARDCODED transaction-local 120s. That local value
--   outlives the gate call and clamps EVERY later statement in the same
--   command — silently overriding the job's own in-string SET prefix.
--   refresh_movers_agg (840s prefix, mig 20260702075500) therefore kept dying
--   at exactly 120s per window call: 11 of its last 12 runs failed
--   2026-07-02 → 2026-07-07 (the lone 07-03 19:20 success, 361s total, is the
--   tell — five window calls each individually under 120s). The 2026-07-02
--   post-mortem blamed cross-job SET leakage on pooled connections; the real
--   120s source for gated jobs was this hardcoded restore. Probe (2026-07-08):
--     SET statement_timeout='840s';
--     SELECT set_config('statement_timeout','120000',true);
--     SHOW statement_timeout;   -->  2min
--   Affects every cron_policy-gated job whose work_check_sql IS NOT NULL and
--   whose real work exceeds 120s per statement.
--
-- FIX: capture the pre-work-check value and restore THAT (still txn-local via
--   is_local=true, so nothing leaks to the pooled session — §3(d) discipline).
--   The 8s work-check bound is kept. The EXCEPTION path needs no explicit
--   restore: the subtransaction abort rolls the 8s GUC change back itself.
--   Deliberately surgical: SECURITY DEFINER + search_path + grants unchanged
--   (CREATE OR REPLACE preserves existing ACLs; no new SECDEF surface added).
-- ============================================================================

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
  v_prev_timeout  text;
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
      v_prev_timeout := current_setting('statement_timeout', true);
      PERFORM set_config('statement_timeout', '8000', true);
      EXECUTE v_policy.work_check_sql INTO v_has_work;
      PERFORM set_config('statement_timeout', coalesce(nullif(v_prev_timeout, ''), '0'), true);
    EXCEPTION WHEN OTHERS THEN
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
