-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod 2026-05-08 00:08 UTC.
-- NOTE: broker-lane work — flagged for review (broker_event_intel,
-- get_broker_event_detail, get_broker_events_upcoming, v_broker_configurations).

CREATE OR REPLACE FUNCTION get_broker_event_detail(p_event_id bigint)
RETURNS TABLE (
  event_id bigint,
  name text,
  occurs_at_local text,
  state text,
  venue_id integer,
  venue_name text,
  venue_location text,
  primary_performer_id integer,
  primary_performer_name text,
  performer_ids integer[],
  configuration_id integer,
  configuration_name text,
  map_medium_url text,
  map_large_url text,
  has_seating_chart boolean,
  fanvenues_key text,
  popularity_score numeric,
  long_term_popularity_score numeric,
  curated_zones_count integer
) LANGUAGE sql STABLE AS $$
  SELECT
    e.id,
    e.name,
    e.occurs_at_local,
    e.state,
    e.venue_id,
    e.venue_name,
    e.venue_location,
    e.primary_performer_id,
    e.primary_performer_name,
    e.performer_ids,
    e.configuration_id,
    e.configuration_name,
    CASE WHEN e.seating_chart_medium IS NOT NULL
          AND e.seating_chart_medium <> 'null'
          AND e.seating_chart_medium ILIKE 'http%'
         THEN e.seating_chart_medium END,
    CASE WHEN e.seating_chart_large IS NOT NULL
          AND e.seating_chart_large <> 'null'
          AND e.seating_chart_large ILIKE 'http%'
         THEN e.seating_chart_large END,
    (e.seating_chart_medium IS NOT NULL
      AND e.seating_chart_medium <> 'null'
      AND e.seating_chart_medium ILIKE 'http%'),
    e.fanvenues_key,
    e.popularity_score,
    e.long_term_popularity_score,
    COALESCE((SELECT COUNT(*)::int FROM performer_zones pz
              WHERE pz.performer_id = e.primary_performer_id
                AND pz.venue_id = e.venue_id
                AND COALESCE(pz.source, 'curated') = 'curated'), 0)
  FROM events e
  WHERE e.id = p_event_id;
$$;

CREATE OR REPLACE FUNCTION get_broker_events_upcoming(
  p_search text DEFAULT NULL,
  p_performer_id integer DEFAULT NULL,
  p_venue_id integer DEFAULT NULL,
  p_days_ahead integer DEFAULT 30,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE (
  event_id bigint,
  name text,
  occurs_at_local text,
  venue_name text,
  primary_performer_name text,
  configuration_id integer,
  configuration_name text,
  has_seating_chart boolean,
  map_medium_url text,
  long_term_popularity_score numeric
) LANGUAGE sql STABLE AS $$
  SELECT
    e.id,
    e.name,
    e.occurs_at_local,
    e.venue_name,
    e.primary_performer_name,
    e.configuration_id,
    e.configuration_name,
    (e.seating_chart_medium IS NOT NULL
      AND e.seating_chart_medium <> 'null'
      AND e.seating_chart_medium ILIKE 'http%'),
    CASE WHEN e.seating_chart_medium IS NOT NULL
          AND e.seating_chart_medium <> 'null'
          AND e.seating_chart_medium ILIKE 'http%'
         THEN e.seating_chart_medium END,
    e.long_term_popularity_score
  FROM events e
  WHERE e.occurs_at_local::timestamptz >= now()
    AND e.occurs_at_local::timestamptz <= now() + (p_days_ahead || ' days')::interval
    AND (p_search IS NULL OR e.name ILIKE '%'||p_search||'%' OR e.venue_name ILIKE '%'||p_search||'%')
    AND (p_performer_id IS NULL OR e.primary_performer_id = p_performer_id OR p_performer_id = ANY(COALESCE(e.performer_ids, ARRAY[]::integer[])))
    AND (p_venue_id IS NULL OR e.venue_id = p_venue_id)
  ORDER BY e.occurs_at_local
  LIMIT p_limit
  OFFSET p_offset;
$$;

CREATE OR REPLACE VIEW v_broker_configurations AS
SELECT
  e.configuration_id,
  e.configuration_name,
  COUNT(*) AS event_count,
  COUNT(DISTINCT e.primary_performer_id) AS performer_count,
  COUNT(DISTINCT e.venue_id) AS venue_count,
  array_agg(DISTINCT e.venue_name) AS venues,
  MAX(CASE WHEN e.seating_chart_medium IS NOT NULL
          AND e.seating_chart_medium <> 'null'
          AND e.seating_chart_medium ILIKE 'http%'
         THEN e.seating_chart_medium END) AS map_medium_url,
  MAX(CASE WHEN e.seating_chart_large IS NOT NULL
          AND e.seating_chart_large <> 'null'
          AND e.seating_chart_large ILIKE 'http%'
         THEN e.seating_chart_large END) AS map_large_url,
  MAX(e.fanvenues_key) AS fanvenues_key
FROM events e
WHERE e.configuration_id IS NOT NULL
  AND e.occurs_at_local::timestamptz >= now()
GROUP BY e.configuration_id, e.configuration_name;

GRANT EXECUTE ON FUNCTION get_broker_event_detail(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_broker_events_upcoming(text, integer, integer, integer, integer, integer) TO authenticated, service_role;
GRANT SELECT ON v_broker_configurations TO authenticated, service_role;
GRANT SELECT ON v_event_seating_chart TO authenticated, service_role;
