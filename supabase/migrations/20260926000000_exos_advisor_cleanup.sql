-- ============================================================================
-- Migration 20260926000000 — Exos (Bridge / D4): Supabase advisor clean-up
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: EXECUTE on exos_tg_* trigger functions and exos_quota_available
--              (revoked from PUBLIC / anon / authenticated);
--              FUNCTION exos_tax_cents (search_path pinned)
-- Pre-reqs: none
--
-- From the 2026-09-26 production-readiness pass over the security advisors:
--  * The exos_tg_* functions are trigger bodies. EXECUTE only matters when a
--    trigger is created (never at fire time), so clients never need it; they
--    were callable over the REST API (a direct call just errors, but the
--    surface shouldn't exist).
--  * exos_quota_available(uuid) told any caller, anon included, the remaining
--    stock of any quota. It is only called from exos_assert_quota and
--    exos_effective_available, which run inside SECURITY DEFINER functions
--    (exos_fulfill_checkout, exos_mint_tickets, availability helpers), so
--    revoking client EXECUTE changes no behaviour. Same treatment the other
--    stock helpers got in 20260925003000.
--  * exos_tax_cents had a role-mutable search_path (function_search_path_mutable).
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

DO $$
DECLARE f regprocedure;
BEGIN
  FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname LIKE 'exos\_tg\_%' AND p.prorettype = 'trigger'::regtype LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', f);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f);
  END LOOP;
END $$;

REVOKE EXECUTE ON FUNCTION public.exos_quota_available(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_quota_available(uuid) TO service_role;

ALTER FUNCTION public.exos_tax_cents(integer, numeric, boolean) SET search_path = public, pg_temp;
