-- ESPN racing events (race schedule) — F1 + NASCAR Cup/Xfinity/Truck.
--
-- Companion to espn_racing_standings (mig 100000): standings are the drivers'
-- championship table; this is the *calendar* of races per series.
--
-- Source: site.api.espn.com/apis/site/v2/sports/racing/{slug}/scoreboard
--   (verified live 2026-07-04). Shape:
--   { events:[{ id, date, endDate?, name, shortName,
--       season:{ year, type, slug },
--       competitions:[{ id, date, status:{ type:{ name, state, completed } },
--                       venue?:{ fullName, address:{city,state,country} } }] }] }
--   NASCAR events carry season.slug (regular-season/…); F1 events carry endDate
--   (multi-day GP weekends). Both share the same envelope.
--
-- CURRENT-schedule table: the scoreboard surfaces the recent/upcoming window per
-- series (~a handful of races), bulk-upserted in place by the espn-racing edge
-- function's `events` scope. Full event JSON is retained in `meta` so nothing is
-- lost if ESPN adds fields. Read-only vs upstream (public GET, RULE 2 N/A).

create table if not exists espn_racing_events (
  series          text not null,       -- 'f1' | 'nascar-cup' | 'nascar-xfinity' | 'nascar-truck'
  espn_event_id   text not null,
  name            text,
  short_name      text,
  event_date      timestamptz,
  end_date        timestamptz,
  season          int,
  season_type     int,
  season_slug     text,
  status_state    text,                -- 'pre' | 'in' | 'post'
  status_name     text,                -- 'STATUS_SCHEDULED' | 'STATUS_FINAL' | …
  completed       boolean,
  venue           text,
  content_hash    text,
  first_seen_at   timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  meta            jsonb,
  primary key (series, espn_event_id)
);
alter table espn_racing_events enable row level security;
create index if not exists idx_espn_racing_events_series_date on espn_racing_events (series, event_date);
create index if not exists idx_espn_racing_events_date on espn_racing_events (event_date);

comment on table espn_racing_events is
  'ESPN race calendar (F1 + NASCAR Cup/Xfinity/Truck). Current-window schedule, bulk-upserted by the espn-racing edge function (events scope).';

-- Read helper for the terminal: races for a series, most-recent/upcoming first.
create or replace function get_espn_racing_events(p_series text default null, p_limit int default 40)
returns table (series text, espn_event_id text, name text, short_name text,
               event_date timestamptz, end_date timestamptz, season int,
               status_state text, status_name text, completed boolean, venue text)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select series, espn_event_id, name, short_name, event_date, end_date, season,
         status_state, status_name, completed, venue
  from public.espn_racing_events
  where p_series is null or series = p_series
  order by event_date desc nulls last
  limit greatest(1, least(coalesce(p_limit, 40), 200));
$$;
comment on function get_espn_racing_events is
  'Race calendar for a racing series (f1|nascar-cup|nascar-xfinity|nascar-truck), or all series when null.';
