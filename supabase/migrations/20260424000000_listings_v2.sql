-- ============================================================
-- Evo Terminal v2: listings-based pipeline
-- ============================================================
-- Runs parallel to the existing `snapshots` table.
-- Capture raw listings (60-day retention) + our own computed
-- event + section metrics (indefinite retention).
--
-- Apply in Supabase Dashboard > SQL Editor.
-- ============================================================

-- ------------------------------------------------------------
-- Raw listings snapshots (60-day retention)
-- ------------------------------------------------------------

create table if not exists listings_snapshots (
  event_id              bigint      not null,
  captured_at           timestamptz not null,
  tevo_ticket_group_id  bigint      not null,
  section               text,
  row                   text,
  quantity              integer,
  retail_price          numeric(12,2),
  wholesale_price       numeric(12,2),
  format                text,
  splits                integer[],
  wheelchair            boolean,
  instant_delivery      boolean,
  eticket               boolean,
  is_ancillary          boolean     not null default false,  -- parking, hospitality, etc.
  primary key (event_id, captured_at, tevo_ticket_group_id)
);

-- Indexes for chart queries + retention sweeps
create index if not exists idx_listings_captured on listings_snapshots (captured_at);
create index if not exists idx_listings_event_time on listings_snapshots (event_id, captured_at desc);

-- ------------------------------------------------------------
-- Event-level metrics (indefinite retention)
-- Computed from listings_snapshots at collect time, excluding ancillary.
-- ------------------------------------------------------------

create table if not exists event_metrics (
  event_id              bigint      not null,
  captured_at           timestamptz not null,

  -- Inventory
  tickets_count         integer,
  groups_count          integer,
  sections_count        integer,
  median_group_size     numeric(8,2),

  -- Ancillary (parking/hospitality, for reference)
  ancillary_groups      integer,
  ancillary_tickets     integer,

  -- Retail price distribution (seat-only)
  retail_min            numeric(12,2),
  retail_p25            numeric(12,2),
  retail_median         numeric(12,2),
  retail_mean           numeric(12,2),
  retail_p75            numeric(12,2),
  retail_p90            numeric(12,2),
  retail_max            numeric(12,2),
  retail_sum            numeric(14,2),

  -- Wholesale price distribution (seat-only)
  wholesale_min         numeric(12,2),
  wholesale_median      numeric(12,2),
  wholesale_mean        numeric(12,2),
  wholesale_max         numeric(12,2),

  -- Market structure
  getin_price           numeric(12,2),    -- min retail for a group with quantity >= 2
  top5_concentration    numeric(5,4),     -- fraction of tickets in top-5 most-stocked sections
  bid_ask_proxy         numeric(5,4),     -- (retail_p25 - wholesale_p25) / retail_p25

  primary key (event_id, captured_at)
);

create index if not exists idx_event_metrics_time on event_metrics (event_id, captured_at desc);

-- ------------------------------------------------------------
-- Section-level metrics (indefinite retention)
-- One row per (event, snapshot, section). Also excludes ancillary
-- from the seat-side by using separate rows for ancillary sections.
-- ------------------------------------------------------------

create table if not exists section_metrics (
  event_id        bigint      not null,
  captured_at     timestamptz not null,
  section         text        not null,
  is_ancillary    boolean     not null default false,
  tickets_count   integer,
  groups_count    integer,
  retail_min      numeric(12,2),
  retail_median   numeric(12,2),
  retail_mean     numeric(12,2),
  retail_max      numeric(12,2),
  primary key (event_id, captured_at, section)
);

create index if not exists idx_section_metrics_time on section_metrics (event_id, captured_at desc);

-- ------------------------------------------------------------
-- Retention sweep function
-- ------------------------------------------------------------

create or replace function sweep_old_listings()
returns integer
language plpgsql
security definer
as $$
declare
  deleted_count integer;
begin
  delete from listings_snapshots
  where captured_at < now() - interval '60 days';
  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

-- ------------------------------------------------------------
-- Time-series view for the chart endpoint
-- ------------------------------------------------------------

create or replace view event_series as
select
  event_id,
  captured_at,
  tickets_count,
  groups_count,
  sections_count,
  retail_min,
  retail_p25,
  retail_median,
  retail_mean,
  retail_p75,
  retail_p90,
  retail_max,
  wholesale_median,
  wholesale_mean,
  getin_price,
  top5_concentration,
  bid_ask_proxy
from event_metrics;

-- ------------------------------------------------------------
-- Seed: NBA playoff round performers (Option B)
-- ------------------------------------------------------------

insert into watchlist (kind, ext_id, label) values
  ('performer', 104936, 'NBA Eastern Conference First Round'),
  ('performer',  31803, 'NBA Western Conference Quarterfinals'),
  ('performer',  32020, 'NBA Eastern Conference Semifinals'),
  ('performer',  32066, 'NBA Western Conference Semifinals'),
  ('performer',  32338, 'NBA Eastern Conference Finals'),
  ('performer',  32259, 'NBA Western Conference Finals'),
  ('performer',  32475, 'NBA Finals')
on conflict (kind, ext_id) do nothing;

-- Note: East Quarterfinals id 31802 and East First Round id 104936 appear
-- to be duplicate labels in TEvo's system. Both represented here just in
-- case — starting with 104936 (the one that appeared in recent performer
-- opponents). Add 31802 manually if you find it returns events the other doesn't.

-- ------------------------------------------------------------
-- Remove Yankees from watchlist (per user's "skip Yankees for now")
-- ------------------------------------------------------------

delete from watchlist where kind = 'performer' and ext_id = 15533;

-- ============================================================
-- Done. Next: deploy collect-listings edge function + pg_cron schedule.
-- ============================================================
