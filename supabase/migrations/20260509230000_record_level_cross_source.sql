-- ============================================================================
-- Migration 20260509230000 — Record-level cross-source joins
--
-- Field-level mapping (data_source_field_map) tells you which COLUMN names
-- match across sources. This migration adds the RECORD-level joins —
-- "this Knicks team in TEvo IS THE SAME ROW as ESPN team 18 IS THE SAME
-- ROW as SG 'New York Knicks' IS THE SAME ROW as Wikipedia pageid 72855".
--
-- (a) BUGFIX v_canonical_event: taxonomy_xref was Cartesian-joining because
--     `event_type='game'` matches 6 canonical labels (MLB/NBA/NFL/NHL/MLS/
--     NCAA-FB/NCAA-MBB all share tevo_event_type='game'). Fix: prefer match
--     by sg_category (league-specific) when available; fall back to
--     event_type-only with canonical_kind='event_type' when sg is null.
--
-- (b) v_canonical_venue: was missing. Now joins entity_venue_map +
--     sg_events_canonical (via name match) + venue_assets (capacity / images
--     / ESPN venue id). Single-row-per-venue with all source ids.
--
-- (c) v_pricing_cross_source: the actual pricing JOIN across all 4 pricing
--     sources at (tevo_event_id, section) grain. FULL OUTER so a section
--     visible on one source but not others still appears. Returns
--     sg_vs_tevo_pct + sd_sold_vs_tevo_listed_pct as instant arbitrage
--     signals. This is what makes "TEvo retail vs SG retail vs SD sold for
--     the same seats" a one-line query.
--
-- (d) v_event_full: kitchen-sink view — single row per event with home
--     performer (canonical, w/ Wikipedia) + venue + per-source pricing
--     summary as jsonb. The single query that answers "give me everything
--     we know about this event".
-- ============================================================================

-- (a) Fix v_canonical_event
CREATE OR REPLACE VIEW v_canonical_event AS
WITH best_label AS (
  SELECT DISTINCT ON (eem.tevo_event_id)
    eem.tevo_event_id,
    COALESCE(tx_sg.canonical_label, tx_evo.canonical_label) AS canonical_label
  FROM entity_event_map eem
  LEFT JOIN sg_events_canonical sgc ON sgc.tevo_event_id = eem.tevo_event_id
  LEFT JOIN taxonomy_xref tx_sg ON sgc.sg_category IS NOT NULL
                                  AND lower(tx_sg.sg_event_type) = lower(sgc.sg_category)
  LEFT JOIN taxonomy_xref tx_evo ON sgc.sg_category IS NULL
                                  AND lower(tx_evo.tevo_event_type) = lower(eem.tevo_event_type)
                                  AND tx_evo.canonical_kind = 'event_type'
  ORDER BY eem.tevo_event_id, tx_sg.canonical_label NULLS LAST, tx_evo.canonical_label NULLS LAST
)
SELECT
  eem.tevo_event_id, eem.tevo_name, eem.event_date,
  eem.tevo_venue_id, eem.tevo_venue_name, eem.tevo_event_type,
  eem.tevo_primary_performer_id, eem.tevo_primary_performer_name,
  eem.espn_event_id, eem.espn_league, eem.espn_slug,
  eem.sd_event_id, eem.sg_event_id, eem.sg_event_name,
  eem.lifecycle_status, eem.lifecycle_is_active,
  eem.sources_count, eem.external_ids AS legacy_external_ids,
  sgc.sg_category, sgc.sg_datetime_utc, sgc.sg_url,
  sgc.has_seller_listings AS sg_has_seller_listings,
  sgc.has_orders          AS sg_has_orders,
  sgc.has_v2_listings_pulled AS sg_has_v2_pulled,
  bl.canonical_label
FROM entity_event_map eem
LEFT JOIN sg_events_canonical sgc ON sgc.tevo_event_id = eem.tevo_event_id
LEFT JOIN best_label bl ON bl.tevo_event_id = eem.tevo_event_id;

-- (b) v_canonical_venue
CREATE OR REPLACE VIEW v_canonical_venue AS
SELECT
  evm.tevo_venue_id, evm.tevo_venue_name, evm.tevo_venue_location,
  evm.sd_venue_id, evm.sd_venue_name, evm.sd_venue_slug,
  evm.sd_venue_city, evm.sd_venue_state,
  evm.sg_venue_name,
  (SELECT sgc.sg_venue_id FROM sg_events_canonical sgc
   WHERE lower(sgc.sg_venue_name) = lower(evm.tevo_venue_name)
   ORDER BY sgc.sg_event_date DESC NULLS LAST LIMIT 1) AS sg_venue_id,
  (SELECT sgc.sg_venue_city FROM sg_events_canonical sgc
   WHERE lower(sgc.sg_venue_name) = lower(evm.tevo_venue_name)
   ORDER BY sgc.sg_event_date DESC NULLS LAST LIMIT 1) AS sg_venue_city,
  (SELECT sgc.sg_venue_state FROM sg_events_canonical sgc
   WHERE lower(sgc.sg_venue_name) = lower(evm.tevo_venue_name)
   ORDER BY sgc.sg_event_date DESC NULLS LAST LIMIT 1) AS sg_venue_state,
  va.capacity AS tevo_capacity, va.city AS tevo_city, va.state AS tevo_state,
  va.is_indoor, va.hero_image_url, va.map_image_url,
  va.espn_venue_id, va.espn_venue_name,
  evm.sources_count, evm.external_ids AS legacy_external_ids
FROM entity_venue_map evm
LEFT JOIN venue_assets va ON va.tevo_venue_id = evm.tevo_venue_id;

-- (c) v_pricing_cross_source
CREATE OR REPLACE VIEW v_pricing_cross_source AS
WITH tevo_sec AS (
  SELECT event_id AS tevo_event_id, section,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price)    AS tevo_retail_median,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY wholesale_price) AS tevo_wholesale_median,
         count(*) AS tevo_listings, sum(quantity) AS tevo_tix,
         max(captured_at) AS tevo_latest
  FROM listings_snapshots
  WHERE captured_at > now() - interval '24 hours'
  GROUP BY event_id, section
),
sg_broker_sec AS (
  SELECT tevo_event_id, section,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price_all_in) AS sg_retail_median,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY broadcast_price)     AS sg_wholesale_median,
         count(*) AS sg_listings, sum(quantity) AS sg_tix,
         count(*) FILTER (WHERE is_b2b) AS sg_b2b_listings,
         count(*) FILTER (WHERE market_source='marketplace') AS sg_fan_listings,
         max(captured_at) AS sg_latest
  FROM seatgeek_listings_snapshots
  WHERE captured_at > now() - interval '24 hours' AND tevo_event_id IS NOT NULL
  GROUP BY tevo_event_id, section
),
sg_seller_sec AS (
  SELECT tevo_event_id, section,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY cost) AS sg_seller_cost_median,
         count(*) AS sg_seller_listings, sum(quantity) AS sg_seller_tix,
         max(pulled_at) AS sg_seller_latest
  FROM seatgeek_seller_listings WHERE tevo_event_id IS NOT NULL
  GROUP BY tevo_event_id, section
),
sd_sales_sec AS (
  SELECT tevo_event_id, section,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY price) AS sd_sold_median,
         count(*) AS sd_sales, sum(quantity) AS sd_tix_sold,
         min(sale_timestamp) AS sd_earliest_sale, max(sale_timestamp) AS sd_latest_sale
  FROM seatdata_sales_snapshots WHERE tevo_event_id IS NOT NULL
  GROUP BY tevo_event_id, section
)
SELECT
  COALESCE(t.tevo_event_id, sb.tevo_event_id, ss.tevo_event_id, sd.tevo_event_id) AS tevo_event_id,
  COALESCE(t.section, sb.section, ss.section, sd.section) AS section,
  round(t.tevo_retail_median::numeric, 2)     AS tevo_retail_median,
  round(t.tevo_wholesale_median::numeric, 2)  AS tevo_wholesale_median,
  t.tevo_listings, t.tevo_tix, t.tevo_latest,
  round(sb.sg_retail_median::numeric, 2)      AS sg_retail_median,
  round(sb.sg_wholesale_median::numeric, 2)   AS sg_wholesale_median,
  sb.sg_listings, sb.sg_tix, sb.sg_b2b_listings, sb.sg_fan_listings, sb.sg_latest,
  round(ss.sg_seller_cost_median::numeric, 2) AS sg_seller_cost_median,
  ss.sg_seller_listings, ss.sg_seller_tix, ss.sg_seller_latest,
  round(sd.sd_sold_median::numeric, 2) AS sd_sold_median,
  sd.sd_sales, sd.sd_tix_sold, sd.sd_earliest_sale, sd.sd_latest_sale,
  CASE WHEN t.tevo_retail_median IS NOT NULL AND sb.sg_retail_median IS NOT NULL THEN
       round(((sb.sg_retail_median - t.tevo_retail_median) / t.tevo_retail_median * 100)::numeric, 1) END AS sg_vs_tevo_pct,
  CASE WHEN t.tevo_retail_median IS NOT NULL AND sd.sd_sold_median IS NOT NULL THEN
       round(((sd.sd_sold_median - t.tevo_retail_median) / t.tevo_retail_median * 100)::numeric, 1) END AS sd_sold_vs_tevo_listed_pct
FROM tevo_sec t
FULL OUTER JOIN sg_broker_sec sb USING (tevo_event_id, section)
FULL OUTER JOIN sg_seller_sec ss USING (tevo_event_id, section)
FULL OUTER JOIN sd_sales_sec  sd USING (tevo_event_id, section);

-- (d) v_event_full
CREATE OR REPLACE VIEW v_event_full AS
SELECT
  ce.tevo_event_id, ce.tevo_name, ce.event_date, ce.tevo_venue_name,
  ce.canonical_label, ce.lifecycle_status, ce.sources_count,
  ce.espn_event_id, ce.sd_event_id, ce.sg_event_id, ce.sg_category,
  jsonb_build_object(
    'tevo_id', hp.tevo_performer_id, 'name', hp.tevo_performer_name,
    'espn_team_id', hp.espn_team_id, 'espn_league', hp.espn_league,
    'sd_id', hp.sd_performer_id, 'sg_name', hp.sg_performer_name,
    'wiki_pageid', hp.wiki_pageid, 'wiki_title', hp.wiki_title,
    'wiki_extract', hp.wiki_extract, 'wiki_image', hp.wiki_image_url
  ) AS home_performer,
  jsonb_build_object(
    'tevo_id', cv.tevo_venue_id, 'name', cv.tevo_venue_name,
    'sg_venue_id', cv.sg_venue_id, 'sg_city', cv.sg_venue_city,
    'sg_state', cv.sg_venue_state, 'capacity', cv.tevo_capacity,
    'is_indoor', cv.is_indoor
  ) AS venue,
  (SELECT jsonb_build_object(
     'tevo_retail_median', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price)::numeric, 2),
     'tevo_listings', count(*), 'tevo_tix', sum(quantity)
   ) FROM listings_snapshots WHERE event_id = ce.tevo_event_id
       AND captured_at > now() - interval '24 hours') AS tevo_pricing,
  (SELECT jsonb_build_object(
     'sg_retail_median', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price_all_in)::numeric, 2),
     'sg_b2b_listings', count(*) FILTER (WHERE is_b2b),
     'sg_fan_listings', count(*) FILTER (WHERE market_source='marketplace'),
     'sg_listings', count(*)
   ) FROM seatgeek_listings_snapshots WHERE tevo_event_id = ce.tevo_event_id
       AND captured_at > now() - interval '24 hours') AS sg_pricing,
  (SELECT jsonb_build_object(
     'sg_seller_cost_median', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY cost)::numeric, 2),
     'sg_seller_listings', count(*), 'sg_seller_tix', sum(quantity)
   ) FROM seatgeek_seller_listings WHERE tevo_event_id = ce.tevo_event_id) AS sg_seller_pricing,
  (SELECT jsonb_build_object(
     'sd_sold_median', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY price)::numeric, 2),
     'sd_sales', count(*), 'sd_tix_sold', sum(quantity),
     'sd_latest_sale', max(sale_timestamp)
   ) FROM seatdata_sales_snapshots WHERE tevo_event_id = ce.tevo_event_id) AS sd_pricing
FROM v_canonical_event ce
LEFT JOIN v_canonical_performer hp ON hp.tevo_performer_id = ce.tevo_primary_performer_id
LEFT JOIN v_canonical_venue cv ON cv.tevo_venue_id = ce.tevo_venue_id;
