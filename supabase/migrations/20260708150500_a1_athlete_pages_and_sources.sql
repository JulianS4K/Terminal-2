-- ============================================================================
-- Migration 20260708150000 — Athlete pages + source map
--
-- Lane:     data plane (A1)
-- Touches:  athlete_pages (new: one canonical "page" per athlete)
--           athlete_external_ids (new: athlete -> each source feed they appear in)
--           build_athlete_pages() (new: (re)build both from the espn_* feeds)
--
-- Operator directive (2026-07-08): "first create pages for each athlete, map to
--   their respective sources and then map wiki where available." This migration
--   is steps 1-2: a canonical athlete registry (the athlete analog of a performer
--   page) plus a per-source coverage map. Step 3 (Wikipedia) is 20260708151000.
--
-- Athletes are ESPN-sourced (no TEvo/SG athlete identity), so espn_athlete_id is
-- the canonical key — mirroring how performer pages key on the primary source's
-- id (tevo_performer_id). Pages are seeded from espn_athletes (rich bio, 8.9k)
-- plus name-only rows for any athlete that appears only in the stats feed.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) athlete_pages — canonical entity, one row per athlete
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS athlete_pages (
  espn_athlete_id   text PRIMARY KEY,
  espn_league       text,
  full_name         text,
  display_name      text,
  short_name        text,
  position          text,
  position_abbr     text,
  jersey            text,
  height_inches     integer,
  weight_lbs        integer,
  birth_date        date,
  age               integer,
  espn_team_id      text,
  status            text,
  experience_years  integer,
  headshot_url      text,
  -- source coverage flags (which feeds carry data for this athlete)
  has_bio           boolean DEFAULT false,
  has_gamelog       boolean DEFAULT false,
  has_stats         boolean DEFAULT false,
  has_brand         boolean DEFAULT false,
  has_team_history  boolean DEFAULT false,
  first_seen_at     timestamptz DEFAULT now(),
  updated_at        timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS athlete_pages_league_idx ON athlete_pages(espn_league);
CREATE INDEX IF NOT EXISTS athlete_pages_name_idx   ON athlete_pages(lower(full_name));
GRANT SELECT ON athlete_pages TO anon;

-- ----------------------------------------------------------------------------
-- (2) athlete_external_ids — map each athlete to every source feed carrying them
--     (source = espn | espn_gamelog | espn_stats | espn_team_history |
--      fantasy_roster | espn_brand). external_name captures the per-feed name
--      variant (they can differ across feeds).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS athlete_external_ids (
  espn_athlete_id  text NOT NULL REFERENCES athlete_pages(espn_athlete_id) ON DELETE CASCADE,
  source           text NOT NULL,
  external_id      text,
  external_name    text,
  espn_league      text,
  meta             jsonb DEFAULT '{}'::jsonb,
  set_at           timestamptz DEFAULT now(),
  PRIMARY KEY (espn_athlete_id, source)
);
CREATE INDEX IF NOT EXISTS athlete_external_ids_source_idx ON athlete_external_ids(source);
GRANT SELECT ON athlete_external_ids TO anon;

-- ----------------------------------------------------------------------------
-- (3) build_athlete_pages() — (re)build pages + source map from the feeds
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION build_athlete_pages()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows integer;
BEGIN
  -- 3a. Upsert rich bio pages from espn_athletes
  INSERT INTO athlete_pages (espn_athlete_id, espn_league, full_name, display_name, short_name,
    position, position_abbr, jersey, height_inches, weight_lbs, birth_date, age, espn_team_id,
    status, experience_years, headshot_url, has_bio, updated_at)
  SELECT espn_athlete_id, espn_league, full_name, display_name, short_name,
         position, position_abbr, jersey, height_inches, weight_lbs, birth_date, age, espn_team_id,
         status, experience_years, headshot_url, true, now()
  FROM espn_athletes
  ON CONFLICT (espn_athlete_id) DO UPDATE SET
    espn_league=EXCLUDED.espn_league, full_name=EXCLUDED.full_name, display_name=EXCLUDED.display_name,
    short_name=EXCLUDED.short_name, position=EXCLUDED.position, position_abbr=EXCLUDED.position_abbr,
    jersey=EXCLUDED.jersey, height_inches=EXCLUDED.height_inches, weight_lbs=EXCLUDED.weight_lbs,
    birth_date=EXCLUDED.birth_date, age=EXCLUDED.age, espn_team_id=EXCLUDED.espn_team_id,
    status=EXCLUDED.status, experience_years=EXCLUDED.experience_years, headshot_url=EXCLUDED.headshot_url,
    has_bio=true, updated_at=now();

  -- 3b. Name-only pages for athletes that appear only in the stats feed
  INSERT INTO athlete_pages (espn_athlete_id, espn_league, full_name, display_name, position, updated_at)
  SELECT DISTINCT ON (s.espn_athlete_id)
         s.espn_athlete_id, s.espn_league, s.athlete_name, s.athlete_name, s.position, now()
  FROM espn_player_stats s
  WHERE NOT EXISTS (SELECT 1 FROM athlete_pages p WHERE p.espn_athlete_id = s.espn_athlete_id)
  ORDER BY s.espn_athlete_id, s.updated_at DESC NULLS LAST
  ON CONFLICT (espn_athlete_id) DO NOTHING;

  -- 3c. Refresh source-coverage flags
  UPDATE athlete_pages p SET
    has_gamelog      = EXISTS (SELECT 1 FROM espn_player_gamelog g       WHERE g.espn_athlete_id = p.espn_athlete_id),
    has_stats        = EXISTS (SELECT 1 FROM espn_player_stats s         WHERE s.espn_athlete_id = p.espn_athlete_id),
    has_brand        = EXISTS (SELECT 1 FROM espn_athlete_brand b        WHERE b.espn_athlete_id = p.espn_athlete_id),
    has_team_history = EXISTS (SELECT 1 FROM espn_athlete_team_history t WHERE t.espn_athlete_id = p.espn_athlete_id),
    updated_at = now();

  -- 3d. Rebuild the source map (one row per athlete x feed present).
  --     Filtered to athletes that have a page so the FK never trips on a feed-
  --     only athlete (e.g. a team_history row with no bio/stats/gamelog).
  DELETE FROM athlete_external_ids;
  INSERT INTO athlete_external_ids (espn_athlete_id, source, external_id, external_name, espn_league, meta)
  SELECT m.espn_athlete_id, m.source, m.external_id, m.external_name, m.espn_league, m.meta
  FROM (
      SELECT espn_athlete_id, 'espn'::text AS source, espn_athlete_id AS external_id,
             COALESCE(display_name, full_name) AS external_name, espn_league,
             jsonb_build_object('headshot_url', headshot_url, 'position', position_abbr) AS meta
        FROM espn_athletes
    UNION ALL
      SELECT espn_athlete_id, 'espn_gamelog', espn_athlete_id, max(athlete_name), max(espn_league), '{}'::jsonb
        FROM espn_player_gamelog GROUP BY espn_athlete_id
    UNION ALL
      SELECT espn_athlete_id, 'espn_stats', espn_athlete_id, max(athlete_name), max(espn_league), '{}'::jsonb
        FROM espn_player_stats GROUP BY espn_athlete_id
    UNION ALL
      SELECT espn_athlete_id, 'espn_team_history', espn_athlete_id, NULL, max(espn_league), '{}'::jsonb
        FROM espn_athlete_team_history GROUP BY espn_athlete_id
    UNION ALL
      SELECT espn_athlete_id, 'fantasy_roster', espn_athlete_id, NULL, max(espn_league), '{}'::jsonb
        FROM fantasy_rosters GROUP BY espn_athlete_id
    UNION ALL
      SELECT espn_athlete_id, 'espn_brand', espn_athlete_id, athlete_name, espn_league,
             jsonb_build_object('league_rank', league_rank, 'brand_score', brand_score)
        FROM espn_athlete_brand
  ) m
  WHERE EXISTS (SELECT 1 FROM athlete_pages p WHERE p.espn_athlete_id = m.espn_athlete_id)
  ON CONFLICT (espn_athlete_id, source) DO NOTHING;

  SELECT count(*) INTO v_rows FROM athlete_pages;
  RETURN v_rows;
END $$;

SELECT build_athlete_pages();
