-- Migration 20260512210000 · level:admin · lane:Audit/Push · writes:sweep_old_listings() · reads:listings_snapshots · pre:none
-- Tighten listings_snapshots retention 60d → 30d.
--
-- Context: C1 audit 2026-05-11 flagged +23.6%/3d growth on listings_snapshots
-- (now 2.4GB / 9.6M rows). Consumer audit 2026-05-12 confirmed:
--   * Price chart workbench reads event_metrics (time-series aggregate, indefinite retention)
--   * Movers / dashboards read aggregates (6-96h windows)
--   * Storefront SQL-only demo + section/row map use LATEST snapshot only
--   * No UI consumer queries listings_snapshots with date filter >96h
-- Trade-off: lose per-listing forensic detail (specific tevo_ticket_group_id
-- price trajectory) >30d. Aggregate time-series (event_metrics, zone_metrics,
-- section_metrics) preserve all >30d trend analysis. Sales tables
-- (evo_orders, evo_order_items, seatgeek_orders, seatgeek_order_tickets,
-- seatgeek_seller_listings, seatgeek_historic_sales, seatgeek_sales_snapshots,
-- seatdata_sales_snapshots) are NEVER swept — forever retention.
--
-- Next step (separate PR): content_hash dedup on listings_snapshots for
-- additional ~47% storage reduction within the 30d window.

CREATE OR REPLACE FUNCTION public.sweep_old_listings()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  deleted_count integer;
BEGIN
  DELETE FROM listings_snapshots
  WHERE captured_at < now() - interval '30 days';
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;

COMMENT ON FUNCTION public.sweep_old_listings() IS
  'Drops listings_snapshots rows older than 30 days. Per-listing detail aged out; aggregates (event_metrics/zone_metrics/section_metrics) preserve trends indefinitely. Sales tables never swept. Daily cron at 03:00.';
