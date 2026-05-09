-- ============================================================================
-- Migration 20260509270000 — Weather climatology fallback for events > 16d out
--
-- Open-Meteo's free forecast caps at 16 days. For events beyond that we
-- compute climatology (rolling 3-year average for same calendar day-hour
-- at the same venue) so day-traders get a "typical weather" signal much
-- earlier in the buying cycle.
-- ============================================================================

-- (a) Climatology aggregation
CREATE OR REPLACE VIEW v_venue_climatology AS
SELECT
  tevo_venue_id,
  extract(month FROM observed_at)::int    AS month,
  extract(day   FROM observed_at)::int    AS day_of_month,
  extract(hour  FROM observed_at)::int    AS hour_of_day,
  count(*)                                AS sample_size_years,
  round(avg(temp_f)::numeric, 1)          AS avg_temp_f,
  round(stddev(temp_f)::numeric, 1)       AS stddev_temp_f,
  round(avg(precip_in)::numeric, 3)       AS avg_precip_in,
  round(100.0 * count(*) FILTER (WHERE precip_in > 0)::numeric / count(*), 1) AS climo_precip_pct,
  round(avg(wind_mph)::numeric, 1)        AS avg_wind_mph,
  round(avg(humidity_pct)::numeric, 0)    AS avg_humidity_pct,
  mode() WITHIN GROUP (ORDER BY wmo_code) AS modal_wmo_code,
  min(observed_at)::date                  AS earliest_year,
  max(observed_at)::date                  AS latest_year
FROM weather_observations
WHERE is_forecast = false
GROUP BY tevo_venue_id,
         extract(month FROM observed_at)::int,
         extract(day   FROM observed_at)::int,
         extract(hour  FROM observed_at)::int;

COMMENT ON VIEW v_venue_climatology IS
  'Per (venue, month, day, hour) historical weather averages. Drives the '
  'climatology fallback for events beyond the 16-day Open-Meteo forecast.';

-- (b) Fallback view — forecast for ≤16d, climatology for > 16d, NULL if neither
CREATE OR REPLACE VIEW v_event_weather_with_fallback AS
SELECT
  e.id AS tevo_event_id, e.name AS event_name,
  e.occurs_at_local, e.venue_id, e.venue_name,
  va.latitude, va.longitude, va.is_indoor,
  (e.occurs_at_local::timestamptz::date - current_date) AS days_to_event,
  CASE
    WHEN va.is_indoor THEN 'indoor_no_weather'
    WHEN e.occurs_at_local::timestamptz::date <= current_date + 16 AND fcst.temp_f IS NOT NULL THEN 'forecast'
    WHEN climo.avg_temp_f IS NOT NULL THEN 'climatology'
    ELSE 'none'
  END AS weather_kind,
  fcst.temp_f       AS fcst_temp_f, fcst.precip_in    AS fcst_precip_in,
  fcst.precip_pct   AS fcst_precip_pct, fcst.wind_mph     AS fcst_wind_mph,
  fcst.gust_mph     AS fcst_gust_mph, fcst.weather_summary AS fcst_summary,
  climo.avg_temp_f       AS climo_avg_temp_f, climo.stddev_temp_f    AS climo_stddev_temp_f,
  climo.avg_precip_in    AS climo_avg_precip_in, climo.climo_precip_pct AS climo_precip_pct,
  climo.avg_wind_mph     AS climo_avg_wind_mph,
  climo.sample_size_years,
  wmo_to_summary(climo.modal_wmo_code) AS climo_modal_summary,
  COALESCE(fcst.temp_f,     climo.avg_temp_f)            AS temp_f,
  COALESCE(fcst.precip_in,  climo.avg_precip_in)         AS precip_in,
  COALESCE(fcst.precip_pct, climo.climo_precip_pct::int) AS precip_pct,
  COALESCE(fcst.wind_mph,   climo.avg_wind_mph)          AS wind_mph,
  COALESCE(fcst.weather_summary, wmo_to_summary(climo.modal_wmo_code)) AS weather_summary
FROM events e
LEFT JOIN venue_assets va ON va.tevo_venue_id = e.venue_id
LEFT JOIN LATERAL (
  SELECT temp_f, precip_in, precip_pct, wind_mph, gust_mph, weather_summary
  FROM weather_observations w
  WHERE w.tevo_venue_id = e.venue_id AND w.is_forecast
    AND w.observed_at BETWEEN e.occurs_at_local::timestamptz - interval '30 minutes'
                          AND e.occurs_at_local::timestamptz + interval '30 minutes'
  ORDER BY abs(extract(epoch FROM (w.observed_at - e.occurs_at_local::timestamptz)))
  LIMIT 1
) fcst ON true
LEFT JOIN v_venue_climatology climo
       ON climo.tevo_venue_id = e.venue_id
      AND climo.month        = extract(month FROM e.occurs_at_local::timestamptz)::int
      AND climo.day_of_month = extract(day   FROM e.occurs_at_local::timestamptz)::int
      AND climo.hour_of_day  = extract(hour  FROM e.occurs_at_local::timestamptz)::int;

COMMENT ON VIEW v_event_weather_with_fallback IS
  'Weather at game time with automatic climatology fallback. weather_kind: '
  'forecast (≤16d), climatology (>16d), indoor_no_weather, or none. Unified '
  'temp_f/precip_in/wind_mph columns auto-pick the right source.';

-- (c) Throttled archive retry — Open-Meteo archive is stricter than forecast.
-- 5s gap = 12 req/min, well under the rate-limit threshold.
CREATE OR REPLACE FUNCTION weather_historical_retry_throttled(p_limit int DEFAULT 10)
RETURNS int AS $$
DECLARE r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT p.tevo_venue_id, va.latitude::text AS lat, va.longitude::text AS lon,
           lower(p.date_window)::date AS d_start, upper(p.date_window)::date AS d_end
    FROM weather_forecast_pending p
    JOIN net._http_response h ON h.id = p.request_id
    JOIN venue_assets va ON va.tevo_venue_id = p.tevo_venue_id
    WHERE p.scope='historical' AND h.status_code = 429
    AND NOT EXISTS (
      SELECT 1 FROM weather_observations wo
      WHERE wo.tevo_venue_id = p.tevo_venue_id AND NOT wo.is_forecast
        AND wo.observed_at::date BETWEEN lower(p.date_window) AND upper(p.date_window)
      HAVING count(*) > 1000
    )
    LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://archive-api.open-meteo.com/v1/archive',
      params := jsonb_build_object(
        'latitude', r.lat, 'longitude', r.lon,
        'start_date', r.d_start::text, 'end_date', r.d_end::text,
        'hourly', 'temperature_2m,precipitation,wind_speed_10m,weather_code,relative_humidity_2m',
        'timezone', 'auto', 'temperature_unit', 'fahrenheit',
        'wind_speed_unit', 'mph', 'precipitation_unit', 'inch'),
      headers := jsonb_build_object('Accept', 'application/json'),
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO weather_forecast_pending(tevo_venue_id, scope, date_window, request_id, fired_at)
    VALUES (r.tevo_venue_id, 'historical', daterange(r.d_start, r.d_end, '[]'), v_req_id, now());
    v_count := v_count + 1;
    PERFORM pg_sleep(5.0);
  END LOOP;
  RETURN v_count;
END $$ LANGUAGE plpgsql;

-- (d) Outdoor-only backfill helper
CREATE OR REPLACE FUNCTION weather_historical_backfill_outdoor(
  p_start date, p_end date, p_limit int DEFAULT 30
) RETURNS int AS $$
DECLARE r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  FOR r IN
    SELECT DISTINCT va.tevo_venue_id, va.latitude::text AS lat, va.longitude::text AS lon
    FROM venue_assets va
    LEFT JOIN weather_forecast_pending p ON p.tevo_venue_id = va.tevo_venue_id
       AND p.scope='historical' AND p.date_window @> p_start
    WHERE va.latitude IS NOT NULL AND va.longitude IS NOT NULL
      AND (va.is_indoor IS NULL OR va.is_indoor = false)
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
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO weather_forecast_pending(tevo_venue_id, scope, date_window, request_id, fired_at)
    VALUES (r.tevo_venue_id, 'historical', daterange(p_start, p_end, '[]'), v_req_id, now());
    v_count := v_count + 1;
    PERFORM pg_sleep(5.0);  -- archive throttle
  END LOOP;
  RETURN v_count;
END $$ LANGUAGE plpgsql;

-- (e) Schedule weekly climatology refresh
SELECT cron.schedule(
  'weather_climatology_weekly',
  '0 6 * * 0',
  $$
  SELECT weather_historical_retry_throttled(20);
  SELECT weather_historical_backfill_outdoor(
    (current_date - interval '3 years')::date,
    (current_date - interval '1 day')::date,
    10);
  SELECT weather_historical_process();
  $$
);
