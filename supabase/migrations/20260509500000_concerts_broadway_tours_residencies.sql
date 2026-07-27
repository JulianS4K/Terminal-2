-- ============================================================================
-- Migration 20260509500000 — Concerts + Broadway pull + tour/residency
--                            /Broadway-run detection views
--
-- Reuses the tournament_categories + tournament_pull_queue/_process
-- infrastructure from mig 490000. Adds 4 new categories:
--   54   = Concerts (parent, covers all genres)
--   1908 = Broadway Musicals
--   1067 = Broadway Plays
--   998  = Off-Broadway
--
-- Then exposes 3 detection views with different shapes:
--
--   v_performer_tours        — same performer at ≥2 distinct venues
--                              within a 12-month rolling window. The
--                              "Eras Tour" / "Bruce Springsteen 2026"
--                              shape.
--   v_performer_residencies  — same performer at SAME venue with ≥3
--                              dates and ≥14 day span. The "U2 at
--                              Sphere" / "Adele at Caesars" shape.
--   v_broadway_runs          — subset of residencies where venue is a
--                              known Broadway theater (Lion King at
--                              Minskoff, Hamilton at Richard Rodgers,
--                              etc.) Long-running, 8 shows/week.
--
-- All three are filterable by performer or venue. AI/RAG consumers
-- can use these in get_event_context to label "this event is the 17th
-- show of Lion King's run at Minskoff" or "this is stop 4 of Bruce's
-- 2026 tour."
-- ============================================================================

-- ============================================================================
-- (1) Add concert + Broadway categories to existing tournament_categories
-- ============================================================================

INSERT INTO tournament_categories(category_id, tevo_label, genre, pages_to_pull, notes) VALUES
  (54,   'Concerts',           'concert',          20, 'Parent category; covers all music genres'),
  (1908, 'Broadway Musicals',  'broadway_musical',  5, 'Lion King, Hamilton, Wicked, etc.'),
  (1067, 'Broadway Plays',     'broadway_play',     3, 'Straight plays on Broadway'),
  (998,  'Off-Broadway',       'off_broadway',      3, 'Smaller NYC theatre productions')
ON CONFLICT (category_id) DO NOTHING;

-- ============================================================================
-- (2) v_performer_tours — same performer at ≥2 distinct venues
-- ============================================================================

CREATE OR REPLACE VIEW v_performer_tours AS
WITH future AS (
  SELECT
    e.primary_performer_id,
    e.primary_performer_name,
    e.id AS tevo_event_id,
    e.venue_id, e.venue_name, e.venue_location,
    e.occurs_at_local::date AS event_date
  FROM events e
  WHERE e.primary_performer_id IS NOT NULL
    AND e.primary_performer_name IS NOT NULL
    AND e.occurs_at_local::timestamptz BETWEEN now() - interval '7 days'
                                            AND now() + interval '12 months'
    AND COALESCE(e.event_type, '') NOT IN ('game')
)
SELECT
  primary_performer_id,
  primary_performer_name,
  count(DISTINCT venue_id)              AS venue_count,
  count(*)                              AS show_count,
  min(event_date)                       AS tour_first_show,
  max(event_date)                       AS tour_last_show,
  (max(event_date) - min(event_date))   AS tour_span_days,
  array_agg(DISTINCT venue_name ORDER BY venue_name) AS venues,
  array_agg(DISTINCT coalesce(regexp_replace(venue_location, '^[^,]+,\s*', ''), 'unknown')) AS regions,
  array_agg(tevo_event_id ORDER BY event_date) AS tevo_event_ids
FROM future
GROUP BY primary_performer_id, primary_performer_name
HAVING count(DISTINCT venue_id) >= 2;

COMMENT ON VIEW v_performer_tours IS
  'Performers playing at 2+ distinct venues in the next 12 months. '
  'The "Bruce Springsteen 2026 / Eras Tour" shape. venues array shows '
  'every venue; regions shows state/country grouping. Filter by '
  'primary_performer_id for a single tour, by venue_count for headline '
  'tours (>=10 stops).';

-- ============================================================================
-- (3) v_performer_residencies — same performer at SAME venue, ≥3 dates,
--                               ≥14 day span. Includes Broadway runs.
-- ============================================================================

CREATE OR REPLACE VIEW v_performer_residencies AS
WITH future AS (
  SELECT
    e.primary_performer_id,
    e.primary_performer_name,
    e.id AS tevo_event_id,
    e.venue_id, e.venue_name, e.venue_location,
    e.occurs_at_local::date AS event_date
  FROM events e
  WHERE e.primary_performer_id IS NOT NULL
    AND e.primary_performer_name IS NOT NULL
    AND e.venue_id IS NOT NULL
    AND e.occurs_at_local::timestamptz BETWEEN now() - interval '7 days'
                                            AND now() + interval '24 months'
    AND COALESCE(e.event_type, '') NOT IN ('game')
)
SELECT
  primary_performer_id,
  primary_performer_name,
  venue_id,
  max(venue_name)                       AS venue_name,
  max(venue_location)                   AS venue_location,
  count(*)                              AS show_count,
  min(event_date)                       AS residency_start,
  max(event_date)                       AS residency_end,
  (max(event_date) - min(event_date))   AS residency_span_days,
  array_agg(tevo_event_id ORDER BY event_date) AS tevo_event_ids
FROM future
GROUP BY primary_performer_id, primary_performer_name, venue_id
HAVING count(*) >= 3
   AND (max(event_date) - min(event_date)) >= 14;

COMMENT ON VIEW v_performer_residencies IS
  'Same performer at same venue, 3+ dates, 14+ day span. Catches both '
  'Vegas residencies (U2 at Sphere, Adele at Caesars) and Broadway '
  'long-runs (Lion King at Minskoff). Use v_broadway_runs for the '
  'Broadway-only subset.';

-- ============================================================================
-- (4) v_broadway_runs — residencies at known Broadway theaters
-- ============================================================================

CREATE OR REPLACE VIEW v_broadway_runs AS
SELECT
  r.*,
  -- Pull the Broadway theater "brand" name from important_x_accounts
  (SELECT xa.name FROM important_x_accounts xa
    WHERE xa.account_type = 'broadway_theater'
      AND lower(r.venue_name) LIKE '%' || lower(replace(xa.name, ' Theatre', '')) || '%'
    LIMIT 1) AS broadway_theater_name
FROM v_performer_residencies r
WHERE
  -- Heuristic: known Broadway-theater venues by name match
  r.venue_name ILIKE ANY (ARRAY[
    '%minskoff%','%majestic%','%gershwin%','%lyric%','%shubert%',
    '%palace theatre%','%winter garden%','%new amsterdam%','%st. james%',
    '%st james%','%broadhurst%','%imperial theatre%','%al hirschfeld%',
    '%hirschfeld%','%longacre%','%music box%','%walter kerr%',
    '%belasco%','%friedman%','%booth theatre%','%ethel barrymore%',
    '%richard rodgers%','%neil simon%','%nederlander%','%marquis theatre%',
    '%circle in the square%','%vivian beaumont%','%studio 54%',
    '%lena horne%','%james earl jones%'
  ]);

COMMENT ON VIEW v_broadway_runs IS
  'Broadway-theater-specific residencies. Subset of v_performer_residencies '
  'filtered by venue name match against known Broadway venues. Lion King '
  'at Minskoff, Hamilton at Richard Rodgers, etc.';
