-- ============================================================================
-- Migration 20260630200000 — Align TD monthly budget gate to the real billing cycle (9th→9th)
--
-- Lane:     A1
-- Touches:  td_credits_this_cycle (NEW fn), td_monthly_budget_ok (CREATE OR REPLACE → cycle-aware).
-- Pre-reqs: 20260630190000 (caps restored), ticketsdata_credit_usage.
--
-- WHY (operator billing screenshot 2026-06-30): the TicketsData plan resets on the **9th** ("Billing
-- Cycle Jun 9 – Jul 9, Quota used 26,349 / 250,000"), NOT the calendar 1st. The monthly gate used
-- td_credits_this_month() (calendar month → resets Jul 1), which would zero the counter Jul 1–9 while the
-- real 250k pool keeps depleting until Jul 9 — an over-burn window. This adds td_credits_this_cycle()
-- (sums recorded credits since the most-recent 9th) and repoints the monthly gate at it, so the gate's
-- window matches the real quota window. Threshold stays 180,000 recorded ≈ 230k real at the MEASURED
-- 1.276 real:recorded ratio (26,349 real / 20,642 recorded since Jun 9) — under the 250k pool with reserve.
--
-- Idempotent (CREATE OR REPLACE) -> apply-before-PR; re-apply is a no-op.
-- ============================================================================

-- Recorded credits since the most-recent billing anchor (the 9th, 00:00 server time).
CREATE OR REPLACE FUNCTION public.td_credits_this_cycle()
 RETURNS bigint
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(sum(credits), 0)::bigint
  FROM public.ticketsdata_credit_usage
  WHERE called_at >= (
    (CASE WHEN extract(day FROM now()) >= 9
          THEN date_trunc('month', now())
          ELSE date_trunc('month', now() - interval '1 month') END)
    + interval '8 days');
$function$;

REVOKE ALL ON FUNCTION public.td_credits_this_cycle() FROM anon;
GRANT  EXECUTE ON FUNCTION public.td_credits_this_cycle() TO service_role, authenticated;

-- Gate on the cycle window (9th→9th), not the calendar month.
CREATE OR REPLACE FUNCTION public.td_monthly_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$ SELECT public.td_credits_this_cycle() < 180000; $function$;
