-- ============================================================================
-- Migration 20260621180156 — pgcrypto search_path + monitoring-view hardening
--
-- Lane:     A1 (DB security)
-- Touches:  public.build_watchlist_daily_email (W, ALTER search_path),
--           public.exos_check_in_ticket        (W, ALTER search_path),
--           public.v_sg_broker_429_health, v_sg_broker_429_starved_events,
--           public.v_sg_blindspot_movers, v_tevo_blindspot_movers,
--           public.v_td_poll_health           (W, ALTER ... security_invoker)
-- Pre-reqs: 20260519130000 (429 views); objects exist
-- Apply:    APPLIED to prod 2026-06-21 (operator-authorized, full permissions).
--           Verified: pgcrypto check fail->ok; security_definer_views 37->32;
--           views still return rows. ⚠ FOLLOW-UP (A1): v_td_poll_health is
--           anon-granted — with security_invoker on, confirm no anon/authenticated
--           surface relies on definer reads (REVOKE anon is the cleaner endgame).
--
-- WHY:
--   Two release_health_check FAILs are chronic security-hygiene backlog, not
--   regressions, but the user asked to clear them:
--     - pgcrypto_missing_extensions_searchpath = 2
--     - security_definer_views (the 5 newest monitoring/alert views)
--
-- PART 1 — pgcrypto search_path (safe, non-behavioral):
--   build_watchlist_daily_email + exos_check_in_ticket are flagged for using a
--   pgcrypto routine without 'extensions' on search_path. (exos_check_in_ticket
--   already schema-qualifies extensions.hmac, so it is effectively a false
--   positive — but adding 'extensions' is harmless and clears the check for
--   both.) Adding a schema to search_path only widens name resolution; it
--   cannot break a qualified call.
--
-- ⚠ PART 2 — security_invoker on the 5 monitoring views (BEHAVIORAL — A1 decide):
--   Flipping security_invoker=true makes each view evaluate RLS as the CALLER
--   instead of the view owner. These are ops/monitoring views; the secure
--   default is invoker. Grants observed 2026-06-21:
--     v_sg_broker_429_health, v_sg_broker_429_starved_events,
--     v_sg_blindspot_movers, v_tevo_blindspot_movers  -> authenticated + service_role
--     v_td_poll_health                                -> anon + authenticated + service_role  (!)
--   v_td_poll_health is reachable by anon — flipping (or, better, REVOKEing
--   anon) is the actual hardening. Risk: if any surface reads these as
--   authenticated/anon expecting definer-level rows, the flip can empty them.
--   A1: confirm no frontend depends on definer reads before applying Part 2;
--   if unsure, apply Part 1 now and split Part 2 out for a targeted review.
--
-- VERIFICATION (run after apply):
--   SELECT * FROM public.release_health_check()
--    WHERE check_name IN ('pgcrypto_missing_extensions_searchpath','security_definer_views');
--   -- pgcrypto -> 'ok'; security_definer_views metric drops by 5.
-- ============================================================================

-- ---- Part 1: pgcrypto search_path (safe) ------------------------------------
ALTER FUNCTION public.build_watchlist_daily_email(text, integer)
  SET search_path TO 'public', 'extensions', 'pg_temp';
ALTER FUNCTION public.exos_check_in_ticket(uuid, text, text, text)
  SET search_path TO 'public', 'extensions', 'pg_temp';

-- ---- Part 2: monitoring-view security_invoker (⚠ behavioral — see header) ----
ALTER VIEW public.v_sg_broker_429_health         SET (security_invoker = true);
ALTER VIEW public.v_sg_broker_429_starved_events SET (security_invoker = true);
ALTER VIEW public.v_sg_blindspot_movers          SET (security_invoker = true);
ALTER VIEW public.v_tevo_blindspot_movers        SET (security_invoker = true);
ALTER VIEW public.v_td_poll_health               SET (security_invoker = true);
