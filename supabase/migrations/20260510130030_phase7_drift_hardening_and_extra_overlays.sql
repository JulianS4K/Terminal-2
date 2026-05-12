-- ============================================================================
-- Migration 20260510130030 — Phase 7: drift hardening + extra overlays
--
-- Lane:     canonical
-- Touches:  event_xref (TRUNCATE TRIGGER), seatgeek_event_xref (TRUNCATE TRIGGER),
--           seatdata_event_xref (TRUNCATE TRIGGER),
--           seatgeek_venue_xref (TRUNCATE TRIGGER), seatdata_venue_xref (TRUNCATE TRIGGER),
--           performer_external_ids (TRUNCATE TRIGGER), performer_espn_team_xref (TRUNCATE TRIGGER),
--           v_event_base, v_event_espn_state, v_event_espn_news,
--           v_event_espn_injuries, v_event_overlay_summary,
--           v_event_context (CREATE VIEW),
--           audit_cross_source_health() (CREATE OR REPLACE)
-- Pre-reqs: 20260510120500 (Phase 6)
--
-- 1. STATEMENT-level guards on per-source xref tables for TRUNCATE
--    (ROW triggers don't fire on TRUNCATE; without these, a truncate would
--    silently drift the canonical registry).
-- 2. Normalize venue country in v_event_base to ISO 2-letter codes so the
--    holiday / school-break overlays match (holidays use 'US'/'CA'/'MX';
--    venue_assets.country uses 'USA'/'Canada'/null).
-- 3. New overlays for ESPN game state, team standings, broker orders,
--    competitor metadata.
-- 4. Refresh v_event_overlay_summary and audit_cross_source_health() to
--    include the new overlays.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. TRUNCATE drift guards. After any TRUNCATE on a per-source xref, recompute
--    that source's slice of canonical_external_ids from scratch.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trg_truncate_resync__event_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM canonical_external_ids WHERE entity_kind='event' AND source_key='espn';
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, matched_at, meta)
  SELECT 'event', tevo_event_id, 'espn', espn_event_id, NULL,
         match_method, matched_at,
         jsonb_strip_nulls(jsonb_build_object(
           'espn_league', espn_league,
           'espn_slug',   espn_slug)) || COALESCE(meta, '{}'::jsonb)
    FROM event_xref;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS event_xref_truncate_resync ON event_xref;
CREATE TRIGGER event_xref_truncate_resync
  AFTER TRUNCATE ON event_xref
  FOR EACH STATEMENT EXECUTE FUNCTION trg_truncate_resync__event_xref();

CREATE OR REPLACE FUNCTION trg_truncate_resync__sg_event_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM canonical_external_ids WHERE entity_kind='event' AND source_key='sg_broker';
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, match_confidence, matched_at, meta)
  SELECT 'event', tevo_event_id, 'sg_broker', sg_event_id::text, sg_event_name,
         match_method, match_confidence, matched_at, COALESCE(meta, '{}'::jsonb)
    FROM seatgeek_event_xref;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS seatgeek_event_xref_truncate_resync ON seatgeek_event_xref;
CREATE TRIGGER seatgeek_event_xref_truncate_resync
  AFTER TRUNCATE ON seatgeek_event_xref
  FOR EACH STATEMENT EXECUTE FUNCTION trg_truncate_resync__sg_event_xref();

CREATE OR REPLACE FUNCTION trg_truncate_resync__sd_event_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM canonical_external_ids WHERE entity_kind='event' AND source_key='seatdata';
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, match_confidence, matched_at, meta)
  SELECT 'event', tevo_event_id, 'seatdata', sd_event_id::text, NULL,
         match_method, match_confidence, matched_at,
         jsonb_strip_nulls(jsonb_build_object(
           'sd_tm_event_id',  sd_tm_event_id,
           'sd_std_event_id', sd_std_event_id,
           'sd_std_venue_id', sd_std_venue_id)) || COALESCE(meta, '{}'::jsonb)
    FROM seatdata_event_xref;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS seatdata_event_xref_truncate_resync ON seatdata_event_xref;
CREATE TRIGGER seatdata_event_xref_truncate_resync
  AFTER TRUNCATE ON seatdata_event_xref
  FOR EACH STATEMENT EXECUTE FUNCTION trg_truncate_resync__sd_event_xref();

CREATE OR REPLACE FUNCTION trg_truncate_resync__sg_venue_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM canonical_external_ids WHERE entity_kind='venue' AND source_key='sg_broker';
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, match_confidence, matched_at, meta)
  SELECT 'venue', tevo_venue_id, 'sg_broker',
         md5(lower(sg_venue_name)), sg_venue_name,
         match_method, match_confidence, matched_at, COALESCE(meta, '{}'::jsonb)
    FROM seatgeek_venue_xref;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS seatgeek_venue_xref_truncate_resync ON seatgeek_venue_xref;
CREATE TRIGGER seatgeek_venue_xref_truncate_resync
  AFTER TRUNCATE ON seatgeek_venue_xref
  FOR EACH STATEMENT EXECUTE FUNCTION trg_truncate_resync__sg_venue_xref();

CREATE OR REPLACE FUNCTION trg_truncate_resync__sd_venue_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM canonical_external_ids WHERE entity_kind='venue' AND source_key='seatdata';
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, match_confidence, matched_at, meta)
  SELECT 'venue', tevo_venue_id, 'seatdata',
         COALESCE(sd_std_venue_id::text, md5(lower(sd_venue_name))),
         sd_venue_name, match_method, match_confidence, matched_at,
         jsonb_strip_nulls(jsonb_build_object(
           'sd_venue_slug',  sd_venue_slug,
           'sd_venue_city',  sd_venue_city,
           'sd_venue_state', sd_venue_state)) || COALESCE(meta, '{}'::jsonb)
    FROM seatdata_venue_xref;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS seatdata_venue_xref_truncate_resync ON seatdata_venue_xref;
CREATE TRIGGER seatdata_venue_xref_truncate_resync
  AFTER TRUNCATE ON seatdata_venue_xref
  FOR EACH STATEMENT EXECUTE FUNCTION trg_truncate_resync__sd_venue_xref();

CREATE OR REPLACE FUNCTION trg_truncate_resync__pei()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM canonical_external_ids WHERE entity_kind='performer' AND source_key NOT IN ('espn_team');
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      matched_at, meta)
  SELECT 'performer', performer_id, source, external_id, external_name,
         set_at,
         jsonb_strip_nulls(jsonb_build_object('league', league)) || COALESCE(meta, '{}'::jsonb)
    FROM performer_external_ids;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS performer_external_ids_truncate_resync ON performer_external_ids;
CREATE TRIGGER performer_external_ids_truncate_resync
  AFTER TRUNCATE ON performer_external_ids
  FOR EACH STATEMENT EXECUTE FUNCTION trg_truncate_resync__pei();

CREATE OR REPLACE FUNCTION trg_truncate_resync__perf_espn_team_xref()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM canonical_external_ids WHERE entity_kind='performer' AND source_key='espn_team';
  INSERT INTO canonical_external_ids (
      entity_kind, tevo_id, source_key, external_id, external_name,
      match_method, matched_at, meta)
  SELECT 'performer', tevo_performer_id, 'espn_team',
         (array_agg(espn_team_id ORDER BY espn_league))[1], NULL,
         (array_agg(match_method ORDER BY espn_league))[1], NOW(),
         jsonb_build_object(
           'leagues',  array_agg(DISTINCT espn_league),
           'team_ids', jsonb_object_agg(espn_league, espn_team_id))
    FROM performer_espn_team_xref
   GROUP BY tevo_performer_id;
  RETURN NULL;
END;
$$;
DROP TRIGGER IF EXISTS performer_espn_team_xref_truncate_resync ON performer_espn_team_xref;
CREATE TRIGGER performer_espn_team_xref_truncate_resync
  AFTER TRUNCATE ON performer_espn_team_xref
  FOR EACH STATEMENT EXECUTE FUNCTION trg_truncate_resync__perf_espn_team_xref();

-- ----------------------------------------------------------------------------
-- 2. Normalize venue_country in v_event_base, and add ESPN game-state +
--    team-standings columns now that we know they exist.
-- ----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_event_overlay_summary CASCADE;
DROP VIEW IF EXISTS v_event_context CASCADE;
DROP VIEW IF EXISTS v_event_espn_news CASCADE;
DROP VIEW IF EXISTS v_event_espn_injuries CASCADE;
DROP VIEW IF EXISTS v_event_holidays CASCADE;
DROP VIEW IF EXISTS v_event_school_breaks CASCADE;
DROP VIEW IF EXISTS v_event_weather CASCADE;
DROP VIEW IF EXISTS v_event_nws_alerts CASCADE;
DROP VIEW IF EXISTS v_event_reddit CASCADE;
DROP VIEW IF EXISTS v_event_major_calendar CASCADE;
DROP VIEW IF EXISTS v_event_sporting_rivalries CASCADE;
DROP VIEW IF EXISTS v_event_mlb_branded_series CASCADE;
DROP VIEW IF EXISTS v_event_base CASCADE;

CREATE VIEW v_event_base AS
SELECT
  e.id                                AS tevo_event_id,
  e.name                              AS event_name,
  e.event_type,
  e.state                             AS event_state,
  e.venue_id                          AS tevo_venue_id,
  e.venue_name,
  e.primary_performer_id              AS tevo_performer_id,
  e.primary_performer_name,
  (e.occurs_at_local::timestamptz)            AS event_at_local,
  (e.occurs_at_local::timestamptz)::date      AS event_date,
  (e.occurs_at_local::timestamptz) AT TIME ZONE 'UTC'      AS event_at_utc,
  va.city                             AS venue_city,
  va.state                            AS venue_state,
  -- ISO 2-letter normalization so date-domain joins work consistently
  CASE upper(va.country)
    WHEN 'USA'    THEN 'US'
    WHEN 'CANADA' THEN 'CA'
    WHEN 'MEXICO' THEN 'MX'
    ELSE upper(va.country)
  END                                 AS venue_country,
  va.is_indoor                        AS venue_is_indoor,
  va.latitude                         AS venue_lat,
  va.longitude                        AS venue_lon,
  va.ugc_county_code,
  va.ugc_forecast_zone,
  va.ugc_fire_weather_zone,
  va.nws_grid_id, va.nws_grid_x, va.nws_grid_y,
  va.nws_time_zone,
  pet.espn_team_id, pet.espn_league
FROM events e
LEFT JOIN venue_assets va  ON va.tevo_venue_id   = e.venue_id
LEFT JOIN LATERAL (
  SELECT espn_team_id, espn_league
    FROM performer_espn_team_xref
   WHERE tevo_performer_id = e.primary_performer_id
   ORDER BY espn_league
   LIMIT 1) pet ON TRUE;

-- Re-create overlays that depend on v_event_base
CREATE VIEW v_event_holidays AS
SELECT
  b.tevo_event_id, b.event_date, b.venue_city, b.venue_state, b.venue_country,
  h.id AS holiday_id, h.holiday_name, h.holiday_type, h.attendance_impact,
  h.country AS holiday_country, h.state AS holiday_state, h.city AS holiday_city,
  CASE
    WHEN h.city  IS NOT NULL AND b.venue_city  = h.city  THEN 3
    WHEN h.state IS NOT NULL AND b.venue_state = h.state THEN 2
    WHEN h.country IS NOT NULL AND b.venue_country = h.country THEN 1
    ELSE 0
  END AS match_specificity
FROM v_event_base b
JOIN holidays h ON h.observed_date = b.event_date
WHERE (h.city    IS NULL OR b.venue_city    = h.city)
  AND (h.state   IS NULL OR b.venue_state   = h.state)
  AND (h.country IS NULL OR b.venue_country = h.country);

CREATE VIEW v_event_school_breaks AS
SELECT
  b.tevo_event_id, b.event_date, b.venue_city, b.venue_state, b.venue_country,
  s.id AS break_id, s.break_name, s.start_date, s.end_date, s.region_scope,
  s.country AS break_country, s.state AS break_state, s.city AS break_city,
  s.district_name,
  CASE
    WHEN s.city  IS NOT NULL AND b.venue_city  = s.city  THEN 3
    WHEN s.state IS NOT NULL AND b.venue_state = s.state THEN 2
    WHEN s.country IS NOT NULL AND b.venue_country = s.country THEN 1
    ELSE 0
  END AS match_specificity
FROM v_event_base b
JOIN school_break_windows s ON b.event_date BETWEEN s.start_date AND s.end_date
WHERE (s.city    IS NULL OR b.venue_city    = s.city)
  AND (s.state   IS NULL OR b.venue_state   = s.state)
  AND (s.country IS NULL OR b.venue_country = s.country);

CREATE VIEW v_event_weather AS
SELECT
  b.tevo_event_id, b.event_at_local, b.tevo_venue_id,
  w.id AS weather_id, w.observed_at, w.is_forecast, w.source_key,
  w.temp_f, w.precip_in, w.precip_pct, w.wind_mph, w.gust_mph,
  w.humidity_pct, w.weather_summary,
  EXTRACT(EPOCH FROM (w.observed_at - b.event_at_local)) / 60.0 AS minutes_offset
FROM v_event_base b
JOIN LATERAL (
  SELECT *
    FROM weather_observations w
   WHERE w.tevo_venue_id = b.tevo_venue_id
     AND w.observed_at BETWEEN b.event_at_local - INTERVAL '12 hours'
                           AND b.event_at_local + INTERVAL '12 hours'
   ORDER BY w.is_forecast ASC,
            ABS(EXTRACT(EPOCH FROM (w.observed_at - b.event_at_local)))
   LIMIT 1) w ON TRUE;

CREATE VIEW v_event_nws_alerts AS
SELECT
  b.tevo_event_id, b.event_at_local, b.tevo_venue_id,
  na.id AS alert_id, na.event AS alert_event, na.severity, na.urgency,
  na.certainty, na.headline, na.onset_at, na.expires_at, na.area_desc,
  naz.ugc_code, naz.ugc_kind,
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

CREATE VIEW v_event_reddit AS
SELECT
  b.tevo_event_id, b.event_at_local, b.tevo_performer_id,
  rp.reddit_post_id, rp.subreddit, rp.title, rp.score, rp.num_comments,
  rp.created_utc, rp.url
FROM v_event_base b
JOIN reddit_posts rp ON rp.tevo_performer_id = b.tevo_performer_id
WHERE rp.created_utc BETWEEN b.event_at_local - INTERVAL '30 days'
                         AND b.event_at_local + INTERVAL '7 days';

CREATE VIEW v_event_major_calendar AS
SELECT
  b.tevo_event_id, b.event_date, b.tevo_venue_id, b.venue_city,
  m.id AS calendar_id, m.event_class, m.event_name AS calendar_event_name,
  m.venue_name AS calendar_venue_name, m.venue_city AS calendar_venue_city,
  m.window_start, m.window_end, m.recurrence,
  m.tevo_venue_id AS calendar_tevo_venue_id,
  CASE
    WHEN m.tevo_venue_id IS NOT NULL AND m.tevo_venue_id = b.tevo_venue_id THEN 'venue_id'
    WHEN m.venue_city    IS NOT NULL AND lower(m.venue_city) = lower(b.venue_city) THEN 'city'
    ELSE 'date_only'
  END AS match_kind
FROM v_event_base b
JOIN major_event_calendar m ON b.event_date BETWEEN m.window_start AND m.window_end
WHERE COALESCE(m.active, true) = true
  AND (m.tevo_venue_id IS NULL
       OR m.tevo_venue_id = b.tevo_venue_id
       OR (m.venue_city IS NOT NULL AND b.venue_city IS NOT NULL
           AND lower(m.venue_city) = lower(b.venue_city)));

CREATE VIEW v_event_sporting_rivalries AS
SELECT
  e.id AS tevo_event_id,
  r.rivalry_name, r.league, r.team_a, r.team_b,
  r.team_a_performer_id, r.team_b_performer_id,
  r.is_branded, r.rivalry_intensity
FROM events e
JOIN sporting_rivalries r
  ON r.team_a_performer_id IS NOT NULL
 AND r.team_b_performer_id IS NOT NULL
 AND e.performer_ids @> ARRAY[r.team_a_performer_id, r.team_b_performer_id];

CREATE VIEW v_event_mlb_branded_series AS
SELECT
  e.id AS tevo_event_id, e.name AS event_name,
  m.branded_name, m.team_a, m.team_b, m.notes,
  CASE
    WHEN e.name ILIKE '%' || m.branded_name || '%' THEN 'branded_name_match'
    ELSE 'team_pair_match'
  END AS match_kind
FROM events e
JOIN mlb_branded_series m
  ON e.name ILIKE '%' || m.branded_name || '%'
  OR (e.name ILIKE '%' || m.team_a || '%' AND e.name ILIKE '%' || m.team_b || '%');

CREATE VIEW v_event_espn_news AS
SELECT
  b.tevo_event_id, b.event_at_local, b.espn_team_id, b.espn_league,
  n.espn_article_id, n.headline, n.description, n.url, n.image_url,
  n.published_at, n.type
FROM v_event_base b
JOIN espn_news n
  ON n.espn_team_id = b.espn_team_id
 AND n.espn_league  = b.espn_league
WHERE n.published_at BETWEEN b.event_at_local - INTERVAL '14 days'
                         AND b.event_at_local;

CREATE VIEW v_event_espn_injuries AS
SELECT
  b.tevo_event_id, b.event_at_local, b.espn_team_id, b.espn_league,
  i.athlete_id, i.athlete_name, i.position, i.status, i.injury_type,
  i.short_comment, i.return_date, i.captured_at
FROM v_event_base b
JOIN espn_injuries_snapshots i
  ON i.espn_team_id = b.espn_team_id
 AND i.espn_league  = b.espn_league
WHERE i.is_baseline = true
  AND i.captured_at <= b.event_at_local;

-- ----------------------------------------------------------------------------
-- 3. New overlays
-- ----------------------------------------------------------------------------

-- v_event_espn_state — latest ESPN game snapshot for events linked via event_xref
DROP VIEW IF EXISTS v_event_espn_state CASCADE;
CREATE VIEW v_event_espn_state AS
SELECT
  ex.tevo_event_id,
  s.espn_event_id, s.espn_league,
  s.captured_at,
  s.state, s.status_short,
  s.home_team_id, s.away_team_id,
  s.home_score,   s.away_score,
  s.spread, s.over_under, s.home_ml, s.away_ml,
  s.home_win_prob, s.attendance,
  s.is_baseline
FROM event_xref ex
JOIN LATERAL (
  SELECT *
    FROM espn_event_snapshots ess
   WHERE ess.espn_event_id = ex.espn_event_id
     AND ess.espn_league   = ex.espn_league
   ORDER BY ess.captured_at DESC
   LIMIT 1) s ON TRUE;

-- v_event_team_standings — current standings for the event's primary performer
DROP VIEW IF EXISTS v_event_team_standings CASCADE;
CREATE VIEW v_event_team_standings AS
SELECT
  b.tevo_event_id, b.event_at_local,
  b.espn_team_id, b.espn_league,
  ts.captured_at,
  ts.wins, ts.losses, ts.ties, ts.win_pct, ts.games_back,
  ts.playoff_seed, ts.conference_rank, ts.division_rank,
  ts.record_summary, ts.standing_summary, ts.streak,
  ts.is_baseline
FROM v_event_base b
JOIN LATERAL (
  SELECT *
    FROM espn_team_snapshots t
   WHERE t.espn_team_id = b.espn_team_id
     AND t.espn_league  = b.espn_league
     AND t.captured_at <= b.event_at_local
   ORDER BY t.captured_at DESC
   LIMIT 1) ts ON TRUE;

-- v_event_evo_orders — broker orders (EVO) per Tevo event
DROP VIEW IF EXISTS v_event_evo_orders CASCADE;
CREATE VIEW v_event_evo_orders AS
SELECT
  oi.event_id           AS tevo_event_id,
  o.evo_order_id,
  o.state               AS order_state,
  o.type                AS order_type,
  o.total, o.subtotal, o.tax, o.shipping, o.service_fee,
  o.refunded, o.balance,
  o.fraud_check_status,
  o.evo_created_at,
  o.evo_updated_at,
  o.client_id, o.client_name,
  o.seller_brokerage_id, o.buyer_brokerage_id
FROM evo_orders o
JOIN evo_order_items oi ON oi.evo_order_id = o.evo_order_id
WHERE oi.event_id IS NOT NULL;

-- v_event_competitors — competitor metadata snapshot per event
DROP VIEW IF EXISTS v_event_competitors CASCADE;
CREATE VIEW v_event_competitors AS
SELECT
  cs.tevo_event_id,
  cs.competitors_count,
  cs.refreshed_at,
  cs.competitors
FROM event_competitors_snapshot cs;

-- ----------------------------------------------------------------------------
-- 4. Refresh v_event_overlay_summary + audit RPC
-- ----------------------------------------------------------------------------

DROP VIEW IF EXISTS v_event_overlay_summary CASCADE;
CREATE VIEW v_event_overlay_summary AS
SELECT
  b.tevo_event_id, b.event_date, b.tevo_venue_id, b.tevo_performer_id,
  EXISTS (SELECT 1 FROM v_event_holidays            WHERE tevo_event_id = b.tevo_event_id) AS has_holiday,
  EXISTS (SELECT 1 FROM v_event_school_breaks       WHERE tevo_event_id = b.tevo_event_id) AS has_school_break,
  EXISTS (SELECT 1 FROM v_event_weather             WHERE tevo_event_id = b.tevo_event_id) AS has_weather,
  EXISTS (SELECT 1 FROM v_event_nws_alerts          WHERE tevo_event_id = b.tevo_event_id) AS has_nws_alert,
  EXISTS (SELECT 1 FROM v_event_reddit              WHERE tevo_event_id = b.tevo_event_id) AS has_reddit,
  EXISTS (SELECT 1 FROM v_event_major_calendar      WHERE tevo_event_id = b.tevo_event_id) AS has_major_calendar,
  EXISTS (SELECT 1 FROM v_event_sporting_rivalries  WHERE tevo_event_id = b.tevo_event_id) AS has_rivalry,
  EXISTS (SELECT 1 FROM v_event_mlb_branded_series  WHERE tevo_event_id = b.tevo_event_id) AS has_branded_series,
  EXISTS (SELECT 1 FROM v_event_espn_news           WHERE tevo_event_id = b.tevo_event_id) AS has_espn_news,
  EXISTS (SELECT 1 FROM v_event_espn_injuries       WHERE tevo_event_id = b.tevo_event_id) AS has_espn_injuries,
  EXISTS (SELECT 1 FROM v_event_espn_state          WHERE tevo_event_id = b.tevo_event_id) AS has_espn_state,
  EXISTS (SELECT 1 FROM v_event_team_standings      WHERE tevo_event_id = b.tevo_event_id) AS has_team_standings,
  EXISTS (SELECT 1 FROM v_event_evo_orders          WHERE tevo_event_id = b.tevo_event_id) AS has_evo_orders,
  EXISTS (SELECT 1 FROM v_event_competitors         WHERE tevo_event_id = b.tevo_event_id) AS has_competitors,
  (
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_holidays            WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_school_breaks       WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_weather             WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_nws_alerts          WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_reddit              WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_major_calendar      WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_sporting_rivalries  WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_mlb_branded_series  WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_espn_news           WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_espn_injuries       WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_espn_state          WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_team_standings      WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_evo_orders          WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END) +
    (CASE WHEN EXISTS (SELECT 1 FROM v_event_competitors         WHERE tevo_event_id = b.tevo_event_id) THEN 1 ELSE 0 END)
  ) AS overlay_signal_count
FROM v_event_base b;

CREATE OR REPLACE FUNCTION audit_cross_source_health()
RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT jsonb_build_object(
    'as_of', NOW(),
    'coverage', (SELECT jsonb_agg(to_jsonb(c.*)) FROM v_canonical_coverage_v2 c),
    'drift', jsonb_build_object(
      'rows_in_xref_missing_from_canonical',
        (SELECT COUNT(*) FROM v_canonical_drift WHERE issue='missing_from_canonical'),
      'sg_canonical_matched_but_no_xref',
        (SELECT COUNT(*) FROM v_canonical_drift WHERE issue='matched_but_no_xref')
    ),
    'orphans', jsonb_build_object(
      'seatgeek', COALESCE((SELECT jsonb_object_agg(kind, total)
                              FROM (SELECT kind, SUM(row_count) AS total
                                      FROM v_orphan_seatgeek_data
                                     GROUP BY kind) x), '{}'::jsonb),
      'seatdata', COALESCE((SELECT jsonb_object_agg(kind, total)
                              FROM (SELECT kind, SUM(row_count) AS total
                                      FROM v_orphan_seatdata_data
                                     GROUP BY kind) x), '{}'::jsonb),
      'sg_canonical_unmatched',
        (SELECT COUNT(*) FROM sg_events_canonical WHERE tevo_event_id IS NULL)
    ),
    'overlay_coverage', (
      SELECT jsonb_build_object(
        'total_events',            COUNT(*),
        'with_any_overlay',        COUNT(*) FILTER (WHERE overlay_signal_count > 0),
        'avg_signals_per_event',   ROUND(AVG(overlay_signal_count)::numeric, 2),
        'with_holiday',            COUNT(*) FILTER (WHERE has_holiday),
        'with_school_break',       COUNT(*) FILTER (WHERE has_school_break),
        'with_weather',            COUNT(*) FILTER (WHERE has_weather),
        'with_nws_alert',          COUNT(*) FILTER (WHERE has_nws_alert),
        'with_reddit',             COUNT(*) FILTER (WHERE has_reddit),
        'with_major_calendar',     COUNT(*) FILTER (WHERE has_major_calendar),
        'with_rivalry',            COUNT(*) FILTER (WHERE has_rivalry),
        'with_branded_series',     COUNT(*) FILTER (WHERE has_branded_series),
        'with_espn_news',          COUNT(*) FILTER (WHERE has_espn_news),
        'with_espn_injuries',      COUNT(*) FILTER (WHERE has_espn_injuries),
        'with_espn_state',         COUNT(*) FILTER (WHERE has_espn_state),
        'with_team_standings',     COUNT(*) FILTER (WHERE has_team_standings),
        'with_evo_orders',         COUNT(*) FILTER (WHERE has_evo_orders),
        'with_competitors',        COUNT(*) FILTER (WHERE has_competitors))
      FROM v_event_overlay_summary)
  );
$$;

GRANT SELECT ON v_event_base, v_event_holidays, v_event_school_breaks,
                v_event_weather, v_event_nws_alerts, v_event_reddit,
                v_event_major_calendar, v_event_sporting_rivalries,
                v_event_mlb_branded_series, v_event_espn_news,
                v_event_espn_injuries, v_event_espn_state,
                v_event_team_standings, v_event_evo_orders,
                v_event_competitors, v_event_overlay_summary
  TO authenticated, anon, service_role;
GRANT EXECUTE ON FUNCTION audit_cross_source_health() TO authenticated, anon, service_role;
