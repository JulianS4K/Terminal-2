-- ============================================================================
-- Migration 20260509530000 — Link sporting_rivalries to performer_ids
--                            + v_upcoming_rivalry_games + get_event_context ext
--
-- Per directive (2026-05-09):
--   "match the rivalries to their respective performers in our database"
--   "make an additional query for coworker"
--   "Fanvenues got bought by stubhub so no go there" — venue map doc
--   updated separately to drop Fanvenues recommendation
--
-- This migration:
--   1. Adds team_a_performer_id + team_b_performer_id columns to
--      sporting_rivalries
--   2. Backfills via JOIN to performer_metadata.name with fallbacks for
--      known name variants (LA Clippers / Athletics / LAFC / etc.)
--   3. Rebuilds v_rivalry_events to use performer_id matches first,
--      falling back to name string for completeness
--   4. Adds v_upcoming_rivalry_games — calendar surface for the UI
--   5. Extends get_event_context() with `rivalry` key
-- ============================================================================

-- (1) Schema
ALTER TABLE sporting_rivalries
  ADD COLUMN IF NOT EXISTS team_a_performer_id bigint,
  ADD COLUMN IF NOT EXISTS team_b_performer_id bigint;

CREATE INDEX IF NOT EXISTS sporting_rivalries_perf_a_idx
  ON sporting_rivalries(team_a_performer_id);
CREATE INDEX IF NOT EXISTS sporting_rivalries_perf_b_idx
  ON sporting_rivalries(team_b_performer_id);

-- (2) Backfill — exact match first, then known variants
WITH variants AS (
  SELECT canonical, alias FROM (VALUES
    ('Los Angeles Clippers',   'LA Clippers'),
    ('Oakland Athletics',      'Athletics'),
    ('Atlanta United',         'Atlanta United FC'),
    ('Los Angeles FC',         'LAFC'),
    ('New York Red Bulls',     'Red Bull New York'),
    ('Vancouver Whitecaps FC', 'Vancouver Whitecaps')
  ) AS v(canonical, alias)
)
UPDATE sporting_rivalries sr SET
  team_a_performer_id = COALESCE(
    (SELECT pm.performer_id FROM performer_metadata pm WHERE pm.name = sr.team_a),
    (SELECT pm.performer_id FROM performer_metadata pm
       JOIN variants v ON v.canonical = sr.team_a AND pm.name = v.alias),
    sr.team_a_performer_id
  ),
  team_b_performer_id = COALESCE(
    (SELECT pm.performer_id FROM performer_metadata pm WHERE pm.name = sr.team_b),
    (SELECT pm.performer_id FROM performer_metadata pm
       JOIN variants v ON v.canonical = sr.team_b AND pm.name = v.alias),
    sr.team_b_performer_id
  );

-- (3) Rebuild v_rivalry_events: match by performer_id first (cleaner), name fallback
CREATE OR REPLACE VIEW v_rivalry_events AS
WITH parsed AS (
  SELECT
    e.id AS tevo_event_id, e.name,
    e.occurs_at_local::date AS event_date,
    e.venue_name, e.venue_id,
    e.primary_performer_id AS home_performer_id,
    e.primary_performer_name AS home_team,
    trim(split_part(e.name, ' at ', 1)) AS away_team
  FROM events e
  WHERE e.event_type = 'game'
    AND e.name ILIKE '% at %'
    AND e.primary_performer_name IS NOT NULL
)
SELECT DISTINCT
  p.tevo_event_id, p.name, p.event_date, p.venue_name, p.venue_id,
  p.home_team, p.away_team, p.home_performer_id,
  sr.rivalry_name, sr.league, sr.is_branded, sr.rivalry_intensity,
  sr.wikipedia_url, sr.notes
FROM parsed p
JOIN sporting_rivalries sr
  ON (
    -- performer-id match (preferred)
    (sr.team_a_performer_id = p.home_performer_id
       AND lower(p.away_team) = lower(sr.team_b))
    OR (sr.team_b_performer_id = p.home_performer_id
       AND lower(p.away_team) = lower(sr.team_a))
    -- name match fallback (case-insensitive, handles unmapped variants)
    OR (lower(sr.team_a) = lower(p.home_team) AND lower(sr.team_b) = lower(p.away_team))
    OR (lower(sr.team_b) = lower(p.home_team) AND lower(sr.team_a) = lower(p.away_team))
  );

COMMENT ON VIEW v_rivalry_events IS
  'Events that match a known rivalry. Matches by performer_id when both '
  'sides have IDs in sporting_rivalries (set via mig 530000), falls back '
  'to case-insensitive name match. Use to overlay "Rivalry Game" badges '
  'on event UI surfaces.';

-- (4) New view — upcoming rivalry games for the UI
CREATE OR REPLACE VIEW v_upcoming_rivalry_games AS
SELECT
  re.tevo_event_id,
  re.name AS event_name,
  re.event_date,
  re.venue_name,
  re.home_team,
  re.away_team,
  re.rivalry_name,
  re.league,
  re.is_branded,
  re.rivalry_intensity,
  re.wikipedia_url,
  -- Pricing + signal at-a-glance
  lem.tickets_count,
  lem.getin_price,
  lem.retail_median,
  -- Known X-account count for the home performer
  (SELECT count(*) FROM important_x_accounts xa
    WHERE xa.team_name = re.home_team) AS x_accounts_home,
  -- Has Reddit-pulse data?
  EXISTS(SELECT 1 FROM v_performer_reddit_pulse vrp
          WHERE vrp.tevo_performer_id = re.home_performer_id) AS has_reddit_pulse
FROM v_rivalry_events re
LEFT JOIN latest_event_metrics lem ON lem.event_id = re.tevo_event_id
WHERE re.event_date >= current_date
ORDER BY re.event_date;

COMMENT ON VIEW v_upcoming_rivalry_games IS
  'Calendar surface: every upcoming rivalry game with at-a-glance pricing '
  '(getin / median / tickets_count) + signal availability flags '
  '(x_accounts_home, has_reddit_pulse). Default landing for any '
  '"hot rivalry games" widget.';

-- (5) Extend get_event_context() with rivalry key
CREATE OR REPLACE FUNCTION get_event_context(p_event_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_event jsonb; v_pricing jsonb; v_espn jsonb; v_performer jsonb;
  v_weather jsonb; v_competitors jsonb; v_orders jsonb;
  v_odds jsonb; v_reddit jsonb; v_news jsonb; v_x jsonb; v_rivalry jsonb;
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

  -- important_news
  SELECT jsonb_agg(jsonb_build_object(
           'title', vn.title, 'subreddit', vn.subreddit,
           'created_utc', vn.created_utc, 'url', vn.url,
           'matched', vn.keyword_match->'hits',
           'categories', vn.keyword_match->'categories'
         ) ORDER BY vn.created_utc DESC) INTO v_news
  FROM (SELECT * FROM v_reddit_important_recent ORDER BY created_utc DESC LIMIT 10) vn
  JOIN events e ON e.primary_performer_id = vn.tevo_performer_id
  WHERE e.id = p_event_id;

  -- x_accounts_known
  SELECT jsonb_build_object(
           'team_known', count(*) FILTER (WHERE account_type = 'team_official'),
           'beat_reporters_known', count(*) FILTER (WHERE account_type = 'beat_reporter'),
           'league_known', count(*) FILTER (WHERE account_type = 'league_official'),
           'insiders_total', (SELECT count(*) FROM important_x_accounts WHERE account_type = 'insider')
         ) INTO v_x
  FROM important_x_accounts xa
  JOIN events e ON e.primary_performer_name = xa.team_name WHERE e.id = p_event_id;

  -- NEW: rivalry context (if event matches a known rivalry)
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
    'our_orders', COALESCE(v_orders, jsonb_build_object('present', false)),
    'generated_at', now()
  );
END; $$;
