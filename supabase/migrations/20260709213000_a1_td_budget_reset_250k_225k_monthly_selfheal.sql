-- ============================================================================
-- Migration 20260709213000 — TD budget reset: fresh 250k pool, 225k/mo target,
--                            self-healing quota-floor guard
--
-- Lane:     A1
-- Touches:  td_daily_budget_ok (CREATE OR REPLACE), td_monthly_budget_ok (CREATE OR REPLACE),
--           td_budget_ok (CREATE OR REPLACE — recency-guard the quota floor).
-- Pre-reqs: 20260630210000 (phased caps), td_credits_today()/td_credits_this_cycle()
--           (cycle anchored to the 9th), ticketsdata_credit_usage.quota_remaining.
--
-- WHY (operator directive 2026-07-09): the TicketsData plan RESET on the 9th and the
-- real pool refilled to a fresh 250,000. Two problems to fix, both here:
--
--   1. STUCK GATE (pipeline dark ~20h). td_budget_ok() was returning FALSE even though
--      the recorded daily+cycle counters were far under cap. Cause: its third term reads
--      the LAST recorded `quota_remaining` from ticketsdata_credit_usage, and that reading
--      was a stale **-4** (the pre-reset exhaustion, logged 00:45). No fetch fires while the
--      gate is shut, so nothing records a fresh reading to reopen it → deadlock. We make the
--      quota floor **recency-aware**: only a reading from the last 3h can block; a stale one
--      falls back to the recorded caps (which are the real accounting). This unsticks the
--      gate immediately (last reading is ~20h old) AND prevents the deadlock recurring.
--
--   2. TARGET = 225,000 REAL/cycle (was 255k post-flip / 300k burn phase). On the 250k pool
--      this leaves a ~25k reserve for /match reports + manual/MVP use. Single-phase now —
--      the 7/09↔7/10 CASE phasing existed only to burn the expiring 300k surplus before the
--      reset; that surplus is gone, so steady-state discipline applies from here.
--
-- CAP BASIS — thresholds are REAL (billing) units. The recorded ledger undercounts real by
-- the measured **1.276×** (billing 26,349 vs recorded 20,642 since Jun 9), so each gate
-- multiplies recorded credits by 1.276 before comparing against the real threshold.
--   * daily  even-spread: real < 7,500/day  (225k ÷ 30 ≈ 7,500; monthly gate is the binding cap)
--   * cycle  hard cap:    real < 225,000     (9th→9th window; the ≤225k guarantee)
--   * quota  floor:       last RECENT (≤3h) API quota_remaining > 10,000 real
--       — a genuine "pool almost gone" backstop that sits BELOW the 225k stop point
--         (250k − 225k = 25k remaining at cap), so it never pre-empts the target; it only
--         catches estimate drift / an emergency the recorded counter missed.
--
-- Idempotent (CREATE OR REPLACE) -> apply-before-PR under operator direction; re-apply is a no-op.
-- The crons (td_pull_drain/td_enqueue_peak_*/td_tier_enqueue_*/axs-probe-drain) are all still
-- ACTIVE and gate on td_budget_ok() — they resume on their own cadence the minute it returns true.
-- ============================================================================

-- Daily even-spread guard (real units): 225k ÷ 30 ≈ 7,500/day.
CREATE OR REPLACE FUNCTION public.td_daily_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (public.td_credits_today()::numeric * 1.276) < 7500;
$function$;

-- Cycle hard cap (real units): the ≤225k-per-billing-cycle guarantee (9th→9th).
CREATE OR REPLACE FUNCTION public.td_monthly_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (public.td_credits_this_cycle()::numeric * 1.276) < 225000;
$function$;

-- Combined gate. Third term = live pool floor, now RECENCY-GUARDED so a stale reading
-- (like the -4 that darked the pipeline) can never block: only a quota_remaining logged
-- in the last 3h is trusted; otherwise COALESCE -> high default -> recorded caps govern.
CREATE OR REPLACE FUNCTION public.td_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.td_daily_budget_ok()
     AND public.td_monthly_budget_ok()
     AND COALESCE(
           (SELECT u.quota_remaining
              FROM public.ticketsdata_credit_usage u
             WHERE u.quota_remaining IS NOT NULL
               AND u.called_at > now() - interval '3 hours'   -- trust only RECENT readings
             ORDER BY u.called_at DESC
             LIMIT 1),
           1000000                                            -- no recent reading -> don't block
         ) > 10000;                                           -- genuine near-empty backstop
$function$;

REVOKE ALL ON FUNCTION public.td_daily_budget_ok()   FROM anon, public;
REVOKE ALL ON FUNCTION public.td_monthly_budget_ok() FROM anon, public;
REVOKE ALL ON FUNCTION public.td_budget_ok()         FROM anon, public;
GRANT EXECUTE ON FUNCTION public.td_daily_budget_ok()   TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.td_monthly_budget_ok() TO service_role, authenticated;
GRANT EXECUTE ON FUNCTION public.td_budget_ok()         TO service_role, authenticated;

COMMENT ON FUNCTION public.td_monthly_budget_ok() IS
  'True if cycle-to-date recorded TD credits ×1.276 < 225,000 REAL (250k pool, ~25k reserve; '
  'cycle anchored to the 9th). The binding ≤225k-per-cycle guarantee.';
COMMENT ON FUNCTION public.td_budget_ok() IS
  'Collective TD gate: daily even-spread AND cycle ≤225k AND recent(≤3h) API quota_remaining > 10,000. '
  'Quota floor is recency-guarded so a stale/negative reading cannot dark the pipeline (deadlock fix 2026-07-09).';
