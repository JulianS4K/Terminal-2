-- Bug fix: meta.espn_slug must always be the ESPN SPORT slug (e.g. 'football/nfl',
-- 'basketball/nba', 'soccer/usa.1', 'soccer/fifa.world') because espn fn v2 builds
-- API paths like `/apis/site/v2/sports/${espn_slug}/...`. Migrations 15 & 16 mixed
-- sport-slugs (from tevo-perf-find rows, correct) with team-slugs (from
-- home_venues + manual rows: 'new-england-patriots', 'bra', etc — wrong, ESPN
-- returned a 404 on those calls).
--
-- This migration:
--   1. Preserves any pre-existing team-slug as meta.espn_team_slug (useful for
--      ESPN team-page URLs).
--   2. Overwrites meta.espn_slug with the canonical sport-slug per league.
--
-- Applied to prod 2026-05-07 via MCP. Idempotent (won't reapply if espn_slug
-- already matches the canonical map for the row's league).

with sport_slug_map(league, sport_slug) as (values
  ('NBA','basketball/nba'),
  ('WNBA','basketball/wnba'),
  ('NFL','football/nfl'),
  ('MLB','baseball/mlb'),
  ('NHL','hockey/nhl'),
  ('MLS','soccer/usa.1'),
  ('World Cup','soccer/fifa.world'),
  ('NCAAF','football/college-football'),
  ('NCAAM','basketball/mens-college-basketball')
)
update performer_external_ids pei
set meta = jsonb_set(
  jsonb_set(
    pei.meta,
    '{espn_team_slug}',
    case
      when pei.meta->>'espn_slug' is not null
        and pei.meta->>'espn_slug' not like '%/%'
        and pei.meta->>'espn_slug' <> m.sport_slug
      then to_jsonb(pei.meta->>'espn_slug')
      else coalesce(pei.meta->'espn_team_slug', 'null'::jsonb)
    end
  ),
  '{espn_slug}',
  to_jsonb(m.sport_slug)
)
from sport_slug_map m
where pei.source = 'espn'
  and pei.league = m.league
  and (pei.meta->>'espn_slug' is null or pei.meta->>'espn_slug' <> m.sport_slug);
