-- ============================================================================
-- Migration 20260524130000 — Exos (Bridge / D4): security-advisor hardening
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_touch_updated_at() (search_path), exos_has_org_role (grants)
-- Pre-reqs: 20260520120000 (phase-1: both objects exist)
--
-- Closes two Supabase security-advisor findings on the live exos schema:
--   1. function_search_path_mutable on exos_touch_updated_at — a trigger fn
--      with a role-mutable search_path. Pin it (defense-in-depth against
--      search_path injection), matching every other exos SECDEF fn.
--   2. anon_security_definer_function_executable on exos_has_org_role — anon
--      can call this role-probe via /rest/v1/rpc. It's only meant as an
--      internal RLS/SECDEF helper; revoke direct anon EXECUTE. Internal use
--      inside policies/functions is unaffected (those run as the definer).
--
-- NOT addressed here (intentional, accepted design — flagged for B1):
--   * security_definer_view on exos_public_{orgs,events,tiers}. These views
--     ARE the anon boundary: they expose only column-narrowed, public-safe
--     fields. anon has no SELECT on the base tables, so security_invoker
--     would break public reads. Leaving them definer is the design.
--   * rls_enabled_no_policy on exos_mail — deny-all to clients is correct;
--     mail is written via SECDEF RPCs and read by the service-role drainer.
--
-- D4 authors; validate on a Supabase preview branch; A1 applies to prod.
-- ============================================================================

ALTER FUNCTION public.exos_touch_updated_at() SET search_path = public, pg_temp;

REVOKE EXECUTE ON FUNCTION public.exos_has_org_role(uuid, text[]) FROM anon, PUBLIC;
