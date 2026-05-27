-- 20260527000000_ticketsdata_ingestion_foundation.sql
--
-- TicketsData ingestion subsystem — DATA LAYER + credit tracking.
--
-- PURPOSE (D0 build 2026-05-27, operator-directed):
--   Stand up persistent snapshots for the 4 TicketsData-only marketplaces
--   (StubHub, VividSeats, Gametime, TickPick) under the "4-interval plan"
--   (axis-1 diurnal: 4 peak-window pulls/day). SeatGeek + Evo stay native.
--   Mirrors the dormant seatdata_listings_snapshots pattern; keys on the
--   universal aq_short_event_id (match_to_aq_event_id) like the rest of the
--   cross-source bridge (PROJECT_BIBLE §5).
--
-- WHAT THIS MIGRATION DOES (data layer only — the pull cron is a follow-up
--   migration once per-event URLs are discovered into the xref):
--   1. ticketsdata_event_xref  — per (tevo_event_id, platform) URL + pull state.
--   2. ticketsdata_listings_snapshots — time-series, content_hash dedup.
--   3. ticketsdata_credit_usage — one row per /fetch|/events|/match call so we
--      can track spend vs the plan budget (1 credit/fetch, 12/match).
--   4. ticketsdata_normalize_listings(platform, content) — maps the 4 distinct
--      raw response schemas into one offer shape (verified live 2026-05-27).
--   5. v_ticketsdata_credit_usage_daily — daily/by-endpoint rollup.
--   All tables: RLS ON, NO anon grants (B1 anon-leak sweep lesson, PR #350/#354).
--
-- NOT APPLIED — authored by D0 (read-only on mutations per bible MCP §6).
--   A1 applies per push protocol after review.

-- ---------- 1. per-event cross-platform mapping ----------
create table if not exists public.ticketsdata_event_xref (
  tevo_event_id     bigint   not null,
  platform          text     not null check (platform in ('stubhub','vividseats','gametime','tickpick')),
  td_event_url      text     not null,
  td_event_id       text,
  aq_short_event_id text,
  match_method      text,
  match_confidence  numeric(3,2),
  last_pull_at      timestamptz,
  last_listings     int,
  active            boolean  not null default true,
  created_at        timestamptz not null default now(),
  primary key (tevo_event_id, platform)
);
create index if not exists ticketsdata_event_xref_active_idx
  on public.ticketsdata_event_xref (active, last_pull_at);

-- ---------- 2. listings snapshots (time series) ----------
create table if not exists public.ticketsdata_listings_snapshots (
  id                bigint generated always as identity primary key,
  tevo_event_id     bigint,
  aq_short_event_id text,
  platform          text not null,
  td_event_url      text,
  pulled_at         timestamptz not null default now(),
  listing_id        text,
  section           text,
  row_label         text,
  quantity          int,
  price_prefee      numeric,
  price_total       numeric,
  fees              numeric,
  is_parking        boolean default false,
  content_hash      text
);
create index if not exists ticketsdata_snap_event_time_idx
  on public.ticketsdata_listings_snapshots (tevo_event_id, pulled_at);
create index if not exists ticketsdata_snap_platform_time_idx
  on public.ticketsdata_listings_snapshots (platform, pulled_at);

-- ---------- 3. credit usage tracking ----------
create table if not exists public.ticketsdata_credit_usage (
  id              bigint generated always as identity primary key,
  called_at       timestamptz not null default now(),
  endpoint        text not null check (endpoint in ('fetch','events','match')),
  platform        text,
  tevo_event_id   bigint,
  credits         int  not null default 1,
  http_status     int,
  quota_remaining int,
  request_id      bigint
);
create index if not exists ticketsdata_credit_usage_time_idx
  on public.ticketsdata_credit_usage (called_at);

-- ---------- 4. normalizer: 4 raw schemas -> one offer shape ----------
-- Verified live 2026-05-27:
--   stubhub    : {status, body:{items:[{listingId, section, row, availableTickets,
--                                        rawPrice, price/priceWithFees, dealScore}]}}
--   vividseats : {status_code, event_id, items:{totalListings, offers:[{listingId,
--                                        section, row, rawPrice, rawPriceWithFees, fees,
--                                        availableTickets}]}}
--   gametime   : {status, body:[{listing_id, section_name, row, quantity,
--                                 price:{prefee,total}, ...}]}   (incl. parking)
--   tickpick   : {status_code, event_id, items:{totalListings, offers:[{listing_id,
--                                 section_name/section_id, row, quantity, price,
--                                 fees:{delivery,facility,service}, is_parking}]}}
create or replace function public.ticketsdata_normalize_listings(p_platform text, p_content jsonb)
returns table (
  listing_id text, section text, row_label text, quantity int,
  price_prefee numeric, price_total numeric, fees numeric, is_parking boolean
)
language plpgsql immutable as $fn$
begin
  if p_platform = 'stubhub' then
    return query
      select o->>'listingId', o->>'section', o->>'row',
             nullif(o->>'availableTickets','')::int,
             nullif(o->>'rawPrice','')::numeric,
             coalesce(nullif(o->>'rawPriceWithFees','')::numeric, nullif(o->>'price','')::numeric),
             nullif(o->>'fees','')::numeric,
             coalesce((o->>'section') ilike '%parking%', false)
      from jsonb_array_elements(p_content #> '{body,items}') o;

  elsif p_platform = 'vividseats' then
    return query
      select o->>'listingId', o->>'section', o->>'row',
             nullif(o->>'availableTickets','')::int,
             nullif(o->>'rawPrice','')::numeric,
             nullif(o->>'rawPriceWithFees','')::numeric,
             nullif(o->>'fees','')::numeric,
             coalesce((o->>'section') ilike '%parking%', false)
      from jsonb_array_elements(p_content #> '{items,offers}') o;

  elsif p_platform = 'gametime' then
    return query
      select o->>'listing_id', coalesce(o->>'section_name', o->>'section'), o->>'row',
             nullif(o->>'quantity','')::int,
             nullif(o #>> '{price,prefee}','')::numeric / 100.0,
             nullif(o #>> '{price,total}','')::numeric / 100.0,
             nullif(o #>> '{price,sales_tax}','')::numeric / 100.0,
             coalesce((o->>'ticket_type') ilike '%parking%'
                      or (o->>'section_name') ilike '%parking%', false)
      from jsonb_array_elements(p_content -> 'body') o;

  elsif p_platform = 'tickpick' then
    return query
      select o->>'listing_id',
             coalesce(nullif(o->>'section_name',''), o->>'section_id'), o->>'row',
             nullif(o->>'quantity','')::int,
             nullif(o->>'price','')::numeric,
             nullif(o->>'price','')::numeric
               + coalesce((o #>> '{fees,delivery}')::numeric,0)
               + coalesce((o #>> '{fees,facility}')::numeric,0)
               + coalesce((o #>> '{fees,service}')::numeric,0),
             coalesce((o #>> '{fees,delivery}')::numeric,0)
               + coalesce((o #>> '{fees,facility}')::numeric,0)
               + coalesce((o #>> '{fees,service}')::numeric,0),
             coalesce((o->>'is_parking')::boolean, false)
      from jsonb_array_elements(p_content #> '{items,offers}') o;
  end if;
end;
$fn$;

-- ---------- 5. credit-usage rollup ----------
create or replace view public.v_ticketsdata_credit_usage_daily as
select date_trunc('day', called_at) as day,
       endpoint,
       count(*)              as calls,
       sum(credits)          as credits,
       min(quota_remaining)  as quota_low,
       max(quota_remaining)  as quota_high
from public.ticketsdata_credit_usage
group by 1,2 order by 1 desc, 2;

-- ---------- 6. lock down (RLS on, anon denied) ----------
alter table public.ticketsdata_event_xref        enable row level security;
alter table public.ticketsdata_listings_snapshots enable row level security;
alter table public.ticketsdata_credit_usage       enable row level security;
revoke all on public.ticketsdata_event_xref,
              public.ticketsdata_listings_snapshots,
              public.ticketsdata_credit_usage,
              public.v_ticketsdata_credit_usage_daily
  from anon;
-- service_role (the pull cron / pg_net path) bypasses RLS; no client policies
-- needed (matches exos_mail: RLS-on, zero anon policies = deny-all to anon).
