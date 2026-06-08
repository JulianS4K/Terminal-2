-- Migration 20260608210000 · lane:D0 (Fantasy feature, Phase 1) → PENDING operator apply · writes:player_game_stats + athlete_external_ids tables (+ RLS + read RPCs) · reads:espn_athletes / espn_teams_canonical / performer_espn_team_xref
--
-- ## NOT YET APPLIED TO PROD — authored as a file only (CLAUDE.md lockdown rule 1).
--
-- Phase 1 of the Fantasy League feature: the PLAYER-STATS DATA FOUNDATION.
--
-- The existing ESPN layer is team-level only (espn_event_snapshots = scores;
-- espn_team_snapshots = standings). There are NO per-player box-score stat
-- lines anywhere, so real fantasy scoring has no source. This migration adds:
--
--   1. player_game_stats   — normalized per-player, per-game box-score lines,
--                             league-agnostic (one table serves NFL/NBA/MLB/
--                             NHL/WNBA). Populated by fantasy_ingest.py from the
--                             open-source `sportsdataverse` packages. Bridged to
--                             espn_athletes via espn_athlete_id.
--   2. athlete_external_ids — player-level crosswalk, mirroring the existing
--                             performer_external_ids (team-level) pattern. Maps
--                             a source-native player id (sportsdataverse / MLBAM)
--                             to the canonical espn_athletes.espn_athlete_id.
--
-- Crosswalk strategy (reuses the canonical mappers, no ad-hoc name matching):
--   * TEAM:   NFL/NBA/NHL/WNBA sportsdataverse feeds carry the ESPN team id
--             natively → validate against espn_teams_canonical /
--             performer_espn_team_xref (always carrying espn_league, since
--             espn_team_id is LEAGUE-SCOPED — id 18 = NBA Knicks AND MLB
--             Pirates AND NFL Saints). MLB (MLBAM ids) resolves by abbr/name
--             against espn_teams_canonical.
--   * PLAYER: NFL/NBA/NHL/WNBA carry the espn athlete id natively → direct
--             insert into athlete_external_ids. MLB resolves by
--             (name + resolved espn_team_id + league) against espn_athletes;
--             unresolved rows keep the MLBAM id with espn_athlete_id NULL.
--
-- These tables are reference data (not user-owned): RLS grants read to
-- `authenticated`; writes happen only via the service_role ingest job.

begin;

-- ----------------------------------------------------------------------------
-- 1. athlete_external_ids — player-level source crosswalk
--    (parallel to performer_external_ids, which is team-level)
-- ----------------------------------------------------------------------------
create table if not exists public.athlete_external_ids (
  source          text not null,                  -- 'sportsdataverse' | 'mlbam' | 'espn' | ...
  external_id     text not null,                  -- source-native player id
  league          text not null,                  -- NFL | NBA | MLB | NHL | WNBA (league-scoped)
  espn_athlete_id text,                            -- → espn_athletes.espn_athlete_id (NULL until resolved)
  external_name   text,                            -- source-native player name (for audit / MLB reconciliation)
  espn_team_id    text,                            -- resolved team (paired with league per the scoping rule)
  match_method    text,                            -- 'native_espn_id' | 'name_team' | 'manual'
  meta            jsonb not null default '{}'::jsonb,
  set_at          timestamptz not null default now(),
  primary key (source, external_id, league)
);
comment on table public.athlete_external_ids is
  'Player-level cross-source id map: source-native player id (sportsdataverse / MLBAM) -> canonical espn_athletes.espn_athlete_id. Mirrors performer_external_ids (team level). Fantasy Phase 1 (mig 20260608210000). espn_team_id is league-scoped: always read with league.';
create index if not exists athlete_external_ids_espn_idx
  on public.athlete_external_ids (espn_athlete_id, league) where espn_athlete_id is not null;
create index if not exists athlete_external_ids_name_idx
  on public.athlete_external_ids (lower(external_name));

-- ----------------------------------------------------------------------------
-- 2. player_game_stats — normalized per-player per-game box scores
-- ----------------------------------------------------------------------------
create table if not exists public.player_game_stats (
  id               bigint generated always as identity primary key,
  source           text not null default 'sportsdataverse',
  league           text not null check (league in ('NFL','NBA','MLB','NHL','WNBA')),
  -- player identity
  espn_athlete_id  text,                            -- bridge to espn_athletes (resolved via athlete_external_ids; NULL if unresolved)
  sdv_player_id    text not null,                   -- source-native player id (join key for MLB reconciliation)
  player_name      text,
  -- game identity
  game_id          text not null,                   -- source-native game id
  espn_event_id    text,                            -- → espn_event_snapshots / event_xref when resolvable
  game_date        date,
  season           int,
  period           int,                             -- week (NFL) / date-bucket index (others)
  -- team identity (ALWAYS paired with league — espn_team_id is league-scoped)
  espn_team_id     text,
  team_abbr        text,
  opponent_team_id text,
  -- the stat line
  stats            jsonb not null default '{}'::jsonb,  -- per-league raw line: {"PTS":31,"REB":8,...} / {"PASS_YDS":312,...}
  ingested_at      timestamptz not null default now(),
  unique (source, league, game_id, sdv_player_id)   -- idempotent upsert target
);
comment on table public.player_game_stats is
  'Per-player per-game box-score lines, league-agnostic (NFL/NBA/MLB/NHL/WNBA). Ingested by fantasy_ingest.py from open-source sportsdataverse packages. Source of truth for fantasy player_box_v1 scoring. Fantasy Phase 1 (mig 20260608210000).';
create index if not exists player_game_stats_athlete_idx on public.player_game_stats (espn_athlete_id, league);
create index if not exists player_game_stats_league_date_idx on public.player_game_stats (league, game_date desc);
create index if not exists player_game_stats_event_idx on public.player_game_stats (espn_event_id) where espn_event_id is not null;
create index if not exists player_game_stats_team_idx on public.player_game_stats (espn_team_id, league);

-- ----------------------------------------------------------------------------
-- 3. RLS — reference data: read to authenticated, writes via service_role only
--    (service_role bypasses RLS; no write policy = no authenticated writes)
-- ----------------------------------------------------------------------------
alter table public.athlete_external_ids enable row level security;
alter table public.player_game_stats    enable row level security;

drop policy if exists athlete_external_ids_read on public.athlete_external_ids;
create policy athlete_external_ids_read on public.athlete_external_ids
  for select to authenticated using (true);

drop policy if exists player_game_stats_read on public.player_game_stats;
create policy player_game_stats_read on public.player_game_stats
  for select to authenticated using (true);

-- ----------------------------------------------------------------------------
-- 4. read helper — latest stat line for an athlete within a window
--    (isolates the player_game_stats read so the scorer + UI reuse one shape)
-- ----------------------------------------------------------------------------
create or replace function public.get_player_game_stats(
  p_espn_athlete_id text,
  p_league          text,
  p_from            timestamptz default now() - interval '7 days',
  p_to              timestamptz default now()
) returns setof public.player_game_stats
language sql stable security definer set search_path = public, pg_temp as
$$
  select *
    from public.player_game_stats
   where espn_athlete_id = p_espn_athlete_id
     and league = p_league
     and game_date >= p_from::date
     and game_date <= p_to::date
   order by game_date desc
$$;

grant select on public.athlete_external_ids to authenticated;
grant select on public.player_game_stats    to authenticated;
grant execute on function public.get_player_game_stats(text, text, timestamptz, timestamptz) to authenticated;

commit;
