-- ============================================================================
-- MIG 20260608203000 — RLS-enable the 2 granted+RLS-off tables (B1-NEXT-55)
--
-- Re-audit 2026-06-08 found the "0 RLS-off" posture had regressed: two public
-- tables carried the default anon/authenticated SELECT grant but had RLS
-- DISABLED (no policy gate) — `seatdata_search_attempts` (anon+auth readable)
-- and `sg_league_priority_config` (auth readable). Verified safe to lock down:
-- NO frontend/app/edge code reads them and NO view/matview depends on them
-- (all real readers are SECDEF/service_role crons, which bypass RLS).
--
-- Fix mirrors the established internal-table pattern (e.g. bot_chat): ENABLE RLS
-- + an `admin_only` deny-all policy for anon/authenticated/coworker_readonly.
-- service_role / SECDEF readers are unaffected (BYPASSRLS).
--
-- (`sg_market_chart` is also RLS-off but NOT granted to anon/auth → already safe;
--  left as-is.)
--
-- ✅ Already applied to prod  Applied via MCP 2026-06-08.
--    Post-apply verified: both tables relrowsecurity=true + admin_only policy present;
--    granted-AND-rls-off count = 0.
-- ============================================================================

ALTER TABLE public.seatdata_search_attempts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS admin_only ON public.seatdata_search_attempts;
CREATE POLICY admin_only ON public.seatdata_search_attempts
  FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);

ALTER TABLE public.sg_league_priority_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS admin_only ON public.sg_league_priority_config;
CREATE POLICY admin_only ON public.sg_league_priority_config
  FOR ALL TO anon, authenticated, coworker_readonly USING (false) WITH CHECK (false);
