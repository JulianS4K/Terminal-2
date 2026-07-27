-- ESPN player statistics pipeline (slice 3 of the "more ESPN pipelines" work).
--
-- Source: site.web.api.espn.com/apis/common/v3/sports/{sport}/{league}/statistics/
--   byathlete?category={cat}&isqualified=false&page=N&limit=50
--   -> { pagination{count,pages}, categories:[{name, names[], displayNames[]}],
--        athletes:[{ athlete{id,displayName,position}, categories:[{name,
--        totals[](display), values[](numeric)}] }] }
--   Verified live 2026-07-04: MLB batting 589 / NBA 230 / WNBA 209 (full roster).
--
-- Leagues + categories (sport-specific): MLB=[batting,pitching] (2 calls, one
-- category each), NBA/WNBA=[general] (one call returns general/offensive/
-- defensive categories merged). Full roster via pagination (isqualified=false).
--
-- CURRENT-SNAPSHOT table (one row per athlete/league/category, upserted in place)
-- rather than append-only history: stats are wide + high-volume (~1.8k athletes),
-- so a bulk upsert keyed on the PK keeps ingest fast and storage bounded. stats =
-- display strings (".336"), stats_num = numeric values, both keyed by ESPN's stat
-- `names`. Ingested by espn-league-collect ?scope=stats.

create table if not exists espn_player_stats (
  espn_athlete_id  text not null,
  espn_league      text not null,
  category         text not null,
  season           int,
  athlete_name     text,
  position         text,
  team_abbr        text,
  stats            jsonb,
  stats_num        jsonb,
  content_hash     text,
  first_seen_at    timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  meta             jsonb,
  primary key (espn_athlete_id, espn_league, category)
);
alter table espn_player_stats enable row level security;
create index if not exists idx_espn_pstats_league_cat on espn_player_stats (espn_league, category);
create index if not exists idx_espn_pstats_name on espn_player_stats (lower(athlete_name));

comment on table espn_player_stats is
  'ESPN full-roster player statistics (current season snapshot, upserted in place). stats=display strings, stats_num=numeric, keyed by ESPN stat names. Written by espn-league-collect ?scope=stats.';

-- Read helper for the terminal: top-N leaders in a league/category by a stat key.
create or replace function get_espn_stat_leaders(
  p_league text, p_category text, p_stat text, p_desc boolean default true, p_limit int default 25)
returns table (espn_athlete_id text, athlete_name text, "position" text, team_abbr text,
               stat_value numeric, stat_display text, season int)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select espn_athlete_id, athlete_name, position, team_abbr,
         (stats_num->>p_stat)::numeric as stat_value,
         coalesce(nullif(nullif(stats->>p_stat, '-'), '--'), stats_num->>p_stat) as stat_display, season
  from public.espn_player_stats
  where espn_league = p_league and category = p_category
    and stats_num ? p_stat and (stats_num->>p_stat) ~ '^-?[0-9.]+$'
  order by (stats_num->>p_stat)::numeric * (case when p_desc then -1 else 1 end)
  limit greatest(1, least(coalesce(p_limit,25), 200));
$$;

comment on function get_espn_stat_leaders is
  'Top-N ESPN player-stat leaders for a league/category sorted by a stat key (from espn_player_stats).';
