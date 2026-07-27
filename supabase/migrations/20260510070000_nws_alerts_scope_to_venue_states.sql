-- ============================================================================
-- Migration 20260510070000 — NWS scope: venue-states only + 30min cadence
--
-- Phase 1 launched the NWS pipeline with a 10-min sweep of all 50 US
-- states. After 3h of live data, the audit said: "we're over-pulling".
--
-- Numbers from the live audit:
--   • 7,200 HTTP calls/day projected (50 states × 6/hr × 24)
--   • 26 of 50 states actually have venues (24 swept for nothing)
--   • 249 distinct alerts ingested in 3h; 10 matched a venue (4% hit rate)
--   • Average alert lifetime: 8 hours
--
-- 10-min latency is overkill for an 8h-lived signal, especially when
-- TEvo listings only refresh every 20 min in the same pipeline. The
-- ticket-broker context tolerates 30-min weather-alert latency.
--
-- Two changes in this migration:
--   1. Default state list derived from venue_assets.ugc_county_code
--      prefix (26 states, not 50)
--   2. Cron 10-min → 30-min cadence
--
-- Result: ~1,250 HTTP calls/day. 83% reduction.
--
-- Manual override preserved: caller can pass p_states for ad-hoc sweeps
-- (e.g. when investigating a specific incident outside our footprint).
-- ============================================================================

CREATE OR REPLACE FUNCTION nws_alerts_queue(p_states text[] DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_states text[];
  st text; v_req_id bigint; v_count int := 0;
BEGIN
  IF p_states IS NOT NULL THEN
    v_states := p_states;
  ELSE
    SELECT array_agg(DISTINCT substring(ugc_county_code, 1, 2))
      INTO v_states
      FROM venue_assets
     WHERE ugc_county_code IS NOT NULL;

    -- Defensive fallback if venue_assets backfill is ever wiped
    IF v_states IS NULL OR cardinality(v_states) = 0 THEN
      v_states := ARRAY['NY','CA','TX','FL','IL','PA','OH','MA','GA','MI'];
    END IF;
  END IF;

  FOREACH st IN ARRAY v_states LOOP
    SELECT net.http_get(
      url := 'https://api.weather.gov/alerts/active',
      params := jsonb_build_object('area', st),
      headers := jsonb_build_object(
        'Accept',     'application/geo+json',
        'User-Agent', 'terminal-2-broker (julian@s4kent.com)'
      ),
      timeout_milliseconds := 20000
    ) INTO v_req_id;
    INSERT INTO nws_alert_pending(state_code, request_id) VALUES (st, v_req_id);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.2);
  END LOOP;
  RETURN v_count;
END $$;

COMMENT ON FUNCTION nws_alerts_queue(text[]) IS
  'Sweeps /alerts/active?area=ST for venue-relevant states only (derived '
  'from venue_assets.ugc_county_code). Pass p_states to override for '
  'manual ad-hoc sweeps. 0.2s pacing keeps us polite to NWS.';

-- Replace 10-min cron with 30-min cadence
SELECT cron.unschedule('nws_alerts_queue_10min');
SELECT cron.schedule('nws_alerts_queue_30min',  '*/30 * * * *', $$ SELECT public.nws_alerts_queue(); $$);
