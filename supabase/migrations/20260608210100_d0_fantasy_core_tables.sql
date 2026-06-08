-- Migration 20260608210100 · lane:D0 (Fantasy feature, Phase 2) → PENDING operator apply · writes:fantasy_* tables + RLS + is_league_member() + v_fantasy_standings + scoring presets · reads:auth.uid()
--
-- ## NOT YET APPLIED TO PROD — authored as a file only (CLAUDE.md lockdown rule 1).
--
-- Phase 2 of the Fantasy League feature — the data model. Head-to-head weekly
-- fantasy for NFL/NBA/MLB/NHL/WNBA, scored from player_game_stats (Phase 1,
-- mig 20260608210000). RPCs are in 20260608210200; the scoring engine in
-- 20260608210300; the cron in 20260608210400.
--
-- Ownership model (matches user_alerts): user-scoped writes go through SECDEF
-- RPCs keyed on auth.uid() (the only path where auth.uid() resolves — the
-- FastAPI service_role bypasses RLS and cannot see it). RLS here is
-- defense-in-depth for any direct PostgREST access.
--
-- Landmine honored throughout: espn_team_id is LEAGUE-SCOPED, so every athlete/
-- team reference carries espn_league alongside espn_team_id.

begin;

-- ----------------------------------------------------------------------------
-- 1. leagues
-- ----------------------------------------------------------------------------
create table if not exists public.fantasy_leagues (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  espn_league     text not null check (espn_league in ('NFL','NBA','MLB','NHL','WNBA')),
  owner_id        uuid not null default auth.uid(),
  format          text not null default 'h2h' check (format in ('h2h','points')),
  roster_size     int  not null default 10,
  roster_slots    jsonb not null default '{}'::jsonb,   -- {"PG":1,"SG":1,...,"BENCH":3} (data-driven, league-agnostic)
  scoring_rules_id bigint,                                -- FK added after fantasy_scoring_rules exists
  draft_type      text not null default 'snake' check (draft_type in ('snake','auto','manual')),
  status          text not null default 'forming' check (status in ('forming','drafting','active','complete')),
  season_start    date,
  season_end      date,
  current_period  int  not null default 0,
  join_code       text unique,
  created_at      timestamptz not null default now()
);
comment on table public.fantasy_leagues is
  'Fantasy leagues. One row per league; espn_league scopes every downstream player/team query. owner_id = commissioner. Fantasy Phase 2 (mig 20260608210100).';

-- ----------------------------------------------------------------------------
-- 2. memberships (managers) — defines "my leagues"
-- ----------------------------------------------------------------------------
create table if not exists public.fantasy_memberships (
  id            bigint generated always as identity primary key,
  league_id     uuid not null references public.fantasy_leagues(id) on delete cascade,
  user_id       uuid not null default auth.uid(),
  team_name     text not null,
  role          text not null default 'manager' check (role in ('commissioner','manager')),
  draft_position int,
  joined_at     timestamptz not null default now(),
  unique (league_id, user_id)
);
create index if not exists fantasy_memberships_league_idx on public.fantasy_memberships (league_id);
create index if not exists fantasy_memberships_user_idx   on public.fantasy_memberships (user_id);

-- is_league_member: SECDEF so RLS policies can call it without recursing on
-- fantasy_memberships' own policy. Used in `using(...)` clauses below.
create or replace function public.is_league_member(p_league_id uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as
$$ select exists (
     select 1 from public.fantasy_memberships m
      where m.league_id = p_league_id and m.user_id = auth.uid()
   ) $$;

-- ----------------------------------------------------------------------------
-- 3. scoring rules (pluggable engine config)
-- ----------------------------------------------------------------------------
create table if not exists public.fantasy_scoring_rules (
  id          bigint generated always as identity primary key,
  name        text not null,
  espn_league text,                                -- null = applies to any league
  owner_id    uuid default auth.uid(),             -- null = built-in preset
  is_preset   boolean not null default false,
  rules       jsonb not null,                      -- {"source":"player_box_v1","components":{...}}
  version     int not null default 1,
  created_at  timestamptz not null default now()
);
comment on table public.fantasy_scoring_rules is
  'Pluggable scoring config. rules.source dispatches the engine (player_box_v1 = per-player stats from player_game_stats; team_result_v1 = team-outcome fallback). rules.components maps stat keys -> point weights. Fantasy Phase 2 (mig 20260608210100).';

-- now that the table exists, wire the league FK
alter table public.fantasy_leagues
  drop constraint if exists fantasy_leagues_scoring_rules_fk;
alter table public.fantasy_leagues
  add constraint fantasy_leagues_scoring_rules_fk
  foreign key (scoring_rules_id) references public.fantasy_scoring_rules(id);

-- ----------------------------------------------------------------------------
-- 4. rosters + drafted players
-- ----------------------------------------------------------------------------
create table if not exists public.fantasy_rosters (
  id            bigint generated always as identity primary key,
  league_id     uuid not null references public.fantasy_leagues(id) on delete cascade,
  membership_id bigint not null references public.fantasy_memberships(id) on delete cascade,
  unique (league_id, membership_id)
);

create table if not exists public.fantasy_roster_players (
  id              bigint generated always as identity primary key,
  roster_id       bigint not null references public.fantasy_rosters(id) on delete cascade,
  league_id       uuid not null references public.fantasy_leagues(id) on delete cascade,
  espn_athlete_id text not null,                   -- soft ref to espn_athletes (no hard FK: ESPN is an ingest pipeline)
  espn_team_id    text,                            -- denormalized at draft (survives trades); paired with league
  espn_league     text,
  slot            text not null,                   -- roster slot (PG / BENCH / ...)
  is_starter      boolean not null default true,
  acquired_via    text not null default 'draft' check (acquired_via in ('draft','add','trade')),
  acquired_at     timestamptz not null default now(),
  unique (league_id, espn_athlete_id)              -- a player is on ONE roster per league
);
create index if not exists fantasy_roster_players_roster_idx on public.fantasy_roster_players (roster_id);

-- ----------------------------------------------------------------------------
-- 5. draft
-- ----------------------------------------------------------------------------
create table if not exists public.fantasy_draft (
  id              bigint generated always as identity primary key,
  league_id       uuid not null unique references public.fantasy_leagues(id) on delete cascade,
  status          text not null default 'pending' check (status in ('pending','in_progress','complete')),
  current_pick_no int not null default 1,
  total_rounds    int,
  pick_order      jsonb not null default '[]'::jsonb,   -- materialized serpentine order: [membership_id, ...] by pick_no
  started_at      timestamptz,
  completed_at    timestamptz
);

create table if not exists public.fantasy_draft_picks (
  id              bigint generated always as identity primary key,
  draft_id        bigint not null references public.fantasy_draft(id) on delete cascade,
  league_id       uuid not null references public.fantasy_leagues(id) on delete cascade,
  pick_no         int not null,
  round           int,
  membership_id   bigint not null references public.fantasy_memberships(id) on delete cascade,
  espn_athlete_id text not null,
  auto_picked     boolean not null default false,
  picked_at       timestamptz not null default now(),
  unique (draft_id, pick_no),
  unique (draft_id, espn_athlete_id)
);

-- ----------------------------------------------------------------------------
-- 6. scoring periods + scores + matchups
-- ----------------------------------------------------------------------------
create table if not exists public.fantasy_scoring_periods (
  id        bigint generated always as identity primary key,
  league_id uuid not null references public.fantasy_leagues(id) on delete cascade,
  period_no int not null,
  starts_at timestamptz not null,
  ends_at   timestamptz not null,
  status    text not null default 'open' check (status in ('open','scored','final')),
  scored_at timestamptz,
  unique (league_id, period_no)
);
create index if not exists fantasy_periods_due_idx on public.fantasy_scoring_periods (status, ends_at);

create table if not exists public.fantasy_player_scores (
  id               bigint generated always as identity primary key,
  league_id        uuid not null references public.fantasy_leagues(id) on delete cascade,
  period_id        bigint not null references public.fantasy_scoring_periods(id) on delete cascade,
  roster_player_id bigint not null references public.fantasy_roster_players(id) on delete cascade,
  espn_athlete_id  text not null,
  points           numeric not null default 0,
  components       jsonb not null default '{}'::jsonb,   -- explainable breakdown: {"PTS":31,"REB":9.6,...}
  computed_at      timestamptz not null default now(),
  unique (period_id, roster_player_id)                    -- idempotent upsert anchor
);

create table if not exists public.fantasy_team_scores (
  id            bigint generated always as identity primary key,
  league_id     uuid not null references public.fantasy_leagues(id) on delete cascade,
  period_id     bigint not null references public.fantasy_scoring_periods(id) on delete cascade,
  membership_id bigint not null references public.fantasy_memberships(id) on delete cascade,
  points        numeric not null default 0,
  unique (period_id, membership_id)
);

create table if not exists public.fantasy_matchups (
  id                   bigint generated always as identity primary key,
  league_id            uuid not null references public.fantasy_leagues(id) on delete cascade,
  period_id            bigint not null references public.fantasy_scoring_periods(id) on delete cascade,
  home_membership_id   bigint not null references public.fantasy_memberships(id) on delete cascade,
  away_membership_id   bigint references public.fantasy_memberships(id) on delete cascade,  -- null = bye
  home_points          numeric,
  away_points          numeric,
  winner_membership_id bigint references public.fantasy_memberships(id) on delete cascade,
  unique (period_id, home_membership_id, away_membership_id)
);

-- ----------------------------------------------------------------------------
-- 7. standings VIEW — derived so it never drifts from the score tables
-- ----------------------------------------------------------------------------
create or replace view public.v_fantasy_standings
with (security_invoker = true) as
with results as (
  -- one row per (membership, matchup) with for/against + W/L/T
  select m.league_id, m.home_membership_id as membership_id,
         m.home_points as pf, coalesce(m.away_points, 0) as pa,
         case when m.away_membership_id is null then null
              when m.winner_membership_id = m.home_membership_id then 1
              when m.winner_membership_id is null then 0 else -1 end as outcome
    from public.fantasy_matchups m
   where m.home_points is not null
  union all
  select m.league_id, m.away_membership_id,
         m.away_points, coalesce(m.home_points, 0),
         case when m.winner_membership_id = m.away_membership_id then 1
              when m.winner_membership_id is null then 0 else -1 end
    from public.fantasy_matchups m
   where m.away_membership_id is not null and m.away_points is not null
)
select
  mb.league_id,
  mb.id   as membership_id,
  mb.team_name,
  count(*) filter (where r.outcome = 1)  as wins,
  count(*) filter (where r.outcome = -1) as losses,
  count(*) filter (where r.outcome = 0)  as ties,
  coalesce(sum(r.pf), 0) as points_for,
  coalesce(sum(r.pa), 0) as points_against,
  rank() over (
    partition by mb.league_id
    order by count(*) filter (where r.outcome = 1) desc,
             coalesce(sum(r.pf), 0) desc
  ) as rank
from public.fantasy_memberships mb
left join results r on r.membership_id = mb.id
group by mb.league_id, mb.id, mb.team_name;
comment on view public.v_fantasy_standings is
  'Derived H2H standings (wins/losses/ties + points for/against + rank) from fantasy_matchups. security_invoker so RLS on the base tables applies. Fantasy Phase 2 (mig 20260608210100).';

-- ----------------------------------------------------------------------------
-- 8. RLS — defense in depth (RPCs are SECDEF and enforce auth.uid())
-- ----------------------------------------------------------------------------
alter table public.fantasy_leagues         enable row level security;
alter table public.fantasy_memberships     enable row level security;
alter table public.fantasy_scoring_rules   enable row level security;
alter table public.fantasy_rosters         enable row level security;
alter table public.fantasy_roster_players  enable row level security;
alter table public.fantasy_draft           enable row level security;
alter table public.fantasy_draft_picks     enable row level security;
alter table public.fantasy_scoring_periods enable row level security;
alter table public.fantasy_player_scores   enable row level security;
alter table public.fantasy_team_scores     enable row level security;
alter table public.fantasy_matchups        enable row level security;

-- leagues: a member (or owner) can see the league; anyone authenticated can
-- look one up by join_code via the join RPC (SECDEF), so SELECT stays scoped.
drop policy if exists fantasy_leagues_read on public.fantasy_leagues;
create policy fantasy_leagues_read on public.fantasy_leagues
  for select to authenticated
  using (owner_id = auth.uid() or public.is_league_member(id));

drop policy if exists fantasy_leagues_owner_write on public.fantasy_leagues;
create policy fantasy_leagues_owner_write on public.fantasy_leagues
  for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- memberships: visible to anyone in the same league; you mutate only your row.
drop policy if exists fantasy_memberships_read on public.fantasy_memberships;
create policy fantasy_memberships_read on public.fantasy_memberships
  for select to authenticated
  using (user_id = auth.uid() or public.is_league_member(league_id));

drop policy if exists fantasy_memberships_self_write on public.fantasy_memberships;
create policy fantasy_memberships_self_write on public.fantasy_memberships
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- scoring rules: presets + own rows readable; mutate only own non-preset rows.
drop policy if exists fantasy_scoring_rules_read on public.fantasy_scoring_rules;
create policy fantasy_scoring_rules_read on public.fantasy_scoring_rules
  for select to authenticated
  using (is_preset or owner_id = auth.uid());

drop policy if exists fantasy_scoring_rules_own_write on public.fantasy_scoring_rules;
create policy fantasy_scoring_rules_own_write on public.fantasy_scoring_rules
  for all to authenticated
  using (owner_id = auth.uid() and not is_preset)
  with check (owner_id = auth.uid() and not is_preset);

-- league-scoped read tables: any member of the league can read; writes happen
-- through SECDEF RPCs / the service-role scorer, so no authenticated-write policy.
do $$
declare t text;
begin
  foreach t in array array[
    'fantasy_rosters','fantasy_roster_players','fantasy_draft','fantasy_draft_picks',
    'fantasy_scoring_periods','fantasy_player_scores','fantasy_team_scores','fantasy_matchups'
  ] loop
    execute format('drop policy if exists %I_member_read on public.%I', t, t);
    execute format(
      'create policy %I_member_read on public.%I for select to authenticated using (public.is_league_member(league_id))',
      t, t);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 9. seed scoring presets (one player_box_v1 per league + a team_result_v1 fallback)
-- ----------------------------------------------------------------------------
insert into public.fantasy_scoring_rules (name, espn_league, is_preset, rules) values
  ('NBA Standard',  'NBA',  true, '{"source":"player_box_v1","components":{"PTS":1,"REB":1.2,"AST":1.5,"STL":3,"BLK":3,"TOV":-1,"FG3M":0.5}}'::jsonb),
  ('WNBA Standard', 'WNBA', true, '{"source":"player_box_v1","components":{"PTS":1,"REB":1.2,"AST":1.5,"STL":3,"BLK":3,"TOV":-1,"FG3M":0.5}}'::jsonb),
  ('NFL Standard',  'NFL',  true, '{"source":"player_box_v1","components":{"PASS_YDS":0.04,"PASS_TD":4,"INT":-2,"RUSH_YDS":0.1,"RUSH_TD":6,"REC":0.5,"REC_YDS":0.1,"REC_TD":6,"FUMBLES_LOST":-2}}'::jsonb),
  ('NHL Standard',  'NHL',  true, '{"source":"player_box_v1","components":{"G":3,"A":2,"SOG":0.5,"PLUS_MINUS":1,"PIM":0.2}}'::jsonb),
  ('MLB Standard',  'MLB',  true, '{"source":"player_box_v1","components":{"H":1,"R":1,"RBI":1,"HR":4,"BB":1,"SB":2,"SO_BAT":-0.5,"K_PIT":1,"IP":1,"ER":-1,"W_PIT":4}}'::jsonb),
  ('Team Result Fallback', null, true, '{"source":"team_result_v1","components":{"win":5,"draw":2,"margin":{"per_point":0.25,"cap":5},"favored_win":1,"underdog_win":3,"availability":{"active":1,"out":-2,"statuses_out":["Out","Injured Reserve","Suspension"]}},"settle_state":"post"}'::jsonb)
on conflict do nothing;

-- ----------------------------------------------------------------------------
-- 10. grants
-- ----------------------------------------------------------------------------
grant select on public.fantasy_leagues, public.fantasy_memberships,
  public.fantasy_scoring_rules, public.fantasy_rosters, public.fantasy_roster_players,
  public.fantasy_draft, public.fantasy_draft_picks, public.fantasy_scoring_periods,
  public.fantasy_player_scores, public.fantasy_team_scores, public.fantasy_matchups,
  public.v_fantasy_standings
  to authenticated;
grant execute on function public.is_league_member(uuid) to authenticated;

commit;
