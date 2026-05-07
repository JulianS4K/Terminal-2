-- Product separation: BROKER (Terminal) vs RETAIL (Chatbot)
-- retail_* views = S4K-owned only, broker fields stripped.
-- broker_* views = full inventory.

DROP VIEW IF EXISTS retail_listings CASCADE;
DROP VIEW IF EXISTS retail_event_zones CASCADE;
DROP VIEW IF EXISTS retail_event_sections CASCADE;
DROP VIEW IF EXISTS retail_event_metrics CASCADE;
DROP VIEW IF EXISTS retail_events CASCADE;

CREATE VIEW retail_events AS
SELECT DISTINCT e.id, e.name, e.occurs_at_local, e.state, e.venue_id, e.venue_name,
       e.venue_location, e.primary_performer_id, e.primary_performer_name
FROM events e WHERE EXISTS (
  SELECT 1 FROM listings_snapshots l
  WHERE l.event_id = e.id AND l.is_owned = true AND l.is_ancillary = false
    AND l.captured_at = (SELECT MAX(captured_at) FROM listings_snapshots WHERE event_id = e.id)
);

CREATE VIEW retail_listings AS
WITH latest AS (SELECT event_id, MAX(captured_at) AS captured_at FROM listings_snapshots GROUP BY event_id)
SELECT l.event_id, l.captured_at, l.tevo_ticket_group_id, l.section, l.row, l.quantity,
       l.retail_price, l.format, l.splits, l.wheelchair, l.instant_delivery, l.eticket
FROM listings_snapshots l JOIN latest USING (event_id, captured_at)
WHERE l.is_owned = true AND l.is_ancillary = false;

CREATE VIEW retail_event_metrics AS
WITH latest AS (SELECT event_id, MAX(captured_at) AS captured_at FROM zone_metrics GROUP BY event_id)
SELECT z.event_id, z.captured_at,
  SUM(z.owned_tickets_count)::int AS tickets_available,
  SUM(z.owned_groups_count)::int  AS listings_available,
  MIN(z.retail_min) AS price_from, MAX(z.retail_max) AS price_to, MIN(z.getin_price) AS getin_price
FROM zone_metrics z JOIN latest USING (event_id, captured_at)
WHERE z.owned_tickets_count > 0
GROUP BY z.event_id, z.captured_at;

CREATE VIEW retail_event_zones AS
WITH latest AS (SELECT event_id, MAX(captured_at) AS captured_at FROM zone_metrics GROUP BY event_id)
SELECT z.event_id, z.captured_at, z.zone, z.zone_source,
  z.owned_tickets_count AS tickets_available, z.owned_groups_count AS listings_available,
  z.retail_min AS price_from, z.retail_median AS price_typical, z.retail_max AS price_to, z.getin_price
FROM zone_metrics z JOIN latest USING (event_id, captured_at)
WHERE z.owned_tickets_count > 0;

CREATE VIEW retail_event_sections AS
WITH latest AS (SELECT event_id, MAX(captured_at) AS captured_at FROM section_metrics GROUP BY event_id)
SELECT s.event_id, s.captured_at, s.section, s.zone, s.zone_source,
  s.owned_tickets_count AS tickets_available, s.owned_groups_count AS listings_available,
  s.retail_min AS price_from, s.retail_median AS price_typical, s.retail_max AS price_to, s.getin_price
FROM section_metrics s JOIN latest USING (event_id, captured_at)
WHERE s.owned_tickets_count > 0 AND s.is_ancillary = false;

CREATE OR REPLACE VIEW broker_listings       AS SELECT * FROM listings_snapshots;
CREATE OR REPLACE VIEW broker_event_metrics  AS SELECT * FROM event_metrics;
CREATE OR REPLACE VIEW broker_event_zones    AS SELECT * FROM zone_metrics;
CREATE OR REPLACE VIEW broker_event_sections AS SELECT * FROM section_metrics;
