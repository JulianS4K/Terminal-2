-- ============================================================================
-- Migration 20260510200000 — Phase 14: event view supporting views
--
-- Lane:     canonical
-- Touches:  v_seatgeek_listings_classified (CREATE VIEW),
--           v_event_competing_events (CREATE VIEW),
--           v_event_data_freshness (CREATE VIEW);
--           reads seatgeek_listings_snapshots, seatgeek_seller_listings,
--           events, v_venue_neighbors, listings_snapshots, evo_orders,
--           evo_order_items, seatgeek_sales_snapshots, seatgeek_orders,
--           seatdata_listings_snapshots, v_event_espn_state, v_event_weather,
--           v_event_nws_alerts, nws_alerts, v_event_reddit
-- Pre-reqs: 20260510130030 (Phase 7), 20260510180000 (Phase 12),
--           20260510190000 (Phase 13), v_venue_neighbors (pre-existing)
--
--   1. v_seatgeek_listings_classified — adds an ownership_class column to
--      seatgeek_listings_snapshots: 'ours_sg' / 'sg_broker' / 'sg_fan'.
--      The price chart plots three separate datasets from this view.
--
--   2. v_event_competing_events — using the existing v_venue_neighbors
--      (distance_miles) plus a ±N-hour window, returns Tevo events at nearby
--      venues that compete with the target event for the same eyeballs.
--      Mirrors the Tevo /events endpoint's lat+lon+within behaviour but
--      runs entirely on our ingested data (no API hop). Default radius is
--      25 miles, default time window is ±6 hours.
--
--   3. v_event_data_freshness — per-source last-pulled timestamp for an event.
--      The header context strip renders this as a "last refreshed Xm ago"
--      timer per source so the broker knows whether what they're seeing
--      is live.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Three-way SG ownership classifier
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_seatgeek_listings_classified CASCADE;
CREATE VIEW v_seatgeek_listings_classified AS
SELECT
  s.*,
  CASE
    WHEN sl.sg_listing_id IS NOT NULL          THEN 'ours_sg'
    WHEN COALESCE(s.is_broker_owned, FALSE)    THEN 'sg_broker'
    ELSE                                            'sg_fan'
  END AS ownership_class
  FROM seatgeek_listings_snapshots s
  LEFT JOIN seatgeek_seller_listings sl
    ON sl.sg_listing_id::text = s.sglid
   AND sl.sg_event_id          = s.sg_event_id;

COMMENT ON VIEW v_seatgeek_listings_classified IS
  'seatgeek_listings_snapshots + ownership_class column. '
  'ours_sg = matched against seatgeek_seller_listings.sg_listing_id, '
  'sg_broker = is_broker_owned and not ours, '
  'sg_fan = not is_broker_owned. Used by the event view price chart to '
  'plot three separate market datasets.';

GRANT SELECT ON v_seatgeek_listings_classified
  TO authenticated, anon, service_role;

-- ----------------------------------------------------------------------------
-- 2. Competing events at nearby venues
--
--    For a given Tevo event, returns other events within RADIUS_MILES of the
--    venue and within ±HOURS_WINDOW of the event time. Matches the Tevo API
--    pattern from "Displaying Events Near Your Users" (lat+lon+within), but
--    using our pre-computed v_venue_neighbors so we never call out.
--
--    Use:
--      SELECT * FROM v_event_competing_events
--       WHERE source_event_id = :tevo_event_id
--       ORDER BY distance_miles, hours_apart;
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_event_competing_events CASCADE;
CREATE VIEW v_event_competing_events AS
WITH src AS (
  SELECT
    e.id          AS source_event_id,
    e.name        AS source_event_name,
    e.venue_id    AS source_venue_id,
    e.venue_name  AS source_venue_name,
    e.occurs_at_local::timestamptz AS source_occurs_at,
    e.primary_performer_id   AS source_primary_performer_id,
    e.primary_performer_name AS source_primary_performer_name,
    e.event_type  AS source_event_type,
    e.popularity_score AS source_popularity_score
  FROM events e
  WHERE e.venue_id IS NOT NULL
    AND e.occurs_at_local IS NOT NULL
),
-- Self at zero miles (always include)
self_pair AS (
  SELECT source_event_id, source_venue_id, source_venue_id AS neighbor_venue_id, 0::numeric AS distance_miles
    FROM src
),
neighbor_pairs AS (
  SELECT s.source_event_id, s.source_venue_id, n.neighbor_venue_id, n.distance_miles
    FROM src s
    JOIN v_venue_neighbors n ON n.venue_id = s.source_venue_id
   WHERE n.distance_miles <= 25       -- default radius cap; UI can re-filter tighter
)
SELECT
  s.source_event_id,
  s.source_event_name,
  s.source_venue_id,
  s.source_venue_name,
  s.source_occurs_at,
  s.source_primary_performer_id,
  s.source_primary_performer_name,
  s.source_event_type,
  comp.id                         AS competing_event_id,
  comp.name                       AS competing_event_name,
  comp.venue_id                   AS competing_venue_id,
  comp.venue_name                 AS competing_venue_name,
  comp.venue_location             AS competing_venue_location,
  comp.occurs_at_local::timestamptz AS competing_occurs_at,
  EXTRACT(EPOCH FROM (comp.occurs_at_local::timestamptz - s.source_occurs_at)) / 3600.0
                                  AS hours_apart,
  comp.primary_performer_id       AS competing_primary_performer_id,
  comp.primary_performer_name     AS competing_primary_performer_name,
  comp.event_type                 AS competing_event_type,
  comp.popularity_score           AS competing_popularity_score,
  pairs.distance_miles
FROM src s
JOIN (
  SELECT * FROM self_pair UNION ALL SELECT * FROM neighbor_pairs
) pairs ON pairs.source_event_id = s.source_event_id
JOIN events comp
  ON comp.venue_id = pairs.neighbor_venue_id
 AND comp.id <> s.source_event_id
 AND comp.occurs_at_local IS NOT NULL
 AND comp.occurs_at_local::timestamptz BETWEEN
       s.source_occurs_at - INTERVAL '6 hours'
   AND s.source_occurs_at + INTERVAL '6 hours';

COMMENT ON VIEW v_event_competing_events IS
  'Tevo events within 25 miles of the source venue and ±6 hours of the source '
  'event start. Mirrors the Tevo /events?lat&lon&within pattern using our '
  'pre-computed v_venue_neighbors. UI may filter further by distance_miles, '
  'hours_apart, popularity_score, or event_type.';

GRANT SELECT ON v_event_competing_events
  TO authenticated, anon, service_role;

-- ----------------------------------------------------------------------------
-- 3. Per-source data freshness for an event
--
--    Returns one row per data source with the most-recent timestamp we have
--    for that event, plus age in minutes. Header strip renders these as
--    little timer chips: "EVO 4m · SG-listings 2m · SG-sales 11m · ESPN 28m".
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_event_data_freshness CASCADE;
CREATE VIEW v_event_data_freshness AS
WITH evo_listings AS (
  SELECT event_id AS tevo_event_id, MAX(captured_at) AS last_seen
    FROM listings_snapshots GROUP BY event_id
),
evo_orders_v AS (
  SELECT oi.event_id AS tevo_event_id, MAX(o.evo_updated_at) AS last_seen
    FROM evo_orders o JOIN evo_order_items oi ON oi.evo_order_id = o.evo_order_id
   WHERE oi.event_id IS NOT NULL
   GROUP BY oi.event_id
),
sg_listings AS (
  SELECT tevo_event_id, MAX(captured_at) AS last_seen
    FROM seatgeek_listings_snapshots WHERE tevo_event_id IS NOT NULL
   GROUP BY tevo_event_id
),
sg_seller AS (
  SELECT tevo_event_id, MAX(pulled_at) AS last_seen
    FROM seatgeek_seller_listings WHERE tevo_event_id IS NOT NULL
   GROUP BY tevo_event_id
),
sg_sales AS (
  SELECT tevo_event_id, MAX(pulled_at) AS last_seen
    FROM seatgeek_sales_snapshots WHERE tevo_event_id IS NOT NULL
   GROUP BY tevo_event_id
),
sg_orders_v AS (
  SELECT tevo_event_id, MAX(pulled_at) AS last_seen
    FROM seatgeek_orders WHERE tevo_event_id IS NOT NULL
   GROUP BY tevo_event_id
),
seatdata_listings AS (
  SELECT tevo_event_id, MAX(captured_at) AS last_seen
    FROM seatdata_listings_snapshots WHERE tevo_event_id IS NOT NULL
   GROUP BY tevo_event_id
),
espn AS (
  SELECT tevo_event_id, MAX(captured_at) AS last_seen
    FROM v_event_espn_state
   GROUP BY tevo_event_id
),
weather AS (
  SELECT tevo_event_id, MAX(observed_at) AS last_seen
    FROM v_event_weather
   GROUP BY tevo_event_id
),
nws AS (
  SELECT ne.tevo_event_id, MAX(na.last_seen_at) AS last_seen
    FROM v_event_nws_alerts ne
    JOIN nws_alerts na ON na.id = ne.alert_id
   GROUP BY ne.tevo_event_id
),
reddit AS (
  SELECT tevo_event_id, MAX(created_utc) AS last_seen
    FROM v_event_reddit
   GROUP BY tevo_event_id
)
SELECT 'evo_listings'::text   AS src, tevo_event_id, last_seen FROM evo_listings
UNION ALL SELECT 'evo_orders',     tevo_event_id, last_seen FROM evo_orders_v
UNION ALL SELECT 'sg_listings',    tevo_event_id, last_seen FROM sg_listings
UNION ALL SELECT 'sg_seller',      tevo_event_id, last_seen FROM sg_seller
UNION ALL SELECT 'sg_sales',       tevo_event_id, last_seen FROM sg_sales
UNION ALL SELECT 'sg_orders',      tevo_event_id, last_seen FROM sg_orders_v
UNION ALL SELECT 'seatdata',       tevo_event_id, last_seen FROM seatdata_listings
UNION ALL SELECT 'espn',           tevo_event_id, last_seen FROM espn
UNION ALL SELECT 'weather',        tevo_event_id, last_seen FROM weather
UNION ALL SELECT 'nws',            tevo_event_id, last_seen FROM nws
UNION ALL SELECT 'reddit',         tevo_event_id, last_seen FROM reddit;

COMMENT ON VIEW v_event_data_freshness IS
  'Per-source most-recent timestamp for an event. Header context strip '
  'renders these as freshness chips so the broker can see at a glance '
  'whether a data feed is stale.';

GRANT SELECT ON v_event_data_freshness
  TO authenticated, anon, service_role;
