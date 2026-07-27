-- ESPN racing standings pipeline — driver championship standings for F1 +
-- NASCAR Cup / Xfinity / Truck.
--
-- Source: site.api.espn.com/apis/v2/sports/racing/{series}/standings  (verified
--   live 2026-07-04). Series slugs: f1, nascar-premier (Cup), nascar-secondary
--   (Xfinity), nascar-truck. Shape:
--   { children:[{ name, standings:{ entries:[{ athlete:{id,displayName,
--     abbreviation, flag:{alt:country}}, stats:[{name,type,value,displayValue}] }] }}] }
--   Each entry has rank + championshipPts (type='points') + per-race finishes.
--
-- CURRENT-snapshot table (~40 drivers × 4 series), bulk-upserted in place by the
-- espn-racing edge function. stats = all named stats keyed by ESPN stat name.

create table if not exists espn_racing_standings (
  series           text not null,          -- 'f1' | 'nascar-cup' | 'nascar-xfinity' | 'nascar-truck'
  espn_athlete_id  text not null,
  driver_name      text,
  driver_abbr      text,
  country          text,
  rank             int,
  points           numeric,
  wins             int,
  season           int,
  stats            jsonb,
  content_hash     text,
  first_seen_at    timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  meta             jsonb,
  primary key (series, espn_athlete_id)
);
alter table espn_racing_standings enable row level security;
create index if not exists idx_espn_racing_series_rank on espn_racing_standings (series, rank);

comment on table espn_racing_standings is
  'ESPN driver championship standings (F1 + NASCAR Cup/Xfinity/Truck). Current-snapshot, bulk-upserted by the espn-racing edge function.';

-- Read helper for the terminal: a series standings table, ordered by rank.
create or replace function get_espn_racing_standings(p_series text, p_limit int default 60)
returns table (rank int, driver_name text, driver_abbr text, country text,
               points numeric, wins int, stats jsonb)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select rank, driver_name, driver_abbr, country, points, wins, stats
  from public.espn_racing_standings
  where series = p_series
  order by rank nulls last
  limit greatest(1, least(coalesce(p_limit, 60), 200));
$$;
comment on function get_espn_racing_standings is
  'Driver standings for a racing series (f1|nascar-cup|nascar-xfinity|nascar-truck).';
