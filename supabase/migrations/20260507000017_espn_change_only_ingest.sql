-- Change-only ESPN ingest: instead of writing a new snapshot row every collector
-- run, only INSERT when the meaningful content has actually changed; otherwise
-- bump last_seen_at on the most recent row. Initial run is the baseline.
--
-- Pattern (used by espn-collect v3+):
--   1. Compute content_hash client-side from canonical fields (md5 of stable JSON).
--   2. Look up the latest snapshot's hash for (team_id, league).
--   3. If null/different -> INSERT (delta detected; baseline if first).
--   4. If same -> UPDATE last_seen_at on that latest row.
-- Net: history shows real state changes, storage is bounded, "no-op" runs cost
-- one UPDATE per team instead of one INSERT.
--
-- Applied to prod 2026-05-07 via MCP. Existing 720 rows backfilled with
-- content_hash + is_baseline=true so the next collector run picks up cleanly.

-- ---- espn_team_snapshots --------------------------------------------------
alter table espn_team_snapshots
  add column if not exists content_hash text,
  add column if not exists last_seen_at timestamptz,
  add column if not exists is_baseline boolean default false;

create index if not exists idx_espn_team_snap_team_captured
  on espn_team_snapshots (espn_team_id, espn_league, captured_at desc);

update espn_team_snapshots
set content_hash = md5(coalesce(wins::text,'')||'|'||coalesce(losses::text,'')||'|'||coalesce(ties::text,'')||'|'||
                        coalesce(win_pct::text,'')||'|'||coalesce(games_back::text,'')||'|'||
                        coalesce(playoff_seed::text,'')||'|'||coalesce(conference_rank::text,'')||'|'||
                        coalesce(division_rank::text,'')||'|'||coalesce(record_summary,'')||'|'||
                        coalesce(standing_summary,'')||'|'||coalesce(streak,'')),
    last_seen_at = captured_at,
    is_baseline  = true
where content_hash is null;

-- ---- espn_injuries_snapshots ----------------------------------------------
alter table espn_injuries_snapshots
  add column if not exists content_hash text,
  add column if not exists last_seen_at timestamptz,
  add column if not exists is_baseline boolean default false;

create index if not exists idx_espn_inj_athlete_team
  on espn_injuries_snapshots (espn_team_id, athlete_id, captured_at desc);

update espn_injuries_snapshots
set content_hash = md5(coalesce(athlete_id,'')||'|'||coalesce(status,'')||'|'||coalesce(injury_type,'')||'|'||
                        coalesce(short_comment,'')||'|'||coalesce(return_date::text,'')),
    last_seen_at = captured_at,
    is_baseline  = true
where content_hash is null;

-- ---- espn_event_snapshots --------------------------------------------------
alter table espn_event_snapshots
  add column if not exists content_hash text,
  add column if not exists last_seen_at timestamptz,
  add column if not exists is_baseline boolean default false;

update espn_event_snapshots
set content_hash = md5(coalesce(state,'')||'|'||coalesce(status_short,'')||'|'||
                        coalesce(home_score::text,'')||'|'||coalesce(away_score::text,'')||'|'||
                        coalesce(spread,'')||'|'||coalesce(over_under::text,'')||'|'||
                        coalesce(home_ml::text,'')||'|'||coalesce(away_ml::text,'')||'|'||
                        coalesce(home_win_prob::text,'')||'|'||coalesce(attendance::text,'')),
    last_seen_at = captured_at,
    is_baseline  = true
where content_hash is null;

-- ---- helper views: latest snapshot per (team/event/athlete) -----------------
create or replace view espn_team_snapshot_latest as
select distinct on (espn_team_id, espn_league)
  espn_team_id, espn_league, content_hash, captured_at, last_seen_at, id
from espn_team_snapshots
order by espn_team_id, espn_league, captured_at desc;

create or replace view espn_event_snapshot_latest as
select distinct on (espn_event_id, espn_league)
  espn_event_id, espn_league, content_hash, captured_at, last_seen_at, id
from espn_event_snapshots
order by espn_event_id, espn_league, captured_at desc;

create or replace view espn_injury_snapshot_latest as
select distinct on (espn_team_id, athlete_id)
  espn_team_id, athlete_id, content_hash, status, captured_at, last_seen_at, id
from espn_injuries_snapshots
where athlete_id is not null
order by espn_team_id, athlete_id, captured_at desc;

-- ---- helper RPCs: insert-if-changed ----------------------------------------
-- All return action='inserted'|'unchanged' + the affected row id. Called by
-- espn-collect v3+ via PostgREST RPC.

create or replace function upsert_espn_team_snapshot(
  p_team_id text,
  p_league text,
  p_hash text,
  p_payload jsonb
) returns table (action text, snap_id bigint) language plpgsql as $$
declare
  latest_hash text;
  latest_id bigint;
begin
  select content_hash, id into latest_hash, latest_id
    from espn_team_snapshots
    where espn_team_id = p_team_id and espn_league = p_league
    order by captured_at desc limit 1;

  if latest_hash is null or latest_hash <> p_hash then
    insert into espn_team_snapshots (
      espn_team_id, espn_league, captured_at,
      wins, losses, ties, win_pct, games_back,
      playoff_seed, conference_rank, division_rank,
      record_summary, standing_summary, streak,
      content_hash, last_seen_at, is_baseline, meta
    ) values (
      p_team_id, p_league, now(),
      (p_payload->>'wins')::int, (p_payload->>'losses')::int, (p_payload->>'ties')::int,
      (p_payload->>'win_pct')::numeric, (p_payload->>'games_back')::numeric,
      (p_payload->>'playoff_seed')::int, (p_payload->>'conference_rank')::int, (p_payload->>'division_rank')::int,
      p_payload->>'record_summary', p_payload->>'standing_summary', p_payload->>'streak',
      p_hash, now(), (latest_hash is null), coalesce(p_payload->'meta', '{}'::jsonb)
    ) returning id into latest_id;
    return query select 'inserted'::text, latest_id;
  else
    update espn_team_snapshots set last_seen_at = now() where id = latest_id;
    return query select 'unchanged'::text, latest_id;
  end if;
end;
$$;

create or replace function upsert_espn_event_snapshot(
  p_event_id text,
  p_league text,
  p_hash text,
  p_payload jsonb
) returns table (action text, snap_id bigint) language plpgsql as $$
declare
  latest_hash text;
  latest_id bigint;
begin
  select content_hash, id into latest_hash, latest_id
    from espn_event_snapshots
    where espn_event_id = p_event_id and espn_league = p_league
    order by captured_at desc limit 1;

  if latest_hash is null or latest_hash <> p_hash then
    insert into espn_event_snapshots (
      espn_event_id, espn_league, captured_at,
      state, status_short, home_team_id, away_team_id, home_score, away_score,
      odds_provider, spread, over_under, home_ml, away_ml, home_win_prob, attendance,
      content_hash, last_seen_at, is_baseline, meta
    ) values (
      p_event_id, p_league, now(),
      p_payload->>'state', p_payload->>'status_short',
      p_payload->>'home_team_id', p_payload->>'away_team_id',
      (p_payload->>'home_score')::int, (p_payload->>'away_score')::int,
      p_payload->>'odds_provider', p_payload->>'spread', (p_payload->>'over_under')::numeric,
      (p_payload->>'home_ml')::int, (p_payload->>'away_ml')::int,
      (p_payload->>'home_win_prob')::numeric, (p_payload->>'attendance')::int,
      p_hash, now(), (latest_hash is null), coalesce(p_payload->'meta', '{}'::jsonb)
    ) returning id into latest_id;
    return query select 'inserted'::text, latest_id;
  else
    update espn_event_snapshots set last_seen_at = now() where id = latest_id;
    return query select 'unchanged'::text, latest_id;
  end if;
end;
$$;

create or replace function upsert_espn_injury(
  p_team_id text,
  p_athlete_id text,
  p_hash text,
  p_payload jsonb
) returns table (action text, snap_id bigint) language plpgsql as $$
declare
  latest_hash text;
  latest_id bigint;
begin
  select content_hash, id into latest_hash, latest_id
    from espn_injuries_snapshots
    where espn_team_id = p_team_id and athlete_id = p_athlete_id
    order by captured_at desc limit 1;

  if latest_hash is null or latest_hash <> p_hash then
    insert into espn_injuries_snapshots (
      espn_team_id, espn_league, captured_at,
      athlete_id, athlete_name, position, status, injury_type,
      short_comment, long_comment, return_date,
      content_hash, last_seen_at, is_baseline, meta
    ) values (
      p_team_id, p_payload->>'espn_league', now(),
      p_athlete_id, p_payload->>'athlete_name', p_payload->>'position',
      p_payload->>'status', p_payload->>'injury_type',
      p_payload->>'short_comment', p_payload->>'long_comment',
      (p_payload->>'return_date')::timestamptz,
      p_hash, now(), (latest_hash is null), coalesce(p_payload->'meta', '{}'::jsonb)
    ) returning id into latest_id;
    return query select 'inserted'::text, latest_id;
  else
    update espn_injuries_snapshots set last_seen_at = now() where id = latest_id;
    return query select 'unchanged'::text, latest_id;
  end if;
end;
$$;

comment on function upsert_espn_team_snapshot  is 'Change-only insert. Returns action=inserted|unchanged. Used by espn-collect v3+.';
comment on function upsert_espn_event_snapshot is 'Change-only insert. Returns action=inserted|unchanged. Used by espn-collect v3+.';
comment on function upsert_espn_injury         is 'Change-only insert per athlete. Used by espn-collect v3+.';
