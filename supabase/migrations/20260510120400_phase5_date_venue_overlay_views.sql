-- ============================================================================
-- Phase 5: date / venue / time overlay views.
--
-- Drop any pre-existing overlay view that has a different column set so the
-- CREATE OR REPLACE statements below don't trip over column drift.
DROP VIEW IF EXISTS v_event_context CASCADE;
DROP VIEW IF EXISTS v_event_weather CASCADE;
DROP VIEW IF EXISTS v_event_holidays CASCADE;
DROP VIEW IF EXISTS v_event_school_breaks CASCADE;
DROP VIEW IF EXISTS v_event_nws_alerts CASCADE;
DROP VIEW IF EXISTS v_event_reddit CASCADE;
DROP VIEW IF EXISTS v_event_major_calendar CASCADE;
DROP VIEW IF EXISTS v_event_sporting_rivalries CASCADE;
DROP VIEW IF EXISTS v_event_mlb_branded_series CASCADE;
DROP VIEW IF EXISTS v_event_espn_news CASCADE;
DROP VIEW IF EXISTS v_event_espn_injuries CASCADE;
DROP VIEW IF EXISTS v_event_base CASCADE;
--
-- These domains have no FK to events but join logically by:
--   * event date (events.occurs_at_local::timestamptz)
--   * event venue (events.venue_id → venue_assets.tevo_venue_id)
--   * primary performer (events.primary_performer_id)
--
-- We expose one canonical event-context view (v_event_context) that wires
-- every event to its location-keyed and date-keyed enrichment, and per-domain
-- overlay views that surface the join logic in isolation.
-- ============================================================================

-- Base view: every event with parsed date, venue location (city/state), and
-- the primary performer's ESPN team identity (when known). Foundation for the
-- overlays below.
CREATE OR REPLACE VIEW v_event_base AS
SELECT
  e.id                                AS tevo_event_id,
  e.name                              AS event_name,
  e.event_type,
  e.state                             AS event_state,
  e.venue_id                          AS tevo_venue_id,
  e.venue_name,
  e.primary_performer_id              AS tevo_performer_id,
  e.primary_performer_name,
  -- parsed date / time fields
  (e.occurs_at_local::timestamptz)            AS event_at_local,
  (e.occurs_at_local::timestamptz)::date      AS event_date,
  (e.occurs_at_local::timestamptz) AT TIME ZONE 'UTC'      AS event_at_utc,
  -- venue context (from venue_assets — best effort)
  va.city                             AS venue_city,
  va.state                            AS venue_state,
  va.country                          AS venue_country,
  va.is_indoor                        AS venue_is_indoor,
  va.latitude                         AS venue_lat,
  va.longitude                        AS venue_lon,
  va.ugc_county_code,
  va.ugc_forecast_zone,
  va.ugc_fire_weather_zone,
  va.nws_grid_id, va.nws_grid_x, va.nws_grid_y,
  va.nws_time_zone,
  -- performer context
  pet.espn_team_id, pet.espn_league
FROM events e
LEFT JOIN venue_assets va  ON va.tevo_venue_id   = e.venue_id
LEFT JOIN LATERAL (
  SELECT espn_team_id, espn_league
    FROM performer_espn_team_xref
   WHERE tevo_performer_id = e.primary_performer_id
   ORDER BY espn_league
   LIMIT 1) pet ON TRUE;

-- ----------------------------------------------------------------------------
-- v_event_holidays — events that fall on a holiday in the venue's locale.
-- Match priority: city > state > country (most-specific wins).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_holidays AS
SELECT
  b.tevo_event_id,
  b.event_date,
  b.venue_city,
  b.venue_state,
  b.venue_country,
  h.id              AS holiday_id,
  h.holiday_name,
  h.holiday_type,
  h.attendance_impact,
  h.country         AS holiday_country,
  h.state           AS holiday_state,
  h.city            AS holiday_city,
  -- specificity: 3=city, 2=state, 1=country, 0=global
  CASE
    WHEN h.city  IS NOT NULL AND b.venue_city  = h.city  THEN 3
    WHEN h.state IS NOT NULL AND b.venue_state = h.state THEN 2
    WHEN h.country IS NOT NULL AND b.venue_country = h.country THEN 1
    ELSE 0
  END AS match_specificity
FROM v_event_base b
JOIN holidays h ON h.observed_date = b.event_date
WHERE  -- only emit holidays whose scope contains the venue
       (h.city    IS NULL OR b.venue_city    = h.city)
   AND (h.state   IS NULL OR b.venue_state   = h.state)
   AND (h.country IS NULL OR b.venue_country = h.country);

-- ----------------------------------------------------------------------------
-- v_event_school_breaks — events that occur during a school break in the venue's locale.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_school_breaks AS
SELECT
  b.tevo_event_id,
  b.event_date,
  b.venue_city,
  b.venue_state,
  b.venue_country,
  s.id              AS break_id,
  s.break_name,
  s.start_date,
  s.end_date,
  s.region_scope,
  s.country         AS break_country,
  s.state           AS break_state,
  s.city            AS break_city,
  s.district_name,
  CASE
    WHEN s.city  IS NOT NULL AND b.venue_city  = s.city  THEN 3
    WHEN s.state IS NOT NULL AND b.venue_state = s.state THEN 2
    WHEN s.country IS NOT NULL AND b.venue_country = s.country THEN 1
    ELSE 0
  END AS match_specificity
FROM v_event_base b
JOIN school_break_windows s
  ON b.event_date BETWEEN s.start_date AND s.end_date
WHERE (s.city    IS NULL OR b.venue_city    = s.city)
  AND (s.state   IS NULL OR b.venue_state   = s.state)
  AND (s.country IS NULL OR b.venue_country = s.country);

-- ----------------------------------------------------------------------------
-- v_event_weather — closest weather observation/forecast for the event venue
-- and event time. Uses ±12h window, prefers actuals over forecasts.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_weather AS
SELECT
  b.tevo_event_id,
  b.event_at_local,
  b.tevo_venue_id,
  w.id              AS weather_id,
  w.observed_at,
  w.is_forecast,
  w.source_key,
  w.temp_f,
  w.precip_in,
  w.precip_pct,
  w.wind_mph,
  w.gust_mph,
  w.humidity_pct,
  w.weather_summary,
  EXTRACT(EPOCH FROM (w.observed_at - b.event_at_local)) / 60.0 AS minutes_offset
FROM v_event_base b
JOIN LATERAL (
  SELECT *
    FROM weather_observations w
   WHERE w.tevo_venue_id = b.tevo_venue_id
     AND w.observed_at BETWEEN b.event_at_local - INTERVAL '12 hours'
                           AND b.event_at_local + INTERVAL '12 hours'
   ORDER BY w.is_forecast ASC,                            -- actuals first
            ABS(EXTRACT(EPOCH FROM (w.observed_at - b.event_at_local)))
   LIMIT 1) w ON TRUE;

-- ----------------------------------------------------------------------------
-- v_event_nws_alerts — active NWS alerts that overlap the event time and
-- whose UGC zone matches the venue's county / forecast / fire-weather zone.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_nws_alerts AS
SELECT
  b.tevo_event_id,
  b.event_at_local,
  b.tevo_venue_id,
  na.id             AS alert_id,
  na.event          AS alert_event,
  na.severity,
  na.urgency,
  na.certainty,
  na.headline,
  na.onset_at,
  na.expires_at,
  na.area_desc,
  naz.ugc_code,
  naz.ugc_kind,
  CASE
    WHEN naz.ugc_code = b.ugc_county_code        THEN 'county'
    WHEN naz.ugc_code = b.ugc_forecast_zone      THEN 'forecast_zone'
    WHEN naz.ugc_code = b.ugc_fire_weather_zone  THEN 'fire_weather_zone'
  END AS matched_zone_kind
FROM v_event_base b
JOIN nws_alert_zones naz
  ON naz.ugc_code IN (b.ugc_county_code, b.ugc_forecast_zone, b.ugc_fire_weather_zone)
JOIN nws_alerts na ON na.id = naz.alert_id
WHERE b.event_at_local BETWEEN COALESCE(na.onset_at, na.effective_at, na.sent_at)
                           AND COALESCE(na.ends_at, na.expires_at, na.sent_at + INTERVAL '24 hours');

-- ----------------------------------------------------------------------------
-- v_event_reddit — recent reddit posts about the event's primary performer
-- in the 30 days leading up to the event.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_reddit AS
SELECT
  b.tevo_event_id,
  b.event_at_local,
  b.tevo_performer_id,
  rp.reddit_post_id,
  rp.subreddit,
  rp.title,
  rp.score,
  rp.num_comments,
  rp.created_utc,
  rp.url
FROM v_event_base b
JOIN reddit_posts rp
  ON rp.tevo_performer_id = b.tevo_performer_id
WHERE rp.created_utc BETWEEN b.event_at_local - INTERVAL '30 days'
                         AND b.event_at_local + INTERVAL '7 days';

-- ----------------------------------------------------------------------------
-- v_event_major_calendar — events whose date falls within a major-event window
-- and whose venue / city matches the calendar entry.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_major_calendar AS
SELECT
  b.tevo_event_id,
  b.event_date,
  b.tevo_venue_id,
  b.venue_city,
  m.id              AS calendar_id,
  m.event_class,
  m.event_name      AS calendar_event_name,
  m.venue_name      AS calendar_venue_name,
  m.venue_city      AS calendar_venue_city,
  m.window_start,
  m.window_end,
  m.recurrence,
  m.tevo_venue_id   AS calendar_tevo_venue_id,
  CASE
    WHEN m.tevo_venue_id IS NOT NULL AND m.tevo_venue_id = b.tevo_venue_id THEN 'venue_id'
    WHEN m.venue_city    IS NOT NULL AND lower(m.venue_city) = lower(b.venue_city) THEN 'city'
    ELSE 'date_only'
  END AS match_kind
FROM v_event_base b
JOIN major_event_calendar m
  ON b.event_date BETWEEN m.window_start AND m.window_end
WHERE COALESCE(m.active, true) = true
  AND (
        m.tevo_venue_id IS NULL
     OR m.tevo_venue_id = b.tevo_venue_id
     OR (m.venue_city IS NOT NULL AND b.venue_city IS NOT NULL
         AND lower(m.venue_city) = lower(b.venue_city))
      );

-- ----------------------------------------------------------------------------
-- v_event_sporting_rivalries — events whose performer set contains both
-- team_a and team_b of a registered rivalry.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_sporting_rivalries AS
SELECT
  e.id              AS tevo_event_id,
  r.rivalry_name,
  r.league,
  r.team_a,
  r.team_b,
  r.team_a_performer_id,
  r.team_b_performer_id,
  r.is_branded,
  r.rivalry_intensity
FROM events e
JOIN sporting_rivalries r
  ON r.team_a_performer_id IS NOT NULL
 AND r.team_b_performer_id IS NOT NULL
 AND e.performer_ids @> ARRAY[r.team_a_performer_id, r.team_b_performer_id];

-- ----------------------------------------------------------------------------
-- v_event_mlb_branded_series — events whose name contains a branded series
-- name OR which match the team_a vs team_b matchup pattern.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_mlb_branded_series AS
SELECT
  e.id              AS tevo_event_id,
  e.name            AS event_name,
  m.branded_name,
  m.team_a,
  m.team_b,
  m.notes,
  CASE
    WHEN e.name ILIKE '%' || m.branded_name || '%' THEN 'branded_name_match'
    ELSE 'team_pair_match'
  END AS match_kind
FROM events e
JOIN mlb_branded_series m
  ON e.name ILIKE '%' || m.branded_name || '%'
  OR (e.name ILIKE '%' || m.team_a || '%' AND e.name ILIKE '%' || m.team_b || '%');

-- ----------------------------------------------------------------------------
-- v_event_espn_news — recent ESPN news for the event's team in the 14 days
-- before the event.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_espn_news AS
SELECT
  b.tevo_event_id,
  b.event_at_local,
  b.espn_team_id,
  b.espn_league,
  n.espn_article_id,
  n.headline,
  n.description,
  n.url,
  n.image_url,
  n.published_at,
  n.type
FROM v_event_base b
JOIN espn_news n
  ON n.espn_team_id = b.espn_team_id
 AND n.espn_league  = b.espn_league
WHERE n.published_at BETWEEN b.event_at_local - INTERVAL '14 days'
                         AND b.event_at_local;

-- ----------------------------------------------------------------------------
-- v_event_espn_injuries — latest injury baseline for the event's team.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_espn_injuries AS
SELECT
  b.tevo_event_id,
  b.event_at_local,
  b.espn_team_id,
  b.espn_league,
  i.athlete_id,
  i.athlete_name,
  i.position,
  i.status,
  i.injury_type,
  i.short_comment,
  i.return_date,
  i.captured_at
FROM v_event_base b
JOIN espn_injuries_snapshots i
  ON i.espn_team_id = b.espn_team_id
 AND i.espn_league  = b.espn_league
WHERE i.is_baseline = true
  AND i.captured_at <= b.event_at_local;

-- ----------------------------------------------------------------------------
-- v_event_context — single-row-per-event aggregate of all overlay signals.
-- Convenience join target: one row per event, json arrays per domain.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_event_context AS
SELECT
  b.tevo_event_id,
  b.event_name,
  b.event_at_local,
  b.event_date,
  b.tevo_venue_id,
  b.venue_name,
  b.venue_city,
  b.venue_state,
  b.tevo_performer_id,
  b.primary_performer_name,
  b.espn_team_id,
  b.espn_league,
  -- holidays
  (SELECT jsonb_agg(jsonb_build_object('name', h.holiday_name,
                                       'type', h.holiday_type,
                                       'specificity', h.match_specificity)
                    ORDER BY h.match_specificity DESC)
     FROM v_event_holidays h WHERE h.tevo_event_id = b.tevo_event_id) AS holidays,
  -- school breaks
  (SELECT jsonb_agg(jsonb_build_object('break_name', s.break_name,
                                       'specificity', s.match_specificity)
                    ORDER BY s.match_specificity DESC)
     FROM v_event_school_breaks s WHERE s.tevo_event_id = b.tevo_event_id) AS school_breaks,
  -- closest weather
  (SELECT to_jsonb(w.*) FROM v_event_weather w
    WHERE w.tevo_event_id = b.tevo_event_id LIMIT 1) AS weather,
  -- active NWS alerts
  (SELECT jsonb_agg(jsonb_build_object('alert_id', a.alert_id,
                                       'event', a.alert_event,
                                       'severity', a.severity,
                                       'matched_zone_kind', a.matched_zone_kind))
     FROM v_event_nws_alerts a WHERE a.tevo_event_id = b.tevo_event_id) AS nws_alerts,
  -- reddit
  (SELECT COUNT(*) FROM v_event_reddit r WHERE r.tevo_event_id = b.tevo_event_id) AS reddit_post_count,
  -- major calendar
  (SELECT jsonb_agg(jsonb_build_object('event_class', m.event_class,
                                       'event_name', m.calendar_event_name,
                                       'match_kind', m.match_kind))
     FROM v_event_major_calendar m WHERE m.tevo_event_id = b.tevo_event_id) AS major_calendar,
  -- rivalries
  (SELECT jsonb_agg(jsonb_build_object('rivalry_name', r.rivalry_name,
                                       'is_branded', r.is_branded,
                                       'intensity', r.rivalry_intensity))
     FROM v_event_sporting_rivalries r WHERE r.tevo_event_id = b.tevo_event_id) AS rivalries,
  -- MLB branded series
  (SELECT jsonb_agg(jsonb_build_object('branded_name', mb.branded_name,
                                       'match_kind', mb.match_kind))
     FROM v_event_mlb_branded_series mb WHERE mb.tevo_event_id = b.tevo_event_id) AS mlb_branded_series,
  -- ESPN news (count only — full join is heavy)
  (SELECT COUNT(*) FROM v_event_espn_news n WHERE n.tevo_event_id = b.tevo_event_id) AS espn_news_count,
  -- ESPN injuries
  (SELECT COUNT(*) FROM v_event_espn_injuries i WHERE i.tevo_event_id = b.tevo_event_id) AS espn_injury_count
FROM v_event_base b;

GRANT SELECT ON v_event_base, v_event_holidays, v_event_school_breaks,
                v_event_weather, v_event_nws_alerts, v_event_reddit,
                v_event_major_calendar, v_event_sporting_rivalries,
                v_event_mlb_branded_series, v_event_espn_news,
                v_event_espn_injuries, v_event_context
  TO authenticated, anon, service_role;
