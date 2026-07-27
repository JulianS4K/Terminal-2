-- ============================================================================
-- Migration 20260509180000 — extend sg_events_canonical sync to orders + sales
--
-- Until now sg_events_canonical was only fed from seatgeek_seller_listings
-- (events with current open inventory). seatgeek_orders carries 161 more
-- distinct sg_event_ids — historical events we sold tickets to but no longer
-- have listings on. Equally interesting for cross-source baselines + analytics.
--
-- Adds:
--   has_orders / has_broker_sales columns on sg_events_canonical
--   sync_sg_orders_to_canonical()       — upsert from seatgeek_orders
--   sync_sg_broker_sales_to_canonical() — upsert from seatgeek_sales_snapshots
--   sync_canonical_to_seatgeek_orders() — back-write tevo_event_id from
--                                         canonical onto matching orders rows
--   Extended sg_canonical_auto_match_tick() to call all three.
-- ============================================================================

ALTER TABLE sg_events_canonical
  ADD COLUMN IF NOT EXISTS has_orders boolean DEFAULT false,
  ADD COLUMN IF NOT EXISTS has_broker_sales boolean DEFAULT false;

CREATE OR REPLACE FUNCTION sync_sg_orders_to_canonical()
RETURNS TABLE(rows_inserted int, rows_updated int) AS $$
DECLARE
  v_inserted int := 0;
  v_updated int := 0;
BEGIN
  WITH src AS (
    SELECT DISTINCT ON (so.sg_event_id)
      so.sg_event_id, so.sg_event_name, so.sg_event_date, so.sg_venue
    FROM seatgeek_orders so
    WHERE so.sg_event_id IS NOT NULL
    ORDER BY so.sg_event_id, so.pulled_at DESC NULLS LAST
  ),
  upserted AS (
    INSERT INTO sg_events_canonical (
      sg_event_id, sg_event_name, sg_event_date, sg_venue_name,
      has_orders, updated_at
    )
    SELECT s.sg_event_id, s.sg_event_name, s.sg_event_date, s.sg_venue,
           true, now()
    FROM src s
    ON CONFLICT (sg_event_id) DO UPDATE SET
      sg_event_name = COALESCE(sg_events_canonical.sg_event_name, EXCLUDED.sg_event_name),
      sg_event_date = COALESCE(sg_events_canonical.sg_event_date, EXCLUDED.sg_event_date),
      sg_venue_name = COALESCE(sg_events_canonical.sg_venue_name, EXCLUDED.sg_venue_name),
      has_orders = true,
      updated_at = now()
    RETURNING (xmax = 0) AS is_insert
  )
  SELECT count(*) FILTER (WHERE is_insert),
         count(*) FILTER (WHERE NOT is_insert)
  INTO v_inserted, v_updated FROM upserted;
  RETURN QUERY SELECT v_inserted, v_updated;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sync_sg_broker_sales_to_canonical()
RETURNS TABLE(rows_inserted int, rows_updated int) AS $$
DECLARE
  v_inserted int := 0;
  v_updated int := 0;
BEGIN
  WITH src AS (
    SELECT DISTINCT sg_event_id FROM seatgeek_sales_snapshots
    WHERE sg_event_id IS NOT NULL
  ),
  upserted AS (
    INSERT INTO sg_events_canonical (
      sg_event_id, sg_event_name, has_broker_sales, updated_at
    )
    SELECT s.sg_event_id, '(broker sales only)', true, now()
    FROM src s
    ON CONFLICT (sg_event_id) DO UPDATE SET
      has_broker_sales = true,
      updated_at = now()
    RETURNING (xmax = 0) AS is_insert
  )
  SELECT count(*) FILTER (WHERE is_insert),
         count(*) FILTER (WHERE NOT is_insert)
  INTO v_inserted, v_updated FROM upserted;
  RETURN QUERY SELECT v_inserted, v_updated;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sg_canonical_auto_match_tick()
RETURNS jsonb AS $$
DECLARE
  v_seller record; v_orders record; v_sales record;
  v_match record; v_back int;
BEGIN
  SELECT * INTO v_seller FROM sync_sg_seller_listings_to_canonical();
  SELECT * INTO v_orders FROM sync_sg_orders_to_canonical();
  SELECT * INTO v_sales  FROM sync_sg_broker_sales_to_canonical();
  v_back := refresh_sg_canonical_from_xref();
  SELECT * INTO v_match FROM auto_match_sg_canonical();
  RETURN jsonb_build_object(
    'seller_inserted',       v_seller.rows_inserted,
    'seller_updated',        v_seller.rows_updated,
    'orders_inserted',       v_orders.rows_inserted,
    'orders_updated',        v_orders.rows_updated,
    'broker_sales_inserted', v_sales.rows_inserted,
    'broker_sales_updated',  v_sales.rows_updated,
    'backsync_from_xref',    v_back,
    'attempted',             v_match.attempted,
    'newly_matched',         v_match.newly_matched,
    'still_unmatched_in_pass', v_match.still_unmatched,
    'total_unmatched_now',   v_match.needs_tevo_search,
    'ran_at', now()
  );
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sync_canonical_to_seatgeek_orders()
RETURNS int AS $$
DECLARE v_count int;
BEGIN
  UPDATE seatgeek_orders so
  SET tevo_event_id = sgc.tevo_event_id
  FROM sg_events_canonical sgc
  WHERE so.sg_event_id = sgc.sg_event_id
    AND so.tevo_event_id IS NULL
    AND sgc.tevo_event_id IS NOT NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;
