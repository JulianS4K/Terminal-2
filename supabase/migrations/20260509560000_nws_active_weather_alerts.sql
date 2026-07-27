-- ============================================================================
-- Migration 20260509560000 — NWS Active Weather Alerts
--
-- Per directive (2026-05-09):
--   "map all available, catalogue the new schema and build"
--
-- Item #2 in the high-leverage context list. NWS api.weather.gov is free,
-- no-auth, requires only User-Agent header. Returns government-issued
-- watches/warnings/advisories with severity/urgency/certainty taxonomy
-- + counties/forecast-zones affected + free-text headline/description/instruction.
--
-- Complement to existing Open-Meteo numerical forecast — adds a categorical
-- alert dimension we don't currently have.
--
-- ----------------------------------------------------------------------------
-- DATA DICTIONARY  (every NWS field captured, see comments for skip rationale)
-- ----------------------------------------------------------------------------
--
--   nws_alerts                — one row per active alert (id PK = URN)
--   nws_alert_zones           — exploded geocode.UGC[] join table
--   nws_alert_references      — exploded references[] (alert update chains)
--   nws_alert_pending         — pg_net staging for state-sweep queue
--   venue_nws_points_pending  — pg_net staging for /points/ backfill queue
--
--   venue_assets gains:
--     ugc_county_code         — e.g. "TXC439"  (Tarrant County)
--     ugc_forecast_zone       — e.g. "TXZ118"  (forecast zone)
--     ugc_fire_weather_zone   — e.g. "TXZ118"  (often same as forecast)
--     nws_grid_id             — e.g. "FWD"     (forecast office / CWA)
--     nws_grid_x, nws_grid_y  — int (gridded forecast indices, optional)
--     nws_radar_station       — e.g. "KFWS"    (Doppler station)
--     nws_time_zone           — e.g. "America/Chicago"
--     nws_points_fetched_at   — timestamptz of last /points/ refresh
--
-- ----------------------------------------------------------------------------
-- WHY UGC IS CRITICAL
--   NWS alerts use either county codes ("XXC###", 51 of 363 alerts in our
--   national snapshot) OR forecast-zone codes ("XXZ###", 313 of 363) but
--   never both for the same alert. We MUST store both per-venue codes so
--   join-on-UGC catches both styles.
-- ============================================================================

-- ============================================================================
-- (1) venue_assets extension — backfill targets for /points/{lat},{lon}
-- ============================================================================

ALTER TABLE venue_assets
  ADD COLUMN IF NOT EXISTS ugc_county_code      text,
  ADD COLUMN IF NOT EXISTS ugc_forecast_zone    text,
  ADD COLUMN IF NOT EXISTS ugc_fire_weather_zone text,
  ADD COLUMN IF NOT EXISTS nws_grid_id          text,
  ADD COLUMN IF NOT EXISTS nws_grid_x           int,
  ADD COLUMN IF NOT EXISTS nws_grid_y           int,
  ADD COLUMN IF NOT EXISTS nws_radar_station    text,
  ADD COLUMN IF NOT EXISTS nws_time_zone        text,
  ADD COLUMN IF NOT EXISTS nws_points_fetched_at timestamptz;

CREATE INDEX IF NOT EXISTS venue_assets_ugc_county_idx   ON venue_assets(ugc_county_code);
CREATE INDEX IF NOT EXISTS venue_assets_ugc_zone_idx     ON venue_assets(ugc_forecast_zone);
CREATE INDEX IF NOT EXISTS venue_assets_nws_grid_idx     ON venue_assets(nws_grid_id);

-- ============================================================================
-- (2) Pending-queue staging tables (mirrors weather_forecast_pending pattern)
-- ============================================================================

CREATE TABLE IF NOT EXISTS venue_nws_points_pending (
  id           bigserial PRIMARY KEY,
  tevo_venue_id bigint NOT NULL,
  request_id   bigint NOT NULL,
  fired_at     timestamptz DEFAULT now(),
  resolved_at  timestamptz,
  http_status  int,
  error        text
);
CREATE INDEX IF NOT EXISTS venue_nws_points_pending_unresolved_idx
  ON venue_nws_points_pending(tevo_venue_id) WHERE resolved_at IS NULL;

CREATE TABLE IF NOT EXISTS nws_alert_pending (
  id           bigserial PRIMARY KEY,
  state_code   text NOT NULL,         -- 'TX','NY','CA',...
  request_id   bigint NOT NULL,
  fired_at     timestamptz DEFAULT now(),
  resolved_at  timestamptz,
  http_status  int,
  alerts_count int,
  error        text
);
CREATE INDEX IF NOT EXISTS nws_alert_pending_unresolved_idx
  ON nws_alert_pending(state_code, fired_at) WHERE resolved_at IS NULL;

-- ============================================================================
-- (3) nws_alerts — full data dictionary, every field captured
-- ============================================================================

CREATE TABLE IF NOT EXISTS nws_alerts (
  -- Identity
  id                 text PRIMARY KEY,           -- URN, e.g. "urn:oid:2.49.0.1.840.0.xxx.001.1"
  alert_url          text,                       -- @id field (api.weather.gov/alerts/{urn})

  -- Taxonomy
  event              text NOT NULL,              -- "Severe Thunderstorm Warning"
  event_code_nws     text,                       -- 3-letter SVW/SVA/TOR/HTY/etc.
  event_code_same    text,                       -- SAME 3-letter
  category           text,                       -- "Met" (always Meteorological)
  status             text,                       -- "Actual"|"Test"|"Exercise"|"System"
  message_type       text,                       -- "Alert"|"Update"|"Cancel"
  scope              text,                       -- "Public" usually
  alert_code         text,                       -- "IPAWSv1.0"
  language           text,                       -- "en-US"

  -- Severity assessment
  severity           text,                       -- Extreme|Severe|Moderate|Minor|Unknown
  urgency            text,                       -- Immediate|Expected|Future|Past|Unknown
  certainty          text,                       -- Observed|Likely|Possible|Unlikely|Unknown
  response_action    text,                       -- Shelter|Avoid|Execute|Monitor|...
  impact_tier        text,                       -- DERIVED: high|medium|low|info

  -- Time windows (all ISO-8601 from NWS, stored as timestamptz)
  sent_at            timestamptz NOT NULL,
  effective_at       timestamptz,
  onset_at           timestamptz,
  expires_at         timestamptz,
  ends_at            timestamptz,

  -- Geographic (text-level; UGC[] explodes into nws_alert_zones)
  area_desc          text,
  fips_codes         text[],                     -- geocode.SAME[] full list
  affected_zones_urls text[],                    -- affectedZones[] URLs

  -- Issuer
  sender             text,                       -- "w-nws.webmaster@noaa.gov"
  sender_name        text,                       -- "NWS Amarillo TX"
  web_url            text,                       -- "http://www.weather.gov"

  -- Human-readable text
  headline           text,
  description        text,
  instruction        text,
  note               text,

  -- Hazard quantitative parameters (promoted from `parameters` jsonb)
  max_wind_gust_mph         numeric,             -- parsed from "60 MPH"
  max_hail_size_in          numeric,             -- parsed from "1.50"
  wind_threat               text,                -- "RADAR INDICATED"|"OBSERVED"
  hail_threat               text,
  thunderstorm_damage_threat text,               -- "BASE"|"CONSIDERABLE"|"DESTRUCTIVE"
  waterspout_detection      text,                -- "OBSERVED"|"POSSIBLE"
  event_motion_description  text,                -- raw storm motion vector
  vtec                      text,                -- internal NWS routing
  awips_identifier          text,
  wmo_identifier            text,
  nws_headline_text         text,                -- parameters.NWSheadline (UPPERCASE single-line)
  block_channels            text[],              -- BLOCKCHANNEL array
  eas_org                   text,                -- EAS-ORG
  expired_references        text[],              -- expiredReferences

  -- Raw payload (forensic + future-proof — extract anything we missed later)
  raw_parameters     jsonb,
  raw_jsonb          jsonb,

  -- Bookkeeping
  ingested_at        timestamptz DEFAULT now(),
  last_seen_at       timestamptz DEFAULT now()   -- updated on every re-ingest
);

CREATE INDEX IF NOT EXISTS nws_alerts_event_idx       ON nws_alerts(event);
CREATE INDEX IF NOT EXISTS nws_alerts_severity_idx    ON nws_alerts(severity);
CREATE INDEX IF NOT EXISTS nws_alerts_impact_idx      ON nws_alerts(impact_tier);
CREATE INDEX IF NOT EXISTS nws_alerts_active_idx
  ON nws_alerts(effective_at, expires_at);
CREATE INDEX IF NOT EXISTS nws_alerts_last_seen_idx   ON nws_alerts(last_seen_at);

COMMENT ON TABLE nws_alerts IS
  'NWS api.weather.gov active alerts, idempotent on id (URN). Captures every '
  'usable field from the GeoJSON response — typed cols where queryable, raw '
  'jsonb for the rest. Cleanup: rows with expires_at + 7d old can be archived. '
  'See nws_alert_zones for the geocode.UGC[] explosion that drives venue match.';

-- ============================================================================
-- (4) nws_alert_zones — geocode.UGC[] explosion (one row per alert*UGC pair)
-- ============================================================================

CREATE TABLE IF NOT EXISTS nws_alert_zones (
  alert_id   text NOT NULL REFERENCES nws_alerts(id) ON DELETE CASCADE,
  ugc_code   text NOT NULL,                 -- "TXC211" (county) | "TXZ118" (forecast zone)
  ugc_kind   text NOT NULL,                 -- 'county' | 'forecast_zone'
  ugc_state  text,                          -- 2-letter state derived from prefix
  PRIMARY KEY (alert_id, ugc_code)
);
CREATE INDEX IF NOT EXISTS nws_alert_zones_ugc_idx       ON nws_alert_zones(ugc_code);
CREATE INDEX IF NOT EXISTS nws_alert_zones_state_idx     ON nws_alert_zones(ugc_state);

COMMENT ON TABLE nws_alert_zones IS
  'Per-alert UGC code list (exploded from nws_alerts.geocode.UGC[]). '
  'Join venue_assets.ugc_county_code OR venue_assets.ugc_forecast_zone '
  'against ugc_code to find alerts affecting a venue. ugc_kind tells you '
  'which side of the union matched.';

-- ============================================================================
-- (5) nws_alert_references — references[] chain (Update→Original)
-- ============================================================================

CREATE TABLE IF NOT EXISTS nws_alert_references (
  alert_id        text NOT NULL REFERENCES nws_alerts(id) ON DELETE CASCADE,
  references_id   text NOT NULL,            -- the original alert URN
  sender          text,
  sent_at         timestamptz,
  PRIMARY KEY (alert_id, references_id)
);

COMMENT ON TABLE nws_alert_references IS
  'Update/cancel chain. When NWS issues an Update or Cancel, the new alert '
  'has a different URN but references the original. Use this to walk the '
  'history of a single hazard event.';

-- ============================================================================
-- (6) impact_tier classifier — derived from event text
-- ============================================================================

CREATE OR REPLACE FUNCTION compute_nws_impact_tier(p_event text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    -- HIGH: life-safety / event-stoppers
    WHEN p_event ~* '(tornado|hurricane|typhoon|tsunami|blizzard|ice storm)\s*(warning|advisory)'                  THEN 'high'
    WHEN p_event ~* 'severe thunderstorm warning'                                                                  THEN 'high'
    WHEN p_event ~* '(extreme heat|excessive heat) warning'                                                        THEN 'high'
    WHEN p_event ~* 'red flag warning'                                                                             THEN 'high'
    WHEN p_event ~* 'special marine warning'                                                                       THEN 'high'
    WHEN p_event ~* '(freeze|hard freeze) warning'                                                                 THEN 'high'
    WHEN p_event ~* 'flash flood warning'                                                                          THEN 'high'
    WHEN p_event ~* 'winter storm warning'                                                                         THEN 'high'
    -- MEDIUM: meaningful but not life-threatening, may affect outdoor venues
    WHEN p_event ~* 'severe thunderstorm watch'                                                                    THEN 'medium'
    WHEN p_event ~* 'tornado watch'                                                                                THEN 'medium'
    WHEN p_event ~* 'flood (warning|advisory|watch)'                                                               THEN 'medium'
    WHEN p_event ~* '(wind|brisk wind|high wind) advisory'                                                         THEN 'medium'
    WHEN p_event ~* 'high wind warning'                                                                            THEN 'medium'
    WHEN p_event ~* '(frost|freeze) (advisory|watch)'                                                              THEN 'medium'
    WHEN p_event ~* 'air quality alert'                                                                            THEN 'medium'
    WHEN p_event ~* 'heat advisory'                                                                                THEN 'medium'
    WHEN p_event ~* 'winter (weather advisory|storm watch)'                                                        THEN 'medium'
    WHEN p_event ~* '(dense fog|dense smoke) advisory'                                                             THEN 'medium'
    WHEN p_event ~* '(lake effect snow|snow squall|beach hazards) (advisory|warning|statement)?'                   THEN 'medium'
    WHEN p_event ~* '(extreme heat|excessive heat) watch'                                                          THEN 'medium'
    -- LOW: marine/niche, mostly noise for stadium/arena venues
    WHEN p_event ~* 'small craft advisory'                                                                         THEN 'low'
    WHEN p_event ~* 'gale (warning|watch)'                                                                         THEN 'low'
    WHEN p_event ~* 'heavy freezing spray (warning|advisory)'                                                      THEN 'low'
    WHEN p_event ~* 'rip current statement'                                                                        THEN 'low'
    WHEN p_event ~* '(low water|lakeshore flood) advisory'                                                         THEN 'low'
    WHEN p_event ~* 'marine weather statement'                                                                     THEN 'low'
    -- INFO: statements, outlooks, fire weather watches
    WHEN p_event ~* '(special weather statement|hydrologic outlook|fire weather watch|test message)'               THEN 'info'
    ELSE 'info'
  END;
$$;

COMMENT ON FUNCTION compute_nws_impact_tier(text) IS
  'Maps NWS event text to a 4-tier severity for UI filtering. Default UI '
  'should show high+medium and let user opt into low (mostly marine noise).';

-- ============================================================================
-- (7) UGC parser helpers
-- ============================================================================

CREATE OR REPLACE FUNCTION ugc_kind(p_ugc text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_ugc ~ '^[A-Z]{2}C\d{3}$' THEN 'county'
    WHEN p_ugc ~ '^[A-Z]{2}Z\d{3}$' THEN 'forecast_zone'
    ELSE 'unknown'
  END;
$$;

CREATE OR REPLACE FUNCTION ugc_state(p_ugc text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_ugc ~ '^[A-Z]{2}[CZ]\d{3}$' THEN substring(p_ugc, 1, 2) END;
$$;

-- Extract trailing UGC token from an api.weather.gov zone URL
-- e.g. "https://api.weather.gov/zones/county/TXC439" → "TXC439"
CREATE OR REPLACE FUNCTION ugc_from_url(p_url text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT substring(p_url FROM '[A-Z]{2}[CZ]\d{3}$');
$$;

-- ============================================================================
-- (8) /points/{lat},{lon} backfill — queue
-- ============================================================================

CREATE OR REPLACE FUNCTION nws_points_queue(p_limit int DEFAULT 30)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  FOR r IN
    SELECT va.tevo_venue_id,
           round(va.latitude::numeric,  4)::text  AS lat,  -- NWS limits precision
           round(va.longitude::numeric, 4)::text  AS lon
    FROM venue_assets va
    LEFT JOIN venue_nws_points_pending p
      ON p.tevo_venue_id = va.tevo_venue_id
     AND p.fired_at > now() - interval '7 days'
    WHERE va.latitude IS NOT NULL AND va.longitude IS NOT NULL
      AND (va.ugc_county_code IS NULL OR va.ugc_forecast_zone IS NULL
           OR va.nws_points_fetched_at IS NULL
           OR va.nws_points_fetched_at < now() - interval '90 days')
      AND p.tevo_venue_id IS NULL
    ORDER BY va.nws_points_fetched_at NULLS FIRST, va.tevo_venue_id
    LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://api.weather.gov/points/' || r.lat || ',' || r.lon,
      headers := jsonb_build_object(
        'Accept',     'application/geo+json',
        'User-Agent', 'terminal-2-broker (julian@s4kent.com)'
      ),
      timeout_milliseconds := 15000
    ) INTO v_req_id;

    INSERT INTO venue_nws_points_pending(tevo_venue_id, request_id)
    VALUES (r.tevo_venue_id, v_req_id);

    v_count := v_count + 1;
    PERFORM pg_sleep(0.25);  -- ~4 req/s; NWS is permissive but be polite
  END LOOP;
  RETURN v_count;
END $$;

-- ============================================================================
-- (9) /points/ response handler — populates venue_assets UGC cols
-- ============================================================================

CREATE OR REPLACE FUNCTION nws_points_process()
RETURNS TABLE(processed int, venues_updated int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_body jsonb; v_props jsonb;
  v_processed int := 0; v_updated int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.tevo_venue_id, h.content, h.status_code
    FROM venue_nws_points_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;

      v_props := v_body -> 'properties';
      IF v_props IS NOT NULL THEN
        UPDATE venue_assets SET
          ugc_county_code       = ugc_from_url(v_props->>'county'),
          ugc_forecast_zone     = ugc_from_url(v_props->>'forecastZone'),
          ugc_fire_weather_zone = ugc_from_url(v_props->>'fireWeatherZone'),
          nws_grid_id           = v_props->>'gridId',
          nws_grid_x            = NULLIF(v_props->>'gridX','')::int,
          nws_grid_y            = NULLIF(v_props->>'gridY','')::int,
          nws_radar_station     = v_props->>'radarStation',
          nws_time_zone         = v_props->>'timeZone',
          nws_points_fetched_at = now()
        WHERE tevo_venue_id = r.tevo_venue_id;
        IF FOUND THEN v_updated := v_updated + 1; END IF;
      END IF;
    END IF;
    UPDATE venue_nws_points_pending
       SET resolved_at = now(), http_status = r.status_code
     WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_updated;
END $$;

-- ============================================================================
-- (10) /alerts/active?area=ST sweep — queue
-- ============================================================================

CREATE OR REPLACE FUNCTION nws_alerts_queue(p_states text[] DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_states text[] := COALESCE(p_states, ARRAY[
    'AL','AK','AZ','AR','CA','CO','CT','DC','DE','FL','GA','HI','ID','IL','IN','IA',
    'KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM',
    'NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA',
    'WV','WI','WY'
  ]);
  st text; v_req_id bigint; v_count int := 0;
BEGIN
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
    PERFORM pg_sleep(0.2);  -- ~5 req/s
  END LOOP;
  RETURN v_count;
END $$;

-- ============================================================================
-- (11) /alerts/active response handler — upserts alerts + zones + references
-- ============================================================================

CREATE OR REPLACE FUNCTION nws_alerts_process()
RETURNS TABLE(processed int, alerts_upserted int, zones_upserted int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_body jsonb; feat jsonb; props jsonb; params jsonb;
  v_id text; v_alert_count int := 0; v_zone_count int := 0; v_processed int := 0;
  ugc text; ref jsonb;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.state_code, h.content, h.status_code
    FROM nws_alert_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;

      IF v_body IS NOT NULL THEN
        FOR feat IN SELECT jsonb_array_elements(v_body -> 'features')
        LOOP
          props  := feat -> 'properties';
          params := COALESCE(props -> 'parameters', '{}'::jsonb);
          v_id   := props ->> 'id';

          INSERT INTO nws_alerts(
            id, alert_url,
            event, event_code_nws, event_code_same, category, status, message_type, scope, alert_code, language,
            severity, urgency, certainty, response_action, impact_tier,
            sent_at, effective_at, onset_at, expires_at, ends_at,
            area_desc, fips_codes, affected_zones_urls,
            sender, sender_name, web_url,
            headline, description, instruction, note,
            max_wind_gust_mph, max_hail_size_in,
            wind_threat, hail_threat, thunderstorm_damage_threat, waterspout_detection,
            event_motion_description, vtec, awips_identifier, wmo_identifier,
            nws_headline_text, block_channels, eas_org, expired_references,
            raw_parameters, raw_jsonb, last_seen_at
          ) VALUES (
            v_id, props ->> '@id',
            props ->> 'event',
            (props -> 'eventCode' -> 'NationalWeatherService' ->> 0),
            (props -> 'eventCode' -> 'SAME' ->> 0),
            props ->> 'category', props ->> 'status', props ->> 'messageType',
            props ->> 'scope', props ->> 'code', props ->> 'language',
            props ->> 'severity', props ->> 'urgency', props ->> 'certainty',
            props ->> 'response',
            compute_nws_impact_tier(props ->> 'event'),
            (props ->> 'sent')::timestamptz,
            NULLIF(props ->> 'effective','')::timestamptz,
            NULLIF(props ->> 'onset','')::timestamptz,
            NULLIF(props ->> 'expires','')::timestamptz,
            NULLIF(props ->> 'ends','')::timestamptz,
            props ->> 'areaDesc',
            ARRAY(SELECT jsonb_array_elements_text(COALESCE(props -> 'geocode' -> 'SAME','[]'::jsonb))),
            ARRAY(SELECT jsonb_array_elements_text(COALESCE(props -> 'affectedZones','[]'::jsonb))),
            props ->> 'sender', props ->> 'senderName', props ->> 'web',
            props ->> 'headline', props ->> 'description',
            props ->> 'instruction', props ->> 'note',
            -- "60 MPH" → 60
            NULLIF(regexp_replace(COALESCE(params -> 'maxWindGust' ->> 0,''), '[^0-9.]', '', 'g'),'')::numeric,
            -- "1.50" → 1.50
            NULLIF(COALESCE(params -> 'maxHailSize' ->> 0,''),'')::numeric,
            params -> 'windThreat' ->> 0,
            params -> 'hailThreat' ->> 0,
            params -> 'thunderstormDamageThreat' ->> 0,
            params -> 'waterspoutDetection' ->> 0,
            params -> 'eventMotionDescription' ->> 0,
            params -> 'VTEC' ->> 0,
            params -> 'AWIPSidentifier' ->> 0,
            params -> 'WMOidentifier' ->> 0,
            params -> 'NWSheadline' ->> 0,
            ARRAY(SELECT jsonb_array_elements_text(COALESCE(params -> 'BLOCKCHANNEL','[]'::jsonb))),
            params -> 'EAS-ORG' ->> 0,
            ARRAY(SELECT jsonb_array_elements_text(COALESCE(params -> 'expiredReferences','[]'::jsonb))),
            params, props,
            now()
          )
          ON CONFLICT (id) DO UPDATE SET
            -- alert was re-seen in sweep; refresh fields that may have changed
            message_type   = EXCLUDED.message_type,
            severity       = EXCLUDED.severity,
            urgency        = EXCLUDED.urgency,
            certainty      = EXCLUDED.certainty,
            expires_at     = EXCLUDED.expires_at,
            ends_at        = EXCLUDED.ends_at,
            headline       = EXCLUDED.headline,
            description    = EXCLUDED.description,
            raw_parameters = EXCLUDED.raw_parameters,
            raw_jsonb      = EXCLUDED.raw_jsonb,
            last_seen_at   = now();
          v_alert_count := v_alert_count + 1;

          -- Explode geocode.UGC[]
          FOR ugc IN
            SELECT jsonb_array_elements_text(COALESCE(props -> 'geocode' -> 'UGC','[]'::jsonb))
          LOOP
            INSERT INTO nws_alert_zones(alert_id, ugc_code, ugc_kind, ugc_state)
            VALUES (v_id, ugc, ugc_kind(ugc), ugc_state(ugc))
            ON CONFLICT (alert_id, ugc_code) DO NOTHING;
            v_zone_count := v_zone_count + 1;
          END LOOP;

          -- Explode references[]
          FOR ref IN
            SELECT jsonb_array_elements(COALESCE(props -> 'references','[]'::jsonb))
          LOOP
            INSERT INTO nws_alert_references(alert_id, references_id, sender, sent_at)
            VALUES (
              v_id,
              ref ->> 'identifier',
              ref ->> 'sender',
              NULLIF(ref ->> 'sent','')::timestamptz
            )
            ON CONFLICT (alert_id, references_id) DO NOTHING;
          END LOOP;
        END LOOP;
      END IF;
    END IF;
    UPDATE nws_alert_pending
       SET resolved_at = now(),
           http_status = r.status_code,
           alerts_count = jsonb_array_length(COALESCE(v_body -> 'features','[]'::jsonb))
     WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_alert_count, v_zone_count;
END $$;

-- ============================================================================
-- (12) v_event_active_weather_alerts — clean per-event listing
-- ============================================================================

CREATE OR REPLACE VIEW v_event_active_weather_alerts AS
SELECT DISTINCT
  e.id AS tevo_event_id,
  e.name AS event_name,
  e.occurs_at_local,
  va.tevo_venue_id,
  a.id AS alert_id,
  a.event,
  a.severity,
  a.urgency,
  a.certainty,
  a.impact_tier,
  a.effective_at,
  a.expires_at,
  a.headline,
  a.instruction,
  a.area_desc,
  a.sender_name,
  a.max_wind_gust_mph,
  a.max_hail_size_in,
  z.ugc_code,
  z.ugc_kind
FROM events e
JOIN venue_assets va ON va.tevo_venue_id = e.venue_id
JOIN nws_alert_zones z
  ON z.ugc_code = va.ugc_county_code
  OR z.ugc_code = va.ugc_forecast_zone
JOIN nws_alerts a ON a.id = z.alert_id
WHERE e.occurs_at_local::timestamptz BETWEEN a.effective_at AND COALESCE(a.expires_at, a.ends_at, a.effective_at + interval '6 hours')
  AND a.status = 'Actual'
  AND e.occurs_at_local::timestamptz > now() - interval '1 day';

COMMENT ON VIEW v_event_active_weather_alerts IS
  'Per-event currently-active NWS alerts. Joins on either ugc_county_code OR '
  'ugc_forecast_zone since alerts use one or the other. Filters out test alerts. '
  'Limited to events from yesterday forward to keep cardinality manageable.';

-- ============================================================================
-- (13) Extend v_event_weather_with_fallback with a weather_alerts jsonb summary
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
  ((e.occurs_at_local)::timestamp with time zone)::date - CURRENT_DATE AS days_to_event,
  CASE
    WHEN fcst.temp_f IS NOT NULL AND va.is_indoor THEN 'forecast_indoor'
    WHEN fcst.temp_f IS NOT NULL                  THEN 'forecast_outdoor'
    WHEN climo.avg_temp_f IS NOT NULL AND va.is_indoor THEN 'climatology_indoor'
    WHEN climo.avg_temp_f IS NOT NULL                  THEN 'climatology_outdoor'
    ELSE 'none'
  END AS weather_kind,
  fcst.temp_f      AS fcst_temp_f,
  fcst.precip_in   AS fcst_precip_in,
  fcst.precip_pct  AS fcst_precip_pct,
  fcst.wind_mph    AS fcst_wind_mph,
  fcst.gust_mph    AS fcst_gust_mph,
  fcst.weather_summary AS fcst_summary,
  climo.avg_temp_f      AS climo_avg_temp_f,
  climo.stddev_temp_f   AS climo_stddev_temp_f,
  climo.avg_precip_in   AS climo_avg_precip_in,
  climo.climo_precip_pct,
  climo.avg_wind_mph    AS climo_avg_wind_mph,
  climo.sample_size_years,
  wmo_to_summary(climo.modal_wmo_code) AS climo_modal_summary,
  COALESCE(fcst.temp_f, climo.avg_temp_f)        AS temp_f,
  COALESCE(fcst.precip_in, climo.avg_precip_in)  AS precip_in,
  COALESCE(fcst.precip_pct, climo.climo_precip_pct::int) AS precip_pct,
  COALESCE(fcst.wind_mph, climo.avg_wind_mph)    AS wind_mph,
  COALESCE(fcst.weather_summary, wmo_to_summary(climo.modal_wmo_code)) AS weather_summary,
  -- NEW: NWS active alerts overlapping this event's venue at event time
  (SELECT json_agg(json_build_object(
            'alert_id',   wa.alert_id,
            'event',      wa.event,
            'severity',   wa.severity,
            'urgency',    wa.urgency,
            'impact_tier',wa.impact_tier,
            'expires_at', wa.expires_at,
            'headline',   wa.headline,
            'instruction',wa.instruction)
          ORDER BY
            CASE wa.severity
              WHEN 'Extreme' THEN 0 WHEN 'Severe' THEN 1
              WHEN 'Moderate' THEN 2 WHEN 'Minor' THEN 3 ELSE 4 END,
            wa.expires_at)
   FROM v_event_active_weather_alerts wa
   WHERE wa.tevo_event_id = e.id) AS weather_alerts
FROM events e
LEFT JOIN venue_assets va ON va.tevo_venue_id = e.venue_id
LEFT JOIN LATERAL (
  SELECT w.temp_f, w.precip_in, w.precip_pct, w.wind_mph, w.gust_mph, w.weather_summary
  FROM weather_observations w
  WHERE w.tevo_venue_id = e.venue_id
    AND w.is_forecast
    AND w.observed_at >= e.occurs_at_local::timestamptz - interval '30 minutes'
    AND w.observed_at <= e.occurs_at_local::timestamptz + interval '30 minutes'
  ORDER BY abs(EXTRACT(epoch FROM (w.observed_at - e.occurs_at_local::timestamptz)))
  LIMIT 1
) fcst ON true
LEFT JOIN v_venue_climatology climo
  ON  climo.tevo_venue_id = e.venue_id
  AND climo.month       = EXTRACT(month FROM e.occurs_at_local::timestamptz)::int
  AND climo.day_of_month = EXTRACT(day  FROM e.occurs_at_local::timestamptz)::int
  AND climo.hour_of_day = EXTRACT(hour FROM e.occurs_at_local::timestamptz)::int;

COMMENT ON VIEW v_event_weather_with_fallback IS
  'Numerical weather (forecast→climatology fallback) PLUS categorical NWS alerts '
  'in one row per event. weather_alerts is a json array sorted by severity desc; '
  'NULL when no active alert intersects the venue at event time.';

-- ============================================================================
-- (14) Extend get_event_context() with weather_alerts key
-- ============================================================================

CREATE OR REPLACE FUNCTION get_event_context(p_event_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_event jsonb; v_pricing jsonb; v_espn jsonb; v_performer jsonb;
  v_weather jsonb; v_competitors jsonb; v_orders jsonb;
  v_odds jsonb; v_reddit jsonb; v_news jsonb; v_x jsonb; v_rivalry jsonb;
  v_calendar jsonb; v_alerts jsonb;
BEGIN
  SELECT to_jsonb(e) - 'performer_ids' INTO v_event FROM events e WHERE id = p_event_id;
  IF v_event IS NULL THEN
    RETURN jsonb_build_object('error','event_not_found','tevo_event_id',p_event_id);
  END IF;
  SELECT to_jsonb(ef) INTO v_pricing FROM v_event_full_v2 ef WHERE ef.tevo_event_id = p_event_id;
  SELECT jsonb_build_object(
    'espn_event_id', x.espn_event_id,
    'latest_state',  (SELECT state FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1),
    'latest_status', (SELECT status_short FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1),
    'latest_score',  (SELECT home_score::text || '-' || away_score::text FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1)
  ) INTO v_espn FROM event_xref x WHERE x.tevo_event_id = p_event_id LIMIT 1;
  SELECT jsonb_build_object(
    'tevo_performer_id', pw.tevo_performer_id, 'wiki_title', pw.wiki_title,
    'wiki_url', pw.wiki_url, 'description', pw.description,
    'extract', pw.extract, 'image_url', pw.image_url
  ) INTO v_performer FROM performer_wikipedia pw
  JOIN events e ON e.primary_performer_id = pw.tevo_performer_id
  WHERE e.id = p_event_id AND NOT pw.is_rejected LIMIT 1;
  SELECT to_jsonb(w) INTO v_weather FROM v_event_weather_with_fallback w WHERE w.tevo_event_id = p_event_id;
  SELECT competitors INTO v_competitors FROM event_competitors_snapshot WHERE tevo_event_id = p_event_id;
  SELECT to_jsonb(o) INTO v_orders FROM our_orders_by_event o WHERE o.tevo_event_id = p_event_id;
  SELECT to_jsonb(bo) INTO v_odds FROM v_event_betting_odds_latest bo WHERE bo.tevo_event_id = p_event_id;
  SELECT to_jsonb(rp) INTO v_reddit FROM v_performer_reddit_pulse rp
    JOIN events e ON e.primary_performer_id = rp.tevo_performer_id WHERE e.id = p_event_id;

  SELECT jsonb_agg(jsonb_build_object(
           'title', vn.title, 'subreddit', vn.subreddit,
           'created_utc', vn.created_utc, 'url', vn.url,
           'matched', vn.keyword_match->'hits',
           'categories', vn.keyword_match->'categories'
         ) ORDER BY vn.created_utc DESC) INTO v_news
  FROM (SELECT * FROM v_reddit_important_recent ORDER BY created_utc DESC LIMIT 10) vn
  JOIN events e ON e.primary_performer_id = vn.tevo_performer_id
  WHERE e.id = p_event_id;

  SELECT jsonb_build_object(
           'team_known', count(*) FILTER (WHERE account_type = 'team_official'),
           'beat_reporters_known', count(*) FILTER (WHERE account_type = 'beat_reporter'),
           'league_known', count(*) FILTER (WHERE account_type = 'league_official'),
           'insiders_total', (SELECT count(*) FROM important_x_accounts WHERE account_type = 'insider')
         ) INTO v_x
  FROM important_x_accounts xa
  JOIN events e ON e.primary_performer_name = xa.team_name WHERE e.id = p_event_id;

  SELECT jsonb_build_object(
           'rivalry_name', re.rivalry_name,
           'league', re.league,
           'is_branded', re.is_branded,
           'rivalry_intensity', re.rivalry_intensity,
           'wikipedia_url', re.wikipedia_url,
           'notes', re.notes
         ) INTO v_rivalry
  FROM v_rivalry_events re
  WHERE re.tevo_event_id = p_event_id LIMIT 1;

  SELECT jsonb_build_object(
           'country',                cc.inferred_country,
           'state',                  cc.inferred_state,
           'city',                   cc.inferred_city,
           'is_holiday',             cc.is_holiday,
           'within_holiday_window',  cc.within_holiday_window,
           'school_break_active',    cc.school_break_active,
           'holidays_today',         COALESCE(cc.holidays_today, '[]'::json),
           'holidays_nearby',        COALESCE(cc.holidays_nearby, '[]'::json),
           'school_breaks_active',   COALESCE(cc.school_breaks_active, '[]'::json)
         ) INTO v_calendar
  FROM v_event_calendar_context cc
  WHERE cc.tevo_event_id = p_event_id;

  -- NEW: NWS active alerts for this event's venue at event time
  SELECT jsonb_agg(jsonb_build_object(
           'alert_id',   wa.alert_id,
           'event',      wa.event,
           'severity',   wa.severity,
           'urgency',    wa.urgency,
           'certainty',  wa.certainty,
           'impact_tier',wa.impact_tier,
           'effective_at', wa.effective_at,
           'expires_at', wa.expires_at,
           'headline',   wa.headline,
           'instruction',wa.instruction,
           'sender_name',wa.sender_name,
           'max_wind_gust_mph', wa.max_wind_gust_mph,
           'max_hail_size_in',  wa.max_hail_size_in)
         ORDER BY
           CASE wa.severity
             WHEN 'Extreme' THEN 0 WHEN 'Severe' THEN 1
             WHEN 'Moderate' THEN 2 WHEN 'Minor' THEN 3 ELSE 4 END) INTO v_alerts
  FROM v_event_active_weather_alerts wa
  WHERE wa.tevo_event_id = p_event_id;

  RETURN jsonb_build_object(
    'tevo_event_id', p_event_id, 'event', v_event,
    'pricing', COALESCE(v_pricing, '{}'::jsonb),
    'espn', COALESCE(v_espn, jsonb_build_object('present', false)),
    'odds', COALESCE(v_odds, jsonb_build_object('present', false)),
    'performer', COALESCE(v_performer, jsonb_build_object('present', false)),
    'weather', COALESCE(v_weather, jsonb_build_object('present', false)),
    'weather_alerts', COALESCE(v_alerts, '[]'::jsonb),
    'competitors', COALESCE(v_competitors, '[]'::jsonb),
    'reddit', COALESCE(v_reddit, jsonb_build_object('present', false)),
    'important_news', COALESCE(v_news, '[]'::jsonb),
    'x_accounts_known', COALESCE(v_x, jsonb_build_object('team_known', 0)),
    'rivalry', COALESCE(v_rivalry, jsonb_build_object('present', false)),
    'calendar', COALESCE(v_calendar, jsonb_build_object('present', false)),
    'our_orders', COALESCE(v_orders, jsonb_build_object('present', false)),
    'generated_at', now()
  );
END $$;

COMMENT ON FUNCTION get_event_context(bigint) IS
  'Single-row jsonb summary of every context dimension we have for one event. '
  'Now 16 keys including weather_alerts (NWS active warnings/watches/advisories). '
  'See QUERY_CATALOG.md for a full schema breakdown.';

-- ============================================================================
-- (15) Cron jobs
-- ============================================================================

-- Backfill /points/ for any venue missing UGC codes (or stale > 90 days)
SELECT cron.schedule(
  'nws_points_queue_daily',
  '15 4 * * *',
  $$ SELECT public.nws_points_queue(50); $$
);
SELECT cron.schedule(
  'nws_points_process_5min',
  '3-59/5 * * * *',
  $$ SELECT public.nws_points_process(); $$
);

-- State-sweep alerts every 10 min
SELECT cron.schedule(
  'nws_alerts_queue_10min',
  '*/10 * * * *',
  $$ SELECT public.nws_alerts_queue(); $$
);
SELECT cron.schedule(
  'nws_alerts_process_5min',
  '4-59/5 * * * *',
  $$ SELECT public.nws_alerts_process(); $$
);

COMMENT ON FUNCTION nws_alerts_queue(text[]) IS
  'Sweeps /alerts/active?area=ST for the given states (default = all 50). '
  'Cron-scheduled every 10 min. Polite stagger: 0.2s between requests.';
COMMENT ON FUNCTION nws_alerts_process() IS
  'Processes pending /alerts/active responses, upserting nws_alerts + '
  'exploding geocode.UGC[] into nws_alert_zones + references[] into '
  'nws_alert_references. Idempotent on alert id (URN).';
