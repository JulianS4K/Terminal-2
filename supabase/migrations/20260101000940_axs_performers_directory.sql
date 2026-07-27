-- AXS artist directory, harvested from veritix /fetch payloads.
--
-- The veritix payload (axs_event_snapshots.raw) carries the AXS artist id + name
-- at startflow.axsEventInfo[0].primaryPerformer {id,name} (and the AXS venue id
-- at .axsVenueID). That lets us build performer artist URLs
-- (axs.com/artists/<id>/<slug>-tickets) for the TicketsData /events lookup —
-- WITHOUT needing AXS search. axs_performers caches the directory; refresh after
-- new pulls. Discovery: build the artist URL, GET /events?performer_url=...&
-- platform=axs, then axs_ingest_performer_events(rid).

create table if not exists public.axs_performers (
  axs_artist_id text primary key,
  performer     text,
  updated_at    timestamptz default now()
);
alter table public.axs_performers enable row level security;

create or replace function public.axs_refresh_performers()
returns integer language plpgsql security definer set search_path=public, pg_temp as $$
declare n int;
begin
  insert into public.axs_performers (axs_artist_id, performer)
  select distinct on (id) id, name from (
    select raw->'startflow'->'axsEventInfo'->0->'primaryPerformer'->>'id'   as id,
           raw->'startflow'->'axsEventInfo'->0->'primaryPerformer'->>'name' as name
    from public.axs_event_snapshots
    where raw->'startflow'->'axsEventInfo'->0->'primaryPerformer'->>'id' is not null) z
  on conflict (axs_artist_id) do update set performer=excluded.performer, updated_at=now();
  get diagnostics n = row_count;
  return (select count(*) from public.axs_performers);
end $$;

-- build the AXS artist URL for a performer we know the id for
create or replace function public.axs_artist_url(p_performer text)
returns text language sql stable as $$
  select 'https://www.axs.com/artists/' || p.axs_artist_id || '/'
       || public.axs_slugify(p.performer) || '-tickets'
  from public.axs_performers p
  where public.axs_slugify(p.performer) = public.axs_slugify(p_performer)
  limit 1;
$$;

select public.axs_refresh_performers();
