-- 20260508140000_espn_team_and_venue_assets.sql
-- Captured from prod (copilot, applied as version 20260508184642).
-- Captured into git 2026-05-08 by code via audit-and-commit (proxy-commit
-- protocol — copilot has no direct git push).
--
-- Adds infrastructure for team logos/colors + venue hero images + venue maps
-- so future UI surfaces can render rich assets. Includes:
--   - 14 new columns on performer_metadata (espn_team_id, colors, multiple
--     logo URLs, espn_team_url / roster / schedule URLs, raw JSON, fetched_at)
--   - venue_assets table (hero / map / capacity / city / state / indoor flag)
--   - v_event_seating_chart view joining events ⇄ venue_assets ⇄ performer_metadata
--   - 3 public RPCs: get_event_assets_public, get_performer_assets_public,
--     get_venue_assets_public
--   - espn_asset_crawl_state queue table seeded with 6 leagues' performers
--     for async ESPN logo/color fetching by a future edge fn.

ALTER TABLE performer_metadata
  ADD COLUMN IF NOT EXISTS espn_team_id        text,
  ADD COLUMN IF NOT EXISTS espn_league         text,
  ADD COLUMN IF NOT EXISTS color_primary       text,
  ADD COLUMN IF NOT EXISTS color_alternate     text,
  ADD COLUMN IF NOT EXISTS logo_default_url    text,
  ADD COLUMN IF NOT EXISTS logo_dark_url       text,
  ADD COLUMN IF NOT EXISTS logo_scoreboard_url text,
  ADD COLUMN IF NOT EXISTS logo_4k_primary_url text,
  ADD COLUMN IF NOT EXISTS logo_secondary_url  text,
  ADD COLUMN IF NOT EXISTS espn_team_url       text,
  ADD COLUMN IF NOT EXISTS espn_roster_url     text,
  ADD COLUMN IF NOT EXISTS espn_schedule_url   text,
  ADD COLUMN IF NOT EXISTS espn_raw            jsonb,
  ADD COLUMN IF NOT EXISTS espn_fetched_at     timestamptz;

CREATE INDEX IF NOT EXISTS idx_performer_metadata_espn_team_id
  ON performer_metadata(espn_team_id) WHERE espn_team_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS venue_assets (
  tevo_venue_id    bigint PRIMARY KEY,
  venue_name       text,
  espn_venue_id    text,
  espn_venue_name  text,
  hero_image_url   text,
  map_image_url    text,
  capacity         integer,
  city             text,
  state            text,
  country          text,
  is_indoor        boolean,
  espn_raw         jsonb,
  source           text DEFAULT 'espn',
  fetched_at       timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_venue_assets_espn_venue_id
  ON venue_assets(espn_venue_id) WHERE espn_venue_id IS NOT NULL;

ALTER TABLE venue_assets ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS venue_assets_anon_read ON venue_assets;
CREATE POLICY venue_assets_anon_read ON venue_assets FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS venue_assets_service_all ON venue_assets;
CREATE POLICY venue_assets_service_all ON venue_assets FOR ALL TO service_role USING (true) WITH CHECK (true);
GRANT SELECT ON venue_assets TO anon, authenticated;
GRANT ALL ON venue_assets TO service_role;

DROP VIEW IF EXISTS v_event_seating_chart CASCADE;
CREATE VIEW v_event_seating_chart AS
SELECT
  e.id AS event_id,
  e.name AS event_name,
  e.occurs_at_local,
  e.venue_id,
  e.venue_name,
  e.venue_location,
  e.configuration_id,
  e.configuration_name,
  CASE WHEN e.seating_chart_medium IS NULL OR e.seating_chart_medium = 'null'
       THEN NULL ELSE e.seating_chart_medium END AS seating_chart_medium,
  CASE WHEN e.seating_chart_large IS NULL OR e.seating_chart_large = 'null'
       THEN NULL ELSE e.seating_chart_large END AS seating_chart_large,
  e.fanvenues_key,
  va.hero_image_url   AS venue_hero_url,
  va.map_image_url    AS venue_map_url,
  va.capacity         AS venue_capacity,
  va.is_indoor        AS venue_is_indoor,
  e.primary_performer_id,
  e.primary_performer_name,
  pm.color_primary    AS team_color_primary,
  pm.color_alternate  AS team_color_alternate,
  pm.logo_default_url AS team_logo_url,
  pm.logo_dark_url    AS team_logo_dark_url,
  pm.espn_team_url    AS team_espn_url,
  (CASE WHEN e.seating_chart_medium IS NULL OR e.seating_chart_medium = 'null'
        THEN false ELSE true END)  AS has_seating_chart,
  (va.hero_image_url IS NOT NULL)  AS has_venue_hero,
  (va.map_image_url IS NOT NULL)   AS has_venue_map,
  (pm.logo_default_url IS NOT NULL) AS has_team_logo
FROM events e
LEFT JOIN venue_assets va        ON va.tevo_venue_id = e.venue_id
LEFT JOIN performer_metadata pm  ON pm.performer_id  = e.primary_performer_id;

GRANT SELECT ON v_event_seating_chart TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION get_event_assets_public(p_event_id bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT to_jsonb(v) FROM v_event_seating_chart v WHERE v.event_id = p_event_id;
$$;
GRANT EXECUTE ON FUNCTION get_event_assets_public(bigint) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION get_performer_assets_public(p_performer_id bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT jsonb_build_object(
    'performer_id', performer_id, 'name', name, 'slug', slug,
    'genre', genre, 'event_type', what_event_type,
    'popularity', popularity_score, 's4k_boost', s4k_popularity_boost,
    'espn_team_id', espn_team_id, 'espn_league', espn_league,
    'color_primary', color_primary, 'color_alternate', color_alternate,
    'logo_default_url', logo_default_url, 'logo_dark_url', logo_dark_url,
    'logo_scoreboard_url', logo_scoreboard_url,
    'logo_4k_primary_url', logo_4k_primary_url,
    'logo_secondary_url', logo_secondary_url,
    'espn_team_url', espn_team_url, 'espn_roster_url', espn_roster_url,
    'espn_schedule_url', espn_schedule_url, 'fetched_at', espn_fetched_at
  )
  FROM performer_metadata WHERE performer_id = p_performer_id;
$$;
GRANT EXECUTE ON FUNCTION get_performer_assets_public(bigint) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION get_venue_assets_public(p_venue_id bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT to_jsonb(va) FROM venue_assets va WHERE va.tevo_venue_id = p_venue_id;
$$;
GRANT EXECUTE ON FUNCTION get_venue_assets_public(bigint) TO anon, authenticated, service_role;

CREATE TABLE IF NOT EXISTS espn_asset_crawl_state (
  performer_id     bigint PRIMARY KEY,
  espn_team_id     text NOT NULL,
  espn_league      text NOT NULL,
  status           text NOT NULL DEFAULT 'pending',
  last_fetched_at  timestamptz,
  last_error       text,
  retries          integer DEFAULT 0
);

GRANT ALL ON espn_asset_crawl_state TO service_role;
GRANT SELECT ON espn_asset_crawl_state TO anon, authenticated;

INSERT INTO espn_asset_crawl_state (performer_id, espn_team_id, espn_league, status)
SELECT performer_id, external_id, league, 'pending'
FROM performer_external_ids
WHERE source = 'espn'
  AND league IN ('NBA','WNBA','MLB','NHL','NFL','MLS')
ON CONFLICT (performer_id) DO NOTHING;
