-- Migration 20260513200000 · level:admin · lane:A1 · writes:pg_proc(grants ×13) · reads:pg_proc · pre:20260513185248
-- Pre-resume audit response 2026-05-13 — REVOKE EXECUTE on every advisor-flagged
-- SECURITY DEFINER function from `anon` + `authenticated`. Round 2 of the lockdown
-- PR #87 started (which fixed get_app_secret).
--
-- Scope of this migration: ACCESS CONTROL ONLY (REVOKE/GRANT). Body asserts for
-- the 4 fns currently missing them are deferred to a separate B1 follow-up PR
-- (cleaner CREATE OR REPLACE with exact body preservation). REVOKE is the real
-- gate; body assert is defense-in-depth.
--
-- Inventory of the 13 advisor-flagged SECDEF fns:
--   GROUP A — REVOKE here, body-assert in B1 follow-up (currently NO body guard, can WRITE):
--     - public.upsert_app_secret(text, text)        — clobbers vault.secrets (P0)
--     - public.nws_alerts_process()                 — writes nws_alerts, nws_alert_zones, etc.
--     - public.get_or_authorize_pull(bigint, text, text, integer)  — inserts event_pulls
--     - public.sweep_old_listings()                 — DELETEs from listings_snapshots
--   GROUP B — REVOKE here, body assert already present (defense in depth):
--     - public.match_listings_to_sg_tick()
--     - public.sweep_duplicate_listings(integer)
--     - public.sweep_expired_pg_net_pending(regclass, integer)
--     - public.sweep_terminal_event_listings(integer)
--     - public.refresh_latest_event_metrics()
--     - public.sweep_all_expired_pg_net_pending(integer)
--   GROUP C — INTENTIONALLY anon-callable (storefront + d2_dashboard pre-auth reads).
--             Leaving anon EXECUTE in place. Listed here for completeness:
--     - public.get_event_assets_public(bigint)
--     - public.get_performer_assets_public(bigint)
--     - public.get_venue_assets_public(bigint)
--             If these are later determined to expose more than retail-safe fields,
--             follow PR #87's exact pattern (REVOKE + body assert).
--
-- Reference: audit findings C1, H1, H6, M3, M4. bot_chat row 94 (B1 ping).
--
-- Reversal: re-GRANT EXECUTE TO anon, authenticated on each function. Per-fn reversal
-- is one line each — but no operational reason to roll back. Keep this migration in
-- place permanently.

BEGIN;

-- ============================================================
-- GROUP A — P0 / HIGH severity: NO body guard, WRITE access
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.upsert_app_secret(text, text)                          FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.upsert_app_secret(text, text)                          TO service_role;

REVOKE EXECUTE ON FUNCTION public.nws_alerts_process()                                   FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.nws_alerts_process()                                   TO service_role;

REVOKE EXECUTE ON FUNCTION public.get_or_authorize_pull(bigint, text, text, integer)     FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.get_or_authorize_pull(bigint, text, text, integer)     TO service_role;

REVOKE EXECUTE ON FUNCTION public.sweep_old_listings()                                   FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sweep_old_listings()                                   TO service_role;

-- ============================================================
-- GROUP B — Already body-guarded; REVOKE for hygiene
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.match_listings_to_sg_tick()                            FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.match_listings_to_sg_tick()                            TO service_role;

REVOKE EXECUTE ON FUNCTION public.sweep_duplicate_listings(integer)                      FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sweep_duplicate_listings(integer)                      TO service_role;

REVOKE EXECUTE ON FUNCTION public.sweep_expired_pg_net_pending(regclass, integer)        FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sweep_expired_pg_net_pending(regclass, integer)        TO service_role;

REVOKE EXECUTE ON FUNCTION public.sweep_terminal_event_listings(integer)                 FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sweep_terminal_event_listings(integer)                 TO service_role;

REVOKE EXECUTE ON FUNCTION public.refresh_latest_event_metrics()                         FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.refresh_latest_event_metrics()                         TO service_role;

REVOKE EXECUTE ON FUNCTION public.sweep_all_expired_pg_net_pending(integer)              FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.sweep_all_expired_pg_net_pending(integer)              TO service_role;

COMMIT;

-- Verification (run separately, NOT inside this migration):
--
--   SELECT p.proname, array_agg(r.grantee ORDER BY r.grantee) AS grantees
--   FROM pg_proc p
--   JOIN information_schema.routine_privileges r ON r.routine_name = p.proname AND r.specific_schema = 'public'
--   WHERE p.proname IN (
--     'upsert_app_secret','nws_alerts_process','get_or_authorize_pull','sweep_old_listings',
--     'match_listings_to_sg_tick','sweep_duplicate_listings','sweep_expired_pg_net_pending',
--     'sweep_terminal_event_listings','refresh_latest_event_metrics','sweep_all_expired_pg_net_pending'
--   )
--   GROUP BY p.proname;
--
-- Expected: every row's grantees array = {postgres, service_role} (no anon, no authenticated).
