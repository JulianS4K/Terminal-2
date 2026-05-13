-- Migration 20260513000100 · level:admin · lane:Audit/Push · writes:revokes+grants+search_path(resolve_seatgeek_order,backfill_seatgeek_orders_resolved,rollup_event_section_row,sg_listings_queue_window,sweep_inactive_event_states,trg_set_updated_at) · reads:- · pre:20260513000050

-- A1 deep audit of C1's code surface (11 migrations) caught 5 SECURITY
-- INVOKER functions + 1 trigger helper missing the defense-in-depth posture
-- established by PRs #57/#67/#68. The pattern: every function should ship
-- with REVOKE FROM PUBLIC + explicit GRANT TO service_role + SET search_path.
--
-- Practical exploit risk on these is LOW today because the functions are
-- SECURITY INVOKER and write into RLS-gated tables — anon callers hit RLS
-- denies. But that's load-bearing on RLS staying right. This migration
-- closes the grant model so the functions are unreachable by anon at the
-- API boundary, and adds search_path so schema-injection is impossible.
--
-- Five INVOKER functions:
--   resolve_seatgeek_order(text)                           — 100060
--   backfill_seatgeek_orders_resolved(int)                 — 100060
--   rollup_event_section_row(bigint, timestamptz)          — 100150
--   sg_listings_queue_window(text, int, int)               — 100210 (touches vault via get_app_secret)
--   sweep_inactive_event_states()                          — 100210
--
-- Plus 1 trigger helper:
--   trg_set_updated_at()                                   — 100000
-- (trigger; only does NEW.updated_at := now(); search_path hardening is
-- hygiene since now() is in pg_catalog. Still worth the 1 line.)
--
-- NOT touched (already locked down):
--   bot_chat_log / bot_chat_resolve            — #64 fix 574ce6a, SD + current_user
--   sweep_expired_pg_net_pending(_all)         — #65 / 20260512200000, SD + current_user
--   sweep_duplicate_listings / _terminal_event_listings / match_listings_to_sg_tick
--                                              — #67 grant + #68 body-assert, fully hardened

-- ---- Grant lockdown ----------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.resolve_seatgeek_order(text)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.backfill_seatgeek_orders_resolved(int)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.rollup_event_section_row(bigint, timestamptz)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sg_listings_queue_window(text, int, int)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sweep_inactive_event_states()
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.trg_set_updated_at()
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.resolve_seatgeek_order(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.backfill_seatgeek_orders_resolved(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.rollup_event_section_row(bigint, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.sg_listings_queue_window(text, int, int) TO service_role;
GRANT EXECUTE ON FUNCTION public.sweep_inactive_event_states() TO service_role;
-- trg_set_updated_at: triggers run as the table owner regardless of grant,
-- so service_role doesn't need EXECUTE — but be explicit anyway so the
-- function isn't reachable via PostgREST RPC by mistake.
GRANT EXECUTE ON FUNCTION public.trg_set_updated_at() TO service_role;

-- ---- search_path hardening --------------------------------------------
-- ALTER FUNCTION ... SET search_path = X attaches a function-level GUC.
-- Subsequent calls run with the locked path regardless of caller's setting.
-- pg_temp is appended last so temp objects can never shadow public ones.
ALTER FUNCTION public.resolve_seatgeek_order(text)
  SET search_path = public, pg_temp;
ALTER FUNCTION public.backfill_seatgeek_orders_resolved(int)
  SET search_path = public, pg_temp;
ALTER FUNCTION public.rollup_event_section_row(bigint, timestamptz)
  SET search_path = public, pg_temp;
ALTER FUNCTION public.sg_listings_queue_window(text, int, int)
  SET search_path = public, pg_temp;
ALTER FUNCTION public.sweep_inactive_event_states()
  SET search_path = public, pg_temp;
ALTER FUNCTION public.trg_set_updated_at()
  SET search_path = pg_catalog, pg_temp;
