-- ============================================================================
-- Migration 20260911050000 — Exos (Bridge / D4): enable RLS on exos_invoice_counters
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_invoice_counters (DDL: ENABLE ROW LEVEL SECURITY, no policies)
-- Pre-reqs: 20260616240000 (exos_invoice_counters + exos_next_invoice_number)
-- Already applied to prod · via MCP 2026-09-11 (operator-directed; PR #975)
--
-- Readiness sweep 2026-09-11: exos_invoice_counters was the ONE exos_* table
-- in prod with rowsecurity = false. It was already unreachable from clients
-- (REVOKE ALL FROM anon, authenticated in 20260616240000) — the only writer is
-- the SECURITY DEFINER exos_next_invoice_number(), which runs as the table
-- owner and is unaffected by RLS. Enabling RLS with NO policies makes the
-- deny-by-default posture structural rather than grant-dependent, and clears
-- the Supabase advisor `rls_disabled_in_public` finding for the D4 schema.
--
-- Idempotent: ENABLE ROW LEVEL SECURITY is a no-op when already enabled.
-- ROLLBACK: ALTER TABLE public.exos_invoice_counters DISABLE ROW LEVEL SECURITY;
-- ============================================================================

ALTER TABLE public.exos_invoice_counters ENABLE ROW LEVEL SECURITY;

-- Belt-and-braces: keep the client grants revoked (re-asserting is harmless).
REVOKE ALL ON public.exos_invoice_counters FROM anon, authenticated;

COMMENT ON TABLE public.exos_invoice_counters IS
  'Per-org monotonic invoice sequence. RLS enabled with no policies: only the '
  'SECURITY DEFINER exos_next_invoice_number() (table owner) reads/writes it.';
