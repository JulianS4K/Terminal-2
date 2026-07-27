-- ESPN player game logs (per-game box-score lines) — the fantasy scoring
-- primitive + the data behind terminal player-detail pages.
--
-- Source: site.web.api.espn.com/apis/common/v3/sports/{sport}/{league}/athletes/
--   {athleteId}/gamelog. Verified live 2026-07-04 (Jalen Brunson, id 3934672):
--   { labels:["MIN",...,"PTS"], names:[...],
--     seasonTypes:[{ displayName, categories:[{ type:"event",
--       events:[{ eventId, stats:[...] }] }] }],
--     events:{ "{eventId}": { gameDate, atVs, gameResult, score, team{abbreviation},
--       opponent{abbreviation}, ... } } }
--
-- One row per (athlete, league, game). stats keyed by label (PTS, REB, MIN, FG…),
-- stats_num = the numeric subset (made-attempted strings like "14-27" stay in
-- stats only). CURRENT-snapshot bulk upsert (a game line is immutable once final,
-- but re-scoring an in-progress game upserts in place).
--
-- Ingested by the batched, staleness-rotating espn-league-collect ?scope=gamelog
-- worker (athlete list sourced from espn_athletes, all 4 requested leagues).

create table if not exists espn_player_gamelog (
  espn_athlete_id  text not null,
  espn_league      text not null,
  espn_event_id    text not null,
  game_date        timestamptz,
  season_type      text,
  opponent_abbr    text,
  home_away        text,          -- 'vs' | '@'
  result           text,          -- 'W' | 'L'
  score            text,
  team_abbr        text,
  athlete_name     text,
  stats            jsonb,         -- { "PTS":"45","REB":"3","MIN":"41","FG":"14-27", ... }
  stats_num        jsonb,         -- numeric subset keyed by label
  content_hash     text,
  first_seen_at    timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  meta             jsonb,
  primary key (espn_athlete_id, espn_league, espn_event_id)
);
alter table espn_player_gamelog enable row level security;
create index if not exists idx_espn_gl_athlete_date on espn_player_gamelog (espn_athlete_id, espn_league, game_date desc);
create index if not exists idx_espn_gl_league_date on espn_player_gamelog (espn_league, game_date desc);
create index if not exists idx_espn_gl_updated on espn_player_gamelog (updated_at);

comment on table espn_player_gamelog is
  'ESPN per-game box-score lines (fantasy scoring primitive + player-page data). One row per athlete per game; stats keyed by ESPN label. Written by espn-league-collect ?scope=gamelog.';

-- Read helper: a player's recent game log for the terminal player page.
create or replace function get_espn_player_gamelog(p_athlete_id text, p_league text, p_limit int default 25)
returns table (espn_event_id text, game_date timestamptz, season_type text,
               opponent_abbr text, home_away text, result text, score text, stats jsonb)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select espn_event_id, game_date, season_type, opponent_abbr, home_away, result, score, stats
  from public.espn_player_gamelog
  where espn_athlete_id = p_athlete_id and espn_league = p_league
  order by game_date desc nulls last
  limit greatest(1, least(coalesce(p_limit, 25), 200));
$$;

comment on function get_espn_player_gamelog is
  'Recent per-game box-score lines for an ESPN athlete (terminal player page / fantasy).';

-- Staleness-rotation batch selector for the gamelog worker: the least-recently-
-- synced active athletes across the requested leagues (never-synced first). The
-- worker writes a marker row per athlete each pass so staleness always advances.
create or replace function espn_gamelog_next_batch(p_leagues text[], p_limit int default 100)
returns table (espn_athlete_id text, espn_league text, full_name text)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select a.espn_athlete_id, a.espn_league, a.full_name
  from public.espn_athletes a
  left join lateral (
    select max(updated_at) mu from public.espn_player_gamelog g
    where g.espn_athlete_id = a.espn_athlete_id and g.espn_league = a.espn_league
  ) g on true
  where a.espn_league = any(p_leagues) and coalesce(a.status,'') <> 'released'
  order by g.mu asc nulls first, a.espn_athlete_id
  limit greatest(1, least(coalesce(p_limit,100), 400));
$$;
comment on function espn_gamelog_next_batch is
  'Least-recently-synced active athletes for the gamelog worker (staleness rotation).';
