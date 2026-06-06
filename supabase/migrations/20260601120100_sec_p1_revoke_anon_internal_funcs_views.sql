-- ============================================================
-- SECURITY P1 — revoke anon/authenticated access to internal SECURITY DEFINER
-- write-jobs and internal SECDEF views (2026-06-01).
-- Source: Supabase Security Advisor lints 0028/0029 (secdef function executable by
-- anon/authenticated) and 0010 (security_definer_view).
--
-- (A) WRITE-CAPABLE SECDEF FUNCTIONS callable by anon.
-- These 12 are internal, cron-driven maintenance/compute/discovery jobs. They run as
-- their owner (postgres), bypass RLS, and several trigger UPSTREAM API calls
-- (TEvo/TM/SeatGeek discovery + listing sweeps). An unauthenticated caller could invoke
-- them on demand to (a) burn upstream API quota / rate-limits and rack up cost, or
-- (b) poison discovery queues / force expensive recomputes (DoS). Clients never call
-- these; cron runs as postgres/service_role and is UNAFFECTED by revoking anon/authenticated.
--
-- DELIBERATELY NOT TOUCHED here (flagged for operator decision in the PR):
--   * tickpick_orders_ingest_from_apps_script(jsonb, text) — anon-callable BY DESIGN,
--     gated by a shared secret; an external Apps Script integration depends on it.
--     Revoking anon would break that integration. Confirm the secret is strong/rotated.
--   * get_returning_entities(...) / get_returning_entity_events(...) — read-only; may be
--     legitimate client RPCs. Left in place pending confirmation.

REVOKE EXECUTE ON FUNCTION public.backfill_aq_maps() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.compute_event_movers_index(p_source text, p_window_days integer) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.compute_sg_fill_rate() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.refresh_sg_broker_sales_event_metrics_lifetime(p_max_events integer) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sg_listings_floor_sweep(p_max integer, p_min_remaining integer) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.sg_priority_poll_tick(p_max_polls integer) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.td_apply_targets() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.td_gt_automap_check() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.td_tm_discover() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.td_tm_discover_drain() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.td_tp_discover() FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.td_tp_discover_drain() FROM anon, authenticated;

-- (B) INTERNAL SECDEF VIEWS readable by anon (owner=postgres → bypass RLS on base tables).
-- These leak internal operational data and should not be client-readable at all:
--   * unified_listings              — exposes wholesale_price, is_owned, brokerage_name
--                                     (margin / sourcing intelligence).
--   * v_sg_token_budget             — reads net._http_response (pg_net internals) to expose
--                                     live SeatGeek rate-limit budget.
--   * v_ticketsdata_credit_usage_daily — exposes API credit/quota consumption per endpoint.
-- Backend reads via service_role and is unaffected.
--
-- NOT TOUCHED: exos_public_events / exos_public_orgs / exos_public_tiers — names imply an
-- intentionally public storefront surface. Flagged for operator: keep public (and instead
-- convert to security_invoker + add anon read policies on base tables) vs. lock down.

REVOKE SELECT ON public.unified_listings                FROM anon, authenticated;
REVOKE SELECT ON public.v_sg_token_budget               FROM anon, authenticated;
REVOKE SELECT ON public.v_ticketsdata_credit_usage_daily FROM anon, authenticated;
