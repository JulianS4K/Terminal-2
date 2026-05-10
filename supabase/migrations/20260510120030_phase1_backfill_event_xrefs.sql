-- ============================================================================
-- Migration 20260510120030 — Phase 1: backfill SG / SD event xref tables
--
-- Lane:     canonical
-- Touches:  seatgeek_event_xref (W), seatdata_event_xref (W),
--           sg_events_canonical (R), seatgeek_listings_snapshots (R),
--           seatgeek_sales_snapshots (R), seatgeek_seller_listings (R),
--           seatgeek_event_metrics (R), seatdata_listings_snapshots (R)
-- Pre-reqs: 20260507000013 (event_xref + per-source xref tables exist),
--           20260509150000 (sg_events_canonical seeded)
--
-- Backfill per-source event xref tables from data already linked to a Tevo
-- event. The SG / SD ingest pipelines store tevo_event_id on each snapshot
-- row but the xref tables drift; this catches them up. Idempotent
-- (ON CONFLICT DO NOTHING).
-- ============================================================================

-- SeatGeek event xref ← sg_events_canonical (rows that already carry tevo_event_id)
INSERT INTO seatgeek_event_xref (
    tevo_event_id, sg_event_id, sg_event_name, sg_event_type, sg_event_location,
    sg_start_data, matched_at, match_method, match_confidence, meta)
SELECT c.tevo_event_id, c.sg_event_id, c.sg_event_name, c.sg_category,
       NULLIF(concat_ws(', ', c.sg_venue_name, c.sg_venue_city, c.sg_venue_state), ''),
       c.sg_datetime_utc, COALESCE(c.matched_at, NOW()),
       COALESCE(c.match_method, 'backfill_from_sg_canonical'),
       c.match_confidence,
       jsonb_build_object('backfilled_at', NOW(), 'origin', 'sg_events_canonical')
  FROM sg_events_canonical c
 WHERE c.tevo_event_id IS NOT NULL
ON CONFLICT (tevo_event_id) DO NOTHING;

-- SeatGeek event xref ← snapshot tables (listings/sales/seller/orders/metrics)
INSERT INTO seatgeek_event_xref (
    tevo_event_id, sg_event_id, matched_at, match_method, meta)
SELECT DISTINCT ON (s.tevo_event_id)
       s.tevo_event_id, s.sg_event_id, NOW(),
       'backfill_from_snapshots',
       jsonb_build_object('backfilled_at', NOW(), 'origin', s.origin)
  FROM (
    SELECT tevo_event_id, sg_event_id, 'listings'::text AS origin
      FROM seatgeek_listings_snapshots WHERE tevo_event_id IS NOT NULL
    UNION ALL
    SELECT tevo_event_id, sg_event_id, 'sales'
      FROM seatgeek_sales_snapshots WHERE tevo_event_id IS NOT NULL
    UNION ALL
    SELECT tevo_event_id, sg_event_id, 'seller'
      FROM seatgeek_seller_listings WHERE tevo_event_id IS NOT NULL
    UNION ALL
    SELECT tevo_event_id, sg_event_id, 'metrics'
      FROM seatgeek_event_metrics
     WHERE tevo_event_id IS NOT NULL AND sg_event_id IS NOT NULL
    UNION ALL
    SELECT tevo_event_id, sg_event_id, 'orders'
      FROM seatgeek_orders
     WHERE tevo_event_id IS NOT NULL AND sg_event_id IS NOT NULL
  ) s
ON CONFLICT (tevo_event_id) DO NOTHING;

-- SeatData event xref ← sd snapshot tables (tevo_event_id is NOT NULL there)
INSERT INTO seatdata_event_xref (
    tevo_event_id, sd_event_id, matched_at, match_method, meta)
SELECT DISTINCT ON (s.tevo_event_id)
       s.tevo_event_id, s.sd_event_id, NOW(),
       'backfill_from_snapshots',
       jsonb_build_object('backfilled_at', NOW(), 'origin', s.origin)
  FROM (
    SELECT tevo_event_id, sd_event_id, 'event_stats'::text AS origin
      FROM seatdata_event_stats
    UNION ALL
    SELECT tevo_event_id, sd_event_id, 'listings'
      FROM seatdata_listings_snapshots
    UNION ALL
    SELECT tevo_event_id, sd_event_id, 'sales'
      FROM seatdata_sales_snapshots
  ) s
ON CONFLICT (tevo_event_id) DO NOTHING;
