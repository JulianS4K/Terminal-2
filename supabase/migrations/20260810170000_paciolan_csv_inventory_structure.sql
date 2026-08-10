-- Migration 20260810170000 · level:data-collection · lane:D6 (author) → A1 (apply) · writes:paciolan_csv_snapshots,paciolan_csv_blocks,paciolan_csv_ingest(jsonb),paciolan_csv_ingest_secure(text,jsonb),v_paciolan_csv_listings · reads:none · pre:20260727190000 (paciolan_event_snapshots model + paciolan_ingest_config secret) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (new tables + SECDEF ingest RPCs + anon EXECUTE grant); reuses paciolan_ingest_config.secret set by mig 20260727190000
--
-- Paciolan/eVenue INVENTORY-CSV structure — the box-office export
-- ("evenue_<org>_<season>_<item>_<ts>.csv") the operator identified as the
-- canonical Paciolan data source. Unlike the extension DOM scrape (per-seat,
-- grouped by v_paciolan_seat_groups), every export row is an ALREADY-GROUPED
-- consecutive-seat block carrying full pricing + fees, so we store the block
-- verbatim — no gaps-and-islands pass. Parser twin: paciolan_client.parse_
-- inventory_csv(). This is a NEW structure alongside the per-seat tables, not a
-- replacement; both normalize to the marketplace listing standard.
--
-- Export quirks handled UPSTREAM by the parser (documented here so the schema's
-- shape is understood): the source has duplicate header names, every other row
-- overwrites its first 20 columns with literal header strings, and org_id /
-- event_url are row-index-corrupted (org_id is derived from the event_id
-- prefix; event_url reconstructed). The block columns (25..40) are clean, so
-- what lands here is the trustworthy part of the export.

-- ---- parent: one row per CSV capture -------------------------------------
create table if not exists public.paciolan_csv_snapshots (
  id             bigint generated always as identity primary key,
  captured_at    timestamptz not null default now(),
  platform       text        not null default 'paciolan',
  host           text,                     -- eVenue host, e.g. 'gohuskies.evenue.net'
  org_id         text,                     -- derived from event_id prefix (source col corrupt)
  distributor_id text,                     -- e.g. 'UW'
  policy_cd      text,
  group_code     text,                     -- e.g. 'FBS'
  season_cd      text,                     -- e.g. 'FB26'
  item_cd        text,                     -- e.g. 'FB01'
  event_id       text,                     -- stable key, e.g. '343:FB26:FB01'
  event_url      text,                     -- reconstructed canonical perf URL
  type           text,                     -- eVenue item type, e.g. 'S'
  event_name     text,                     -- 'Football vs. Washington State'
  opponent       text,
  venue          text,
  event_date     date,
  event_time     text,                     -- as rendered (may be TBD)
  time_tbd       boolean,
  event_dt_local timestamptz,
  event_dt_utc   timestamptz,
  sale_from_dt   timestamptz,
  sold_out       boolean,
  block_count    int,                      -- # block rows in this capture
  seat_count     int,                      -- sum(qty) across blocks
  source_filename text,
  raw            jsonb                      -- full event header + any extra context
);
create index if not exists idx_paciolan_csv_snap_event
  on public.paciolan_csv_snapshots (event_id, captured_at desc);
create index if not exists idx_paciolan_csv_snap_host
  on public.paciolan_csv_snapshots (host, season_cd, item_cd, captured_at desc);

comment on table public.paciolan_csv_snapshots is
  'Paciolan/eVenue inventory-CSV capture header (one per export upload). platform=paciolan; event_id (e.g. 343:FB26:FB01) is the stable key. org_id/event_url are derived — the source columns are row-index-corrupted. Read-only upstream (RULE 2).';

-- ---- block-level listings (already grouped by the export) ----------------
create table if not exists public.paciolan_csv_blocks (
  id               bigint generated always as identity primary key,
  snapshot_id      bigint not null references public.paciolan_csv_snapshots(id) on delete cascade,
  captured_at      timestamptz not null default now(),
  event_id         text,                   -- denormalized for direct joins
  level            text,                   -- seat-key part 1, e.g. '100'
  section          text,                   -- seat-key part 2, e.g. '101'
  row              text,                   -- row label, e.g. '10'
  qty              int,                    -- seats in the block
  seat_first       text,
  seat_last        text,
  seats_range      text,                   -- '1-11' (or single seat)
  price_level      text,                   -- eVenue price-level code, e.g. '14'
  pl_desc          text,                   -- 'Corners 100'
  price_type       text,                   -- 'A'
  pt_desc          text,                   -- 'Single Game Ticket'
  price_usd        numeric,                -- face
  facility_fee_usd numeric,
  per_ticket_fee_usd numeric,
  all_in_price_usd numeric,                -- price + facility + per_ticket
  seat_key_first   text,                   -- '100:101:10:1'
  seat_key_last    text,                   -- '100:101:10:11'
  view_from_section_url text,
  raw              jsonb
);
create index if not exists idx_paciolan_csv_blocks_snap
  on public.paciolan_csv_blocks (snapshot_id, level, section, row);
create index if not exists idx_paciolan_csv_blocks_event
  on public.paciolan_csv_blocks (event_id, captured_at desc);

comment on table public.paciolan_csv_blocks is
  'Paciolan/eVenue inventory-CSV rows — one already-grouped consecutive-seat block each (row/qty/seat_first/seat_last) with full pricing + fees. level/section split from the seat key. all_in_price_usd = price + facility + per_ticket.';

-- ---- ingest RPC (mirror of paciolan_ingest) ------------------------------
-- SECURITY DEFINER: the FastAPI /api/paciolan/csv-ingest route validates the
-- shared X-Ingest-Secret (never service_role) BEFORE calling this. Inserts the
-- event header + all blocks from one parsed CSV, returns the new snapshot_id.
-- No net.* calls — writes our own tables only (RULE 2).
create or replace function public.paciolan_csv_ingest(p_payload jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_snap_id bigint;
  v_block_count int;
  v_seat_count int;
  v_event jsonb := coalesce(p_payload->'event', '{}'::jsonb);
begin
  insert into public.paciolan_csv_snapshots (
    platform, host, org_id, distributor_id, policy_cd, group_code, season_cd,
    item_cd, event_id, event_url, type, event_name, opponent, venue,
    event_date, event_time, time_tbd, event_dt_local, event_dt_utc,
    sale_from_dt, sold_out, source_filename, raw
  ) values (
    coalesce(v_event->>'platform', 'paciolan'),
    v_event->>'host', v_event->>'org_id', v_event->>'distributor_id',
    v_event->>'policy_cd', v_event->>'group_code', v_event->>'season_cd',
    v_event->>'item_cd', v_event->>'event_id', v_event->>'event_url',
    v_event->>'type', v_event->>'event_name', v_event->>'opponent',
    v_event->>'venue',
    nullif(v_event->>'event_date','')::date,
    v_event->>'event_time',
    (v_event->>'time_tbd')::boolean,
    nullif(v_event->>'event_dt_local','')::timestamptz,
    nullif(v_event->>'event_dt_utc','')::timestamptz,
    nullif(v_event->>'sale_from_dt','')::timestamptz,
    (v_event->>'sold_out')::boolean,
    p_payload->>'source_filename',
    v_event
  ) returning id into v_snap_id;

  insert into public.paciolan_csv_blocks (
    snapshot_id, event_id, level, section, row, qty, seat_first, seat_last,
    seats_range, price_level, pl_desc, price_type, pt_desc, price_usd,
    facility_fee_usd, per_ticket_fee_usd, all_in_price_usd, seat_key_first,
    seat_key_last, view_from_section_url, raw
  )
  select v_snap_id, v_event->>'event_id',
         b->>'level', b->>'section', b->>'row',
         nullif(b->>'qty','')::int,
         b->>'seat_first', b->>'seat_last', b->>'seats_range',
         b->>'price_level', b->>'pl_desc', b->>'price_type', b->>'pt_desc',
         nullif(b->>'price_usd','')::numeric,
         nullif(b->>'facility_fee_usd','')::numeric,
         nullif(b->>'per_ticket_fee_usd','')::numeric,
         nullif(b->>'all_in_price_usd','')::numeric,
         b->>'seat_key_first', b->>'seat_key_last', b->>'view_from_section_url',
         b
  from jsonb_array_elements(coalesce(p_payload->'blocks', '[]'::jsonb)) b;
  get diagnostics v_block_count = row_count;

  select coalesce(sum(qty), 0) into v_seat_count
  from public.paciolan_csv_blocks where snapshot_id = v_snap_id;

  update public.paciolan_csv_snapshots
     set block_count = v_block_count, seat_count = v_seat_count
   where id = v_snap_id;

  return v_snap_id;
end;
$$;

comment on function public.paciolan_csv_ingest(jsonb) is
  'Ingest one parsed Paciolan/eVenue inventory CSV ({event, blocks}), returns snapshot_id. SECDEF; the /api/paciolan/csv-ingest route gates the shared ingest secret first. RULE 2: writes our own tables only, never any evenue.net host.';

-- ---- marketplace listing standard (consistent with v_paciolan_listings) --
create or replace view public.v_paciolan_csv_listings as
select
  b.snapshot_id,
  b.event_id,
  s.host                                            as tenant,
  b.level,
  b.section,
  b.row,
  b.qty                                             as quantity,
  b.price_usd                                       as face_price,
  b.all_in_price_usd                                as retail_price,
  (select array(select generate_series(1, greatest(coalesce(b.qty,1),1)))) as splits,
  b.pl_desc,
  b.pt_desc,
  b.price_level,
  b.price_type,
  (b.pl_desc ilike '%wheelchair%' or b.pl_desc ilike '%accessible%') as wheelchair,
  b.seat_first,
  b.seat_last,
  b.seats_range                                     as seat_numbers,
  b.view_from_section_url
from public.paciolan_csv_blocks b
join public.paciolan_csv_snapshots s on s.id = b.snapshot_id;

comment on view public.v_paciolan_csv_listings is
  'Paciolan/eVenue inventory-CSV blocks in the marketplace listing standard (level/section/row/quantity/retail_price/splits), one row per already-grouped block. retail_price = all-in (price+fees); face_price = price_usd. Read-only.';

-- ---- RLS: paciolan_csv_* tables are service-role-only ---------------------
-- No anon/authenticated policies → deny-all to the public API. service_role
-- bypasses RLS; the SECDEF ingest functions insert regardless. Same posture as
-- the paciolan_* and axs_* snapshot tables.
alter table public.paciolan_csv_snapshots enable row level security;
alter table public.paciolan_csv_blocks    enable row level security;

-- Core insert stays service-role only (used by the FastAPI route, which gates
-- its own X-Ingest-Secret).
revoke all on function public.paciolan_csv_ingest(jsonb) from public;
grant execute on function public.paciolan_csv_ingest(jsonb) to service_role;

-- Secret-gated wrapper the extension / uploader can call with the anon key,
-- reusing the paciolan_ingest_config secret from mig 20260727190000.
create or replace function public.paciolan_csv_ingest_secure(p_secret text, p_payload jsonb)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_expected text;
  v_n int;
begin
  select secret into v_expected from public.paciolan_ingest_config where id = 1;
  if v_expected is null then
    raise exception 'paciolan ingest not configured';
  end if;
  if p_secret is null or length(p_secret) <> length(v_expected)
     or not (p_secret = v_expected) then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  v_n := coalesce(jsonb_array_length(p_payload->'blocks'), 0);
  if v_n = 0 then
    raise exception 'empty payload';
  end if;
  if v_n > 50000 then
    raise exception 'payload too large';
  end if;
  return public.paciolan_csv_ingest(p_payload);
end;
$$;

comment on function public.paciolan_csv_ingest_secure(text, jsonb) is
  'Secret-gated CSV ingest: validates the shared secret (paciolan_ingest_config) then delegates to paciolan_csv_ingest(). EXECUTE granted to anon/authenticated so an uploader can call it with the public anon key + secret. RULE 2: writes our own tables only.';

revoke all on function public.paciolan_csv_ingest_secure(text, jsonb) from public;
grant execute on function public.paciolan_csv_ingest_secure(text, jsonb) to anon, authenticated;
