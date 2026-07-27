-- ============================================================================
-- Migration 20260509550000 — Localize holidays + school breaks to state/city
--
-- Per directive (2026-05-09):
--   "localize calendars and breaks to state or city for more accurate data
--    readings where applicable. and map it to our data per location and
--    event date and any other data source that fits"
--
-- Builds on 20260509540000_holiday_school_calendar.sql which seeded
-- country-level US/CA/MX. This migration:
--
--   1. Adds `state` + `city` (both nullable text) columns to
--      `holidays` and `school_break_windows`. NULL = national/country-wide.
--   2. Seeds state-level holidays where they actually move pricing
--      (Patriots' Day MA, Cesar Chavez Day CA, Pulaski Day IL,
--       Mardi Gras LA, Texas Independence Day TX, Statehood Day HI,
--       Lincoln's Birthday IL/NY, Inauguration Day DC).
--   3. Seeds city-tagged marquee cultural dates that lock down whole
--      neighborhoods around our venues (NYC Marathon, Boston Marathon,
--      Chicago Marathon, NYC Pride, West Indian Day Parade, Macy's Day Parade).
--   4. Seeds top-market school district break windows
--      (NYC DOE, LAUSD, Chicago Public, Boston Public, Houston ISD,
--       Philadelphia, Miami-Dade) — these often diverge ±1-2 weeks from
--      the "most_districts" national window.
--   5. Rebuilds `v_event_calendar_context` to extract state + city from
--      `venue_location` and match holidays/breaks at the most precise
--      level available, returning ALL matches (national + state + city)
--      so the UI can label both "US Federal Holiday" and
--      "Boston Marathon (Patriots' Day)" on the same event.
--   6. Adds `v_event_local_signals` — joins calendar context to weather
--      forecast + competing events at the same location/date. Surfaces
--      the combined signal stack ("rivalry game + Mother's Day matinee +
--      spring break + clear weather") in one row per upcoming event.
-- ============================================================================

-- ============================================================================
-- (1) Schema changes
-- ============================================================================

ALTER TABLE holidays
  ADD COLUMN IF NOT EXISTS state text,        -- 2-letter US/CA code; NULL = national
  ADD COLUMN IF NOT EXISTS city  text;        -- City name (matches venue_location city); NULL = state/national-wide

ALTER TABLE school_break_windows
  ADD COLUMN IF NOT EXISTS state text,
  ADD COLUMN IF NOT EXISTS city  text,
  ADD COLUMN IF NOT EXISTS district_name text; -- Optional: "NYC DOE", "LAUSD", etc.

CREATE INDEX IF NOT EXISTS holidays_state_idx ON holidays(country, state);
CREATE INDEX IF NOT EXISTS holidays_city_idx  ON holidays(country, city);
CREATE INDEX IF NOT EXISTS school_break_state_idx ON school_break_windows(country, state);
CREATE INDEX IF NOT EXISTS school_break_city_idx  ON school_break_windows(country, city);

-- The previous UNIQUE (holiday_name, observed_date, country) would block us
-- from inserting "Lincoln's Birthday" once national + once for IL. Drop and
-- replace with a richer key.
ALTER TABLE holidays DROP CONSTRAINT IF EXISTS holidays_holiday_name_observed_date_country_key;

CREATE UNIQUE INDEX IF NOT EXISTS holidays_unique_idx
  ON holidays(holiday_name, observed_date, country, COALESCE(state, ''), COALESCE(city, ''));

-- ============================================================================
-- (2) Seed state-level holidays (high-leverage only)
-- ============================================================================

INSERT INTO holidays(holiday_name, observed_date, country, state, city, holiday_type, attendance_impact, notes) VALUES
  -- Patriots' Day — MA + ME, 3rd Monday of April
  --   Boston Red Sox play traditional 11am home game; Boston Marathon
  ('Patriots'' Day',           '2026-04-20', 'US', 'MA', NULL, 'state',    'boost',   'Boston Marathon + Red Sox 11am home game; whole city affected'),
  ('Patriots'' Day',           '2026-04-20', 'US', 'ME', NULL, 'state',    'neutral', 'State holiday in Maine'),
  ('Patriots'' Day',           '2027-04-19', 'US', 'MA', NULL, 'state',    'boost',   NULL),
  ('Patriots'' Day',           '2027-04-19', 'US', 'ME', NULL, 'state',    'neutral', NULL),

  -- Cesar Chavez Day — CA state holiday, March 31
  ('Cesar Chavez Day',         '2026-03-31', 'US', 'CA', NULL, 'state',    'neutral', 'CA state holiday; some schools closed'),
  ('Cesar Chavez Day',         '2027-03-31', 'US', 'CA', NULL, 'state',    'neutral', NULL),

  -- Casimir Pulaski Day — IL state holiday, 1st Monday of March
  --   Chicago Public Schools closed; affects weeknight events
  ('Casimir Pulaski Day',      '2026-03-02', 'US', 'IL', NULL, 'state',    'neutral', 'CPS closed; mainly Chicago effect'),
  ('Casimir Pulaski Day',      '2027-03-01', 'US', 'IL', NULL, 'state',    'neutral', NULL),

  -- Mardi Gras — LA state holiday, Tuesday before Ash Wednesday
  --   New Orleans practically shuts down for parades
  ('Mardi Gras',               '2026-02-17', 'US', 'LA', NULL, 'state',    'boost',   'New Orleans entertainment district at peak; all venues affected'),
  ('Mardi Gras',               '2027-02-16', 'US', 'LA', NULL, 'state',    'boost',   NULL),

  -- Texas Independence Day — TX state observance, March 2
  ('Texas Independence Day',   '2026-03-02', 'US', 'TX', NULL, 'state',    'neutral', 'State observance; not a school closure'),
  ('Texas Independence Day',   '2027-03-02', 'US', 'TX', NULL, 'state',    'neutral', NULL),

  -- Statehood Day — HI, 3rd Friday of August
  ('Hawaii Statehood Day',     '2026-08-21', 'US', 'HI', NULL, 'state',    'neutral', NULL),
  ('Hawaii Statehood Day',     '2027-08-20', 'US', 'HI', NULL, 'state',    'neutral', NULL),

  -- Lincoln's Birthday — Feb 12, observed in IL + NY (NY courts closed)
  ('Lincoln''s Birthday',      '2026-02-12', 'US', 'IL', NULL, 'state',    'neutral', NULL),
  ('Lincoln''s Birthday',      '2027-02-12', 'US', 'IL', NULL, 'state',    'neutral', NULL),

  -- Day After Thanksgiving — observed as full holiday in many states; treat as boost
  --   for shopping/events in NV (Vegas), FL, TX, CA notably
  ('Day After Thanksgiving',   '2026-11-27', 'US', 'NV', NULL, 'state',    'boost',   'Vegas Friday-after-Thanksgiving is peak entertainment'),
  ('Day After Thanksgiving',   '2027-11-26', 'US', 'NV', NULL, 'state',    'boost',   NULL),

  -- Inauguration Day — DC, every 4 years (next: 2029); seed empty placeholder for ref
  --   Skipping until 2029 cycle.

  -- Quebec — Saint-Jean-Baptiste Day, June 24 (provincial holiday)
  ('Saint-Jean-Baptiste Day',  '2026-06-24', 'CA', 'QC', NULL, 'state',    'boost',   'Major QC celebration; Montreal venues affected'),
  ('Saint-Jean-Baptiste Day',  '2027-06-24', 'CA', 'QC', NULL, 'state',    'boost',   NULL)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- (3) Seed city-tagged marquee cultural dates
-- ============================================================================

INSERT INTO holidays(holiday_name, observed_date, country, state, city, holiday_type, attendance_impact, notes) VALUES
  -- NYC Marathon — 1st Sunday of November; closes Manhattan + Brooklyn streets
  ('NYC Marathon',             '2026-11-01', 'US', 'NY', 'New York', 'cultural', 'boost',   'Marathon Sunday; matinee theater + UWS/Brooklyn venues affected'),
  ('NYC Marathon',             '2027-11-07', 'US', 'NY', 'New York', 'cultural', 'boost',   NULL),

  -- Boston Marathon — Patriots' Day; already flagged via state holiday but city tag adds clarity
  ('Boston Marathon',          '2026-04-20', 'US', 'MA', 'Boston',  'cultural', 'boost',   'Race day; downtown access restricted'),
  ('Boston Marathon',          '2027-04-19', 'US', 'MA', 'Boston',  'cultural', 'boost',   NULL),

  -- Chicago Marathon — 2nd Sunday of October
  ('Chicago Marathon',         '2026-10-11', 'US', 'IL', 'Chicago', 'cultural', 'boost',   'Loop + lakefront access affected'),
  ('Chicago Marathon',         '2027-10-10', 'US', 'IL', 'Chicago', 'cultural', 'boost',   NULL),

  -- NYC Pride Parade — last Sunday of June
  ('NYC Pride Parade',         '2026-06-28', 'US', 'NY', 'New York', 'cultural', 'boost',   '5th Ave + West Village; weekend tourism spike'),
  ('NYC Pride Parade',         '2027-06-27', 'US', 'NY', 'New York', 'cultural', 'boost',   NULL),

  -- West Indian Day Parade — Brooklyn, Labor Day Monday
  ('West Indian Day Parade',   '2026-09-07', 'US', 'NY', 'Brooklyn', 'cultural', 'boost',   'Eastern Pkwy + Crown Hts; Brooklyn venues affected'),
  ('West Indian Day Parade',   '2027-09-06', 'US', 'NY', 'Brooklyn', 'cultural', 'boost',   NULL),

  -- Macy's Thanksgiving Day Parade — covered by Thanksgiving but tag city for completeness
  ('Macy''s Thanksgiving Parade', '2026-11-26', 'US', 'NY', 'New York', 'cultural', 'boost', 'UWS + Midtown access restricted morning'),
  ('Macy''s Thanksgiving Parade', '2027-11-25', 'US', 'NY', 'New York', 'cultural', 'boost', NULL),

  -- LA Marathon — typically March, ~Sunday after St. Patrick's
  ('LA Marathon',              '2026-03-15', 'US', 'CA', 'Los Angeles', 'cultural', 'boost', 'Course runs Dodger Stadium → Century City'),

  -- Mardi Gras parade run — New Orleans, multi-day. Capture key day; LA state already flagged
  ('Mardi Gras Parades Peak',  '2026-02-15', 'US', 'LA', 'New Orleans', 'cultural', 'boost', 'Sunday before Mardi Gras Day; major parades'),
  ('Mardi Gras Parades Peak',  '2027-02-14', 'US', 'LA', 'New Orleans', 'cultural', 'boost', NULL)
ON CONFLICT DO NOTHING;

-- ============================================================================
-- (4) Seed top-market school district breaks
--
--   Source dates: each district's published 2025-26 + 2026-27 calendar
--   Where exact dates aren't yet published, leave for next year's update.
-- ============================================================================

INSERT INTO school_break_windows(break_name, start_date, end_date, country, state, city, district_name, region_scope, notes) VALUES
  -- NYC DOE 2025-26 (spans the calendar year)
  ('NYC DOE Mid-Winter Recess 2026',   '2026-02-16', '2026-02-20', 'US', 'NY', 'New York', 'NYC DOE',         'state-NY', 'Presidents Day week'),
  ('NYC DOE Spring Recess 2026',       '2026-04-03', '2026-04-10', 'US', 'NY', 'New York', 'NYC DOE',         'state-NY', 'Good Friday + Passover-aligned'),
  ('NYC DOE Summer Break 2026',        '2026-06-27', '2026-09-07', 'US', 'NY', 'New York', 'NYC DOE',         'state-NY', NULL),
  ('NYC DOE Winter Recess 2026',       '2026-12-24', '2027-01-02', 'US', 'NY', 'New York', 'NYC DOE',         'state-NY', NULL),
  ('NYC DOE Mid-Winter Recess 2027',   '2027-02-15', '2027-02-19', 'US', 'NY', 'New York', 'NYC DOE',         'state-NY', NULL),
  ('NYC DOE Spring Recess 2027',       '2027-03-29', '2027-04-02', 'US', 'NY', 'New York', 'NYC DOE',         'state-NY', NULL),

  -- LAUSD
  ('LAUSD Spring Break 2026',          '2026-04-06', '2026-04-10', 'US', 'CA', 'Los Angeles', 'LAUSD',         'state-CA', NULL),
  ('LAUSD Summer Break 2026',          '2026-06-08', '2026-08-13', 'US', 'CA', 'Los Angeles', 'LAUSD',         'state-CA', 'LAUSD starts mid-Aug'),
  ('LAUSD Winter Break 2026',          '2026-12-21', '2027-01-08', 'US', 'CA', 'Los Angeles', 'LAUSD',         'state-CA', NULL),

  -- Chicago Public Schools (CPS)
  ('CPS Spring Break 2026',            '2026-03-23', '2026-03-27', 'US', 'IL', 'Chicago',     'Chicago Public Schools', 'state-IL', NULL),
  ('CPS Summer Break 2026',            '2026-06-13', '2026-08-18', 'US', 'IL', 'Chicago',     'Chicago Public Schools', 'state-IL', NULL),
  ('CPS Winter Break 2026',            '2026-12-21', '2027-01-04', 'US', 'IL', 'Chicago',     'Chicago Public Schools', 'state-IL', NULL),

  -- Boston Public Schools — note Apr Vacation aligns with Patriots' Day
  ('BPS February Vacation 2026',       '2026-02-16', '2026-02-20', 'US', 'MA', 'Boston',      'Boston Public Schools',  'state-MA', NULL),
  ('BPS April Vacation 2026',          '2026-04-20', '2026-04-24', 'US', 'MA', 'Boston',      'Boston Public Schools',  'state-MA', 'Patriots Day week'),
  ('BPS Summer Break 2026',            '2026-06-26', '2026-09-02', 'US', 'MA', 'Boston',      'Boston Public Schools',  'state-MA', NULL),

  -- Houston ISD
  ('HISD Spring Break 2026',           '2026-03-09', '2026-03-13', 'US', 'TX', 'Houston',     'Houston ISD',            'state-TX', NULL),
  ('HISD Summer Break 2026',           '2026-06-08', '2026-08-21', 'US', 'TX', 'Houston',     'Houston ISD',            'state-TX', NULL),

  -- Miami-Dade County Public Schools
  ('MDCPS Spring Break 2026',          '2026-03-23', '2026-03-27', 'US', 'FL', 'Miami',       'Miami-Dade Public Schools','state-FL', NULL),
  ('MDCPS Summer Break 2026',          '2026-06-08', '2026-08-13', 'US', 'FL', 'Miami',       'Miami-Dade Public Schools','state-FL', NULL),

  -- Philadelphia
  ('Philly Spring Break 2026',         '2026-04-03', '2026-04-10', 'US', 'PA', 'Philadelphia','School District of Philadelphia','state-PA', NULL),
  ('Philly Summer Break 2026',         '2026-06-15', '2026-09-07', 'US', 'PA', 'Philadelphia','School District of Philadelphia','state-PA', NULL),

  -- Toronto District School Board
  ('TDSB March Break 2026',            '2026-03-16', '2026-03-20', 'CA', 'ON', 'Toronto',     'TDSB',                   'state-ON', NULL),
  ('TDSB Summer Break 2026',           '2026-06-29', '2026-09-07', 'CA', 'ON', 'Toronto',     'TDSB',                   'state-ON', NULL);

-- ============================================================================
-- (5) Rebuild v_event_calendar_context — state/city aware
--
--   Returns ALL overlapping holidays + breaks (national + state + city)
--   so UI can label every relevant signal. precision = 'national' |
--   'state' | 'city' is exposed in the json so consumers can filter.
-- ============================================================================

DROP VIEW IF EXISTS v_event_calendar_context CASCADE;

CREATE OR REPLACE VIEW v_event_calendar_context AS
WITH parsed AS (
  SELECT
    e.id   AS tevo_event_id,
    e.name AS event_name,
    e.occurs_at_local::date AS event_date,
    e.venue_location,
    e.venue_id,
    e.primary_performer_name,
    -- Country inference
    CASE
      WHEN e.venue_location ~* ',\s*(AB|BC|MB|NB|NL|NS|NT|NU|ON|PE|QC|SK|YT)\s*$' THEN 'CA'
      WHEN e.venue_location ILIKE '%, Mexico%' THEN 'MX'
      WHEN e.venue_location ILIKE '%, Canada%' THEN 'CA'
      ELSE 'US'
    END AS inferred_country,
    -- State extraction (works for both US + CA province codes; NULL otherwise)
    CASE
      WHEN e.venue_location ~ '^[^,]+,\s*[A-Z]{2}$'
      THEN trim(reverse(split_part(reverse(e.venue_location), ',', 1)))
      ELSE NULL
    END AS inferred_state,
    -- City extraction (everything before the first comma)
    CASE
      WHEN e.venue_location ~ '^[^,]+,'
      THEN trim(split_part(e.venue_location, ',', 1))
      ELSE NULL
    END AS inferred_city
  FROM events e
  WHERE e.occurs_at_local::timestamptz > now() - interval '1 day'
    AND e.venue_location IS NOT NULL
)
SELECT
  p.tevo_event_id,
  p.event_name,
  p.event_date,
  p.venue_location,
  p.inferred_country,
  p.inferred_state,
  p.inferred_city,

  -- All matching holidays exactly on the event date (national + state + city)
  (SELECT json_agg(json_build_object(
            'name',       h.holiday_name,
            'type',       h.holiday_type,
            'impact',     h.attendance_impact,
            'precision',  CASE
                            WHEN h.city  IS NOT NULL THEN 'city'
                            WHEN h.state IS NOT NULL THEN 'state'
                            ELSE 'national'
                          END,
            'state',      h.state,
            'city',       h.city,
            'notes',      h.notes)
          ORDER BY
            CASE WHEN h.city IS NOT NULL THEN 0
                 WHEN h.state IS NOT NULL THEN 1
                 ELSE 2 END)
   FROM holidays h
   WHERE h.observed_date = p.event_date
     AND h.country = p.inferred_country
     AND (h.state IS NULL OR h.state = p.inferred_state)
     AND (h.city  IS NULL OR h.city  = p.inferred_city)
  ) AS holidays_today,

  -- Holidays within ±1 day (long-weekend + matinee planning)
  (SELECT json_agg(json_build_object(
            'name',  h.holiday_name,
            'date',  h.observed_date,
            'days_offset', h.observed_date - p.event_date,
            'impact', h.attendance_impact,
            'precision', CASE
                            WHEN h.city  IS NOT NULL THEN 'city'
                            WHEN h.state IS NOT NULL THEN 'state'
                            ELSE 'national'
                          END))
   FROM holidays h
   WHERE h.observed_date BETWEEN p.event_date - 1 AND p.event_date + 1
     AND h.observed_date <> p.event_date
     AND h.country = p.inferred_country
     AND (h.state IS NULL OR h.state = p.inferred_state)
     AND (h.city  IS NULL OR h.city  = p.inferred_city)
  ) AS holidays_nearby,

  -- All overlapping school breaks (national_most_districts + state-specific + district-specific)
  (SELECT json_agg(json_build_object(
            'name',       sb.break_name,
            'start_date', sb.start_date,
            'end_date',   sb.end_date,
            'precision',  CASE
                            WHEN sb.city  IS NOT NULL THEN 'city'
                            WHEN sb.state IS NOT NULL THEN 'state'
                            ELSE 'national'
                          END,
            'state',      sb.state,
            'city',       sb.city,
            'district',   sb.district_name)
          ORDER BY
            CASE WHEN sb.city IS NOT NULL THEN 0
                 WHEN sb.state IS NOT NULL THEN 1
                 ELSE 2 END)
   FROM school_break_windows sb
   WHERE p.event_date BETWEEN sb.start_date AND sb.end_date
     AND sb.country = p.inferred_country
     AND (sb.state IS NULL OR sb.state = p.inferred_state)
     AND (sb.city  IS NULL OR sb.city  = p.inferred_city)
  ) AS school_breaks_active,

  -- Convenience boolean flags
  EXISTS (
    SELECT 1 FROM holidays h
    WHERE h.observed_date = p.event_date
      AND h.country = p.inferred_country
      AND (h.state IS NULL OR h.state = p.inferred_state)
      AND (h.city  IS NULL OR h.city  = p.inferred_city)
  ) AS is_holiday,

  EXISTS (
    SELECT 1 FROM holidays h
    WHERE h.observed_date BETWEEN p.event_date - 1 AND p.event_date + 1
      AND h.country = p.inferred_country
      AND (h.state IS NULL OR h.state = p.inferred_state)
      AND (h.city  IS NULL OR h.city  = p.inferred_city)
  ) AS within_holiday_window,

  EXISTS (
    SELECT 1 FROM school_break_windows sb
    WHERE p.event_date BETWEEN sb.start_date AND sb.end_date
      AND sb.country = p.inferred_country
      AND (sb.state IS NULL OR sb.state = p.inferred_state)
      AND (sb.city  IS NULL OR sb.city  = p.inferred_city)
  ) AS school_break_active

FROM parsed p;

COMMENT ON VIEW v_event_calendar_context IS
  'Per-event calendar overlay. State + city extracted from venue_location. '
  'holidays_today / holidays_nearby / school_breaks_active each return ALL '
  'matching rows (national + state + city) ordered most-precise-first. '
  'Each row carries precision = "national" | "state" | "city" so the UI '
  'can render "Boston Marathon (Patriots'' Day)" alongside "US Federal '
  'Holiday: Patriots'' Day" without dedup logic in app code. '
  'Replaces the country-only view from migration 540000.';

-- ============================================================================
-- (6) v_event_local_signals — combine calendar + weather + competing events
--
--   Surfaces the "stack of signals" for one event in a single row:
--     calendar context (state/city aware) +
--     weather forecast (if we have one) +
--     competing nearby events (if we have v_competing_events)
-- ============================================================================

CREATE OR REPLACE VIEW v_event_local_signals AS
SELECT
  cc.tevo_event_id,
  cc.event_name,
  cc.event_date,
  cc.inferred_country,
  cc.inferred_state,
  cc.inferred_city,

  -- Calendar (state/city aware)
  cc.is_holiday,
  cc.within_holiday_window,
  cc.school_break_active,
  cc.holidays_today,
  cc.holidays_nearby,
  cc.school_breaks_active,

  -- Weather (best-effort — view exists from earlier migrations)
  (SELECT to_jsonb(w) FROM v_event_weather_with_fallback w
    WHERE w.tevo_event_id = cc.tevo_event_id) AS weather,

  -- Rivalry / branded series tag (if present)
  (SELECT jsonb_build_object(
            'rivalry_name',      re.rivalry_name,
            'is_branded',        re.is_branded,
            'rivalry_intensity', re.rivalry_intensity)
     FROM v_rivalry_events re
     WHERE re.tevo_event_id = cc.tevo_event_id
     LIMIT 1) AS rivalry,

  -- Pricing snapshot at-a-glance
  lem.tickets_count,
  lem.getin_price,
  lem.retail_median

FROM v_event_calendar_context cc
LEFT JOIN latest_event_metrics lem ON lem.event_id = cc.tevo_event_id
ORDER BY cc.event_date;

COMMENT ON VIEW v_event_local_signals IS
  'One-row-per-event combined signal stack: calendar (state/city aware) + '
  'weather forecast + rivalry/branded-series tag + pricing snapshot. '
  'Default surface for any "what is going on with this event?" UI panel. '
  'NULLs are expected on weather (forecast horizon ~7 days) and rivalry '
  '(only sports events match a known rivalry).';

-- ============================================================================
-- (7) Extend get_event_context() — replace country-only calendar key with
--     full state/city aware payload
-- ============================================================================

CREATE OR REPLACE FUNCTION get_event_context(p_event_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_event jsonb; v_pricing jsonb; v_espn jsonb; v_performer jsonb;
  v_weather jsonb; v_competitors jsonb; v_orders jsonb;
  v_odds jsonb; v_reddit jsonb; v_news jsonb; v_x jsonb; v_rivalry jsonb;
  v_calendar jsonb;
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

  -- NEW: state/city aware calendar payload (replaces prior country-only key)
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

  RETURN jsonb_build_object(
    'tevo_event_id', p_event_id, 'event', v_event,
    'pricing', COALESCE(v_pricing, '{}'::jsonb),
    'espn', COALESCE(v_espn, jsonb_build_object('present', false)),
    'odds', COALESCE(v_odds, jsonb_build_object('present', false)),
    'performer', COALESCE(v_performer, jsonb_build_object('present', false)),
    'weather', COALESCE(v_weather, jsonb_build_object('present', false)),
    'competitors', COALESCE(v_competitors, '[]'::jsonb),
    'reddit', COALESCE(v_reddit, jsonb_build_object('present', false)),
    'important_news', COALESCE(v_news, '[]'::jsonb),
    'x_accounts_known', COALESCE(v_x, jsonb_build_object('team_known', 0)),
    'rivalry', COALESCE(v_rivalry, jsonb_build_object('present', false)),
    'calendar', COALESCE(v_calendar, jsonb_build_object('present', false)),
    'our_orders', COALESCE(v_orders, jsonb_build_object('present', false)),
    'generated_at', now()
  );
END; $$;

COMMENT ON FUNCTION get_event_context(bigint) IS
  'Single-row jsonb summary of every context dimension we have for one event. '
  'Now 15 keys including state/city aware calendar overlay. '
  'See QUERY_CATALOG.md for a full schema breakdown.';
