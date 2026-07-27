-- ============================================================================
-- Migration 20260509310000 — Refine competing-events to ±24h time window
--
-- Was: same calendar date filter. Missed cross-midnight pairs (e.g. game
-- ending at 10pm tonight vs concert starting 12:30am tomorrow).
--
-- Now: ±24 hours from event start datetime. Captures the real "same window
-- of attention" set for ticket buyers. Excludes week-out events.
--
-- RPC parameter renamed: p_day_window (int days) → p_window_hours (int, 24).
-- ============================================================================

DROP VIEW IF EXISTS v_competing_events;
CREATE VIEW v_competing_events AS
SELECT
  e.id AS tevo_event_id, e.name AS event_name,
  e.occurs_at_local::timestamptz AS event_at,
  e.venue_name, e.event_type, e.primary_performer_name,
  c.id AS competing_event_id, c.name AS competing_event_name,
  c.occurs_at_local::timestamptz AS competing_event_at,
  c.venue_name AS competing_venue_name, c.event_type AS competing_event_type,
  c.primary_performer_name AS competing_performer,
  vn.distance_miles, vn.city AS our_city, vn.neighbor_city AS competing_city,
  -- Hours offset (signed): negative = competing happens BEFORE ours
  round((extract(epoch FROM (c.occurs_at_local::timestamptz - e.occurs_at_local::timestamptz))/3600)::numeric, 1) AS hours_offset
FROM events e
JOIN v_venue_neighbors vn ON vn.venue_id = e.venue_id
JOIN events c ON c.venue_id = vn.neighbor_venue_id
            AND c.id <> e.id
            AND abs(extract(epoch FROM (c.occurs_at_local::timestamptz - e.occurs_at_local::timestamptz))) <= 24*3600
WHERE vn.distance_miles <= 20;

DROP FUNCTION IF EXISTS find_competing_events(bigint, numeric, int);
CREATE FUNCTION find_competing_events(
  p_event_id bigint,
  p_radius_miles numeric DEFAULT 20,
  p_window_hours int DEFAULT 24
) RETURNS TABLE (
  competing_event_id bigint, competing_event_name text,
  competing_event_at timestamptz, competing_venue text, competing_city text,
  competing_event_type text, competing_performer text,
  distance_miles numeric, hours_offset numeric
) AS $$
DECLARE v_lat numeric; v_lon numeric; v_at timestamptz;
BEGIN
  SELECT va.latitude, va.longitude, e.occurs_at_local::timestamptz
  INTO v_lat, v_lon, v_at
  FROM events e LEFT JOIN venue_assets va ON va.tevo_venue_id = e.venue_id
  WHERE e.id = p_event_id;
  IF v_lat IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT c.id, c.name, c.occurs_at_local::timestamptz,
    c.venue_name, va.city, c.event_type, c.primary_performer_name,
    haversine_miles(v_lat, v_lon, va.latitude, va.longitude),
    round((extract(epoch FROM (c.occurs_at_local::timestamptz - v_at))/3600)::numeric, 1)
  FROM events c
  JOIN venue_assets va ON va.tevo_venue_id = c.venue_id
  WHERE c.id <> p_event_id AND va.latitude IS NOT NULL
    AND haversine_miles(v_lat, v_lon, va.latitude, va.longitude) <= p_radius_miles
    AND abs(extract(epoch FROM (c.occurs_at_local::timestamptz - v_at))) <= p_window_hours * 3600
  ORDER BY haversine_miles(v_lat, v_lon, va.latitude, va.longitude),
           abs(extract(epoch FROM (c.occurs_at_local::timestamptz - v_at)));
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON VIEW v_competing_events IS
  '±24 HOURS competing events within 20 miles. Captures cross-midnight pairs '
  '(e.g. tonight game vs tomorrow-AM concert). hours_offset signed: '
  'negative = competing event is BEFORE ours.';
COMMENT ON FUNCTION find_competing_events(bigint, numeric, int) IS
  'Per-event competing-event finder. Defaults: 20mi radius, ±24h time window. '
  'Returns hours_offset signed. Pass larger window_hours for series context.';
