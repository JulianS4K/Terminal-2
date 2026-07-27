-- Migration 20260702131000 · level:security · lane:A1 (DB security, RULE-2) · writes:REVOKE EXECUTE d0_s4kent_gate_health() FROM anon · reads:none · pre:20260702130000 · auth:APPLIED via MCP 2026-07-02 ~06:00 UTC; this file is the idempotent codification (re-apply is a no-op)
--
-- Least-privilege follow-up to 20260702130000. Supabase's default privileges
-- auto-GRANT anon/authenticated EXECUTE on every new public function, so
-- d0_s4kent_gate_health() landed with a direct anon grant despite the parent
-- migration intending authenticated-only. Data was never exposed — the
-- function's body gate raises 42501 for any non-@s4kent caller — but tighten
-- the grant to match intent. authenticated + service_role retain EXECUTE.
--
-- Verified post-apply: proacl = {postgres=X,authenticated=X,service_role=X};
-- has_function_privilege('anon',...)=false, ('authenticated',...)=true.

REVOKE EXECUTE ON FUNCTION public.d0_s4kent_gate_health() FROM anon;

-- ROLLBACK: GRANT EXECUTE ON FUNCTION public.d0_s4kent_gate_health() TO anon;
