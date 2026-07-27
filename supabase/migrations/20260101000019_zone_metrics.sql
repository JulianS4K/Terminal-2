-- Per-zone metrics captured at the same cadence as event_metrics.
-- Zone resolution: performer_zones (curated, via match_performer_zone) → derive_zone_fallback() (system).

CREATE TABLE IF NOT EXISTS zone_metrics (
  event_id           bigint      NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  captured_at        timestamptz NOT NULL,
  zone               text        NOT NULL,
  zone_source        text        NOT NULL CHECK (zone_source IN ('curated','fallback','unmapped')),
  tickets_count      integer,
  groups_count       integer,
  sections_count     integer,
  retail_min         numeric, retail_p25 numeric, retail_median numeric, retail_mean numeric,
  retail_p75         numeric, retail_p90 numeric, retail_max    numeric, retail_sum  numeric,
  wholesale_min      numeric, wholesale_median numeric, wholesale_mean numeric, wholesale_max numeric,
  getin_price        numeric,
  owned_groups_count    integer, owned_tickets_count integer, owned_share numeric, owned_median_retail numeric,
  PRIMARY KEY (event_id, captured_at, zone)
);
CREATE INDEX IF NOT EXISTS zone_metrics_event_captured_idx ON zone_metrics (event_id, captured_at DESC);
CREATE INDEX IF NOT EXISTS zone_metrics_zone_idx ON zone_metrics (zone);

CREATE OR REPLACE FUNCTION compute_event_zone_metrics(p_event_id bigint, p_captured_at timestamptz)
RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE v_performer_id bigint; v_venue_id bigint; v_count integer;
BEGIN
  SELECT primary_performer_id, venue_id INTO v_performer_id, v_venue_id FROM events WHERE id = p_event_id;
  WITH zoned AS (
    SELECT l.event_id, l.captured_at, l.section, l.row, l.quantity, l.retail_price, l.wholesale_price, l.is_owned,
      curated.name AS curated_name,
      CASE WHEN curated.name IS NOT NULL THEN curated.name
           ELSE COALESCE(derive_zone_fallback(l.section, l.row), 'unmapped') END AS zone,
      CASE WHEN curated.name IS NOT NULL THEN 'curated'
           WHEN derive_zone_fallback(l.section, l.row) IS NOT NULL THEN 'fallback' ELSE 'unmapped' END AS zone_source
    FROM listings_snapshots l
    LEFT JOIN LATERAL (SELECT match_performer_zone(v_performer_id, v_venue_id, l.section, l.row) AS name) curated ON true
    WHERE l.event_id = p_event_id AND l.captured_at = p_captured_at AND l.is_ancillary = false
  ),
  expanded AS (
    SELECT z.zone, z.zone_source, z.retail_price, z.wholesale_price, z.is_owned
    FROM zoned z JOIN LATERAL generate_series(1, GREATEST(z.quantity, 0)) AS gs(n) ON true
  ),
  agg AS (
    SELECT z.zone,
      MAX(CASE WHEN z.zone_source='curated' THEN 3 WHEN z.zone_source='fallback' THEN 2 ELSE 1 END) AS src_rank,
      SUM(z.quantity)::int AS tickets_count, COUNT(*)::int AS groups_count,
      COUNT(DISTINCT z.section)::int AS sections_count,
      MIN(z.retail_price) FILTER (WHERE z.quantity >= 2 AND z.retail_price IS NOT NULL) AS getin_price,
      COUNT(*) FILTER (WHERE z.is_owned)::int AS owned_groups_count,
      COALESCE(SUM(z.quantity) FILTER (WHERE z.is_owned), 0)::int AS owned_tickets_count
    FROM zoned z GROUP BY z.zone
  ),
  pct AS (
    SELECT e.zone,
      MIN(e.retail_price) AS retail_min,
      percentile_cont(0.25) WITHIN GROUP (ORDER BY e.retail_price) AS retail_p25,
      percentile_cont(0.5)  WITHIN GROUP (ORDER BY e.retail_price) AS retail_median,
      AVG(e.retail_price) AS retail_mean,
      percentile_cont(0.75) WITHIN GROUP (ORDER BY e.retail_price) AS retail_p75,
      percentile_cont(0.9)  WITHIN GROUP (ORDER BY e.retail_price) AS retail_p90,
      MAX(e.retail_price) AS retail_max, SUM(e.retail_price) AS retail_sum,
      MIN(e.wholesale_price) AS wholesale_min,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY e.wholesale_price) AS wholesale_median,
      AVG(e.wholesale_price) AS wholesale_mean, MAX(e.wholesale_price) AS wholesale_max,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY e.retail_price) FILTER (WHERE e.is_owned) AS owned_median_retail
    FROM expanded e GROUP BY e.zone
  )
  INSERT INTO zone_metrics (event_id, captured_at, zone, zone_source, tickets_count, groups_count, sections_count,
    retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90, retail_max, retail_sum,
    wholesale_min, wholesale_median, wholesale_mean, wholesale_max, getin_price,
    owned_groups_count, owned_tickets_count, owned_share, owned_median_retail)
  SELECT p_event_id, p_captured_at, a.zone,
    CASE a.src_rank WHEN 3 THEN 'curated' WHEN 2 THEN 'fallback' ELSE 'unmapped' END,
    a.tickets_count, a.groups_count, a.sections_count,
    round(p.retail_min::numeric,2), round(p.retail_p25::numeric,2), round(p.retail_median::numeric,2),
    round(p.retail_mean::numeric,2), round(p.retail_p75::numeric,2), round(p.retail_p90::numeric,2),
    round(p.retail_max::numeric,2), round(p.retail_sum::numeric,2),
    round(p.wholesale_min::numeric,2), round(p.wholesale_median::numeric,2),
    round(p.wholesale_mean::numeric,2), round(p.wholesale_max::numeric,2),
    round(a.getin_price::numeric,2), a.owned_groups_count, a.owned_tickets_count,
    CASE WHEN a.tickets_count > 0 THEN round((a.owned_tickets_count::numeric / a.tickets_count)::numeric, 4) ELSE NULL END,
    round(p.owned_median_retail::numeric,2)
  FROM agg a JOIN pct p ON p.zone = a.zone
  ON CONFLICT (event_id, captured_at, zone) DO UPDATE SET
    zone_source = EXCLUDED.zone_source, tickets_count = EXCLUDED.tickets_count,
    groups_count = EXCLUDED.groups_count, sections_count = EXCLUDED.sections_count,
    retail_min = EXCLUDED.retail_min, retail_p25 = EXCLUDED.retail_p25,
    retail_median = EXCLUDED.retail_median, retail_mean = EXCLUDED.retail_mean,
    retail_p75 = EXCLUDED.retail_p75, retail_p90 = EXCLUDED.retail_p90,
    retail_max = EXCLUDED.retail_max, retail_sum = EXCLUDED.retail_sum,
    wholesale_min = EXCLUDED.wholesale_min, wholesale_median = EXCLUDED.wholesale_median,
    wholesale_mean = EXCLUDED.wholesale_mean, wholesale_max = EXCLUDED.wholesale_max,
    getin_price = EXCLUDED.getin_price, owned_groups_count = EXCLUDED.owned_groups_count,
    owned_tickets_count = EXCLUDED.owned_tickets_count, owned_share = EXCLUDED.owned_share,
    owned_median_retail = EXCLUDED.owned_median_retail;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $fn$;

CREATE OR REPLACE VIEW latest_zone_metrics AS
SELECT zm.* FROM zone_metrics zm
JOIN (SELECT event_id, MAX(captured_at) AS captured_at FROM zone_metrics GROUP BY event_id) latest USING (event_id, captured_at);
