-- ============================================================================
-- Migration 20260509540000 — Holiday + school calendar reference
--
-- Hand-seeded reference tables for holidays + school break windows in
-- the markets we cover (US + Canada + Mexico). Static, free, no API.
--
-- Why this matters for ticket pricing:
--   - Tuesday-night NBA prices very differently if school is in/out
--   - Yom Kippur dampens NYC weeknight events
--   - Easter Sunday matinee Broadway gets a price bump
--   - Memorial Day weekend / Labor Day shifts demand windows
--
-- Today we have NONE of this. This migration plugs the gap.
--
-- Two tables + one event-overlay view:
--   holidays                    — discrete dates + impact rating
--   school_break_windows        — date ranges + region scope
--   v_event_calendar_context    — joins events to overlapping rows
-- ============================================================================

-- ============================================================================
-- (1) holidays — date + country + type + attendance impact
-- ============================================================================

CREATE TABLE IF NOT EXISTS holidays (
  id              bigserial PRIMARY KEY,
  holiday_name    text NOT NULL,
  observed_date   date NOT NULL,           -- the date the holiday is observed
  country         text NOT NULL,            -- 'US' | 'CA' | 'MX'
  holiday_type    text NOT NULL,            -- 'federal' | 'religious' | 'cultural' | 'state'
  attendance_impact text DEFAULT 'neutral', -- 'boost' | 'neutral' | 'dampen'
  notes           text,
  added_at        timestamptz DEFAULT now(),
  UNIQUE (holiday_name, observed_date, country)
);

CREATE INDEX IF NOT EXISTS holidays_date_idx ON holidays(observed_date);
CREATE INDEX IF NOT EXISTS holidays_country_idx ON holidays(country);

COMMENT ON TABLE holidays IS
  'Discrete-date holidays affecting ticket demand. Hand-maintained per '
  'year. attendance_impact: "boost" = expect higher demand (Mother''s Day '
  'matinee Broadway, Super Bowl Sunday); "dampen" = lower demand '
  '(Yom Kippur weeknight, Christmas Day evening); "neutral" = no clear '
  'directional effect.';

-- ============================================================================
-- (2) school_break_windows — date ranges + region scope
-- ============================================================================

CREATE TABLE IF NOT EXISTS school_break_windows (
  id           bigserial PRIMARY KEY,
  break_name   text NOT NULL,
  start_date   date NOT NULL,
  end_date     date NOT NULL,
  country      text NOT NULL,           -- 'US' | 'CA' | 'MX'
  region_scope text DEFAULT 'national', -- 'national' | 'most_districts' | 'state-XX'
  notes        text,
  added_at     timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS school_break_windows_dates_idx
  ON school_break_windows USING gist(daterange(start_date, end_date, '[]'));
CREATE INDEX IF NOT EXISTS school_break_windows_country_idx
  ON school_break_windows(country);

COMMENT ON TABLE school_break_windows IS
  'School break date ranges. Most US districts follow similar patterns. '
  'region_scope = "most_districts" means ~80%+ of US districts observe '
  'these dates within ±3 days. Use country=US for general US-wide '
  'context.';

-- ============================================================================
-- (3) Seed: 2026 + 2027 federal + key religious/cultural holidays
-- ============================================================================

INSERT INTO holidays(holiday_name, observed_date, country, holiday_type, attendance_impact, notes) VALUES
  -- US 2026
  ('New Year''s Day',            '2026-01-01', 'US', 'federal',  'boost',   'NYE the night before is the bigger ticket event'),
  ('MLK Jr. Day',                '2026-01-19', 'US', 'federal',  'neutral', '3rd Monday of January'),
  ('Valentine''s Day',           '2026-02-14', 'US', 'cultural', 'boost',   'Romantic show / dinner pairing — Broadway, comedy, dinner-theater'),
  ('Presidents Day',             '2026-02-16', 'US', 'federal',  'boost',   'Long weekend'),
  ('Easter Sunday',              '2026-04-05', 'US', 'religious','boost',   'Matinee Broadway, family events'),
  ('Memorial Day',               '2026-05-25', 'US', 'federal',  'boost',   'Long weekend; outdoor sports + concerts strong'),
  ('Mother''s Day',              '2026-05-10', 'US', 'cultural', 'boost',   'Matinee performances especially'),
  ('Father''s Day',              '2026-06-21', 'US', 'cultural', 'boost',   NULL),
  ('Juneteenth',                 '2026-06-19', 'US', 'federal',  'neutral', NULL),
  ('Independence Day',           '2026-07-04', 'US', 'federal',  'boost',   'Outdoor / festival weekend'),
  ('Labor Day',                  '2026-09-07', 'US', 'federal',  'boost',   'Long weekend'),
  ('Rosh Hashanah',              '2026-09-12', 'US', 'religious','dampen',  'NY/NJ/Florida Jewish-population markets'),
  ('Yom Kippur',                 '2026-09-21', 'US', 'religious','dampen',  'Strongest dampen signal in NYC; weeknight events drop'),
  ('Columbus Day / Indigenous Peoples Day', '2026-10-12', 'US', 'federal', 'neutral', NULL),
  ('Halloween',                  '2026-10-31', 'US', 'cultural', 'neutral', 'Friday in 2026; mixed effect on weekend events'),
  ('Veterans Day',               '2026-11-11', 'US', 'federal',  'neutral', NULL),
  ('Thanksgiving',               '2026-11-26', 'US', 'federal',  'boost',   'Travel-heavy, NFL games, Macy''s parade'),
  ('Black Friday',               '2026-11-27', 'US', 'cultural', 'neutral', NULL),
  ('Christmas Eve',              '2026-12-24', 'US', 'cultural', 'dampen',  'Most events skip this day'),
  ('Christmas Day',              '2026-12-25', 'US', 'federal',  'boost',   'NBA Christmas Day games are major; otherwise mostly closed'),
  ('New Year''s Eve',            '2026-12-31', 'US', 'cultural', 'boost',   'NYE concerts, Broadway, party events'),

  -- US 2027 (forward visibility)
  ('New Year''s Day',            '2027-01-01', 'US', 'federal',  'boost',   NULL),
  ('MLK Jr. Day',                '2027-01-18', 'US', 'federal',  'neutral', NULL),
  ('Super Bowl Sunday',          '2027-02-14', 'US', 'cultural', 'dampen',  'Most events skip Super Bowl Sunday — 2027 Super Bowl LXI'),
  ('Valentine''s Day',           '2027-02-14', 'US', 'cultural', 'boost',   'Same day as Super Bowl in 2027 — interesting collision'),
  ('Presidents Day',             '2027-02-15', 'US', 'federal',  'boost',   NULL),
  ('St. Patrick''s Day',         '2027-03-17', 'US', 'cultural', 'boost',   'NYC, Boston, Chicago especially'),
  ('Easter Sunday',              '2027-03-28', 'US', 'religious','boost',   NULL),
  ('Mother''s Day',              '2027-05-09', 'US', 'cultural', 'boost',   NULL),
  ('Memorial Day',               '2027-05-31', 'US', 'federal',  'boost',   NULL),
  ('Juneteenth',                 '2027-06-19', 'US', 'federal',  'neutral', NULL),
  ('Father''s Day',              '2027-06-20', 'US', 'cultural', 'boost',   NULL),
  ('Independence Day',           '2027-07-04', 'US', 'federal',  'boost',   NULL),
  ('Labor Day',                  '2027-09-06', 'US', 'federal',  'boost',   NULL),
  ('Rosh Hashanah',              '2027-10-02', 'US', 'religious','dampen',  NULL),
  ('Yom Kippur',                 '2027-10-11', 'US', 'religious','dampen',  NULL),
  ('Columbus Day',               '2027-10-11', 'US', 'federal',  'neutral', NULL),
  ('Halloween',                  '2027-10-31', 'US', 'cultural', 'neutral', 'Sunday in 2027'),
  ('Veterans Day',               '2027-11-11', 'US', 'federal',  'neutral', NULL),
  ('Thanksgiving',               '2027-11-25', 'US', 'federal',  'boost',   NULL),
  ('Christmas Eve',              '2027-12-24', 'US', 'cultural', 'dampen',  NULL),
  ('Christmas Day',              '2027-12-25', 'US', 'federal',  'boost',   NULL),
  ('New Year''s Eve',            '2027-12-31', 'US', 'cultural', 'boost',   NULL),

  -- 2026 Super Bowl is Feb 8, 2026 — already past for current data window but seed for future ref
  ('Super Bowl Sunday',          '2026-02-08', 'US', 'cultural', 'dampen',  'Super Bowl LX — most events dampen'),

  -- Canada 2026 federal + Quebec
  ('New Year''s Day',            '2026-01-01', 'CA', 'federal',  'boost',   NULL),
  ('Family Day',                 '2026-02-16', 'CA', 'federal',  'boost',   'Several provinces; varies by province'),
  ('Good Friday',                '2026-04-03', 'CA', 'federal',  'neutral', NULL),
  ('Easter Monday',              '2026-04-06', 'CA', 'federal',  'neutral', NULL),
  ('Victoria Day',               '2026-05-18', 'CA', 'federal',  'boost',   'Long weekend'),
  ('Canada Day',                 '2026-07-01', 'CA', 'federal',  'boost',   NULL),
  ('Civic Holiday',              '2026-08-03', 'CA', 'federal',  'boost',   'Long weekend in Ontario, AB, BC etc.'),
  ('Labour Day',                 '2026-09-07', 'CA', 'federal',  'boost',   NULL),
  ('Thanksgiving',               '2026-10-12', 'CA', 'federal',  'boost',   '2nd Monday of October'),
  ('Remembrance Day',            '2026-11-11', 'CA', 'federal',  'neutral', NULL),
  ('Christmas Day',              '2026-12-25', 'CA', 'federal',  'boost',   NULL),
  ('Boxing Day',                 '2026-12-26', 'CA', 'federal',  'boost',   'Major shopping/event day'),

  -- Mexico 2026 federal
  ('Día de la Constitución',     '2026-02-02', 'MX', 'federal',  'neutral', '5 Feb observed first Monday'),
  ('Natalicio de Benito Juárez', '2026-03-16', 'MX', 'federal',  'neutral', NULL),
  ('Día del Trabajo',            '2026-05-01', 'MX', 'federal',  'boost',   NULL),
  ('Cinco de Mayo',              '2026-05-05', 'MX', 'cultural', 'boost',   'Strong US-market signal too'),
  ('Día de la Independencia',    '2026-09-16', 'MX', 'federal',  'boost',   'Major celebration'),
  ('Día de los Muertos',         '2026-11-02', 'MX', 'cultural', 'boost',   NULL),
  ('Día de la Revolución',       '2026-11-16', 'MX', 'federal',  'neutral', NULL),
  ('Navidad',                    '2026-12-25', 'MX', 'federal',  'boost',   NULL)
ON CONFLICT (holiday_name, observed_date, country) DO NOTHING;

-- ============================================================================
-- (4) Seed: US school break windows (most-districts-style)
-- ============================================================================

INSERT INTO school_break_windows(break_name, start_date, end_date, country, region_scope, notes) VALUES
  -- 2026 academic year breaks
  ('Spring Break 2026',           '2026-03-23', '2026-04-10', 'US', 'most_districts', 'Two-week window covers ~80% of district variability'),
  ('Easter / Spring Break 2026',  '2026-04-01', '2026-04-10', 'US', 'most_districts', 'Easter-aligned districts'),
  ('Summer Break 2026',           '2026-06-15', '2026-08-25', 'US', 'most_districts', NULL),
  ('Thanksgiving Break 2026',     '2026-11-25', '2026-11-29', 'US', 'most_districts', 'Wed-Sun typical'),
  ('Winter Break 2026',           '2026-12-21', '2027-01-04', 'US', 'most_districts', '~2-week window'),

  -- 2027 forward
  ('MLK Day Long Weekend 2027',   '2027-01-16', '2027-01-18', 'US', 'most_districts', NULL),
  ('Presidents Day Long Weekend', '2027-02-13', '2027-02-15', 'US', 'most_districts', NULL),
  ('Spring Break 2027',           '2027-03-15', '2027-04-04', 'US', 'most_districts', NULL),
  ('Memorial Day Weekend 2027',   '2027-05-29', '2027-05-31', 'US', 'most_districts', NULL),
  ('Summer Break 2027',           '2027-06-14', '2027-08-24', 'US', 'most_districts', NULL),

  -- Canada: similar structure, slightly different dates
  ('Spring Break (Canada) 2026',  '2026-03-09', '2026-03-22', 'CA', 'most_districts', '2-week window covers BC, AB, ON variance'),
  ('Summer Break (Canada) 2026',  '2026-06-29', '2026-09-07', 'CA', 'most_districts', NULL),
  ('Winter Break (Canada) 2026',  '2026-12-21', '2027-01-04', 'CA', 'most_districts', NULL);

-- ============================================================================
-- (5) v_event_calendar_context — overlay view
-- ============================================================================

CREATE OR REPLACE VIEW v_event_calendar_context AS
SELECT
  e.id AS tevo_event_id,
  e.name AS event_name,
  e.occurs_at_local::date AS event_date,
  e.venue_location,
  -- Country inference from venue_location (very rough)
  CASE
    WHEN e.venue_location ~* ',\s*(AB|BC|MB|NB|NL|NS|NT|NU|ON|PE|QC|SK|YT)\s*$' THEN 'CA'
    WHEN e.venue_location ILIKE '%, Mexico%'  THEN 'MX'
    WHEN e.venue_location ILIKE '%, Canada%'  THEN 'CA'
    ELSE 'US'
  END AS inferred_country,
  -- Holiday on the event date
  (SELECT json_agg(json_build_object(
            'name', h.holiday_name,
            'type', h.holiday_type,
            'impact', h.attendance_impact))
   FROM holidays h
   WHERE h.observed_date = e.occurs_at_local::date
     AND h.country = (CASE
       WHEN e.venue_location ~* ',\s*(AB|BC|MB|NB|NL|NS|NT|NU|ON|PE|QC|SK|YT)\s*$' THEN 'CA'
       WHEN e.venue_location ILIKE '%, Mexico%'  THEN 'MX'
       WHEN e.venue_location ILIKE '%, Canada%'  THEN 'CA'
       ELSE 'US' END)
  ) AS holidays_today,
  -- Holiday within ±1 day (long-weekend signal)
  EXISTS (
    SELECT 1 FROM holidays h
    WHERE h.observed_date BETWEEN e.occurs_at_local::date - 1
                              AND e.occurs_at_local::date + 1
      AND h.country = (CASE
       WHEN e.venue_location ~* ',\s*(AB|BC|MB|NB|NL|NS|NT|NU|ON|PE|QC|SK|YT)\s*$' THEN 'CA'
       WHEN e.venue_location ILIKE '%, Mexico%'  THEN 'MX'
       WHEN e.venue_location ILIKE '%, Canada%'  THEN 'CA'
       ELSE 'US' END)
  ) AS within_holiday_window,
  -- Inside a school break window?
  EXISTS (
    SELECT 1 FROM school_break_windows sb
    WHERE e.occurs_at_local::date BETWEEN sb.start_date AND sb.end_date
      AND sb.country = (CASE
       WHEN e.venue_location ~* ',\s*(AB|BC|MB|NB|NL|NS|NT|NU|ON|PE|QC|SK|YT)\s*$' THEN 'CA'
       WHEN e.venue_location ILIKE '%, Mexico%'  THEN 'MX'
       WHEN e.venue_location ILIKE '%, Canada%'  THEN 'CA'
       ELSE 'US' END)
  ) AS school_break_active,
  -- Which break (if any)
  (SELECT sb.break_name
   FROM school_break_windows sb
   WHERE e.occurs_at_local::date BETWEEN sb.start_date AND sb.end_date
     AND sb.country = (CASE
       WHEN e.venue_location ~* ',\s*(AB|BC|MB|NB|NL|NS|NT|NU|ON|PE|QC|SK|YT)\s*$' THEN 'CA'
       WHEN e.venue_location ILIKE '%, Mexico%'  THEN 'MX'
       WHEN e.venue_location ILIKE '%, Canada%'  THEN 'CA'
       ELSE 'US' END)
   LIMIT 1) AS active_school_break
FROM events e
WHERE e.occurs_at_local::timestamptz > now() - interval '1 day';

COMMENT ON VIEW v_event_calendar_context IS
  'Per-event holiday + school-break context. holidays_today = json '
  'array of holidays falling exactly on event date. '
  'within_holiday_window = true if any holiday within ±1 day '
  '(captures long-weekend pricing). school_break_active = true if event '
  'date falls inside any school break window for the inferred country. '
  'Inferred country comes from venue_location regex.';
