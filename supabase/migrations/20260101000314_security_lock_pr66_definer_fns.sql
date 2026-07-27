-- Migration 20260513000000 · level:admin · lane:Audit/Push · writes:revokes+grants(sweep_duplicate_listings,sweep_terminal_event_listings,match_listings_to_sg_tick) · pre:20260512240000

-- A1 security review of PR #66: three SECURITY DEFINER functions shipped
-- without explicit REVOKE FROM PUBLIC. Postgres grants EXECUTE to PUBLIC by
-- default on CREATE FUNCTION; combined with SECURITY DEFINER, an anon caller
-- can hit /rest/v1/rpc/<fn> via PostgREST and:
--   * sweep_duplicate_listings(p_max_events := <huge>) — mass DELETE on listings_snapshots
--   * sweep_terminal_event_listings(p_max_events := <huge>) — same
--   * match_listings_to_sg_tick() — pollute listing_xref with bogus matches
--
-- Pattern inconsistent with PR #64/#65 which REVOKE + assert current_user at
-- the function body. This migration brings #66's functions in line: REVOKE
-- from PUBLIC/anon/authenticated; explicit GRANT to service_role only.
-- Cron jobs run as the cron-owner (service_role/postgres) so they're
-- unaffected.
--
-- Follow-up (separate PR): re-CREATE the 3 functions with `IF current_user
-- NOT IN ('service_role', 'postgres') THEN RAISE EXCEPTION` defense-in-depth
-- per the pattern A1 established in 20260512200000 and C1 adopted in #64.
-- The grant model is the primary gate; the body assertion is belt-and-
-- suspenders for the day someone widens a grant by mistake.

REVOKE EXECUTE ON FUNCTION public.sweep_duplicate_listings(int)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sweep_terminal_event_listings(int)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.match_listings_to_sg_tick()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.sweep_duplicate_listings(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.sweep_terminal_event_listings(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.match_listings_to_sg_tick() TO service_role;
