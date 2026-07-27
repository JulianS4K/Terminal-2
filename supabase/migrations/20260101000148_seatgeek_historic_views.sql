-- ============================================================================
-- Migration 20260509200000 — historic-sales analytical views
--
-- Read-friendly aggregations on top of seatgeek_historic_sales for the
-- terminal redesign's "historic data" layer.
-- ============================================================================

CREATE OR REPLACE VIEW v_sg_historic_per_performer AS
WITH home AS (
  SELECT tevo_performer_id_home AS tevo_performer_id, season_label, season_type,
         sale_price, sale_quantity, sg_event_date, sg_category
  FROM seatgeek_historic_sales WHERE tevo_performer_id_home IS NOT NULL
),
away AS (
  SELECT tevo_performer_id_away AS tevo_performer_id, season_label, season_type,
         sale_price, sale_quantity, sg_event_date, sg_category
  FROM seatgeek_historic_sales WHERE tevo_performer_id_away IS NOT NULL
),
all_sales AS (SELECT * FROM home UNION ALL SELECT * FROM away)
SELECT s.tevo_performer_id, pm.name AS performer_name, pm.espn_league,
       s.season_label, s.season_type,
       count(*) AS sales,
       sum(s.sale_quantity) AS tickets,
       round(min(s.sale_price)::numeric, 2) AS min_price,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY s.sale_price)::numeric, 2) AS p25_price,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY s.sale_price)::numeric, 2) AS median_price,
       round(percentile_cont(0.75) WITHIN GROUP (ORDER BY s.sale_price)::numeric, 2) AS p75_price,
       round(max(s.sale_price)::numeric, 2) AS max_price,
       round(avg(s.sale_price)::numeric, 2) AS avg_price,
       min(s.sg_event_date) AS earliest, max(s.sg_event_date) AS latest
FROM all_sales s
LEFT JOIN performer_metadata pm ON pm.performer_id = s.tevo_performer_id
GROUP BY s.tevo_performer_id, pm.name, pm.espn_league, s.season_label, s.season_type;

CREATE OR REPLACE VIEW v_sg_historic_per_section_kind AS
SELECT sg_category, season_label, season_type, section_kind, section_prefix,
       count(*) AS sales, sum(sale_quantity) AS tickets,
       round(min(sale_price)::numeric, 2) AS min_price,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY sale_price)::numeric, 2) AS median_price,
       round(max(sale_price)::numeric, 2) AS max_price,
       round(avg(sale_price)::numeric, 2) AS avg_price
FROM seatgeek_historic_sales
GROUP BY sg_category, season_label, season_type, section_kind, section_prefix;

CREATE OR REPLACE VIEW v_sg_historic_per_matchup AS
SELECT least(performer_away, performer_home) AS performer_a,
       greatest(performer_away, performer_home) AS performer_b,
       sg_category, season_label,
       count(*) AS sales, sum(sale_quantity) AS tickets,
       round(min(sale_price)::numeric, 2) AS min_price,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY sale_price)::numeric, 2) AS median_price,
       round(max(sale_price)::numeric, 2) AS max_price,
       count(DISTINCT sg_event_id) AS distinct_games,
       min(sg_event_date) AS earliest, max(sg_event_date) AS latest
FROM seatgeek_historic_sales
WHERE performer_away IS NOT NULL AND performer_home IS NOT NULL
GROUP BY least(performer_away, performer_home), greatest(performer_away, performer_home),
         sg_category, season_label;

CREATE OR REPLACE VIEW v_sg_historic_concert_performer AS
SELECT performer_headliner, sg_venue, sg_event_date, sg_event_id,
       count(*) AS sales, sum(sale_quantity) AS tickets,
       round(min(sale_price)::numeric, 2) AS min_price,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY sale_price)::numeric, 2) AS median_price,
       round(max(sale_price)::numeric, 2) AS max_price,
       array_agg(DISTINCT section_kind) AS section_kinds_used
FROM seatgeek_historic_sales
WHERE performer_headliner IS NOT NULL
GROUP BY performer_headliner, sg_venue, sg_event_date, sg_event_id;
