-- Migration 20260727190000 · lane:A1 (data plane — new upstream source)
--   writes (DDL): paciolan_event_snapshots, paciolan_section_snapshots,
--                 paciolan_seat_snapshots (tables); paciolan_ingest(jsonb) RPC
--                 (SECDEF); v_paciolan_seat_groups, v_paciolan_listings (views)
--   reads: none (ingest is browser-extension-sourced; no server-side pull)
--   auth:  OPERATOR-APPROVAL REQUIRED before apply_migration (new source +
--          tables + SECDEF ingest RPC). Author: D0 → apply: A1.
--
-- Paciolan / eVenue primary box-office inventory, browser-extension-sourced
-- (see paciolan_extension/ + paciolan_client.py). eVenue = Paciolan's consumer
-- storefront brand at <tenant>.evenue.net; we CATEGORIZE/LABEL the source as
-- 'paciolan' (the platform) and store the tenant subdomain per row — the same
-- way the repo labels by platform. The seat-level model mirrors
-- axs_seat_snapshots, with the eVenue map's LEVEL (U/L/CH/BN/S/WC/PD/SC) split
-- out from the section label per operator directive.
--
-- DATA RULE (grouping): consecutive AVAILABLE seats in the same
-- level+section+row at the same price + seat_type collapse into one "N
-- together" block via classic gaps-and-islands — a sold/missing seat is the
-- qty break. Identical to v_axs_seat_groups.

-- ---- parent: one row per capture -----------------------------------------
create table if not exists public.paciolan_event_snapshots (
  id            bigint generated always as identity primary key,
  captured_at   timestamptz not null default now(),
  platform      text        not null default 'paciolan',
  tenant        text,                    -- eVenue subdomain, e.g. 'bgsufalcons'
  event_code    text,                    -- price_type/perf, e.g. 'F26/F01'
  source_url    text,
  event_name    text,
  venue_name    text,
  section_count int,
  seat_count    int,                     -- available seats captured
  raw           jsonb                    -- meta + any extra capture context
);
create index if not exists idx_paciolan_ev_tenant_cap
  on public.paciolan_event_snapshots (tenant, event_code, captured_at desc);

comment on table public.paciolan_event_snapshots is
  'Paciolan/eVenue capture header (one per browser-extension seat-map scrape). platform=paciolan; tenant=eVenue subdomain. Browser-extension-sourced, read-only upstream.';

-- ---- section-level availability summary (always present, no expand) -------
create table if not exists public.paciolan_section_snapshots (
  id            bigint generated always as identity primary key,
  snapshot_id   bigint not null references public.paciolan_event_snapshots(id) on delete cascade,
  captured_at   timestamptz not null default now(),
  tenant        text,
  level         text,                    -- U | L | CH | BN | S | WC | PD | SC
  section_label text,                    -- venue token, e.g. '16U','20A'
  pct_available numeric,                 -- 0..100 from the map's percent attr
  disabled      boolean,                 -- greyed/unavailable section
  raw           jsonb
);
create index if not exists idx_paciolan_sec_snap
  on public.paciolan_section_snapshots (snapshot_id, level, section_label);

comment on table public.paciolan_section_snapshots is
  'Paciolan/eVenue per-section availability % (top-level map, no seat expand). level split from section_label.';

-- ---- seat-level (mirror of axs_seat_snapshots; level split out) -----------
create table if not exists public.paciolan_seat_snapshots (
  id            bigint generated always as identity primary key,
  snapshot_id   bigint not null references public.paciolan_event_snapshots(id) on delete cascade,
  section_snapshot_id bigint references public.paciolan_section_snapshots(id) on delete set null,
  captured_at   timestamptz not null default now(),
  tenant        text,
  level         text,                    -- U | L | CH | BN | S | WC | PD | SC
  section_label text,                    -- '16U','20A'
  row_label     text,
  seat_number   text,                    -- as rendered (may be lettered/GA)
  seat_no       int,                     -- numeric parse, null for GA/lettered
  seat_type     text,                    -- standard | premium | accessible | ga
  price         numeric,
  is_ga         boolean default false,
  available     boolean default true,    -- we ingest available seats
  data_seat_key text,                    -- original 'U:16U:19:1'
  raw_item      jsonb
);
create index if not exists idx_paciolan_seat_snap
  on public.paciolan_seat_snapshots (snapshot_id, level, section_label, row_label, seat_no);

comment on table public.paciolan_seat_snapshots is
  'Paciolan/eVenue per-seat inventory (browser-extension-sourced). Mirrors axs_seat_snapshots with eVenue level split from section_label. seat_type/price are the grouping break keys.';

-- ---- ingest RPC ----------------------------------------------------------
-- SECURITY DEFINER: the FastAPI /api/paciolan/ingest route validates the
-- shared X-Ingest-Secret (never service_role) BEFORE calling this, and only a
-- service-role db may invoke it. Inserts header + sections + seats from one
-- extension capture, returns the new snapshot_id. No net.* calls (extension is
-- the only browser touchpoint; this only WRITES our own tables).
create or replace function public.paciolan_ingest(p_payload jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_snap_id bigint;
  v_seat_count int;
  v_section_count int;
begin
  insert into public.paciolan_event_snapshots (
    platform, tenant, event_code, source_url, event_name, venue_name,
    section_count, seat_count, raw
  ) values (
    coalesce(p_payload->>'platform', 'paciolan'),
    p_payload->>'tenant',
    p_payload->>'event_code',
    p_payload->>'source_url',
    p_payload->>'event_name',
    p_payload->>'venue_name',
    coalesce(jsonb_array_length(p_payload->'sections'), 0),
    coalesce(jsonb_array_length(p_payload->'seats'), 0),
    p_payload - 'sections' - 'seats'
  ) returning id into v_snap_id;

  insert into public.paciolan_section_snapshots (
    snapshot_id, tenant, level, section_label, pct_available, disabled, raw
  )
  select v_snap_id, p_payload->>'tenant',
         s->>'level', s->>'section_label',
         nullif(s->>'pct_available','')::numeric,
         coalesce((s->>'disabled')::boolean, false),
         s
  from jsonb_array_elements(coalesce(p_payload->'sections', '[]'::jsonb)) s;
  get diagnostics v_section_count = row_count;

  insert into public.paciolan_seat_snapshots (
    snapshot_id, tenant, level, section_label, row_label, seat_number,
    seat_no, seat_type, price, is_ga, available, data_seat_key, raw_item
  )
  select v_snap_id, p_payload->>'tenant',
         st->>'level', st->>'section_label', st->>'row_label',
         st->>'seat_number',
         nullif(st->>'seat_no','')::int,
         st->>'seat_type',
         nullif(st->>'price','')::numeric,
         coalesce((st->>'is_ga')::boolean, false),
         coalesce((st->>'available')::boolean, true),
         st->>'data_seat_key',
         st
  from jsonb_array_elements(coalesce(p_payload->'seats', '[]'::jsonb)) st;
  get diagnostics v_seat_count = row_count;

  update public.paciolan_event_snapshots
     set section_count = v_section_count, seat_count = v_seat_count
   where id = v_snap_id;

  return v_snap_id;
end;
$$;

comment on function public.paciolan_ingest(jsonb) is
  'Ingest one Paciolan/eVenue browser-extension capture (header+sections+seats), returns snapshot_id. SECDEF; the /api/paciolan/ingest route gates the shared ingest secret first. RULE 2: writes our own tables only, never any evenue.net host.';

-- ---- consecutive-seat grouping (twin of v_axs_seat_groups) ---------------
create or replace view public.v_paciolan_seat_groups as
with base as (
  select snapshot_id, tenant, level, section_label, row_label, seat_type,
         price, is_ga, seat_number, seat_no
  from public.paciolan_seat_snapshots
  where available is true
),
islands as (
  select *,
    case when seat_no is not null then
      seat_no - row_number() over (
        partition by snapshot_id, tenant, level, section_label, row_label,
                     seat_type, price
        order by seat_no)
    end as grp
  from base
)
select
  snapshot_id, tenant, level, section_label, row_label, seat_type, price,
  bool_or(is_ga)     as is_ga,
  count(*)           as qty,
  min(seat_no)       as seat_from,
  max(seat_no)       as seat_to,
  string_agg(coalesce(seat_no::text, seat_number), ','
             order by seat_no nulls last, seat_number) as seats
from islands
group by snapshot_id, tenant, level, section_label, row_label, seat_type,
         price, grp,
         case when grp is null then seat_number end;

comment on view public.v_paciolan_seat_groups is
  'Paciolan DATA RULE: consecutive available seats (same level+section+row+price+seat_type, adjacent seat numbers) collapsed into one "N together" block via gaps-and-islands. qty=block size, seat_from/seat_to=range, seats=members. Missing seat = qty break. Non-numeric labels stay qty-1. Mirrors v_axs_seat_groups.';

-- ---- marketplace listing standard (twin of v_axs_listings) ---------------
create or replace view public.v_paciolan_listings as
select
  g.snapshot_id,
  g.tenant,
  g.level,
  g.section_label                                   as section,
  g.row_label                                       as row,
  g.qty                                             as quantity,
  g.price                                           as retail_price,
  (select array(select generate_series(1, g.qty)))  as splits,
  g.seat_type                                       as type,
  (g.seat_type = 'accessible')                      as wheelchair,
  g.is_ga,
  g.seat_from,
  g.seat_to,
  g.seats                                           as seat_numbers
from public.v_paciolan_seat_groups g;

comment on view public.v_paciolan_listings is
  'Paciolan/eVenue box-office inventory in the marketplace listing standard (level/section/row/quantity/retail_price/type/wheelchair/splits), one row per consecutive-seat block. Adds seat_from/seat_to/seat_numbers. Read-only. Mirrors v_axs_listings.';
