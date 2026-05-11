-- ============================================================================
-- Migration 20260510210000 — Phase 15: performer view supporting views
--
-- Lane:     canonical
-- Touches:  v_performer_summary, v_performer_upcoming_events,
--           v_performer_aggregate_inventory, v_performer_aggregate_sales,
--           v_performer_event_highlights, v_performer_inventory_timeseries,
--           v_performer_sales_timeseries, v_performer_section_drift,
--           v_performer_competing_nearby, v_performer_data_freshness
--           (all CREATE VIEW); reads events, event_metrics, event_alerts,
--           listings_snapshots, v_seatgeek_listings_classified,
--           v_event_sales_combined, v_event_competing_events,
--           v_event_data_freshness, section_metrics, v_performer_tours,
--           performer_espn_team_xref, performer_wikipedia
-- Pre-reqs: 20260510130030 (Phase 7), 20260510190000 (Phase 13 — sales view),
--           20260510200000 (Phase 14 — SG classifier + competing events
--                                       + data freshness)
--
-- Performer-rollup views backing the performer-view page
-- (docs/performer-view-wireframe-v5.md). 10 core views — sports ESPN
-- expansions (v_team_*) will follow in Phase 15b. All read-only; canonical
-- lane owns these view names. Page queries should always filter by
-- performer_id (tevo_performer_id) for fast plans.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. v_performer_summary — identity + active-tour + ESPN xref + wiki
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_summary CASCADE;
CREATE VIEW v_performer_summary AS
WITH performers AS (
  SELECT DISTINCT primary_performer_id AS performer_id,
         primary_performer_name        AS performer_name
    FROM events
   WHERE primary_performer_id IS NOT NULL
),
latest_type AS (
  SELECT DISTINCT ON (primary_performer_id)
         primary_performer_id, event_type, occurs_at_local
    FROM events
   WHERE primary_performer_id IS NOT NULL
   ORDER BY primary_performer_id, occurs_at_local DESC
)
SELECT
  p.performer_id,
  p.performer_name,
  lt.event_type,
  pt.venue_count          AS active_tour_venue_count,
  pt.show_count           AS active_tour_show_count,
  pt.tour_first_show      AS active_tour_first_show,
  pt.tour_last_show       AS active_tour_last_show,
  pt.tour_span_days       AS active_tour_span_days,
  pt.regions              AS active_tour_regions,
  pet.espn_team_id,
  pet.espn_league,
  pw.description          AS wiki_description,
  pw.image_url            AS wiki_image_url,
  pw.wiki_url             AS wiki_url,
  pw.extract              AS wiki_extract,
  (pet.espn_team_id IS NOT NULL) AS is_sports_team
FROM performers p
LEFT JOIN latest_type lt              ON lt.primary_performer_id = p.performer_id
LEFT JOIN v_performer_tours pt        ON pt.primary_performer_id = p.performer_id
LEFT JOIN performer_espn_team_xref pet ON pet.tevo_performer_id   = p.performer_id
LEFT JOIN performer_wikipedia pw      ON pw.tevo_performer_id    = p.performer_id;

GRANT SELECT ON v_performer_summary TO authenticated, anon, service_role;


-- ----------------------------------------------------------------------------
-- 2. v_performer_upcoming_events — per-event metrics row for performer page
--    Schedule/Shows table + chart dots + at-a-glance + highlights all build
--    on this. Filter by performer_id at query time.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_upcoming_events CASCADE;
CREATE VIEW v_performer_upcoming_events AS
WITH em_latest AS (
  SELECT DISTINCT ON (event_id) *
    FROM event_metrics
   ORDER BY event_id, captured_at DESC
),
em_24h AS (
  SELECT DISTINCT ON (event_id)
         event_id, retail_median, getin_price
    FROM event_metrics
   WHERE captured_at < now() - INTERVAL '24 hours'
   ORDER BY event_id, captured_at DESC
),
em_7d AS (
  SELECT DISTINCT ON (event_id)
         event_id, retail_median, getin_price
    FROM event_metrics
   WHERE captured_at < now() - INTERVAL '7 days'
   ORDER BY event_id, captured_at DESC
),
alert_counts AS (
  SELECT tevo_event_id, COUNT(*) AS open_alert_count
    FROM event_alerts
   WHERE acknowledged_at IS NULL
   GROUP BY tevo_event_id
)
SELECT
  e.id                                          AS event_id,
  e.primary_performer_id                        AS performer_id,
  e.primary_performer_name                      AS performer_name,
  e.name                                        AS event_name,
  e.venue_id,
  e.venue_name,
  e.venue_location,
  e.occurs_at_local::timestamptz                AS occurs_at,
  (e.occurs_at_local::timestamptz)::date        AS event_date,
  EXTRACT(DAY FROM (e.occurs_at_local::timestamptz - now()))::int AS days_to_event,
  e.event_type,
  e.popularity_score,
  e.long_term_popularity_score,
  -- sports home/away inference from "Away at Home" event_name pattern
  CASE
    WHEN e.event_type = 'game' AND e.name ILIKE '% at %' THEN
      CASE WHEN lower(trim(split_part(e.name, ' at ', 2)))
                = lower(coalesce(e.primary_performer_name, ''))
           THEN 'H' ELSE 'A' END
    ELSE NULL
  END                                            AS home_or_away,
  -- region from venue_location (last token, e.g. "New York, NY" -> "NY")
  trim(split_part(e.venue_location, ',', -1))    AS venue_region,
  em.tickets_count                              AS market_tickets,
  em.retail_median                              AS market_median,
  em.getin_price                                AS market_getin,
  em.owned_tickets_count                        AS owned_tickets,
  em.owned_share                                AS owned_share,
  em.owned_median_retail                        AS owned_median,
  em.nonowned_median_retail                     AS market_nonowned_median,
  (em.retail_median - em_24h.retail_median)     AS market_median_delta_24h,
  (em.retail_median - em_7d.retail_median)      AS market_median_delta_7d,
  (em.getin_price   - em_24h.getin_price)       AS getin_delta_24h,
  (em.getin_price   - em_7d.getin_price)        AS getin_delta_7d,
  COALESCE(alert_counts.open_alert_count, 0)    AS open_alert_count
FROM events e
LEFT JOIN em_latest em       ON em.event_id      = e.id
LEFT JOIN em_24h             ON em_24h.event_id  = e.id
LEFT JOIN em_7d              ON em_7d.event_id   = e.id
LEFT JOIN alert_counts       ON alert_counts.tevo_event_id = e.id
WHERE e.occurs_at_local IS NOT NULL
  AND e.occurs_at_local::timestamptz >= now() - INTERVAL '7 days'
  AND e.primary_performer_id IS NOT NULL;

GRANT SELECT ON v_performer_upcoming_events TO authenticated, anon, service_role;


-- ----------------------------------------------------------------------------
-- 3. v_performer_aggregate_inventory — totals by ownership_class
--    Rolls up evo-owned / evo-mkt / sg-ours / sg-broker / sg-fan across the
--    performer's upcoming events. One row per (performer_id, source).
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_aggregate_inventory CASCADE;
CREATE VIEW v_performer_aggregate_inventory AS
WITH performer_events AS (
  SELECT id AS event_id, primary_performer_id AS performer_id
    FROM events
   WHERE occurs_at_local::timestamptz >= now()
     AND primary_performer_id IS NOT NULL
),
evo_latest AS (
  SELECT DISTINCT ON (event_id, tevo_ticket_group_id) *
    FROM listings_snapshots
   ORDER BY event_id, tevo_ticket_group_id, captured_at DESC
),
sg_latest AS (
  SELECT DISTINCT ON (tevo_event_id, sglid) *
    FROM v_seatgeek_listings_classified
   WHERE tevo_event_id IS NOT NULL
   ORDER BY tevo_event_id, sglid, captured_at DESC
)
SELECT pe.performer_id,
       CASE WHEN evo.is_owned THEN 'evo_owned' ELSE 'evo_mkt' END AS source,
       SUM(evo.quantity)                  AS qty,
       COUNT(*)                           AS listing_count,
       AVG(evo.retail_price)              AS avg_price,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY evo.retail_price) AS median_price
  FROM performer_events pe
  JOIN evo_latest evo ON evo.event_id = pe.event_id
 GROUP BY pe.performer_id, evo.is_owned
UNION ALL
SELECT pe.performer_id,
       'sg_' || sg.ownership_class                              AS source,
       SUM(sg.quantity)                                          AS qty,
       COUNT(*)                                                  AS listing_count,
       AVG(sg.retail_price_all_in)                               AS avg_price,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY sg.retail_price_all_in) AS median_price
  FROM performer_events pe
  JOIN sg_latest sg ON sg.tevo_event_id = pe.event_id
 GROUP BY pe.performer_id, sg.ownership_class;

GRANT SELECT ON v_performer_aggregate_inventory TO authenticated, anon, service_role;


-- ----------------------------------------------------------------------------
-- 4. v_performer_aggregate_sales — totals from v_event_sales_combined
--    rolled to performer scope over a time window (last 7 / 30 days).
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_aggregate_sales CASCADE;
CREATE VIEW v_performer_aggregate_sales AS
WITH performer_events AS (
  SELECT id AS event_id, primary_performer_id AS performer_id
    FROM events
   WHERE occurs_at_local::timestamptz >= now() - INTERVAL '7 days'
     AND primary_performer_id IS NOT NULL
)
SELECT pe.performer_id,
       s.src,
       s.is_ours,
       SUM(s.qty)                                AS total_qty,
       SUM(s.qty * s.price)                      AS gross_dollars,
       COUNT(*)                                  AS sale_lines,
       SUM(s.qty) FILTER (WHERE s.sold_at >= now() - INTERVAL '24 hours') AS qty_24h,
       SUM(s.qty) FILTER (WHERE s.sold_at >= now() - INTERVAL '7 days')   AS qty_7d,
       SUM(s.qty) FILTER (WHERE s.sold_at >= now() - INTERVAL '30 days')  AS qty_30d,
       MIN(s.sold_at)                            AS earliest_sale_at,
       MAX(s.sold_at)                            AS latest_sale_at
  FROM performer_events pe
  JOIN v_event_sales_combined s ON s.tevo_event_id = pe.event_id
 GROUP BY pe.performer_id, s.src, s.is_ours;

GRANT SELECT ON v_performer_aggregate_sales TO authenticated, anon, service_role;


-- ----------------------------------------------------------------------------
-- 5. v_performer_event_highlights — min/max/avg with event_id pointers
--    Powers the "Event Metrics Highlights" panel on the performer view.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_event_highlights CASCADE;
CREATE VIEW v_performer_event_highlights AS
WITH upcoming AS (
  SELECT performer_id, event_id, event_name, event_date, venue_name, home_or_away,
         market_median, market_getin, owned_median,
         (owned_median - market_median) AS spread,
         market_tickets, days_to_event, open_alert_count
    FROM v_performer_upcoming_events
   WHERE occurs_at >= now()
),
agg AS (
  SELECT performer_id,
         AVG(market_median)            AS avg_market_median,
         AVG(market_getin)             AS avg_market_getin,
         AVG(owned_median)             AS avg_owned_median,
         AVG(spread)                   AS avg_spread,
         AVG(market_tickets)           AS avg_market_tickets,
         AVG(days_to_event)            AS avg_days_to_event,
         SUM(market_tickets)           AS total_market_tickets,
         SUM(open_alert_count)         AS total_alerts,
         COUNT(*)                      AS event_count,
         MIN(event_date)               AS first_event_date,
         MAX(event_date)               AS last_event_date
    FROM upcoming
   GROUP BY performer_id
),
pick_max AS (
  SELECT DISTINCT ON (performer_id, kind)
         performer_id, kind, event_id, event_name, venue_name, event_date, value
    FROM (
      SELECT performer_id, 'getin_high'::text   AS kind, event_id, event_name, venue_name, event_date, market_getin AS value FROM upcoming
      UNION ALL
      SELECT performer_id, 'ours_median_high', event_id, event_name, venue_name, event_date, owned_median FROM upcoming
      UNION ALL
      SELECT performer_id, 'spread_widest',   event_id, event_name, venue_name, event_date, spread FROM upcoming
      UNION ALL
      SELECT performer_id, 'inventory_high', event_id, event_name, venue_name, event_date, market_tickets FROM upcoming
    ) u
    ORDER BY performer_id, kind, value DESC NULLS LAST
),
pick_min AS (
  SELECT DISTINCT ON (performer_id, kind)
         performer_id, kind, event_id, event_name, venue_name, event_date, value
    FROM (
      SELECT performer_id, 'getin_low'::text    AS kind, event_id, event_name, venue_name, event_date, market_getin AS value FROM upcoming
      UNION ALL
      SELECT performer_id, 'ours_median_low',  event_id, event_name, venue_name, event_date, owned_median FROM upcoming
      UNION ALL
      SELECT performer_id, 'spread_tightest',  event_id, event_name, venue_name, event_date, spread FROM upcoming
      UNION ALL
      SELECT performer_id, 'inventory_low',    event_id, event_name, venue_name, event_date, market_tickets FROM upcoming
    ) u
    ORDER BY performer_id, kind, value ASC NULLS LAST
)
SELECT a.performer_id,
       a.event_count, a.first_event_date, a.last_event_date,
       a.avg_market_median, a.avg_market_getin, a.avg_owned_median,
       a.avg_spread, a.avg_market_tickets, a.avg_days_to_event,
       a.total_market_tickets, a.total_alerts,
       jsonb_object_agg(pm.kind, jsonb_build_object(
         'event_id', pm.event_id, 'event_name', pm.event_name,
         'venue_name', pm.venue_name, 'event_date', pm.event_date,
         'value', pm.value))           AS highs,
       jsonb_object_agg(pn.kind, jsonb_build_object(
         'event_id', pn.event_id, 'event_name', pn.event_name,
         'venue_name', pn.venue_name, 'event_date', pn.event_date,
         'value', pn.value))           AS lows
  FROM agg a
  LEFT JOIN pick_max pm ON pm.performer_id = a.performer_id
  LEFT JOIN pick_min pn ON pn.performer_id = a.performer_id
 GROUP BY a.performer_id, a.event_count, a.first_event_date, a.last_event_date,
          a.avg_market_median, a.avg_market_getin, a.avg_owned_median,
          a.avg_spread, a.avg_market_tickets, a.avg_days_to_event,
          a.total_market_tickets, a.total_alerts;

GRANT SELECT ON v_performer_event_highlights TO authenticated, anon, service_role;


-- ----------------------------------------------------------------------------
-- 6. v_performer_inventory_timeseries — hourly sum across upcoming events
--    by ownership_class. Powers the "Total Inventory Over Time" chart.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_inventory_timeseries CASCADE;
CREATE VIEW v_performer_inventory_timeseries AS
WITH performer_events AS (
  SELECT id AS event_id, primary_performer_id AS performer_id
    FROM events
   WHERE occurs_at_local::timestamptz >= now()
     AND primary_performer_id IS NOT NULL
)
SELECT pe.performer_id,
       date_trunc('hour', ls.captured_at)        AS bucket,
       CASE WHEN ls.is_owned THEN 'evo_owned' ELSE 'evo_mkt' END AS source,
       SUM(ls.quantity)                          AS qty,
       COUNT(*)                                  AS listings
  FROM performer_events pe
  JOIN listings_snapshots ls ON ls.event_id = pe.event_id
 WHERE ls.captured_at >= now() - INTERVAL '30 days'
 GROUP BY pe.performer_id, bucket, ls.is_owned
UNION ALL
SELECT pe.performer_id,
       date_trunc('hour', sg.captured_at)        AS bucket,
       'sg_' || sg.ownership_class               AS source,
       SUM(sg.quantity)                          AS qty,
       COUNT(*)                                  AS listings
  FROM performer_events pe
  JOIN v_seatgeek_listings_classified sg ON sg.tevo_event_id = pe.event_id
 WHERE sg.captured_at >= now() - INTERVAL '30 days'
 GROUP BY pe.performer_id, bucket, sg.ownership_class;

GRANT SELECT ON v_performer_inventory_timeseries TO authenticated, anon, service_role;


-- ----------------------------------------------------------------------------
-- 7. v_performer_sales_timeseries — hourly sales velocity across performer
--    Cumulative sum is done on the page (window function); this view just
--    surfaces hourly buckets.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_sales_timeseries CASCADE;
CREATE VIEW v_performer_sales_timeseries AS
WITH performer_events AS (
  SELECT id AS event_id, primary_performer_id AS performer_id
    FROM events
   WHERE occurs_at_local::timestamptz >= now() - INTERVAL '7 days'
     AND primary_performer_id IS NOT NULL
)
SELECT pe.performer_id,
       date_trunc('hour', s.sold_at)             AS bucket,
       s.src,
       s.is_ours,
       SUM(s.qty)                                AS qty,
       SUM(s.qty * s.price)                      AS gross_dollars,
       COUNT(*)                                  AS sale_lines
  FROM performer_events pe
  JOIN v_event_sales_combined s ON s.tevo_event_id = pe.event_id
 WHERE s.sold_at >= now() - INTERVAL '30 days'
 GROUP BY pe.performer_id, bucket, s.src, s.is_ours;

GRANT SELECT ON v_performer_sales_timeseries TO authenticated, anon, service_role;


-- ----------------------------------------------------------------------------
-- 8. v_performer_section_drift — section_metrics rolled across upcoming events
--    Powers the "Hottest Section Across Tour/Home Games" panel.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_section_drift CASCADE;
CREATE VIEW v_performer_section_drift AS
WITH performer_events AS (
  SELECT id AS event_id, primary_performer_id AS performer_id
    FROM events
   WHERE occurs_at_local::timestamptz >= now()
     AND primary_performer_id IS NOT NULL
),
sm_latest AS (
  SELECT DISTINCT ON (event_id, section)
         event_id, section, zone, retail_median, tickets_count, getin_price, captured_at
    FROM section_metrics
   ORDER BY event_id, section, captured_at DESC
),
sm_24h AS (
  SELECT DISTINCT ON (event_id, section)
         event_id, section, retail_median, tickets_count
    FROM section_metrics
   WHERE captured_at < now() - INTERVAL '24 hours'
   ORDER BY event_id, section, captured_at DESC
)
SELECT pe.performer_id,
       sl.section,
       MAX(sl.zone)                              AS zone,
       AVG(sl.retail_median)                     AS avg_median,
       AVG(sl.getin_price)                       AS avg_getin,
       SUM(sl.tickets_count)                     AS total_listings,
       AVG(sl.retail_median - s24.retail_median) AS avg_median_drift_24h,
       SUM(sl.tickets_count - s24.tickets_count) AS listings_delta_24h,
       COUNT(DISTINCT sl.event_id)               AS event_count
  FROM performer_events pe
  JOIN sm_latest sl ON sl.event_id = pe.event_id
  LEFT JOIN sm_24h s24 ON s24.event_id = sl.event_id AND s24.section = sl.section
 GROUP BY pe.performer_id, sl.section;

GRANT SELECT ON v_performer_section_drift TO authenticated, anon, service_role;


-- ----------------------------------------------------------------------------
-- 9. v_performer_competing_nearby — dedup'd v_event_competing_events with
--    conflict_event_id pointers showing which of our events conflicts.
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_competing_nearby CASCADE;
CREATE VIEW v_performer_competing_nearby AS
WITH performer_events AS (
  SELECT id AS event_id, primary_performer_id AS performer_id
    FROM events
   WHERE occurs_at_local::timestamptz >= now()
     AND primary_performer_id IS NOT NULL
)
SELECT DISTINCT ON (pe.performer_id, ce.competing_event_id)
       pe.performer_id,
       ce.competing_event_id,
       ce.competing_event_name,
       ce.competing_venue_id,
       ce.competing_venue_name,
       ce.competing_occurs_at,
       ce.competing_event_type,
       ce.competing_popularity_score,
       ce.hours_apart,
       ce.distance_miles,
       pe.event_id                                AS conflict_event_id
  FROM performer_events pe
  JOIN v_event_competing_events ce ON ce.source_event_id = pe.event_id
 ORDER BY pe.performer_id, ce.competing_event_id, ce.distance_miles;

GRANT SELECT ON v_performer_competing_nearby TO authenticated, anon, service_role;


-- ----------------------------------------------------------------------------
-- 10. v_performer_data_freshness — per-source last_seen rolled to performer
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_performer_data_freshness CASCADE;
CREATE VIEW v_performer_data_freshness AS
WITH performer_events AS (
  SELECT id AS event_id, primary_performer_id AS performer_id
    FROM events
   WHERE occurs_at_local::timestamptz >= now()
     AND primary_performer_id IS NOT NULL
)
SELECT pe.performer_id, f.src, MAX(f.last_seen) AS last_seen
  FROM performer_events pe
  JOIN v_event_data_freshness f ON f.tevo_event_id = pe.event_id
 GROUP BY pe.performer_id, f.src;

GRANT SELECT ON v_performer_data_freshness TO authenticated, anon, service_role;
