-- ============================================================
-- SECURITY P1b — follow-up to sec_p1 (2026-06-01).
-- Several of the internal SECDEF write-jobs carried an explicit EXECUTE grant to PUBLIC,
-- so the REVOKE FROM anon/authenticated in sec_p1 was a no-op for them (access was
-- inherited via the PUBLIC pseudo-role). Revoke from PUBLIC to actually lock them down.
-- Verified: service_role holds its own explicit EXECUTE grant on all 12, and the cron
-- jobs run as the postgres owner — so backend and cron are unaffected.
-- ============================================================
REVOKE EXECUTE ON FUNCTION public.backfill_aq_maps() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.compute_event_movers_index(p_source text, p_window_days integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.compute_sg_fill_rate() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.refresh_sg_broker_sales_event_metrics_lifetime(p_max_events integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.sg_listings_floor_sweep(p_max integer, p_min_remaining integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.sg_priority_poll_tick(p_max_polls integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.td_apply_targets() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.td_gt_automap_check() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.td_tm_discover() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.td_tm_discover_drain() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.td_tp_discover() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.td_tp_discover_drain() FROM PUBLIC;
