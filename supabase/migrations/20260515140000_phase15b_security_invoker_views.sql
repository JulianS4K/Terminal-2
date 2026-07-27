-- Migration 20260515140000 · level:admin · lane:Audit/Push · writes:ALTER VIEW security_invoker on 7 phase-15b views + tighten tickpick ingest RPC GRANTs · reads:- · pre:20260514120000,20260515120000
-- Phase-15b ESPN-team views regression + TickPick RPC grant tightening.
--
-- Two follow-ups caught by audit pass:
--
-- 1. C1's PR #92 (migration 20260514120000_phase15b_revision_recent_results)
--    used `CREATE OR REPLACE VIEW` which resets the `security_invoker`
--    reloption to false. PR #94 (security_invoker_view_sweep) had set it
--    to true on the 139 then-existing views, but the 7 phase-15b views
--    were created AFTER that sweep, so they're SECURITY DEFINER again:
--      v_team_season_progression
--      v_team_attendance_trend
--      v_team_win_prob_trend
--      v_team_recent_results
--      v_team_roster_full
--      v_team_schedule_30d
--      v_team_transactions
--    Re-applying the same security_invoker=true flag closes 7 ERROR lints.
--
-- 2. tickpick_orders_ingest_from_apps_script (migration 20260515120000)
--    was granted EXECUTE to anon + authenticated + service_role. Only
--    anon is needed (Apps Script uses the anon key). Revoke from
--    authenticated to tighten the surface. The advisor will still warn
--    about anon-callable SECDEF (intentional, gated by shared secret) —
--    we add a long COMMENT documenting the intent so the warning is
--    explicit-by-design.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 (this session). Idempotent.

-- ============================================================
-- 1. Re-apply security_invoker=true to the 7 phase-15b views
-- ============================================================

ALTER VIEW public.v_team_season_progression  SET (security_invoker = true);
ALTER VIEW public.v_team_attendance_trend    SET (security_invoker = true);
ALTER VIEW public.v_team_win_prob_trend      SET (security_invoker = true);
ALTER VIEW public.v_team_recent_results      SET (security_invoker = true);
ALTER VIEW public.v_team_roster_full         SET (security_invoker = true);
ALTER VIEW public.v_team_schedule_30d        SET (security_invoker = true);
ALTER VIEW public.v_team_transactions        SET (security_invoker = true);

-- ============================================================
-- 2. Tighten tickpick_orders_ingest_from_apps_script grants
-- ============================================================

REVOKE EXECUTE ON FUNCTION public.tickpick_orders_ingest_from_apps_script(jsonb, text)
  FROM authenticated;
-- anon retains EXECUTE — Apps Script uses the anon JWT.
-- service_role retains EXECUTE — useful for ad-hoc backfills via MCP.

COMMENT ON FUNCTION public.tickpick_orders_ingest_from_apps_script(jsonb, text) IS
  'Apps Script → Supabase ingest path for TickPick orders. '
  'EXPLICITLY anon-callable (Apps Script uses the public anon JWT). '
  'Security is enforced by the shared_secret check against vault entry '
  'APPSCRIPT_INGEST_SECRET (48 base64 chars). Advisor lints '
  '0028_anon_security_definer_function_executable + '
  '0029_authenticated_security_definer_function_executable are expected '
  'and documented as intentional. UPSERTs the JSONB array into '
  'tickpick_orders by tp_order_id. Returns (inserted, updated, skipped).';
