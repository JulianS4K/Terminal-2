-- Migration 20260513200100 · level:admin · lane:A1 · writes:pg_policies(leads_anon_insert) · reads:pg_policies · pre:20260513200000
-- Pre-resume audit response 2026-05-13 — fix Supabase advisor RLS_POLICY_ALWAYS_TRUE
-- finding on public.leads.leads_anon_insert.
--
-- The existing policy was `INSERT ... WITH CHECK (true)` — effectively bypasses RLS for
-- anon-INSERT. If `public.leads` is meant to accept anon-submitted contact forms, that's
-- intentional but unsafe (no rate limiting, no shape validation, anyone with the public
-- anon key can spam-insert). If it's meant to be service-role-only, the policy never
-- should have been WITH CHECK (true).
--
-- Decision (subject to operator review): DROP the anon-insert policy. service_role still
-- writes (RLS bypasses for service_role per Supabase default), and the storefront's
-- existing service-role-backed `app.py` paths are unaffected. If anon-submitted leads
-- are needed later, replace this migration with a constrained policy that validates at
-- minimum: email-format regex + length cap + per-IP rate limit (out of scope for this PR).
--
-- Reference: audit finding H6. bot_chat row 94 (B1 ping).
--
-- Reversal: CREATE POLICY leads_anon_insert ON public.leads FOR INSERT TO anon WITH CHECK (true);

BEGIN;

DROP POLICY IF EXISTS leads_anon_insert ON public.leads;

COMMIT;

-- Verification:
--   SELECT polname, polcmd, polroles::regrole[], pg_get_expr(polqual, polrelid)        AS using_expr,
--                                                pg_get_expr(polwithcheck, polrelid)   AS check_expr
--   FROM pg_policy
--   WHERE polrelid = 'public.leads'::regclass;
-- Expected: no row for leads_anon_insert.
