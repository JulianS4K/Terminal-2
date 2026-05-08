-- Cowork migration. Captured into git by code (auditor) on 2026-05-08.
-- Originally applied to prod 2026-05-08 02:08 UTC.
--
-- WHY-pattern signals: contextual data sources that explain demand/preference.
-- Each signal is normalized to value -1..1 (positive = demand boost, negative = drag).

CREATE TABLE IF NOT EXISTS why_signals (
  id              bigserial PRIMARY KEY,
  scope           text NOT NULL,                  -- 'event' | 'performer' | 'venue' | 'city' | 'global'
  scope_id        bigint,
  scope_label     text,
  signal_kind     text NOT NULL,
  signal_value    numeric NOT NULL,
  signal_label    text,
  weight          numeric DEFAULT 1.0,
  source          text NOT NULL,
  meta            jsonb DEFAULT '{}'::jsonb,
  fetched_at      timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz
);

CREATE INDEX IF NOT EXISTS why_signals_scope_idx       ON why_signals (scope, scope_id);
CREATE INDEX IF NOT EXISTS why_signals_kind_idx        ON why_signals (signal_kind);
CREATE INDEX IF NOT EXISTS why_signals_fresh_idx       ON why_signals (fetched_at DESC);
CREATE INDEX IF NOT EXISTS why_signals_expires_idx     ON why_signals (expires_at) WHERE expires_at IS NOT NULL;

CREATE OR REPLACE VIEW v_event_why_context AS
WITH event_sigs AS (
  SELECT scope_id AS event_id,
         jsonb_agg(jsonb_build_object('kind', signal_kind, 'value', signal_value, 'label', signal_label, 'weight', weight)) AS signals,
         sum(signal_value * weight) AS net_boost
  FROM why_signals
  WHERE scope='event' AND (expires_at IS NULL OR expires_at > now())
  GROUP BY scope_id
),
perf_sigs AS (
  SELECT scope_id AS performer_id,
         jsonb_agg(jsonb_build_object('kind', signal_kind, 'value', signal_value, 'label', signal_label, 'weight', weight)) AS signals,
         sum(signal_value * weight) AS net_boost
  FROM why_signals
  WHERE scope='performer' AND (expires_at IS NULL OR expires_at > now())
  GROUP BY scope_id
),
city_sigs AS (
  SELECT scope_label AS city,
         jsonb_agg(jsonb_build_object('kind', signal_kind, 'value', signal_value, 'label', signal_label, 'weight', weight)) AS signals,
         sum(signal_value * weight) AS net_boost
  FROM why_signals
  WHERE scope='city' AND (expires_at IS NULL OR expires_at > now())
  GROUP BY scope_label
)
SELECT
  e.id AS event_id, e.name, e.event_type, e.occurs_at_local,
  e.primary_performer_id, e.venue_name, e.venue_location,
  COALESCE(es.signals, '[]'::jsonb) AS event_signals,
  COALESCE(ps.signals, '[]'::jsonb) AS performer_signals,
  COALESCE(cs.signals, '[]'::jsonb) AS city_signals,
  COALESCE(es.net_boost, 0) + COALESCE(ps.net_boost, 0) + COALESCE(cs.net_boost, 0) AS total_why_boost
FROM events e
LEFT JOIN event_sigs es ON es.event_id = e.id
LEFT JOIN perf_sigs  ps ON ps.performer_id = e.primary_performer_id
LEFT JOIN city_sigs  cs ON cs.city = split_part(coalesce(e.venue_location,''), ',', 1)
WHERE e.occurs_at_local::timestamptz >= now()
  AND e.occurs_at_local::timestamptz <= now() + interval '60 days';

GRANT SELECT ON why_signals, v_event_why_context TO authenticated, service_role;

COMMENT ON TABLE why_signals IS
  'Contextual demand-signal store. Sources: weather (NOAA/OWM), social (Spotify/Reddit/YouTube/Bandsintown), news, holidays. Per-event/performer/city/global scope.';
