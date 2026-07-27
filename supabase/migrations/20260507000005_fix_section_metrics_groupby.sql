-- Fix GROUP BY bug in compute_event_section_metrics — restructured CTEs so the
-- zone-source CASE expression is computed once per row before grouping.

CREATE OR REPLACE FUNCTION compute_event_section_metrics(p_event_id bigint, p_captured_at timestamptz)
RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE v_performer_id bigint; v_venue_id bigint; v_count integer;
BEGIN
  SELECT primary_performer_id, venue_id INTO v_performer_id, v_venue_id FROM events WHERE id = p_event_id;
  WITH per_row AS (
    SELECT l.section, l.row, l.quantity, l.retail_price, l.wholesale_price, l.is_owned, l.is_ancillary,
      curated.name AS curated_name, derive_zone_fallback(l.section, l.row) AS fb_zone,
      COALESCE(curated.name, derive_zone_fallback(l.section, l.row), 'unmapped') AS zone,
      CASE WHEN curated.name IS NOT NULL THEN 'curated'
           WHEN derive_zone_fallback(l.section, l.row) IS NOT NULL THEN 'fallback' ELSE 'unmapped' END AS zone_source
    FROM listings_snapshots l
    LEFT JOIN LATERAL (SELECT match_performer_zone(v_performer_id, v_venue_id, l.section, l.row) AS name) curated ON true
    WHERE l.event_id = p_event_id AND l.captured_at = p_captured_at AND l.section IS NOT NULL
  ),
  expanded AS (
    SELECT pr.section, pr.retail_price, pr.wholesale_price, pr.is_owned
    FROM per_row pr JOIN LATERAL generate_series(1, GREATEST(pr.quantity, 0)) AS gs(n) ON true
  ),
  per_section_zone_counts AS (
    SELECT section, zone, zone_source, COUNT(*) AS row_cnt
    FROM per_row GROUP BY section, zone, zone_source
  ),
  per_section_zone AS (
    SELECT section, zone, zone_source,
      ROW_NUMBER() OVER (PARTITION BY section
        ORDER BY CASE zone_source WHEN 'curated' THEN 0 WHEN 'fallback' THEN 1 ELSE 2 END, row_cnt DESC) AS rn
    FROM per_section_zone_counts
  ),
  agg AS (
    SELECT pr.section, bool_and(pr.is_ancillary) AS all_ancillary,
      SUM(pr.quantity)::int AS tickets_count, COUNT(*)::int AS groups_count,
      MIN(pr.retail_price) FILTER (WHERE pr.quantity >= 2 AND pr.retail_price IS NOT NULL) AS getin_price,
      COUNT(*) FILTER (WHERE pr.is_owned)::int AS owned_groups_count,
      COALESCE(SUM(pr.quantity) FILTER (WHERE pr.is_owned), 0)::int AS owned_tickets_count
    FROM per_row pr GROUP BY pr.section
  ),
  pct AS (
    SELECT e.section, MIN(e.retail_price) AS retail_min,
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
    FROM expanded e GROUP BY e.section
  )
  INSERT INTO section_metrics (event_id, captured_at, section, is_ancillary,
    tickets_count, groups_count, sections_count,
    retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90, retail_max, retail_sum,
    wholesale_min, wholesale_median, wholesale_mean, wholesale_max, getin_price,
    owned_groups_count, owned_tickets_count, owned_share, owned_median_retail, zone, zone_source)
  SELECT p_event_id, p_captured_at, a.section, a.all_ancillary, a.tickets_count, a.groups_count, 1,
    round(p.retail_min::numeric,2), round(p.retail_p25::numeric,2), round(p.retail_median::numeric,2),
    round(p.retail_mean::numeric,2), round(p.retail_p75::numeric,2), round(p.retail_p90::numeric,2),
    round(p.retail_max::numeric,2), round(p.retail_sum::numeric,2),
    round(p.wholesale_min::numeric,2), round(p.wholesale_median::numeric,2),
    round(p.wholesale_mean::numeric,2), round(p.wholesale_max::numeric,2),
    round(a.getin_price::numeric,2), a.owned_groups_count, a.owned_tickets_count,
    CASE WHEN a.tickets_count > 0 THEN round((a.owned_tickets_count::numeric / a.tickets_count)::numeric, 4) ELSE NULL END,
    round(p.owned_median_retail::numeric,2), z.zone, z.zone_source
  FROM agg a JOIN pct p ON p.section = a.section
  LEFT JOIN per_section_zone z ON z.section = a.section AND z.rn = 1
  ON CONFLICT (event_id, captured_at, section) DO UPDATE SET
    is_ancillary = EXCLUDED.is_ancillary, tickets_count = EXCLUDED.tickets_count,
    groups_count = EXCLUDED.groups_count, sections_count = EXCLUDED.sections_count,
    retail_min = EXCLUDED.retail_min, retail_p25 = EXCLUDED.retail_p25,
    retail_median = EXCLUDED.retail_median, retail_mean = EXCLUDED.retail_mean,
    retail_p75 = EXCLUDED.retail_p75, retail_p90 = EXCLUDED.retail_p90,
    retail_max = EXCLUDED.retail_max, retail_sum = EXCLUDED.retail_sum,
    wholesale_min = EXCLUDED.wholesale_min, wholesale_median = EXCLUDED.wholesale_median,
    wholesale_mean = EXCLUDED.wholesale_mean, wholesale_max = EXCLUDED.wholesale_max,
    getin_price = EXCLUDED.getin_price, owned_groups_count = EXCLUDED.owned_groups_count,
    owned_tickets_count = EXCLUDED.owned_tickets_count, owned_share = EXCLUDED.owned_share,
    owned_median_retail = EXCLUDED.owned_median_retail,
    zone = EXCLUDED.zone, zone_source = EXCLUDED.zone_source;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $fn$;
