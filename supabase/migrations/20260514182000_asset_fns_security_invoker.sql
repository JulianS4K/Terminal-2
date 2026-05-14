-- Migration 20260514182000 · level:admin · lane:Audit/Push · writes:get_event_assets_public,get_performer_assets_public,get_venue_assets_public (security mode) · reads:- · pre:20260514181000
-- Security advisor WARN sweep — Level 2b of the post-pause cleanup.
-- Closes bot_chat row 94 (B1 SECDEF round-2 lockdown) that was 22h+ pending.
--
-- Before: 6 WARN lints (anon_security_definer_function_executable × 3 +
--         authenticated_security_definer_function_executable × 3) for the
--         3 public asset fetchers.
-- After:  0 WARN of this class. Cumulative advisor: 486 → 126 (−74%).
--
-- These functions are intentionally anon-callable (storefront UI hits them
-- via /rest/v1/rpc/get_*_assets_public) and are STABLE / read-only:
--   - get_event_assets_public:     SELECT FROM v_event_seating_chart
--   - get_performer_assets_public: SELECT FROM performer_metadata + joins
--   - get_venue_assets_public:     SELECT FROM venue_assets
--
-- All underlying tables/views (v_event_seating_chart, venue_assets,
-- performer_metadata, espn_teams_canonical, espn_athletes) already grant
-- SELECT to anon + authenticated. Flipping these functions from
-- SECURITY DEFINER to SECURITY INVOKER is safe: anon still calls them,
-- caller perms suffice, advisor warning clears.
--
-- Reversible: ALTER FUNCTION ... SECURITY DEFINER.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 ~17:45 UTC during cron-paused window
-- (bot_chat row 106). Idempotent codification per SYNC_PROTOCOL §5.

ALTER FUNCTION public.get_event_assets_public(bigint)     SECURITY INVOKER;
ALTER FUNCTION public.get_performer_assets_public(bigint) SECURITY INVOKER;
ALTER FUNCTION public.get_venue_assets_public(bigint)     SECURITY INVOKER;
