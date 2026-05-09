-- ============================================================================
-- Migration 20260509400000 — Surface weather forecast for indoor + outdoor
--
-- Per directive: "keep weather forecast if indoors or outdoors events."
--
-- The forecast queue already pulls weather for ALL venues with coords
-- regardless of indoor/outdoor — that's correct. The bug is at the view
-- layer: v_event_weather_with_fallback collapses `weather_kind` to
-- 'indoor_no_weather' when va.is_indoor is true, which made consumers
-- (including get_event_context and the Knicks audit) think no data
-- existed even when forecast rows DID. 93 of 671 indoor events were
-- already silently sitting on forecast data that the view was hiding.
--
-- WHAT THIS CHANGES:
--   weather_kind enum split into source-of-truth labels:
--     'forecast_indoor'   — indoor venue, forecast data present
--     'forecast_outdoor'  — outdoor venue, forecast data present
--     'climatology_indoor'  — indoor, beyond 16d, climatology only
--     'climatology_outdoor' — outdoor, beyond 16d, climatology only
--     'none' — no data at all
--   is_indoor flag remains a separate column so consumers can decide
--   whether to surface or downplay weather based on venue type.
--
-- The point: indoor weather IS still relevant — a snowstorm affects
-- attendance even at an indoor arena (people don't drive in), and
-- AI/RAG consumers benefit from full context whether or not the actual
-- game is climate-controlled.
-- ============================================================================

CREATE OR REPLACE VIEW v_event_weather_with_fallback AS
SELECT
  e.id AS tevo_event_id,
  e.name AS event_name,
  e.occurs_at_local,
  e.venue_id,
  e.venue_name,
  va.latitude,
  va.longitude,
  va.is_indoor,
  e.occurs_at_local::timestamptz::date - CURRENT_DATE AS days_to_event,
  CASE
    WHEN fcst.temp_f IS NOT NULL AND va.is_indoor      THEN 'forecast_indoor'
    WHEN fcst.temp_f IS NOT NULL                       THEN 'forecast_outdoor'
    WHEN climo.avg_temp_f IS NOT NULL AND va.is_indoor THEN 'climatology_indoor'
    WHEN climo.avg_temp_f IS NOT NULL                  THEN 'climatology_outdoor'
    ELSE 'none'
  END AS weather_kind,
  fcst.temp_f       AS fcst_temp_f,
  fcst.precip_in    AS fcst_precip_in,
  fcst.precip_pct   AS fcst_precip_pct,
  fcst.wind_mph     AS fcst_wind_mph,
  fcst.gust_mph     AS fcst_gust_mph,
  fcst.weather_summary AS fcst_summary,
  climo.avg_temp_f      AS climo_avg_temp_f,
  climo.stddev_temp_f   AS climo_stddev_temp_f,
  climo.avg_precip_in   AS climo_avg_precip_in,
  climo.climo_precip_pct,
  climo.avg_wind_mph    AS climo_avg_wind_mph,
  climo.sample_size_years,
  wmo_to_summary(climo.modal_wmo_code) AS climo_modal_summary,
  COALESCE(fcst.temp_f, climo.avg_temp_f)               AS temp_f,
  COALESCE(fcst.precip_in, climo.avg_precip_in)         AS precip_in,
  COALESCE(fcst.precip_pct, climo.climo_precip_pct::int) AS precip_pct,
  COALESCE(fcst.wind_mph, climo.avg_wind_mph)            AS wind_mph,
  COALESCE(fcst.weather_summary, wmo_to_summary(climo.modal_wmo_code)) AS weather_summary
FROM events e
LEFT JOIN venue_assets va ON va.tevo_venue_id = e.venue_id
LEFT JOIN LATERAL (
  SELECT w.temp_f, w.precip_in, w.precip_pct, w.wind_mph, w.gust_mph, w.weather_summary
  FROM weather_observations w
  WHERE w.tevo_venue_id = e.venue_id AND w.is_forecast
    AND w.observed_at >= e.occurs_at_local::timestamptz - interval '30 minutes'
    AND w.observed_at <= e.occurs_at_local::timestamptz + interval '30 minutes'
  ORDER BY abs(EXTRACT(epoch FROM w.observed_at - e.occurs_at_local::timestamptz))
  LIMIT 1
) fcst ON true
LEFT JOIN v_venue_climatology climo
  ON climo.tevo_venue_id = e.venue_id
 AND climo.month       = EXTRACT(month FROM e.occurs_at_local::timestamptz)::int
 AND climo.day_of_month = EXTRACT(day   FROM e.occurs_at_local::timestamptz)::int
 AND climo.hour_of_day  = EXTRACT(hour  FROM e.occurs_at_local::timestamptz)::int;

COMMENT ON VIEW v_event_weather_with_fallback IS
  'Per-event weather: forecast within 16d, climatology fallback beyond. '
  'weather_kind labels source-of-truth (forecast vs climatology) AND '
  'venue type (indoor vs outdoor). Indoor venues get the same weather '
  'data — AI/RAG and decision surfaces choose how to present based on '
  'is_indoor flag, not on whether data exists.';

-- ============================================================================
-- Drain stuck forecast-pending rows (>4h with no resolution).
-- Caused MSG (tevo_venue_id 896) to show 0 observations in the Knicks audit
-- — pending row blocked the next queue iteration.
-- ============================================================================

DELETE FROM weather_forecast_pending
WHERE resolved_at IS NULL AND fired_at < now() - interval '4 hours';
