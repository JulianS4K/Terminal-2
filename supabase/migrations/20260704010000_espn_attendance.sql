-- ESPN league attendance pipeline (slice 2 of the "more ESPN pipelines" work).
--
-- Source: www.espn.com/{league}/attendance/_/year/{Y}  (legacy server-rendered
--   HTML table, class="tablehead"; verified live 2026-07-04). The /_/year/{Y}
--   form is required — the bare URL renders an empty page for a not-yet-started
--   season in the offseason.
--
-- Column layout VARIES by league, so the parser reads the header groups
-- (Home/Road/Overall) + labels (GMS/TOTAL/AVG/PCT) rather than fixed indices:
--   MLB: Home(GMS,TOTAL,AVG,PCT) Road(GMS,AVG,PCT) Overall(GMS,AVG,PCT)
--   NFL: Home(GMS,TOTAL,AVG)     Road(GMS,TOTAL,AVG) Overall(GMS,TOTAL,AVG)
-- Hence every metric (games/total/avg/pct) exists for every section; a league
-- that omits one simply leaves it NULL. (NHL uses a modern non-table page and is
-- skipped — it yields 0 rows, no error.)
--
-- Change-only snapshots (mirrors espn_team_snapshots): attendance accrues over a
-- season, so a daily snapshot only INSERTs when the numbers move. Ingested by
-- espn-league-collect ?scope=attendance. Surfaced on the terminal performer
-- (team) page AND the venue page (a venue's home attendance = its team's).

create table if not exists espn_attendance_snapshots (
  id             bigserial primary key,
  espn_team_id   text not null,
  espn_league    text not null,
  captured_at    timestamptz not null default now(),
  season         int,
  rank           int,
  team_name      text,
  team_abbr      text,
  home_games     int,
  home_total     bigint,
  home_avg       int,
  home_pct       numeric,
  road_games     int,
  road_total     bigint,
  road_avg       int,
  road_pct       numeric,
  overall_games  int,
  overall_total  bigint,
  overall_avg    int,
  overall_pct    numeric,
  content_hash   text,
  last_seen_at   timestamptz,
  is_baseline    boolean default false,
  meta           jsonb,
  unique (espn_team_id, espn_league, captured_at)
);
alter table espn_attendance_snapshots enable row level security;
-- Idempotent add for the road/overall totals (NFL-style layout) in case an
-- earlier revision of this table was already applied.
alter table espn_attendance_snapshots add column if not exists road_total bigint;
alter table espn_attendance_snapshots add column if not exists overall_total bigint;
create index if not exists idx_espn_att_team_captured
  on espn_attendance_snapshots (espn_team_id, espn_league, captured_at desc);

comment on table espn_attendance_snapshots is
  'ESPN season attendance per team (home/road/overall games+total+avg+pct). Change-only daily snapshots parsed from www.espn.com/{league}/attendance/_/year/{Y} by espn-league-collect ?scope=attendance.';

create or replace view espn_attendance_latest as
select distinct on (espn_team_id, espn_league)
  espn_team_id, espn_league, season, rank, team_name, team_abbr,
  home_games, home_total, home_avg, home_pct,
  road_games, road_total, road_avg, road_pct,
  overall_games, overall_total, overall_avg, overall_pct,
  content_hash, captured_at, last_seen_at, id
from espn_attendance_snapshots
order by espn_team_id, espn_league, captured_at desc;

create or replace function upsert_espn_attendance_snapshot(
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
    from espn_attendance_snapshots
    where espn_team_id = p_team_id and espn_league = p_league
    order by captured_at desc limit 1;

  if latest_hash is null or latest_hash <> p_hash then
    insert into espn_attendance_snapshots (
      espn_team_id, espn_league, captured_at, season, rank, team_name, team_abbr,
      home_games, home_total, home_avg, home_pct,
      road_games, road_total, road_avg, road_pct,
      overall_games, overall_total, overall_avg, overall_pct,
      content_hash, last_seen_at, is_baseline, meta
    ) values (
      p_team_id, p_league, now(),
      (p_payload->>'season')::int, (p_payload->>'rank')::int,
      p_payload->>'team_name', p_payload->>'team_abbr',
      (p_payload->>'home_games')::int, (p_payload->>'home_total')::bigint,
      (p_payload->>'home_avg')::int, (p_payload->>'home_pct')::numeric,
      (p_payload->>'road_games')::int, (p_payload->>'road_total')::bigint,
      (p_payload->>'road_avg')::int, (p_payload->>'road_pct')::numeric,
      (p_payload->>'overall_games')::int, (p_payload->>'overall_total')::bigint,
      (p_payload->>'overall_avg')::int, (p_payload->>'overall_pct')::numeric,
      p_hash, now(), (latest_hash is null), coalesce(p_payload->'meta', '{}'::jsonb)
    ) returning id into latest_id;
    return query select 'inserted'::text, latest_id;
  else
    update espn_attendance_snapshots set last_seen_at = now() where id = latest_id;
    return query select 'unchanged'::text, latest_id;
  end if;
end;
$$;

comment on function upsert_espn_attendance_snapshot is
  'Change-only attendance snapshot insert. Returns action=inserted|unchanged. Used by espn-league-collect ?scope=attendance.';
