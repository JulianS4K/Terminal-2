-- ============================================================================
-- Migration 20260525190000 · level:security · lane:Security
-- writes: EXECUTE grants on 5 SECDEF fns (REVOKE anon/authenticated, keep service_role)
-- reads:  pg_proc (audit only)
-- pre:    none (idempotent REVOKE/GRANT)
--
-- B1 sweep 2026-05-25 — Supabase security advisor ("Public Can Execute
-- SECURITY DEFINER Function", 29 hits). 24 are body-gated (shared-secret /
-- auth.jwt) or intentional read-only diagnostics; 5 are UNGATED. These are the
-- residual gaps PR #298 did not cover — #298 revoked anon EXECUTE on 16 SECDEF
-- fns incl. `cron_should_fire`, but missed its two siblings from the same
-- migration (20260515250000) plus 3 others added since.
--
-- Each is SECURITY DEFINER + owned by `postgres` (bypassrls), so an anon caller
-- executes them with full privilege over PostgREST (/rest/v1/rpc/<fn>).
--
-- FINDINGS CLOSED HERE (5 fns)
-- -------------------------------------------------------------------------
-- SEC-MED (3 VOLATILE — anon could trigger privileged work):
--   * cron_resume_with_gate(text)            -- resumes/unpauses a cron job
--   * rollup_event_section_row_batch(int)    -- expensive batch compute (amplification/DoS)
--   * tevo_blindspot_metrics_refresh()       -- triggers metrics-refresh work
-- SEC-LOW (2 STABLE — read-only, defense-in-depth):
--   * cron_last_fire(text)                   -- reads last cron fire time
--   * cross_source_venue_resolve(text,text,text) -- venue-resolution lookup
--
-- SAFE: all 5 are invoked by crons / backend running as service_role (retains
-- EXECUTE), and intra-DB callers run as their own SECDEF owner; no anon /
-- authenticated app path calls any of them. Matches the #298 pattern + outcome
-- (anon EXECUTE = denied; service_role unaffected; functions resolve by oid).
--
-- ## Regression risk
-- cron.failed_jobs_90min — none (service_role retains EXECUTE; cron DO-blocks
--   unchanged; oids preserved — no CREATE OR REPLACE here, only grants).
-- PostgREST anon/authenticated callers — intentionally lose access to these 5
--   RPCs. Re-probe after apply: SET ROLE anon; SELECT public.cron_last_fire('x'); -> permission denied.
--
-- ## Already applied to prod
-- NOT YET. Operator authorizes prod apply (2026-05-13 lockdown). cron_* fns are
-- C1-lane (cron policy gate), the rollup/refresh/venue fns are A1/D-lane; REVOKE
-- is identical + safe — owning lanes flagged in bot_chat; A1 has apply-time veto.
-- ============================================================================

-- --- SEC-MED: VOLATILE — anon could trigger privileged work ------------------
REVOKE EXECUTE ON FUNCTION public.cron_resume_with_gate(text)              FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cron_resume_with_gate(text)              TO service_role;
REVOKE EXECUTE ON FUNCTION public.rollup_event_section_row_batch(integer)  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.rollup_event_section_row_batch(integer)  TO service_role;
REVOKE EXECUTE ON FUNCTION public.tevo_blindspot_metrics_refresh()         FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.tevo_blindspot_metrics_refresh()         TO service_role;

-- --- SEC-LOW: STABLE read-only — defense-in-depth ----------------------------
REVOKE EXECUTE ON FUNCTION public.cron_last_fire(text)                                  FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cron_last_fire(text)                                  TO service_role;
REVOKE EXECUTE ON FUNCTION public.cross_source_venue_resolve(text, text, text)          FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cross_source_venue_resolve(text, text, text)          TO service_role;
