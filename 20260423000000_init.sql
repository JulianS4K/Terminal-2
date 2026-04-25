-- Evo Terminal Postgres schema for Supabase.
-- Already applied to project hzrizjeaxlqcxfrtczpq. Kept for reference / fresh setup.

-- ============================================================
-- Data tables
-- ============================================================

create table if not exists events (
  id                     bigint primary key,
  name                   text,
  occurs_at_local        text,
  state                  text,
  venue_id               bigint,
  venue_name             text,
  venue_location         text,
  primary_performer_id   bigint,
  primary_performer_name text,
  performer_ids          bigint[],
  last_seen              timestamptz
);

create table if not exists snapshots (
  id                  bigserial primary key,
  event_id            bigint not null references events(id) on delete cascade,
  captured_at         timestamptz not null,
  ticket_groups_count integer,
  tickets_count       integer,
  retail_price_min    numeric,
  retail_price_avg    numeric,
  retail_price_max    numeric,
  retail_price_sum    numeric,
  wholesale_price_avg numeric,
  wholesale_price_sum numeric
);
create index if not exists idx_snap_event_time on snapshots(event_id, captured_at desc);

create table if not exists watch_sources (
  event_id     bigint not null references events(id) on delete cascade,
  source_type  text   not null check (source_type in ('performer','venue')),
  source_id    bigint not null,
  source_label text,
  first_seen   timestamptz not null default now(),
  primary key (event_id, source_type, source_id)
);

create table if not exists watchlist (
  id       bigserial primary key,
  kind     text   not null check (kind in ('performer','venue')),
  ext_id   bigint not null,
  label    text,
  added_at timestamptz not null default now(),
  unique (kind, ext_id)
);

create table if not exists runs (
  id               bigserial primary key,
  started_at       timestamptz not null default now(),
  finished_at      timestamptz,
  events_collected integer,
  stats_errors     integer
);

-- ============================================================
-- Settings (TEvo credentials, other runtime config)
-- ============================================================

create table if not exists settings (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);

-- Lock down: no policies = only service_role key can read/write.
alter table settings enable row level security;

-- ============================================================
-- Views
-- ============================================================

create or replace view latest_snapshots as
select distinct on (event_id) *
from snapshots
order by event_id, captured_at desc;

create or replace view event_velocity as
with ranked as (
  select *, row_number() over (partition by event_id order by captured_at desc) as rn
  from snapshots
)
select
  e.id,
  e.name,
  e.occurs_at_local,
  e.venue_name,
  e.primary_performer_name,
  curr.captured_at                                            as latest_at,
  curr.tickets_count                                          as tickets_now,
  curr.retail_price_avg                                       as avg_now,
  curr.retail_price_min                                       as min_now,
  prev.captured_at                                            as previous_at,
  (curr.tickets_count - prev.tickets_count)                   as tickets_delta,
  round(curr.retail_price_avg - prev.retail_price_avg, 2)     as avg_delta,
  round(curr.retail_price_min - prev.retail_price_min, 2)     as min_delta
from events e
join ranked curr on curr.event_id = e.id and curr.rn = 1
left join ranked prev on prev.event_id = e.id and prev.rn = 2;

-- ============================================================
-- Seed watchlist (fresh setup only — already populated in prod)
-- ============================================================

insert into watchlist (kind, ext_id, label) values
  ('performer', 15533, 'New York Yankees')
on conflict (kind, ext_id) do nothing;

-- ============================================================
-- Seed settings (placeholder — real values inserted manually)
-- ============================================================

-- Run separately with real values:
-- insert into settings (key, value) values
--   ('tevo_token',  'YOUR_TEVO_TOKEN'),
--   ('tevo_secret', 'YOUR_TEVO_SECRET')
-- on conflict (key) do update set value = excluded.value, updated_at = now();
