-- 20260508023500_fix_get_event_zones_public_numeric_cast.sql
-- Captured from prod (copilot, applied as version 20260508171641).
-- Captured into git 2026-05-08 by code via audit-and-commit.
--
-- Fix: explicit ::numeric casts on min/percentile/max so the function returns
-- numeric columns matching its declared signature (was failing on type
-- inference before).

DROP FUNCTION IF EXISTS get_event_zones_public(bigint, boolean);
CREATE OR REPLACE FUNCTION get_event_zones_public(
  p_event_id bigint, p_include_all boolean DEFAULT false
) RETURNS TABLE (
  zone_name text, zone_source text, display_order integer,
  listings integer, total_tickets integer,
  cheapest numeric, median numeric, most_expensive numeric
) LANGUAGE plpgsql STABLE AS $$
DECLARE v_perf bigint; v_venue bigint;
BEGIN
  SELECT primary_performer_id, venue_id INTO v_perf, v_venue FROM events WHERE id = p_event_id;
  RETURN QUERY
  WITH latest_snap AS (
    SELECT max(captured_at) AS captured_at
    FROM listings_snapshots
    WHERE event_id = p_event_id AND is_ancillary = false
      AND (type IS NULL OR type = 'event')
      AND captured_at > now() - interval '24 hours'
  ),
  filtered AS (
    SELECT ls.section, ls.retail_price, ls.quantity
    FROM listings_snapshots ls, latest_snap s
    WHERE ls.event_id = p_event_id AND ls.captured_at = s.captured_at
      AND ls.is_ancillary = false AND (ls.type IS NULL OR ls.type = 'event')
      AND ls.retail_price IS NOT NULL AND ls.retail_price > 0
      AND (p_include_all OR ls.is_owned = true)
  ),
  zoned AS (
    SELECT f.*,
      COALESCE(
        (SELECT pz.name FROM performer_zones pz
         JOIN performer_zone_rules pr ON pr.zone_id = pz.id
         WHERE pz.performer_id = v_perf AND pz.venue_id = v_venue
           AND COALESCE(pz.source,'curated') = 'curated'
           AND f.section ILIKE pr.section_from LIMIT 1),
        classify_zone_canonical(f.section)
      ) AS zname,
      COALESCE(
        (SELECT pz.source FROM performer_zones pz
         JOIN performer_zone_rules pr ON pr.zone_id = pz.id
         WHERE pz.performer_id = v_perf AND pz.venue_id = v_venue
           AND f.section ILIKE pr.section_from LIMIT 1),
        'system'
      ) AS zsource,
      COALESCE(
        (SELECT pz.display_order FROM performer_zones pz
         JOIN performer_zone_rules pr ON pr.zone_id = pz.id
         WHERE pz.performer_id = v_perf AND pz.venue_id = v_venue
           AND f.section ILIKE pr.section_from LIMIT 1),
        9000
      ) AS dorder
    FROM filtered f
  )
  SELECT zname, zsource, MIN(dorder)::int,
         count(*)::int, sum(quantity)::int,
         min(retail_price)::numeric,
         (percentile_cont(0.5) WITHIN GROUP (ORDER BY retail_price))::numeric,
         max(retail_price)::numeric
  FROM zoned
  GROUP BY zname, zsource
  ORDER BY (zsource = 'curated') DESC, MIN(dorder), MIN(retail_price);
END;
$$;
GRANT EXECUTE ON FUNCTION get_event_zones_public(bigint, boolean)
  TO anon, authenticated, service_role;
