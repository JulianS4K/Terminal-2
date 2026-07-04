-- Fantasy league domain model + scoring engine (v1).
--
-- Builds on the ESPN pipelines: player identity (espn_athletes / espn_player_stats)
-- and the per-game scoring primitive (espn_player_gamelog, mig 20260704060000).
-- This migration adds the app schema (rulesets, leagues, teams, rosters, matchups)
-- and the scoring function that turns a game-log line into fantasy points.
--
-- Scoring model: a ruleset is a jsonb map of ESPN stat LABEL -> points-per-unit
-- (keys match espn_player_gamelog.stats keys for that sport, e.g. NBA "PTS":1,
-- "REB":1.2, "AST":1.5, "STL":3, "BLK":3, "TO":-1). fantasy_gamelog_points()
-- multiplies each rule by the player's stat and sums. A team's score for a period
-- sums its STARTERS' game-log points over that period.
--
-- Not yet included (follow-ups): draft, waivers/free-agency, trades, in-season
-- lineup locks, live scoring, projections, standings rollups, and the UI. This is
-- the data + scoring foundation.

-- ---- scoring rulesets --------------------------------------------------------
create table if not exists fantasy_scoring_rulesets (
  id          bigserial primary key,
  name        text not null,
  sport       text not null,                 -- 'basketball' | 'baseball' | ...
  rules       jsonb not null,                -- { "<stat_label>": <points_per_unit> }
  is_default  boolean default false,
  created_at  timestamptz not null default now()
);
alter table fantasy_scoring_rulesets enable row level security;

-- ---- leagues -----------------------------------------------------------------
create table if not exists fantasy_leagues (
  id            bigserial primary key,
  name          text not null,
  espn_league   text not null,               -- 'NBA' | 'MLB' | 'NFL' | 'WNBA'
  ruleset_id    bigint references fantasy_scoring_rulesets(id),
  roster_size   int not null default 10,
  starters      int not null default 5,
  owner_email   text,
  settings      jsonb not null default '{}'::jsonb,
  created_at    timestamptz not null default now()
);
alter table fantasy_leagues enable row level security;

-- ---- fantasy teams (the managers) -------------------------------------------
create table if not exists fantasy_teams (
  id            bigserial primary key,
  league_id     bigint not null references fantasy_leagues(id) on delete cascade,
  team_name     text not null,
  manager_email text,
  created_at    timestamptz not null default now()
);
alter table fantasy_teams enable row level security;
create index if not exists idx_fantasy_teams_league on fantasy_teams (league_id);

-- ---- rosters (athletes on a fantasy team) -----------------------------------
create table if not exists fantasy_rosters (
  id               bigserial primary key,
  fantasy_team_id  bigint not null references fantasy_teams(id) on delete cascade,
  espn_athlete_id  text not null,
  espn_league      text not null,
  slot             text not null default 'bench',   -- 'starter' | 'bench'
  acquired_at      timestamptz not null default now(),
  unique (fantasy_team_id, espn_athlete_id)
);
alter table fantasy_rosters enable row level security;
create index if not exists idx_fantasy_rosters_team on fantasy_rosters (fantasy_team_id);
create index if not exists idx_fantasy_rosters_athlete on fantasy_rosters (espn_athlete_id, espn_league);

-- ---- head-to-head matchups ---------------------------------------------------
create table if not exists fantasy_matchups (
  id            bigserial primary key,
  league_id     bigint not null references fantasy_leagues(id) on delete cascade,
  week          int,
  period_start  date not null,
  period_end    date not null,
  home_team_id  bigint references fantasy_teams(id) on delete cascade,
  away_team_id  bigint references fantasy_teams(id) on delete cascade,
  home_points   numeric,
  away_points   numeric,
  status        text not null default 'scheduled',   -- 'scheduled' | 'final'
  created_at    timestamptz not null default now()
);
alter table fantasy_matchups enable row level security;
create index if not exists idx_fantasy_matchups_league on fantasy_matchups (league_id, period_start);

-- ---- scoring engine ----------------------------------------------------------
-- Points for a single game-log line under a ruleset. Sums points_per * stat for
-- every rule whose stat label is present + numeric in the line.
create or replace function fantasy_gamelog_points(p_stats jsonb, p_rules jsonb)
returns numeric language sql immutable as $$
  select coalesce(sum(
    (p_rules->>k)::numeric
    * case when (p_stats->>k) ~ '^-?[0-9]+(\.[0-9]+)?$' then (p_stats->>k)::numeric else 0 end
  ), 0)::numeric
  from jsonb_object_keys(p_rules) k
  where p_stats ? k;
$$;
comment on function fantasy_gamelog_points is
  'Fantasy points for one game-log line under a ruleset (label->points_per map).';

-- A fantasy team's total points over a period: sum of its STARTERS'
-- game-log points, using the league's ruleset. Returns per-player + team total.
create or replace function fantasy_team_score(p_team_id bigint, p_start date, p_end date)
returns table (espn_athlete_id text, athlete_name text, games int, points numeric)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  with lg as (
    select l.espn_league, rs.rules
    from fantasy_teams t
    join fantasy_leagues l on l.id = t.league_id
    left join fantasy_scoring_rulesets rs on rs.id = l.ruleset_id
    where t.id = p_team_id
  ),
  starters as (
    select r.espn_athlete_id, r.espn_league
    from fantasy_rosters r
    where r.fantasy_team_id = p_team_id and r.slot = 'starter'
  )
  select g.espn_athlete_id,
         max(g.athlete_name) as athlete_name,
         count(*)::int as games,
         coalesce(sum(fantasy_gamelog_points(g.stats, (select rules from lg))), 0)::numeric as points
  from starters s
  join lg on true
  join espn_player_gamelog g
    on g.espn_athlete_id = s.espn_athlete_id
   and g.espn_league = lg.espn_league
   and g.espn_event_id <> 'none'
   and g.game_date::date between p_start and p_end
  group by g.espn_athlete_id
  order by points desc;
$$;
comment on function fantasy_team_score is
  'Per-starter + total fantasy points for a team over a date range (from espn_player_gamelog).';

-- ---- seed default rulesets ---------------------------------------------------
-- NBA/WNBA standard-ish points league (labels match espn_player_gamelog).
insert into fantasy_scoring_rulesets (name, sport, rules, is_default)
select 'NBA Standard Points', 'basketball',
  '{"PTS":1,"REB":1.2,"AST":1.5,"STL":3,"BLK":3,"TO":-1}'::jsonb, true
where not exists (select 1 from fantasy_scoring_rulesets where name = 'NBA Standard Points');
