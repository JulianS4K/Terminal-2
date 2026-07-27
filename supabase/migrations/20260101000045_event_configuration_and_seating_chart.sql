-- Cowork migration. Captured into git by code (auditor) on 2026-05-07.
-- Originally applied to prod 2026-05-08 00:04 UTC.
--
-- v27: cache configuration + seating chart fields per event so broker terminal
-- and retail chat can surface the map without re-fetching /v9/events/{id}.
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS configuration_id integer,
  ADD COLUMN IF NOT EXISTS configuration_name text,
  ADD COLUMN IF NOT EXISTS seating_chart_medium text,
  ADD COLUMN IF NOT EXISTS seating_chart_large text,
  ADD COLUMN IF NOT EXISTS fanvenues_key text,
  ADD COLUMN IF NOT EXISTS popularity_score numeric,
  ADD COLUMN IF NOT EXISTS long_term_popularity_score numeric;

CREATE INDEX IF NOT EXISTS events_configuration_id_idx ON events (configuration_id) WHERE configuration_id IS NOT NULL;

-- Helper: a clean view that filters out TEvo's literal-string "null"
-- and exposes a single boolean has_seating_chart.
CREATE OR REPLACE VIEW v_event_seating_chart AS
SELECT
  id AS event_id,
  configuration_id,
  configuration_name,
  CASE WHEN seating_chart_medium IS NOT NULL
        AND seating_chart_medium <> 'null'
        AND seating_chart_medium ILIKE 'http%'
       THEN seating_chart_medium END AS map_medium_url,
  CASE WHEN seating_chart_large IS NOT NULL
        AND seating_chart_large <> 'null'
        AND seating_chart_large ILIKE 'http%'
       THEN seating_chart_large END AS map_large_url,
  fanvenues_key,
  popularity_score,
  long_term_popularity_score,
  (seating_chart_medium IS NOT NULL
    AND seating_chart_medium <> 'null'
    AND seating_chart_medium ILIKE 'http%') AS has_seating_chart
FROM events;
