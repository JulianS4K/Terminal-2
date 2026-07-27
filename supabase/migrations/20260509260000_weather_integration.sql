-- ============================================================================
-- Migration 20260509260000 — Weather integration via Open-Meteo + OSM Nominatim
--
-- Two-stage async pipeline using pg_net (no API keys for either source):
--   Stage 1: geocode venue_assets via OSM Nominatim (UA-required)
--   Stage 2: pull Open-Meteo forecast for venues with coords + upcoming events
--   Stage 3: pull Open-Meteo historical archive for past events
--
-- Cadences:
--   venue_geocode_queue       every 5 min  — Nominatim for ungeocoded venues
--   venue_geocode_process     every 5 min  — parses Nominatim responses (offset +1m)
--   weather_forecast_queue    every 30 min — Open-Meteo for upcoming-event venues
--   weather_forecast_process  every 30 min — parses weather responses (offset +5m)
--
-- Time-to-weather for a new event:
--   Venue already geocoded: ≤ 30 min (next forecast tick)
--   Venue new (no coords):  ≤ 5 min geocode + 30 min weather = ≤ 35 min total
-- ============================================================================

-- (1) venue_assets — add coordinates
ALTER TABLE venue_assets
  ADD COLUMN IF NOT EXISTS latitude  numeric(9,6),
  ADD COLUMN IF NOT EXISTS longitude numeric(9,6),
  ADD COLUMN IF NOT EXISTS geocoded_at timestamptz,
  ADD COLUMN IF NOT EXISTS geocode_source text;

CREATE INDEX IF NOT EXISTS venue_assets_geocoded_idx
  ON venue_assets(tevo_venue_id) WHERE latitude IS NOT NULL;
CREATE INDEX IF NOT EXISTS venue_assets_ungeocoded_idx
  ON venue_assets(tevo_venue_id) WHERE latitude IS NULL;

-- (2) Pending tables for async pipeline
CREATE TABLE IF NOT EXISTS venue_geocode_pending (
  tevo_venue_id   bigint PRIMARY KEY,
  venue_name      text,
  query_string    text,
  request_id      bigint,
  fired_at        timestamptz DEFAULT now(),
  resolved_at     timestamptz
);

CREATE TABLE IF NOT EXISTS weather_forecast_pending (
  tevo_venue_id   bigint NOT NULL,
  scope           text NOT NULL,
  date_window     daterange,
  request_id      bigint,
  fired_at        timestamptz DEFAULT now(),
  resolved_at     timestamptz,
  PRIMARY KEY (tevo_venue_id, scope, fired_at)
);

-- (3) weather_observations — canonical table
CREATE TABLE IF NOT EXISTS weather_observations (
  id              bigserial PRIMARY KEY,
  source_key      text NOT NULL DEFAULT 'open_meteo' REFERENCES data_sources(source_key),
  tevo_venue_id   bigint NOT NULL,
  observed_at     timestamptz NOT NULL,
  fetched_at      timestamptz DEFAULT now(),
  is_forecast     boolean NOT NULL,
  temp_f          numeric,
  precip_in       numeric,
  precip_pct      int,
  wind_mph        numeric,
  gust_mph        numeric,
  humidity_pct    int,
  wmo_code        int,
  weather_summary text,
  raw_jsonb       jsonb,
  UNIQUE (tevo_venue_id, observed_at, is_forecast)
);

CREATE INDEX IF NOT EXISTS weather_obs_venue_time_idx
  ON weather_observations(tevo_venue_id, observed_at);
CREATE INDEX IF NOT EXISTS weather_obs_forecast_idx
  ON weather_observations(tevo_venue_id, observed_at) WHERE is_forecast;

CREATE OR REPLACE FUNCTION wmo_to_summary(p_code int) RETURNS text AS $$
BEGIN
  RETURN CASE p_code
    WHEN 0 THEN 'clear'
    WHEN 1 THEN 'mostly clear' WHEN 2 THEN 'partly cloudy' WHEN 3 THEN 'overcast'
    WHEN 45 THEN 'fog' WHEN 48 THEN 'rime fog'
    WHEN 51 THEN 'light drizzle' WHEN 53 THEN 'drizzle' WHEN 55 THEN 'heavy drizzle'
    WHEN 56 THEN 'freezing drizzle' WHEN 57 THEN 'heavy freezing drizzle'
    WHEN 61 THEN 'light rain' WHEN 63 THEN 'rain' WHEN 65 THEN 'heavy rain'
    WHEN 66 THEN 'freezing rain' WHEN 67 THEN 'heavy freezing rain'
    WHEN 71 THEN 'light snow' WHEN 73 THEN 'snow' WHEN 75 THEN 'heavy snow'
    WHEN 77 THEN 'snow grains'
    WHEN 80 THEN 'rain showers' WHEN 81 THEN 'heavy rain showers' WHEN 82 THEN 'violent rain showers'
    WHEN 85 THEN 'snow showers' WHEN 86 THEN 'heavy snow showers'
    WHEN 95 THEN 'thunderstorm' WHEN 96 THEN 'thunderstorm + hail' WHEN 99 THEN 'severe thunderstorm + hail'
    ELSE 'code ' || p_code::text END;
END $$ LANGUAGE plpgsql IMMUTABLE;

-- (4) Geocoder
CREATE OR REPLACE FUNCTION venue_geocode_queue(p_limit int DEFAULT 30)
RETURNS int AS $$
DECLARE r RECORD; v_req_id bigint; v_count int := 0; v_q text;
BEGIN
  FOR r IN
    SELECT va.tevo_venue_id, va.venue_name, va.city, va.state, va.country
    FROM venue_assets va
    LEFT JOIN venue_geocode_pending p
      ON p.tevo_venue_id = va.tevo_venue_id AND p.fired_at > now() - interval '6 hours'
    WHERE va.latitude IS NULL AND va.venue_name IS NOT NULL AND p.tevo_venue_id IS NULL
    ORDER BY va.tevo_venue_id LIMIT p_limit
  LOOP
    v_q := concat_ws(', ', r.venue_name, r.city, r.state, coalesce(r.country, 'USA'));
    SELECT net.http_get(
      url := 'https://nominatim.openstreetmap.org/search',
      params := jsonb_build_object('q', v_q, 'format', 'json', 'limit', '1', 'addressdetails', '0'),
      headers := jsonb_build_object(
        'User-Agent', 'Terminal2-S4K/1.0 (https://github.com/JulianS4K/Terminal-2; admin@s4kent.com)',
        'Accept', 'application/json'),
      timeout_milliseconds := 12000
    ) INTO v_req_id;
    INSERT INTO venue_geocode_pending(tevo_venue_id, venue_name, query_string, request_id, fired_at)
    VALUES (r.tevo_venue_id, r.venue_name, v_q, v_req_id, now())
    ON CONFLICT (tevo_venue_id) DO UPDATE SET
      venue_name = EXCLUDED.venue_name, query_string = EXCLUDED.query_string,
      request_id = EXCLUDED.request_id, fired_at = now(), resolved_at = NULL;
    v_count := v_count + 1;
    PERFORM pg_sleep(1.1);
  END LOOP;
  RETURN v_count;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION venue_geocode_process()
RETURNS TABLE(processed int, hits int, misses int) AS $$
DECLARE r RECORD; v_body jsonb; v_lat numeric; v_lon numeric;
  v_processed int := 0; v_hits int := 0; v_misses int := 0;
BEGIN
  FOR r IN
    SELECT p.tevo_venue_id, h.content, h.status_code
    FROM venue_geocode_pending p JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
    v_lat := NULL; v_lon := NULL;
    IF v_body IS NOT NULL AND jsonb_typeof(v_body) = 'array' AND jsonb_array_length(v_body) > 0 THEN
      v_lat := (v_body->0->>'lat')::numeric; v_lon := (v_body->0->>'lon')::numeric;
    END IF;
    IF v_lat IS NOT NULL AND v_lon IS NOT NULL THEN
      UPDATE venue_assets SET latitude = v_lat, longitude = v_lon,
        geocoded_at = now(), geocode_source = 'nominatim_osm'
      WHERE tevo_venue_id = r.tevo_venue_id;
      v_hits := v_hits + 1;
    ELSE v_misses := v_misses + 1; END IF;
    UPDATE venue_geocode_pending SET resolved_at = now() WHERE tevo_venue_id = r.tevo_venue_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_hits, v_misses;
END $$ LANGUAGE plpgsql;

-- (5) Weather forecast
CREATE OR REPLACE FUNCTION weather_forecast_queue(p_limit int DEFAULT 30)
RETURNS int AS $$
DECLARE r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT va.tevo_venue_id, va.latitude::text AS lat, va.longitude::text AS lon
    FROM venue_assets va
    JOIN events e ON e.venue_id = va.tevo_venue_id
                 AND e.occurs_at_local::date BETWEEN current_date AND current_date + 16
    LEFT JOIN weather_forecast_pending p ON p.tevo_venue_id = va.tevo_venue_id
                                        AND p.scope='forecast'
                                        AND p.fired_at > now() - interval '4 hours'
    WHERE va.latitude IS NOT NULL AND va.longitude IS NOT NULL AND p.tevo_venue_id IS NULL
    ORDER BY va.tevo_venue_id LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://api.open-meteo.com/v1/forecast',
      params := jsonb_build_object(
        'latitude', r.lat, 'longitude', r.lon,
        'hourly', 'temperature_2m,precipitation,precipitation_probability,wind_speed_10m,wind_gusts_10m,weather_code,relative_humidity_2m',
        'forecast_days', '16', 'timezone', 'auto',
        'temperature_unit', 'fahrenheit', 'wind_speed_unit', 'mph', 'precipitation_unit', 'inch'),
      headers := jsonb_build_object('Accept', 'application/json'),
      timeout_milliseconds := 15000
    ) INTO v_req_id;
    INSERT INTO weather_forecast_pending(tevo_venue_id, scope, request_id, fired_at)
    VALUES (r.tevo_venue_id, 'forecast', v_req_id, now());
    v_count := v_count + 1;
    PERFORM pg_sleep(0.3);
  END LOOP;
  RETURN v_count;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION _persist_weather_response(
  p_venue_id bigint, p_body jsonb, p_is_forecast boolean
) RETURNS int AS $$
DECLARE v_count int := 0;
BEGIN
  IF p_body IS NULL OR p_body->'hourly' IS NULL THEN RETURN 0; END IF;
  WITH src AS (
    SELECT i AS idx,
      ((p_body->'hourly'->'time')->>i)::timestamptz AS observed_at,
      (p_body->'hourly'->'temperature_2m'->>i)::numeric AS temp_f,
      (p_body->'hourly'->'precipitation'->>i)::numeric AS precip_in,
      CASE WHEN p_is_forecast THEN (p_body->'hourly'->'precipitation_probability'->>i)::int ELSE NULL END AS precip_pct,
      (p_body->'hourly'->'wind_speed_10m'->>i)::numeric AS wind_mph,
      CASE WHEN p_is_forecast THEN (p_body->'hourly'->'wind_gusts_10m'->>i)::numeric ELSE NULL END AS gust_mph,
      (p_body->'hourly'->'relative_humidity_2m'->>i)::int AS humidity_pct,
      (p_body->'hourly'->'weather_code'->>i)::int AS wmo_code
    FROM generate_series(0, jsonb_array_length(p_body->'hourly'->'time') - 1) AS i
  ),
  ins AS (
    INSERT INTO weather_observations
      (source_key, tevo_venue_id, observed_at, is_forecast,
       temp_f, precip_in, precip_pct, wind_mph, gust_mph, humidity_pct,
       wmo_code, weather_summary, raw_jsonb)
    SELECT 'open_meteo', p_venue_id, s.observed_at, p_is_forecast,
           s.temp_f, s.precip_in, s.precip_pct, s.wind_mph, s.gust_mph, s.humidity_pct,
           s.wmo_code, wmo_to_summary(s.wmo_code),
           jsonb_build_object('idx', s.idx, 'lat', p_body->>'latitude', 'lon', p_body->>'longitude')
    FROM src s
    ON CONFLICT (tevo_venue_id, observed_at, is_forecast) DO UPDATE SET
      temp_f = EXCLUDED.temp_f, precip_in = EXCLUDED.precip_in,
      precip_pct = EXCLUDED.precip_pct, wind_mph = EXCLUDED.wind_mph,
      gust_mph = EXCLUDED.gust_mph, humidity_pct = EXCLUDED.humidity_pct,
      wmo_code = EXCLUDED.wmo_code, weather_summary = EXCLUDED.weather_summary,
      fetched_at = now()
    RETURNING 1
  )
  SELECT count(*) INTO v_count FROM ins;
  RETURN v_count;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION weather_forecast_process()
RETURNS TABLE(processed int, rows_persisted int) AS $$
DECLARE r RECORD; v_body jsonb;
  v_processed int := 0; v_persisted int := 0;
BEGIN
  FOR r IN
    SELECT p.tevo_venue_id, h.content, h.status_code, p.fired_at
    FROM weather_forecast_pending p JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL AND p.scope = 'forecast'
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      v_persisted := v_persisted + _persist_weather_response(r.tevo_venue_id, v_body, true);
    END IF;
    UPDATE weather_forecast_pending SET resolved_at = now()
      WHERE tevo_venue_id = r.tevo_venue_id AND scope='forecast' AND fired_at = r.fired_at;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $$ LANGUAGE plpgsql;

-- (6) Historical archive
CREATE OR REPLACE FUNCTION weather_historical_backfill(
  p_start date, p_end date, p_limit int DEFAULT 30
) RETURNS int AS $$
DECLARE r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT va.tevo_venue_id, va.latitude::text AS lat, va.longitude::text AS lon
    FROM venue_assets va
    JOIN events e ON e.venue_id = va.tevo_venue_id
    JOIN seatgeek_historic_sales hs ON hs.sg_event_id IN (
      SELECT sg_event_id FROM seatgeek_event_xref WHERE tevo_event_id = e.id)
    LEFT JOIN weather_forecast_pending p ON p.tevo_venue_id = va.tevo_venue_id
       AND p.scope='historical' AND p.date_window @> p_start
    WHERE va.latitude IS NOT NULL AND hs.sg_event_date BETWEEN p_start AND p_end
      AND p.tevo_venue_id IS NULL
    ORDER BY va.tevo_venue_id LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://archive-api.open-meteo.com/v1/archive',
      params := jsonb_build_object(
        'latitude', r.lat, 'longitude', r.lon,
        'start_date', p_start::text, 'end_date', p_end::text,
        'hourly', 'temperature_2m,precipitation,wind_speed_10m,weather_code,relative_humidity_2m',
        'timezone', 'auto', 'temperature_unit', 'fahrenheit',
        'wind_speed_unit', 'mph', 'precipitation_unit', 'inch'),
      headers := jsonb_build_object('Accept', 'application/json'),
      timeout_milliseconds := 25000
    ) INTO v_req_id;
    INSERT INTO weather_forecast_pending(tevo_venue_id, scope, date_window, request_id, fired_at)
    VALUES (r.tevo_venue_id, 'historical', daterange(p_start, p_end, '[]'), v_req_id, now());
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION weather_historical_process()
RETURNS TABLE(processed int, rows_persisted int) AS $$
DECLARE r RECORD; v_body jsonb;
  v_processed int := 0; v_persisted int := 0;
BEGIN
  FOR r IN
    SELECT p.tevo_venue_id, p.fired_at, h.content, h.status_code
    FROM weather_forecast_pending p JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL AND p.scope='historical'
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb; EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      v_persisted := v_persisted + _persist_weather_response(r.tevo_venue_id, v_body, false);
    END IF;
    UPDATE weather_forecast_pending SET resolved_at = now()
      WHERE tevo_venue_id = r.tevo_venue_id AND scope='historical' AND fired_at = r.fired_at;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $$ LANGUAGE plpgsql;

-- (7) v_event_weather — weather at game time
CREATE OR REPLACE VIEW v_event_weather AS
SELECT
  e.id AS tevo_event_id, e.name AS event_name,
  e.occurs_at_local, e.venue_id, e.venue_name,
  va.latitude, va.longitude,
  w.observed_at, w.temp_f, w.precip_in, w.precip_pct,
  w.wind_mph, w.gust_mph, w.humidity_pct,
  w.wmo_code, w.weather_summary, w.is_forecast,
  w.fetched_at AS weather_fetched_at
FROM events e
LEFT JOIN venue_assets va ON va.tevo_venue_id = e.venue_id
LEFT JOIN LATERAL (
  SELECT * FROM weather_observations w
  WHERE w.tevo_venue_id = e.venue_id
    AND w.observed_at BETWEEN e.occurs_at_local::timestamptz - interval '30 minutes'
                          AND e.occurs_at_local::timestamptz + interval '30 minutes'
  ORDER BY abs(extract(epoch FROM (w.observed_at - e.occurs_at_local::timestamptz)))
  LIMIT 1
) w ON true;

-- (8) Register data sources + field map
INSERT INTO data_sources(source_key, display_name, kind, host, auth_method, notes) VALUES
  ('open_meteo', 'Open-Meteo', 'enrichment', 'api.open-meteo.com', 'public',
   'Free forecast (16-day hourly) + historical archive (1940-present). No API key.'),
  ('osm_nominatim', 'OpenStreetMap Nominatim', 'enrichment', 'nominatim.openstreetmap.org', 'public',
   'Free geocoder. UA required. 1 req/sec rate limit. Used to populate venue_assets lat/lon.')
ON CONFLICT (source_key) DO UPDATE SET
  display_name = EXCLUDED.display_name, kind = EXCLUDED.kind,
  host = EXCLUDED.host, notes = EXCLUDED.notes;

INSERT INTO data_source_field_map(source_key, entity_kind, canonical_field, source_field, source_table, example_value, notes) VALUES
  ('open_meteo',    'weather', 'temp_f',          'temperature_2m',         'weather_observations.temp_f',          '62.1', NULL),
  ('open_meteo',    'weather', 'precip_in',       'precipitation',          'weather_observations.precip_in',       '0.000', NULL),
  ('open_meteo',    'weather', 'precip_pct',      'precipitation_probability','weather_observations.precip_pct',    '0', 'forecast only'),
  ('open_meteo',    'weather', 'wind_mph',        'wind_speed_10m',         'weather_observations.wind_mph',        '6.7', NULL),
  ('open_meteo',    'weather', 'gust_mph',        'wind_gusts_10m',         'weather_observations.gust_mph',        '6.3', 'forecast only'),
  ('open_meteo',    'weather', 'humidity_pct',    'relative_humidity_2m',   'weather_observations.humidity_pct',    '58', NULL),
  ('open_meteo',    'weather', 'wmo_code',        'weather_code',           'weather_observations.wmo_code',        '0', 'WMO standard'),
  ('open_meteo',    'weather', 'is_forecast',     '(derived)',              'weather_observations.is_forecast',     'true | false', NULL),
  ('osm_nominatim', 'venue',   'latitude',        'lat',                    'venue_assets.latitude',                '37.4280', NULL),
  ('osm_nominatim', 'venue',   'longitude',       'lon',                    'venue_assets.longitude',               '-122.1548', NULL)
ON CONFLICT (source_key, entity_kind, canonical_field) DO UPDATE SET
  source_field = EXCLUDED.source_field, source_table = EXCLUDED.source_table,
  example_value = EXCLUDED.example_value, notes = EXCLUDED.notes;

-- (9) Schedule cron jobs
SELECT cron.schedule('venue_geocode_queue_5min',     '*/5 * * * *',  $$ SELECT venue_geocode_queue(30); $$);
SELECT cron.schedule('venue_geocode_process_5min',   '1-59/5 * * * *', $$ SELECT venue_geocode_process(); $$);
SELECT cron.schedule('weather_forecast_queue_30min', '*/30 * * * *', $$ SELECT weather_forecast_queue(30); $$);
SELECT cron.schedule('weather_forecast_process_30min','5-59/30 * * * *', $$ SELECT weather_forecast_process(); $$);

COMMENT ON TABLE weather_observations IS
  'Open-Meteo weather observations. is_forecast=true for ≤16-day forecasts; '
  '=false for historical archive (ERA5 reanalysis, lags real-time by ~5 days).';
