-- Owned-inventory tracking + retail-dispersion metrics.
-- Already applied to prod via Supabase MCP on 2026-04-25; captured here for reproducibility.
-- Replaces the always-zero bid_ask_proxy with three real signals derived from /v9/ticket_groups.

alter table listings_snapshots
  add column if not exists office_id      bigint,
  add column if not exists office_name    text,
  add column if not exists brokerage_id   bigint,
  add column if not exists brokerage_name text,
  add column if not exists is_owned       boolean not null default false;

create index if not exists idx_listings_owned
  on listings_snapshots (event_id, captured_at)
  where is_owned = true;

alter table event_metrics
  add column if not exists price_dispersion    numeric,  -- retail_p75 / retail_p25
  add column if not exists tail_premium        numeric,  -- retail_p90 / retail_median
  add column if not exists owned_groups_count  integer,
  add column if not exists owned_tickets_count integer,
  add column if not exists owned_share         numeric,  -- owned_tickets_count / tickets_count
  add column if not exists owned_median_retail numeric;

comment on column event_metrics.price_dispersion is
  'Retail interquartile ratio: retail_p75 / retail_p25. Higher = wider price band.';
comment on column event_metrics.tail_premium is
  'Premium of the high tail vs median: retail_p90 / retail_median. Higher = steeper top end.';
comment on column event_metrics.owned_share is
  'Share of seat-tickets owned by S4K vs total marketplace: owned_tickets_count / tickets_count.';
