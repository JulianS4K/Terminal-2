-- ============================================================================
-- Migration 20260630190000 — Restore TD budget caps to the 250k/mo pool
--
-- Lane:     A1
-- Touches:  td_daily_budget_ok (CREATE OR REPLACE), td_monthly_budget_ok (CREATE OR REPLACE).
-- Pre-reqs: td_credits_today()/td_credits_this_month() (20260527050000); these now include AXS (mig
--           20260630160000), so the gate covers COLLECTIVE TD usage across SH/VD/GT/TM/TP/AXS.
--
-- WHY (operator directive 2026-06-30): the monthly pool is **250,000 real credits**; keep collective TD
-- usage below it. The LIVE gate had drifted to `td_credits_today() < 50,000` / `td_credits_this_month()
-- < 600,000` — far too high for a 250k pool (600k recorded ≈ 800k real). Real quota burn ≈ **1.33×
-- recorded** (non-200 fetches burn quota without logging — sizing math documented in 20260609140000), so
-- to keep REAL collective burn under 250k the RECORDED monthly gate must be ~250k/1.33 ≈ 188k; we use
-- **180,000** (matches the original 250k-plan sizing: 250k − ~11k /match reserve = 239k real ÷ 1.33).
-- Daily is set to **9,000** — above today's Phase-1-instrumentation transient (~8.1k, AXS just began
-- logging) so it does not false-trip mid-demo, while still capping single-day runaway; the MONTHLY gate
-- is the binding ≤250k-real guarantee.
--
-- NOTE: the AXS probe (axs_probe_step) does not itself gate on td_budget_ok — only the secondary enqueue
-- (td_enqueue_peak) does. AXS is small (~25k/mo) and counts toward td_credits_this_month, so the monthly
-- gate still throttles the big lever (secondary) at 180k. Per-platform self-gating is Phase 3.
--
-- Idempotent (CREATE OR REPLACE) -> apply-before-PR; re-apply is a no-op.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.td_daily_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$ SELECT public.td_credits_today() < 9000; $function$;

CREATE OR REPLACE FUNCTION public.td_monthly_budget_ok()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$ SELECT public.td_credits_this_month() < 180000; $function$;
