-- ============================================================================
-- Migration 20260705150060 — revoke anon/authenticated EXECUTE on internal
--                            SECURITY DEFINER mutators
--
-- Lane:     A1 (DB security / Auditor)
-- Touches:  function grants (W): sg_sales_poll_tick, td_sg_discover,
--           td_log_poll_failure, sweep_old_broadway_cast_pulls
-- Pre-reqs: none
--
-- Applied to prod 2026-07-05 via MCP (operator-directed supabase-audit
-- session); idempotent on replay.
--
-- Four cron/trigger-internal SECDEF functions (vault-secret access, paid-API
-- budget burn, log sweeps) were executable by anon/authenticated via
-- PostgREST RPC. No FE caller exists (repo-verified); sg_sales_poll_tick
-- already self-guards on current_user — grants now match. Deliberately NOT
-- revoked: tickpick_orders_ingest_from_apps_script (external Google Apps
-- Script caller on the anon key, gated by a vault shared secret — follow-up:
-- move to an edge fn with requireCronSecret), set_user_alert_active
-- (FE, auth.uid()-scoped), get_terminal_news_ticker + fantasy_* (FE-facing).
-- ============================================================================

revoke execute on function public.sg_sales_poll_tick(integer, integer) from public, anon, authenticated;
revoke execute on function public.td_sg_discover(integer) from public, anon, authenticated;
revoke execute on function public.td_log_poll_failure() from public, anon, authenticated;
revoke execute on function public.sweep_old_broadway_cast_pulls() from public, anon, authenticated;
