-- Migration 20260829190000 · level:data-collection · lane:A1 · writes:s4k_marketplace_orders,s4k_marketplace_sync_runs,s4k_marketplace_ingest(jsonb)[new],v_s4k_marketplace_health[new] · reads:none · pre:vault.EVENUEDESK_API_KEY (seeded 2026-08-29) · auth:OPERATOR-APPROVAL REQUIRED before apply (new SECDEF fn)
--
-- S4K Marketplace Orders — landing + reconciliation.
--
-- Source: https://crm.s4kcs.com/api/v1 (X-API-Key, scope marketplace:read).
-- Live open/undelivered SELL-SIDE orders from six resale marketplaces:
-- TickPick, GoTickets, SeatGeek, StubHub, Vivid Seats, Gametime.
--
-- §0 THIS IS NOT THE eVENUE DESK FEED, AND NOT PACIOLAN.
--   Verified against the live host 2026-08-29: every /api/v1/feed/* and
--   /api/v1/events path from the eVenue Desk API reference returns 404 here.
--   That reference describes primary box-office INVENTORY (seat blocks); this
--   API serves our own resale ORDERS. Different subject, different grammar —
--   none of FEED_COLUMNS / ticket_uid / event_uid applies. Nothing here reads
--   or writes a paciolan_* or evenuedesk_* object.
--
-- §1 RULE 2. Read-only upstream. The API is documented GET-only ("Nothing here
--   can change anything") and the key carries only marketplace:read. No write
--   path to crm.s4kcs.com exists here and none may be added.
--
-- §2 NO CRON IN THIS MIGRATION — DELIBERATE. Measured 2026-08-29: one
--   /marketplace/orders call returns 22,399 rows in a 10,304,034-byte body and
--   takes ~60 s. Polling that through pg_net every 10 minutes would push
--   ~1.5 GB/day into net._http_response, which on this project is ALREADY
--   58 GB across 288k rows with only a `created` index and no pruning. The
--   fetch must therefore happen in an edge function / app route that parses in
--   memory and calls s4k_marketplace_ingest() with the result, so pg_net only
--   ever carries a small summary — the same shape as the espn-collect crons
--   (migration 20260507000021). The cron lands with that fetcher, not here.
--
-- §3 PARTIAL SUCCESS IS NORMAL — the reconciliation rule.
--   A live fetch returns HTTP 200 with rows from the marketplaces that
--   answered and an `errors[]` naming those that did not. So "no StubHub rows"
--   can mean StubHub had none OR StubHub errored, and those must never be
--   conflated. s4k_marketplace_ingest() therefore closes out stale orders
--   ONLY for sources that actually reported in this payload. A source in
--   errors[] is left completely untouched.
--   The same applies to `filtered_by_source`: rows dropped by the event-date
--   window are absent from `rows` but still exist upstream (measured: 7,081
--   filtered, SeatGeek 3253 / StubHub 3601 / Vivid Seats 227), so a windowed
--   pull must NOT be used to close out orders. `p_windowed` makes that
--   explicit and disables close-out entirely.

-- ---- 1) current open orders -------------------------------------------------
create table if not exists public.s4k_marketplace_orders (
  source          text not null,          -- TickPick | GoTickets | SeatGeek | StubHub | Vivid Seats | Gametime
  order_id        text not null,          -- upstream `id`; ALWAYS text (values like 'AQPMJSE2FO' are not numeric)
  order_status    text,
  seller_status   text,
  event_name      text,
  event_date      date,
  venue_name      text,
  venue_city      text,
  venue_state     text,
  section         text,
  row_label       text,                   -- upstream key is `row`, which is reserved-ish in SQL
  seats           text,                   -- free text: '5, 6', '*', or ''
  quantity        int,
  price           numeric,                -- seller payout / wholesale figure, USD
  delivery        text,
  inhand_date     date,
  payout_date     date,
  notes           text,
  purchase_date   date,
  first_seen_at   timestamptz not null default now(),
  last_seen_at    timestamptz not null default now(),
  closed_at       timestamptz,            -- set when a reporting source stops listing it
  primary key (source, order_id)
);
create index if not exists idx_s4k_mkt_open       on public.s4k_marketplace_orders (source, event_date)
  where closed_at is null;
create index if not exists idx_s4k_mkt_event_date on public.s4k_marketplace_orders (event_date);
create index if not exists idx_s4k_mkt_last_seen  on public.s4k_marketplace_orders (last_seen_at desc);
alter table public.s4k_marketplace_orders enable row level security;  -- service-role only
comment on table public.s4k_marketplace_orders is
  'Open/undelivered sell-side orders across six resale marketplaces, from crm.s4kcs.com /api/v1/marketplace/orders. Separate source from paciolan_* (primary box-office inventory). closed_at is set only when a source that actually REPORTED in a full pull stops listing the order — never on a partial or windowed pull.';
grant select on public.s4k_marketplace_orders to service_role;

-- ---- 2) one row per sync run (small; the audit trail) -----------------------
create table if not exists public.s4k_marketplace_sync_runs (
  id                 bigint generated always as identity primary key,
  ran_at             timestamptz not null default now(),
  fetched_at         timestamptz,          -- upstream's own timestamp
  row_count          int,
  upserted           int,
  closed             int,
  sources_reported   text[],               -- markets that answered
  sources_errored    jsonb,                -- upstream errors[] verbatim
  filtered_out       int,
  filtered_by_source jsonb,
  windowed           boolean default false,
  ev_from            date,
  ev_to              date
);
create index if not exists idx_s4k_mkt_runs_ran on public.s4k_marketplace_sync_runs (ran_at desc);
alter table public.s4k_marketplace_sync_runs enable row level security;
comment on table public.s4k_marketplace_sync_runs is
  'Audit trail for S4K marketplace order syncs. sources_errored non-empty means the run was PARTIAL and closed out nothing for those markets.';
grant select on public.s4k_marketplace_sync_runs to service_role;

-- ---- 3) ingest + reconcile ---------------------------------------------------
-- p_payload is the raw /marketplace/orders response:
--   {count, rows[], errors[], filtered_out, filtered_by_source, window, fetched_at}
create or replace function public.s4k_marketplace_ingest(
  p_payload  jsonb,
  p_windowed boolean default false
)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_run_id    bigint;
  v_reported  text[];
  v_errored   jsonb := coalesce(p_payload->'errors', '[]'::jsonb);
  v_upserted  int := 0;
  v_closed    int := 0;
begin
  if p_payload is null or jsonb_typeof(p_payload->'rows') <> 'array' then
    raise exception 's4k_marketplace_ingest: payload has no rows[] array';
  end if;

  -- Which sources can this payload actually speak for? A market present in
  -- errors[] reported NOTHING, so its absence from rows[] is meaningless.
  select coalesce(array_agg(distinct s), '{}')
    into v_reported
    from jsonb_array_elements(p_payload->'rows') r
    cross join lateral (select r->>'source' as s) x
   where s is not null and s <> ''
     and not exists (
       select 1 from jsonb_array_elements(v_errored) e
        where lower(e->>'market') = lower(s)
     );

  -- Upsert every row we received. Empty strings are normalized to NULL before
  -- casting: the API sends '' rather than null for absent dates.
  with incoming as (
    select
      r->>'source'                                as source,
      r->>'id'                                    as order_id,
      r->>'order_status'                          as order_status,
      r->>'seller_status'                         as seller_status,
      r->>'event_name'                            as event_name,
      nullif(r->>'event_date','')::date           as event_date,
      r->>'venue_name'                            as venue_name,
      r->>'venue_city'                            as venue_city,
      r->>'venue_state'                           as venue_state,
      r->>'section'                               as section,
      r->>'row'                                   as row_label,
      r->>'seats'                                 as seats,
      nullif(r->>'quantity','')::int              as quantity,
      nullif(r->>'price','')::numeric             as price,
      r->>'delivery'                              as delivery,
      nullif(r->>'inhand_date','')::date          as inhand_date,
      nullif(r->>'payout_date','')::date          as payout_date,
      r->>'notes'                                 as notes,
      nullif(r->>'purchase_date','')::date        as purchase_date
    from jsonb_array_elements(p_payload->'rows') r
    where coalesce(r->>'source','') <> '' and coalesce(r->>'id','') <> ''
  ), upserted as (
    insert into public.s4k_marketplace_orders as o (
      source, order_id, order_status, seller_status, event_name, event_date,
      venue_name, venue_city, venue_state, section, row_label, seats,
      quantity, price, delivery, inhand_date, payout_date, notes, purchase_date,
      last_seen_at, closed_at
    )
    select source, order_id, order_status, seller_status, event_name, event_date,
           venue_name, venue_city, venue_state, section, row_label, seats,
           quantity, price, delivery, inhand_date, payout_date, notes, purchase_date,
           now(), null
      from incoming
    on conflict (source, order_id) do update set
      order_status  = excluded.order_status,
      seller_status = excluded.seller_status,
      event_name    = excluded.event_name,
      event_date    = excluded.event_date,
      venue_name    = excluded.venue_name,
      venue_city    = excluded.venue_city,
      venue_state   = excluded.venue_state,
      section       = excluded.section,
      row_label     = excluded.row_label,
      seats         = excluded.seats,
      quantity      = excluded.quantity,
      price         = excluded.price,
      delivery      = excluded.delivery,
      inhand_date   = excluded.inhand_date,
      payout_date   = excluded.payout_date,
      notes         = excluded.notes,
      purchase_date = excluded.purchase_date,
      last_seen_at  = now(),
      closed_at     = null            -- it is listed again; reopen it
    returning 1
  )
  select count(*) into v_upserted from upserted;

  -- Close out orders a REPORTING source no longer lists.
  --
  -- Skipped entirely for a windowed pull: rows outside the event-date window
  -- are absent from rows[] but still open upstream (measured 7,081 such rows
  -- on the default window), so closing on a windowed pull would mass-close
  -- live orders. Only a full pull may close.
  if not p_windowed and array_length(v_reported, 1) is not null then
    with closed as (
      update public.s4k_marketplace_orders o
         set closed_at = now()
       where o.closed_at is null
         and o.source = any(v_reported)
         and not exists (
           select 1 from jsonb_array_elements(p_payload->'rows') r
            where r->>'source' = o.source and r->>'id' = o.order_id
         )
      returning 1
    )
    select count(*) into v_closed from closed;
  end if;

  insert into public.s4k_marketplace_sync_runs (
    fetched_at, row_count, upserted, closed, sources_reported, sources_errored,
    filtered_out, filtered_by_source, windowed, ev_from, ev_to
  ) values (
    nullif(p_payload->>'fetched_at','')::timestamptz,
    coalesce((p_payload->>'count')::int, jsonb_array_length(p_payload->'rows')),
    v_upserted, v_closed, v_reported, v_errored,
    nullif(p_payload->>'filtered_out','')::int,
    p_payload->'filtered_by_source',
    p_windowed,
    nullif(p_payload#>>'{window,ev_from}','')::date,
    nullif(p_payload#>>'{window,ev_to}','')::date
  ) returning id into v_run_id;

  return v_run_id;
end $$;

revoke all on function public.s4k_marketplace_ingest(jsonb, boolean) from public;
grant execute on function public.s4k_marketplace_ingest(jsonb, boolean) to service_role;
comment on function public.s4k_marketplace_ingest is
  'Land one /marketplace/orders response. Closes out stale orders ONLY for sources that actually reported (never for a source in errors[]), and never on a windowed pull — a market that errored or a row outside the window is absent from rows[] but still open upstream.';

-- ---- 4) health view ---------------------------------------------------------
create or replace view public.v_s4k_marketplace_health as
select
  (select max(ran_at) from public.s4k_marketplace_sync_runs)                    as last_run_at,
  (select count(*) from public.s4k_marketplace_orders where closed_at is null)  as open_orders,
  (select count(distinct source) from public.s4k_marketplace_orders
    where closed_at is null)                                                    as sources_with_open_orders,
  -- Partial runs are the thing to watch: a market erroring for hours means its
  -- orders are silently frozen at whatever the last good pull saw.
  (select count(*) from public.s4k_marketplace_sync_runs
    where ran_at > now() - interval '24 hours'
      and sources_errored <> '[]'::jsonb)                                       as partial_runs_24h,
  (select sources_errored from public.s4k_marketplace_sync_runs
    order by ran_at desc limit 1)                                               as last_run_errors,
  (select max(last_seen_at) from public.s4k_marketplace_orders)                 as freshest_order_seen;
comment on view public.v_s4k_marketplace_health is
  'S4K marketplace sync health. partial_runs_24h > 0 means some marketplace has been failing and its orders are stale, not absent.';
grant select on public.v_s4k_marketplace_health to service_role;
