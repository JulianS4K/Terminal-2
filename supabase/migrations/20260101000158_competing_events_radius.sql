-- ============================================================================
-- Migration 20260509300000 — Competing events within radius (geo-aware)
--
-- Day-trader query: "what other events are competing for the same audience
-- in this metro on this day?" Auto-populates as more venues get geocoded
-- by the existing venue_geocode_queue_5min cron.
--
-- (a) haversine_miles(lat1,lon1,lat2,lon2) — great-circle distance
-- (b) v_venue_neighbors — pre-joins venue pairs within 50 miles
-- (c) v_competing_events — same-date events at venues within 20 miles
-- (d) find_competing_events(event_id, radius_mi, day_window) RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION haversine_miles(
  p_lat1 numeric, p_lon1 numeric, p_lat2 numeric, p_lon2 numeric
) RETURNS numeric AS $$
DECLARE
  v_r numeric := 3959;
  v_dlat numeric; v_dlon numeric;
  v_a numeric; v_c numeric;
  v_lat1 numeric; v_lat2 numeric;
BEGIN
  IF p_lat1 IS NULL OR p_lon1 IS NULL OR p_lat2 IS NULL OR p_lon2 IS NULL THEN
    RETURN NULL;
  END IF;
  v_lat1 := radians(p_lat1::float);
  v_lat2 := radians(p_lat2::float);
  v_dlat := radians((p_lat2 - p_lat1)::float);
  v_dlon := radians((p_lon2 - p_lon1)::float);
  v_a := sin(v_dlat/2)^2 + cos(v_lat1)*cos(v_lat2)*sin(v_dlon/2)^2;
  v_c := 2 * atan2(sqrt(v_a), sqrt(1 - v_a));
  RETURN round((v_r * v_c)::numeric, 2);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE VIEW v_venue_neighbors AS
SELECT
  a.tevo_venue_id AS venue_id,
  a.venue_name, a.city, a.state,
  b.tevo_venue_id AS neighbor_venue_id,
  b.venue_name AS neighbor_name,
  b.city AS neighbor_city,
  haversine_miles(a.latitude, a.longitude, b.latitude, b.longitude) AS distance_miles
FROM venue_assets a
JOIN venue_assets b
  ON a.tevo_venue_id <> b.tevo_venue_id
 AND a.latitude IS NOT NULL AND b.latitude IS NOT NULL
 AND haversine_miles(a.latitude, a.longitude, b.latitude, b.longitude) <= 50;

CREATE OR REPLACE VIEW v_competing_events AS
SELECT
  e.id AS tevo_event_id, e.name AS event_name,
  e.occurs_at_local::timestamptz::date AS event_date,
  e.venue_name, e.event_type, e.primary_performer_name,
  c.id AS competing_event_id, c.name AS competing_event_name,
  c.occurs_at_local::timestamptz::date AS competing_event_date,
  c.venue_name AS competing_venue_name, c.event_type AS competing_event_type,
  c.primary_performer_name AS competing_performer,
  vn.distance_miles, vn.city AS our_city, vn.neighbor_city AS competing_city
FROM events e
JOIN v_venue_neighbors vn ON vn.venue_id = e.venue_id
JOIN events c ON c.venue_id = vn.neighbor_venue_id
            AND c.id <> e.id
            AND c.occurs_at_local::timestamptz::date = e.occurs_at_local::timestamptz::date
WHERE vn.distance_miles <= 20;

CREATE OR REPLACE FUNCTION find_competing_events(
  p_event_id bigint,
  p_radius_miles numeric DEFAULT 20,
  p_day_window int DEFAULT 0
) RETURNS TABLE (
  competing_event_id bigint,
  competing_event_name text,
  competing_event_date date,
  competing_venue text,
  competing_city text,
  competing_event_type text,
  competing_performer text,
  distance_miles numeric,
  date_offset_days int
) AS $$
DECLARE v_lat numeric; v_lon numeric; v_date date;
BEGIN
  SELECT va.latitude, va.longitude, e.occurs_at_local::timestamptz::date
  INTO v_lat, v_lon, v_date
  FROM events e LEFT JOIN venue_assets va ON va.tevo_venue_id = e.venue_id
  WHERE e.id = p_event_id;
  IF v_lat IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT
    c.id, c.name, c.occurs_at_local::timestamptz::date,
    c.venue_name, va.city, c.event_type, c.primary_performer_name,
    haversine_miles(v_lat, v_lon, va.latitude, va.longitude),
    (c.occurs_at_local::timestamptz::date - v_date)::int
  FROM events c
  JOIN venue_assets va ON va.tevo_venue_id = c.venue_id
  WHERE c.id <> p_event_id AND va.latitude IS NOT NULL
    AND haversine_miles(v_lat, v_lon, va.latitude, va.longitude) <= p_radius_miles
    AND abs(c.occurs_at_local::timestamptz::date - v_date) <= p_day_window
  ORDER BY haversine_miles(v_lat, v_lon, va.latitude, va.longitude),
           c.occurs_at_local;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION haversine_miles(numeric, numeric, numeric, numeric) IS
  'Great-circle distance between two lat/lon points in miles.';
COMMENT ON VIEW v_venue_neighbors IS
  'All venue-pairs within 50 miles. Refreshes automatically as new venues geocode.';
COMMENT ON VIEW v_competing_events IS
  'Per-event same-date events within 20mi. Auto-grows as venue geocode '
  'coverage expands via venue_geocode_queue_5min cron.';
COMMENT ON FUNCTION find_competing_events(bigint, numeric, int) IS
  'Per-event competing-event finder. radius_miles + day_window adjustable.';
