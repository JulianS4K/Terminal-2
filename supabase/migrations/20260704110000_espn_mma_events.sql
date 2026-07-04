-- ESPN MMA (UFC) fight-card pipeline — stores event fight cards / bouts.
--
-- Source: UFC scoreboard (site.api.espn.com/apis/site/v2/sports/mma/ufc/
--   scoreboard) -> event ids; fightcenter (site.web.api.espn.com/apis/common/v3/
--   sports/mma/ufc/fightcenter/{eventId}) -> { event, venue, cards:{ main,
--   prelims1, ... } } where each card group has competitions[] (bouts) with
--   type.text (weight class), status, and competitors[].athlete + displayRecord
--   + winner. Verified live 2026-07-04 (events 600059148 / 600059599).
--
-- The existing `espn` edge fn already RENDERS a single event's card on demand;
-- this pipeline STORES upcoming + recent UFC cards so they're queryable. One row
-- per event, fights[] jsonb. Current-snapshot upsert (results firm up as an event
-- completes). Ingested by the espn-mma edge function.

create table if not exists espn_mma_events (
  espn_event_id  text primary key,
  name           text,
  event_date     timestamptz,
  venue          text,
  league         text not null default 'UFC',
  status         text,
  fights         jsonb,        -- [{segment, weight_class, status, result, fighters:[{name,id,record,winner}]}]
  fight_count    int,
  content_hash   text,
  first_seen_at  timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  meta           jsonb
);
alter table espn_mma_events enable row level security;
create index if not exists idx_espn_mma_date on espn_mma_events (event_date desc);

comment on table espn_mma_events is
  'ESPN UFC fight cards (events + bouts as fights[] jsonb). Current-snapshot, written by the espn-mma edge function.';

-- Read helper: upcoming + recent UFC cards for the terminal.
create or replace function get_espn_mma_events(p_limit int default 20)
returns table (espn_event_id text, name text, event_date timestamptz, venue text,
               status text, fight_count int, fights jsonb)
language sql stable security definer set search_path to 'public','pg_temp' as $$
  select espn_event_id, name, event_date, venue, status, fight_count, fights
  from public.espn_mma_events
  order by event_date desc nulls last
  limit greatest(1, least(coalesce(p_limit, 20), 100));
$$;
comment on function get_espn_mma_events is
  'Recent/upcoming UFC fight cards with bouts (from espn_mma_events).';
