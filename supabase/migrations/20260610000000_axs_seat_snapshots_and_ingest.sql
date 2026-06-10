-- AXS per-seat retention + snapshot ingest wired into the serial drainer.
--
-- Until now axs_probe_step() read only body.meta.api to classify, then threw the
-- ~1.8MB veritix body away. AXS is seat-granular (offers[].items[] = individual
-- seats with section/row/seat#/type/status/price-level), so we now persist the
-- full pull: axs_event_snapshots (event metrics + raw) + axs_section_snapshots
-- (per-section rollup) + axs_seat_snapshots (every seat, max retention incl. the
-- raw item jsonb). Read-only upstream: this only PARSES a GET response already in
-- net._http_response — no new outbound call (CLAUDE.md §2).

-- ---- per-seat retention table ----------------------------------------------
create table if not exists public.axs_seat_snapshots (
  id                  bigint generated always as identity primary key,
  snapshot_id         bigint not null references public.axs_event_snapshots(id) on delete cascade,
  section_snapshot_id bigint references public.axs_section_snapshots(id) on delete set null,
  captured_at         timestamptz not null default now(),
  tevo_event_id       bigint,
  tevo_venue_id       bigint,
  axs_event_id        text,
  section_id          text,
  section_label       text,
  row_id              text,
  row_label           text,
  seat_number         text,
  seat_type           text,        -- STANDARD | ACCESSIBLE | FLASHSEATS | PREMIUMVIP
  status_code         int,
  status_label        text,
  neighborhood        text,
  neighborhood_label  text,
  price_level_id      text,
  price_level_label   text,
  price_code_label    text,
  is_ga               boolean,
  display_order       int,
  offer_id            text,
  src                 text,        -- primary | resale (9000000… offerIDs = AXS-Marketplace resale)
  price               numeric,     -- resolved $ (price-level base, else originalPrice)
  original_price      numeric,
  seller_name         text,
  info1               text,
  info2               text,
  raw_item            jsonb        -- full seat object — retain everything
);
create index if not exists axs_seat_snapshots_snapshot_idx   on public.axs_seat_snapshots (snapshot_id);
create index if not exists axs_seat_snapshots_section_idx     on public.axs_seat_snapshots (section_snapshot_id);
create index if not exists axs_seat_snapshots_tevo_event_idx  on public.axs_seat_snapshots (tevo_event_id) where tevo_event_id is not null;
create index if not exists axs_seat_snapshots_axs_event_idx   on public.axs_seat_snapshots (axs_event_id, captured_at desc);
comment on table public.axs_seat_snapshots is
  'Per-seat normalization of an AXS pull (FK axs_event_snapshots / axs_section_snapshots). One row per veritix offers[].items[] seat; raw_item retains the full source object. Read-only source.';
alter table public.axs_seat_snapshots enable row level security;

-- probe log learns where it persisted (and whether it still needs to)
alter table public.axs_probe add column if not exists snapshot_id bigint;

-- ---- ingest: parse one veritix response into event+section+seat rows -------
create or replace function public.axs_ingest_snapshot(p_response_id bigint, p_axs_event_id text)
returns bigint
language plpgsql security definer set search_path = public, net, extensions as $$
declare
  v_content jsonb; v_body jsonb; v_meta jsonb;
  v_tevo_event bigint; v_tevo_venue bigint; v_event_url text;
  v_snap bigint;
begin
  select content::jsonb into v_content from net._http_response where id = p_response_id;
  if v_content is null then return null; end if;
  v_body := v_content->'body';
  v_meta := v_body->'meta';
  if (v_meta->>'api') is distinct from 'veritix' then return null; end if;  -- only real payloads

  select tevo_event_id, tevo_venue_id, event_url
    into v_tevo_event, v_tevo_venue, v_event_url
  from public.axs_events where axs_event_id = p_axs_event_id;

  -- flatten every seat once, resolving price from the price-level map (cents->$)
  create temp table _axs_seats on commit drop as
  select
    it as raw_item,
    it->>'sectionID' as section_id, it->>'sectionLabel' as section_label,
    it->>'rowID' as row_id, it->>'rowLabel' as row_label, it->>'number' as seat_number,
    it->>'seatType' as seat_type,
    nullif(it->>'statusCode','')::int as status_code, it->>'statusCodeLabel' as status_label,
    it->>'neighborhoodPrintDescription' as neighborhood, it->>'neighborhoodLabel' as neighborhood_label,
    it->>'priceLevelID' as price_level_id, it->>'priceLevelLabel' as price_level_label,
    it->>'priceCodeLabel' as price_code_label,
    (it->>'isGASection')::boolean as is_ga,
    nullif(it->>'displayOrder','')::int as display_order,
    it->>'offerID' as offer_id,
    case when (it->>'offerID') ~ '^9' then 'resale' else 'primary' end as src,
    coalesce(pm.price, nullif(it->>'originalPrice','')::numeric) as price,
    nullif(it->>'originalPrice','')::numeric as original_price,
    it->>'sellerName' as seller_name, it->>'info1' as info1, it->>'info2' as info2
  from jsonb_array_elements(v_body->'offers'->'offers') o,
       jsonb_array_elements(o->'items') it
  left join lateral (
    select max((pl->'prices'->0->>'base')::numeric)/100 as price
    from jsonb_array_elements(v_body->'prices'->'offerPrices') op,
         jsonb_array_elements(op->'zonePrices') zp,
         jsonb_array_elements(zp->'priceLevels') pl
    where pl->>'priceLevelID' = it->>'priceLevelID'
  ) pm on true;

  -- event-level snapshot
  insert into public.axs_event_snapshots (
    axs_event_id, event_url, tevo_event_id, tevo_venue_id, event_name, venue_name,
    occurs_at_local, event_tz, api, currency, price_min, price_max, getin,
    listings_count, sections_count, offers_count, seats_primary, seats_resale,
    in_axs_list, canonical_matched, response_s, quota_remaining, raw)
  select
    p_axs_event_id, v_event_url, v_tevo_event, v_tevo_venue,
    v_meta->>'event', v_meta->>'venue',
    v_meta->>'event_date', v_meta->>'event_date_zone', v_meta->>'api',
    coalesce(v_body->'prices'->>'currency','USD'),
    nullif(v_meta->>'price_min','')::numeric, nullif(v_meta->>'price_max','')::numeric,
    (select min(price) from _axs_seats),
    nullif(v_meta->>'listings','')::int, nullif(v_meta->>'sections_count','')::int,
    nullif(v_meta->>'offer_groups','')::int,
    (select count(*) from _axs_seats where src='primary'),
    (select count(*) from _axs_seats where src='resale'),
    (v_tevo_venue is not null), (v_tevo_venue is not null),
    nullif(v_content->>'response_s','')::numeric,
    nullif(v_content->>'quota_remaining','')::bigint,
    v_body
  returning id into v_snap;

  -- per-section rollup (capture section_label -> id for the seat FK)
  create temp table _axs_secmap (id bigint, section_label text) on commit drop;
  with ins as (
    insert into public.axs_section_snapshots (
      snapshot_id, tevo_event_id, tevo_venue_id, axs_event_id, section_label,
      neighborhood, is_ga, sold_out, avail_qty, price_min, price_max, seat_types, has_resale)
    select v_snap, v_tevo_event, v_tevo_venue, p_axs_event_id, s.section_label,
           max(s.neighborhood), bool_or(coalesce(s.is_ga,false)), false,
           count(*), min(s.price), max(s.price),
           array_agg(distinct s.seat_type) filter (where s.seat_type is not null),
           bool_or(s.src='resale')
    from _axs_seats s group by s.section_label
    returning id, section_label)
  insert into _axs_secmap select id, section_label from ins;

  -- every seat, linked to its section snapshot
  insert into public.axs_seat_snapshots (
    snapshot_id, section_snapshot_id, tevo_event_id, tevo_venue_id, axs_event_id,
    section_id, section_label, row_id, row_label, seat_number, seat_type,
    status_code, status_label, neighborhood, neighborhood_label, price_level_id,
    price_level_label, price_code_label, is_ga, display_order, offer_id, src,
    price, original_price, seller_name, info1, info2, raw_item)
  select v_snap, m.id, v_tevo_event, v_tevo_venue, p_axs_event_id,
         s.section_id, s.section_label, s.row_id, s.row_label, s.seat_number, s.seat_type,
         s.status_code, s.status_label, s.neighborhood, s.neighborhood_label, s.price_level_id,
         s.price_level_label, s.price_code_label, s.is_ga, s.display_order, s.offer_id, s.src,
         s.price, s.original_price, s.seller_name, s.info1, s.info2, s.raw_item
  from _axs_seats s
  left join _axs_secmap m on m.section_label is not distinct from s.section_label;

  drop table if exists _axs_seats;
  drop table if exists _axs_secmap;
  return v_snap;
end $$;

-- ---- drainer: persist confirmed pulls + refresh axs_ok on a cadence ---------
create or replace function public.axs_probe_step(p_max_attempts int default 4, p_refresh_hours int default 12)
returns table(action text, ev text, detail text)
language plpgsql security definer set search_path = public, net, extensions as $$
declare
  v_ev text; v_url text; v_rid bigint; v_snap bigint;
begin
  -- PHASE 1: classify any landed in-flight response. A confirmed axs_ok event is
  -- never demoted by a later flaky no_data (refresh pulls can come back empty).
  update public.axs_probe p
  set status_code = r.status_code,
      checked_at  = now(),
      last_reason = coalesce(r.content::jsonb->'body'->'meta'->>'reason',
                             case when r.error_msg is not null then 'timeout'
                                  when r.status_code in (502,503,504) then 'worker_unavailable'
                                  when r.status_code=200 and (r.content::jsonb->'body'->'meta'->>'api')='veritix' then 'veritix'
                                  else null end),
      is_axs_primary = case
        when r.status_code=200 and (r.content::jsonb->'body'->'meta'->>'api')='veritix' then true
        when p.is_axs_primary then true                              -- already confirmed; keep
        when r.status_code in (400,404,410,422) then false
        when r.status_code=200 then case when p.attempts >= p_max_attempts then false else null end
        else null end,
      status = case
        when r.status_code=200 and (r.content::jsonb->'body'->'meta'->>'api')='veritix' then 'axs_ok'
        when p.is_axs_primary then 'axs_ok'                          -- already confirmed; keep
        when r.status_code in (400,404,410,422) then 'not_axs'
        when r.status_code=200 then case when p.attempts >= p_max_attempts then 'not_axs' else 'retry' end
        else case when p.attempts >= p_max_attempts then 'inconclusive' else 'retry' end
      end
  from net._http_response r
  where r.id = p.request_id and p.checked_at is null;

  -- persist a full snapshot for any freshly-landed veritix pull not yet ingested
  for v_ev, v_rid in
    select p.axs_event_id, p.request_id
    from public.axs_probe p
    join net._http_response r on r.id = p.request_id
    where p.status='axs_ok' and p.snapshot_id is null
      and (r.content::jsonb->'body'->'meta'->>'api')='veritix'
  loop
    v_snap := public.axs_ingest_snapshot(v_rid, v_ev);
    if v_snap is not null then
      update public.axs_probe set snapshot_id = v_snap where axs_event_id = v_ev;
      update public.axs_events
        set last_snapshot_id = v_snap, last_pulled_at = now(), api = 'veritix'
        where axs_event_id = v_ev;
    end if;
  end loop;

  -- mirror terminal verdicts onto the registry
  update public.axs_events e
  set is_axs_primary = p.is_axs_primary, probe_status = p.status, probed_at = p.checked_at
  from public.axs_probe p
  where p.axs_event_id = e.axs_event_id
    and p.status in ('axs_ok','not_axs','inconclusive')
    and (e.probe_status is distinct from p.status or e.probed_at is distinct from p.checked_at);

  -- serial: never fire while a prior request is still outstanding
  if exists (select 1 from public.axs_probe where request_id is not null and checked_at is null) then
    return query select 'in_flight'::text, null::text, 'awaiting prior response'::text; return;
  end if;

  -- PHASE 2: next eligible = unprobed, retryable under cap, OR a stale axs_ok due
  -- for a refresh snapshot. Classification (unprobed/retry) is prioritized first.
  select e.axs_event_id, e.event_url into v_ev, v_url
  from public.axs_events e
  left join public.axs_probe p on p.axs_event_id = e.axs_event_id
  where e.active
    and (
      p.axs_event_id is null
      or (p.status='retry' and p.attempts < p_max_attempts)
      or (p.status='axs_ok' and (e.last_pulled_at is null
                                 or e.last_pulled_at < now() - make_interval(hours => p_refresh_hours)))
    )
  order by
    case when p.axs_event_id is null or p.status='retry' then 0 else 1 end,
    coalesce(p.attempts,0), coalesce(e.last_pulled_at, 'epoch'::timestamptz), e.axs_event_id
  limit 1;

  if v_ev is null then
    return query select 'done'::text, null::text, 'all events terminal / fresh'::text; return;
  end if;

  select net.http_get(
    url := 'https://ticketsdata.com/fetch',
    params := jsonb_build_object(
      'username',  public.get_app_secret(p_name => 'TICKETSDATA_USERNAME'),
      'password',  public.get_app_secret(p_name => 'TICKETSDATA_PASSWORD'),
      'event_url', v_url, 'platform', 'axs'),
    timeout_milliseconds := 100000
  ) into v_rid;

  -- re-fire resets the per-pull state (snapshot_id null => the new pull re-ingests)
  -- but preserves is_axs_primary so an established verdict survives a flaky refresh.
  insert into public.axs_probe (axs_event_id, request_id, fired_at, attempts, status)
  values (v_ev, v_rid, now(), 1, 'pending')
  on conflict (axs_event_id) do update
    set request_id=excluded.request_id, fired_at=now(),
        attempts=public.axs_probe.attempts+1, status='pending',
        checked_at=null, status_code=null, snapshot_id=null;

  return query select 'fired'::text, v_ev, ('rid='||v_rid)::text;
end $$;

-- one-shot: let the 21 already-confirmed axs_ok events ingest on the next pass
-- (their original buffers were purged) by clearing their last_pulled_at so the
-- refresh window picks them up.
update public.axs_events set last_pulled_at = null where probe_status = 'axs_ok';
