-- ============================================================================
-- Migration 20260630210000 — Phased TD caps: 300k plan now → 8k REAL/day from 7/9
--
-- Lane:     A1
-- Touches:  td_daily_budget_ok (CREATE OR REPLACE), td_monthly_budget_ok (CREATE OR REPLACE),
--           cron job 'axs-probe-drain' (jobid 402, add td_budget_ok() to the gate).
-- Pre-reqs: 20260630190000/200000 (caps + cycle alignment), td_credits_today()/td_credits_this_cycle().
--
-- WHY (operator directive 2026-06-30): two phases, flipping automatically at the 7/9 billing reset.
--   * NOW → 7/9 (current cycle): run on the **300k plan** — loose, to burn the otherwise-expiring surplus
--     (SG-via-TD / non-owned fill). Cycle real < 300,000; daily real < 40,000 (runaway guard only).
--   * FROM 7/9: **8k REAL/day** discipline → 8k × 31 ≈ 248k, just under the 250k pool. Cycle real < 248,000.
--
-- CRITICAL: thresholds are REAL (billing units). The recorded ledger undercounts real by the MEASURED
-- **1.276×** (billing 26,349 vs recorded 20,642 since Jun 9, verified to 0.04%), so each gate compares
-- (recorded × 1.276) against the real threshold. A literal-recorded cap would mis-size by ~28%.
-- The CASE on now() vs 2026-07-09 flips phases with no manual edit; td_credits_this_cycle() already
-- resets on the 9th, so the post-7/9 cycle counter starts fresh under the 248k cap.
--
-- Also gate the AXS probe (jobid 402) on td_budget_ok() so "total" truly includes AXS (~1k real/day).
-- (Supersedes the cron command set in 20260630170000.)
--
-- Idempotent (CREATE OR REPLACE + cron.schedule upsert) -> apply-before-PR; re-apply is a no-op.
-- ============================================================================

-- 1.276 = measured real:recorded ratio (refine if the platform mix shifts; see v_td_credit_cost_per_call).
CREATE OR REPLACE FUNCTION public.td_daily_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (public.td_credits_today()::numeric * 1.276)
         < CASE WHEN now() < timestamptz '2026-07-09' THEN 40000   -- 300k plan: loose daily guard
                ELSE 8000 END;                                       -- 8k real/day from 7/9
$function$;

CREATE OR REPLACE FUNCTION public.td_monthly_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (public.td_credits_this_cycle()::numeric * 1.276)
         < CASE WHEN now() < timestamptz '2026-07-09' THEN 300000   -- 300k plan, current cycle
                ELSE 248000 END;                                      -- just below 250k from 7/9
$function$;

-- AXS probe: only fire when the budget gate is open, so collective real usage respects the active cap.
SELECT cron.schedule(
  'axs-probe-drain',
  '* * * * *',
  $cmd$do $b$ begin
    if (public.is_peak() or (extract(minute from now())::int % 10 = 8)) and public.td_budget_ok() then
      perform public.axs_probe_step();
    end if;
  end $b$;$cmd$
);
