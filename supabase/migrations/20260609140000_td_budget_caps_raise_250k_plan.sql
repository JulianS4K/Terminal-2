-- Migration 20260609140000 · lane:D0 (author) → A1 (apply) ·
--   writes (DDL): td_daily_budget_ok(), td_monthly_budget_ok() — threshold raise ·
--   reads: ticketsdata_credit_usage (via td_credits_today/_this_month) ·
--   spends: nothing (raises the ceiling; actual spend is enqueue-LIMIT bound) ·
--   pre: 20260527150000 (daily cap 300), 20260527130000 (monthly cap 9000)
--
-- ## NOT YET APPLIED — author-only migration file.
--    Pending A1 review + explicit operator apply (CLAUDE.md §1). Validate on a
--    Supabase branch before any prod apply.
--
-- WHY ───────────────────────────────────────────────────────────────────────
-- The 250k/mo plan upgrade went LIVE 2026-06-09 (verified: API quota_remaining
-- flipped from ~6.9k to 256,911 between 13:40–17:00 UTC; dashboard agrees). The
-- old caps were sized for the 10k Starter plan and now throttle us 25×+ below
-- the real pool:
--     td_daily_budget_ok   < 300      (10k ÷ 30d)
--     td_monthly_budget_ok < 9,000    (10k − 1k test reserve)
--
-- SIZING — why NOT 240k/8k ─────────────────────────────────────────────────
-- These gates count RECORDED credits (td_charge_credit logs 1/call, only on
-- HTTP 200). But measured real quota burn is ~1.33× recorded — non-200 traffic
-- (404/503/timeout/retry) consumes plan quota without being logged. So a
-- recorded-credit cap of N implies ~1.33·N real burn. To keep real burn under
-- the 250k pool WITH a reserve for /match reports (≤600/mo × 12 = 7,200 credits)
-- and manual/MVP use:
--     real budget for /fetch+/events ≈ 250,000 − ~11,000 reserve ≈ 239,000
--     recorded-credit cap            ≈ 239,000 ÷ 1.33               ≈ 180,000/mo
--     daily even-spread              ≈ 180,000 ÷ 30                 =  6,000/day
--
-- NOTE: this only RAISES the ceiling. Actual spend stays ~300/day until the
-- td_enqueue_peak LIMIT / cadence is raised separately — do that incrementally
-- and watch the real quota_remaining delta vs recorded credits (the 1.33× ratio)
-- before pushing toward the cap. Best long-term fix: also charge a credit on
-- terminal non-200s so recorded ≈ real and the 1.33× fudge disappears.
-- ─────────────────────────────────────────────────────────────────────────────

-- Daily soft cap: 300 → 6,000 recorded (~7,980 real burn/day even-spread).
CREATE OR REPLACE FUNCTION public.td_daily_budget_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.td_credits_today() < 6000;
  -- 250k/mo plan (live 2026-06-09). 6,000 recorded/day ≈ 7,980 real (×1.33) ≈
  -- 180,000 recorded/mo. Raise alongside enqueue LIMIT; watch real-burn ratio.
$$;
REVOKE ALL ON FUNCTION public.td_daily_budget_ok() FROM anon, public;
COMMENT ON FUNCTION public.td_daily_budget_ok() IS
  'True if today''s recorded TD credits < 6,000 (250k/mo plan, live 2026-06-09). '
  'Recorded under-counts real burn ~1.33×; cap chosen so real stays under pool.';

-- Monthly hard cap: 9,000 → 180,000 recorded (~239k real, leaving ~11k for
-- /match reports + manual).
CREATE OR REPLACE FUNCTION public.td_monthly_budget_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.td_credits_this_month() < 180000;
  -- 250k/mo plan (live 2026-06-09). 180,000 recorded ≈ 239,000 real burn (×1.33),
  -- reserving ~11,000 for /match (≤600 reports × 12) + manual/MVP use.
  -- RULE: if plan or the recorded-vs-real ratio changes, update here + comment.
$$;
REVOKE ALL ON FUNCTION public.td_monthly_budget_ok() FROM anon, public;
COMMENT ON FUNCTION public.td_monthly_budget_ok() IS
  'True if month-to-date recorded TD credits < 180,000 (250k/mo plan, live '
  '2026-06-09; ~239k real burn at the measured 1.33× recorded-to-real ratio).';
