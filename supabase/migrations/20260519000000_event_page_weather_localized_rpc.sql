-- Migration 20260519000000 · lane:D0 (author) → A1 (apply) · writes:get_event_weather_localized · reads:v_event_weather_with_fallback,v_event_nws_alerts · pre:20260518040000 · auth:operator-approved 2026-05-19
--
-- D0 — venue-localized weather + NWS alerts for the event page.
-- Replaces the v3 RPC `weather` payload's behavior of returning ALL
-- alerts unfiltered.
--
-- Per A1 audit (bot_chat #309): v_event_weather_with_fallback exposes
-- fallback-aware top-level cols (temp_f/precip_in/precip_pct/wind_mph/
-- weather_summary) — no fcst_*/climo_* branching needed. weather_kind
-- column signals source: 'none' / 'forecast_indoor' / 'forecast_outdoor'
-- / 'climatology_outdoor'. v_event_nws_alerts filters alerts to the
-- event's venue via UGC zone match (matched_zone_kind tells us which
-- of county/forecast/fire-weather zone matched).

CREATE OR REPLACE FUNCTION public.get_event_weather_localized(p_event_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email    text;
  v_forecast jsonb;
  v_alerts   jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Forecast row from v_event_weather_with_fallback (one row per event).
  SELECT to_jsonb(f) INTO v_forecast
  FROM (
    SELECT
      tevo_event_id,
      venue_id,
      venue_name,
      is_indoor,
      occurs_at_local,
      days_to_event,
      weather_kind,
      temp_f,
      weather_summary       AS summary,
      precip_pct,
      precip_in,
      wind_mph,
      latitude,
      longitude
    FROM public.v_event_weather_with_fallback
    WHERE tevo_event_id = p_event_id
    LIMIT 1
  ) f;

  -- Localized NWS alerts via v_event_nws_alerts (auto-scoped to venue UGC zones).
  SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.severity_rank, a.expires_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_alerts
  FROM (
    SELECT
      alert_id,
      alert_event,
      severity,
      urgency,
      certainty,
      headline,
      area_desc,
      onset_at,
      expires_at,
      matched_zone_kind,
      ugc_code,
      -- For server-side ORDER BY: Extreme=1, Severe=2, Moderate=3, Minor=4, Unknown=5
      CASE lower(coalesce(severity, ''))
        WHEN 'extreme'  THEN 1
        WHEN 'severe'   THEN 2
        WHEN 'moderate' THEN 3
        WHEN 'minor'    THEN 4
        ELSE 5
      END AS severity_rank
    FROM public.v_event_nws_alerts
    WHERE tevo_event_id = p_event_id
  ) a;

  RETURN jsonb_build_object(
    'event_id',  p_event_id,
    'forecast',  v_forecast,
    'alerts',    v_alerts
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_event_weather_localized(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_weather_localized(integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_weather_localized(integer) IS
  'D0 event Overview — venue-localized weather forecast (v_event_weather_with_fallback) + NWS alerts (v_event_nws_alerts, filtered to event venue UGC zones). Replaces the v3 RPC weather payloads global-alert behavior. Email-gated.';
