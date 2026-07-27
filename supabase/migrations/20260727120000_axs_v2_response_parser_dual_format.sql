-- ============================================================================
-- Migration 20260727120000 — AXS v2 response parser (dual-format) + drain self-heal
--
-- Lane:     A1 (data plane — AXS ingest pipeline)
-- Touches:  axs_ingest_snapshot() (W), axs_probe_step() (W),
--           axs_resp_ok() (W, new), axs_resp_reason() (W, new),
--           axs_probe (W, runtime), axs_event_snapshots (W, runtime),
--           axs_section_snapshots (W, runtime), axs_seat_snapshots (W, runtime),
--           axs_events (W, runtime, via ingest)
-- Pre-reqs: 20260629210030 (axs_probe_step backoff), 20260610060000 (axs_ingest_snapshot),
--           net._http_response, public.safe_jsonb, public.td_charge_credit,
--           vault: TICKETSDATA_USERNAME/PASSWORD (unchanged)
--
-- WHY: TicketsData restructured its AXS (/fetch?platform=axs) payload. The old
-- "veritix" envelope (body.meta / body.prices.offerPrices / body.offers.offers /
-- body.startflow) is gone; the new envelope is body.event{} + body.status/exit_code,
-- and — crucially — the SAME per-seat manifest + price book, just RELOCATED to
-- body.inventory.offer_search[0].offers[].items[] and
-- body.inventory.inventory_v4[0].offerPrices. The old distiller keyed on
-- body.meta.api == 'veritix', so since ~2026-07-02 every pull returned HTTP 200 but
-- ingested to NULL (216 events stranded at snapshot_id=-1), and a lost 'pending'
-- probe wedged the drain via the in-flight guard — AXS was dark ~25 days.
--
-- WHAT: keep BOTH formats — new (v2) default, legacy veritix fallback. The seat
-- item shape is identical across formats, so a single shared extraction feeds
-- axs_event_snapshots + axs_section_snapshots + axs_seat_snapshots (the latter
-- powers v_axs_seat_groups -> v_axs_listings, i.e. the section/row/qty table);
-- only the JSON path to the manifest + price book and the event-metadata fields
-- differ per format. Plus harden axs_probe_step: (1) success classifier accepts
-- either envelope; (2) self-heal probes stuck 'pending' whose response aged out of
-- net's TTL, and only treat sub-10-minute pendings as in-flight, so one lost
-- response can't deadlock the drain again; (3) deactivate events the harvester
-- reports 'expired' (past) so they stop burning TD credits every refresh cycle.
--
-- New immutable helpers axs_resp_ok()/axs_resp_reason() classify either envelope.
-- ============================================================================

create or replace function public.axs_resp_ok(p jsonb)
returns boolean language sql immutable as $$
  select coalesce(
       (p->'body'->'meta'->>'api') = 'veritix'                          -- legacy veritix envelope
    or (    (p->'body'->>'status') in ('ok','success')
        and coalesce(p->'body'->>'exit_code','0') = '0'
        and jsonb_typeof(p->'body'->'event') = 'object' ),              -- new v2 harvest envelope
    false);
$$;

create or replace function public.axs_resp_reason(p jsonb, p_status int, p_err text)
returns text language sql immutable as $$
  select case
    when (p->'body'->'meta'->>'reason') is not null then p->'body'->'meta'->>'reason'
    when p_err is not null                          then 'timeout'
    when p_status in (502,503,504)                  then 'worker_unavailable'
    when p_status = 200 and (p->'body'->'meta'->>'api') = 'veritix' then 'veritix'
    when p_status = 200 and (p->'body'->>'status') in ('ok','success')
         and jsonb_typeof(p->'body'->'event') = 'object'            then 'axs_v2'
    when p_status = 200                             then 'non_json'
    else null end;
$$;

-- ---------------------------------------------------------------------------
-- axs_ingest_snapshot — dual-format, shared seat-level extraction
-- ---------------------------------------------------------------------------
create or replace function public.axs_ingest_snapshot(p_response_id bigint, p_axs_event_id text)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'public', 'net', 'extensions', 'pg_temp'
as $function$
declare
  v_content jsonb; v_body jsonb; v_meta jsonb; v_event jsonb;
  v_is_new boolean; v_is_old boolean; v_venue_name text;
  v_offers jsonb; v_offerprices jsonb;
  v_tevo_event bigint; v_tevo_venue bigint; v_event_url text; v_snap bigint;
begin
  select public.safe_jsonb(content) into v_content from net._http_response where id = p_response_id;
  if v_content is null then return null; end if;
  v_body := v_content->'body';
  v_meta := v_body->'meta';

  v_is_new := (    jsonb_typeof(v_body->'event') = 'object'
               and coalesce(v_body->>'status','') in ('ok','success')
               and coalesce(v_body->>'exit_code','0') = '0');
  v_is_old := ((v_meta->>'api') = 'veritix');
  if not v_is_new and not v_is_old then return null; end if;

  select tevo_event_id, tevo_venue_id, event_url
    into v_tevo_event, v_tevo_venue, v_event_url
  from public.axs_events where axs_event_id = p_axs_event_id;

  -- Locate the seat manifest + price book (relocated in v2, identical shape).
  if v_is_new then
    v_event       := v_body->'event';
    v_venue_name  := v_event->'venue'->>'name';
    v_offers      := v_body->'inventory'->'offer_search'->0->'offers';
    v_offerprices := v_body->'inventory'->'inventory_v4'->0->'offerPrices';
  else
    v_venue_name  := v_meta->>'venue';
    v_offers      := v_body->'offers'->'offers';
    v_offerprices := v_body->'prices'->'offerPrices';
  end if;

  if v_tevo_venue is null then
    select tevo_venue_id into v_tevo_venue from public.axs_venues
    where axs_name_norm = public.venue_norm(v_venue_name) and tevo_venue_id is not null limit 1;
  end if;

  -- Shared per-seat extraction (both formats use the same item shape).
  drop table if exists _axs_seats;
  create temp table _axs_seats on commit drop as
  select
    it as raw_item,
    it->>'sectionID' as section_id, it->>'sectionLabel' as section_label,
    it->>'rowID' as row_id, it->>'rowLabel' as row_label, it->>'number' as seat_number,
    it->>'seatType' as seat_type,
    nullif(it->>'statusCode','')::int as status_code, it->>'statusCodeLabel' as status_label,
    coalesce(it->>'neighborhoodPrintDescription', it->>'neighborhoodLabel') as neighborhood,
    it->>'neighborhoodLabel' as neighborhood_label,
    it->>'priceLevelID' as price_level_id, it->>'priceLevelLabel' as price_level_label,
    it->>'priceCodeLabel' as price_code_label,
    (it->>'isGASection')::boolean as is_ga,
    nullif(it->>'displayOrder','')::int as display_order,
    it->>'offerID' as offer_id,
    -- Resale detection is FORMAT-SPECIFIC: v2 carries offerType in the price book
    -- ('Single' = primary, '…Resale…' = resale); the offerID '9…' prefix is a stale
    -- FlashSeats artifact that is WRONG in v2 (v2 primary offerIDs also start with 9).
    case when v_is_new then
           case when lower(coalesce(otype.offer_type,'')) like '%resale%' then 'resale' else 'primary' end
         else
           case when (it->>'offerID') ~ '^9' then 'resale' else 'primary' end
    end as src,
    coalesce(pm.price, nullif(it->>'originalPrice','')::numeric) as price,
    nullif(it->>'originalPrice','')::numeric as original_price,
    it->>'sellerName' as seller_name, it->>'info1' as info1, it->>'info2' as info2
  from jsonb_array_elements(coalesce(v_offers,'[]'::jsonb)) o,
       jsonb_array_elements(coalesce(o->'items','[]'::jsonb)) it
  left join lateral (
    select max((pl->'prices'->0->>'base')::numeric)/100 as price
    from jsonb_array_elements(coalesce(v_offerprices,'[]'::jsonb)) op,
         jsonb_array_elements(op->'zonePrices') zp,
         jsonb_array_elements(zp->'priceLevels') pl
    where pl->>'priceLevelID' = it->>'priceLevelID'
  ) pm on true
  left join lateral (
    select op->>'offerType' as offer_type
    from jsonb_array_elements(coalesce(v_offerprices,'[]'::jsonb)) op
    where op->>'offerID' = it->>'offerID' limit 1
  ) otype on true;

  if v_is_new then
    insert into public.axs_event_snapshots (
      axs_event_id, event_url, tevo_event_id, tevo_venue_id, event_name, venue_name,
      occurs_at_local, event_tz, api, onsale_now, currency, price_min, price_max, getin,
      listings_count, sections_count, offers_count, seats_primary, seats_resale,
      in_axs_list, canonical_matched, response_s, quota_remaining, raw)
    select
      p_axs_event_id, v_event_url, v_tevo_event, v_tevo_venue,
      v_event->>'title', v_venue_name,
      v_event->>'starts_local', coalesce(v_event->>'timezone', v_event->'venue'->>'timezone'),
      'veritix',                                       -- normalize source tag; downstream stays uniform
      (v_body->'onsale'->'status'->>'onSaleNow')::boolean,
      coalesce(v_event->>'currency','USD'),
      (select min(price) from _axs_seats),
      (select max(price) from _axs_seats),
      (select min(price) from _axs_seats where src='primary'),
      (select count(*) from _axs_seats),
      (select count(distinct section_label) from _axs_seats),
      jsonb_array_length(coalesce(v_body->'offers','[]'::jsonb)),
      (select count(*) from _axs_seats where src='primary'),
      (select count(*) from _axs_seats where src='resale'),
      (v_tevo_venue is not null), (v_tevo_venue is not null),
      nullif(v_content->>'response_s','')::numeric,
      nullif(v_content->>'quota_remaining','')::bigint,
      v_body
    returning id into v_snap;
  else
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
  end if;

  -- Section rollup (shared).
  drop table if exists _axs_secmap;
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

  -- Per-seat rows (shared) — feeds v_axs_seat_groups -> v_axs_listings (section/row/qty).
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

  update public.axs_events set tevo_venue_id = coalesce(tevo_venue_id, v_tevo_venue)
    where axs_event_id = p_axs_event_id;
  perform public.axs_apply_aq(p_axs_event_id);

  return v_snap;
end $function$;

-- ---------------------------------------------------------------------------
-- axs_probe_step — dual-format classifier + stuck-pending self-heal + expired deactivation
-- ---------------------------------------------------------------------------
create or replace function public.axs_probe_step(p_max_attempts integer DEFAULT 4, p_refresh_hours integer DEFAULT 12, p_ingest_limit integer DEFAULT 5)
 returns TABLE(action text, ev text, detail text)
 language plpgsql
 security definer
 set search_path to 'public', 'net', 'extensions', 'pg_temp'
as $function$
declare
  v_ev text; v_url text; v_rid bigint; v_snap bigint;
begin
  -- Self-heal: a probe stuck 'pending' whose response has aged out of net's TTL
  -- (never landed) must not wedge the drain forever via the in-flight guard below.
  update public.axs_probe p
     set status = 'retry', checked_at = now(), last_reason = 'timeout'
   where p.status = 'pending' and p.checked_at is null
     and p.fired_at < now() - interval '10 minutes'
     and not exists (select 1 from net._http_response r where r.id = p.request_id);

  update public.axs_probe p
  set status_code = r.status_code,
      checked_at  = now(),
      last_reason = public.axs_resp_reason(public.safe_jsonb(r.content), r.status_code, r.error_msg),
      is_axs_primary = case
        when public.axs_resp_ok(public.safe_jsonb(r.content)) then true
        when p.is_axs_primary then true
        when r.status_code in (400,404,410,422) then false
        when r.status_code=200 then case when p.attempts >= p_max_attempts then false else null end
        else null end,
      status = case
        when public.axs_resp_ok(public.safe_jsonb(r.content)) then 'axs_ok'
        when p.is_axs_primary then 'axs_ok'
        when r.status_code in (400,404,410,422) then 'not_axs'
        when r.status_code=200 then case when p.attempts >= p_max_attempts then 'not_axs' else 'retry' end
        else case when p.attempts >= p_max_attempts then 'inconclusive' else 'retry' end
      end
  from net._http_response r
  where r.id = p.request_id and p.checked_at is null;

  -- Deactivate events the harvester reports as past ('expired'): they carry no
  -- inventory and would otherwise be re-pulled every refresh cycle forever.
  update public.axs_events e set active = false
  from net._http_response r
  join public.axs_probe p on p.request_id = r.id
  where p.axs_event_id = e.axs_event_id and e.active
    and (public.safe_jsonb(r.content)->'body'->>'status') = 'expired';

  for v_ev, v_rid in
    select p.axs_event_id, p.request_id
    from public.axs_probe p
    where p.status='axs_ok' and p.snapshot_id is null and p.request_id is not null
    order by p.checked_at nulls last
    limit greatest(p_ingest_limit, 1)
  loop
    v_snap := public.axs_ingest_snapshot(v_rid, v_ev);
    if v_snap is not null then
      update public.axs_probe set snapshot_id = v_snap where axs_event_id = v_ev;
      update public.axs_events e
        set last_snapshot_id = v_snap, last_pulled_at = now(),
            active = case when s.occurs_at_local is not null
                           and s.occurs_at_local::timestamptz < now()
                          then false else e.active end
        from public.axs_event_snapshots s
        where e.axs_event_id = v_ev and s.id = v_snap;

      perform public.td_charge_credit(
                1, s.tevo_event_id, 'AXS', '/fetch',
                coalesce(pr.status_code, 200), s.quota_remaining::int)
      from public.axs_event_snapshots s
      left join public.axs_probe pr on pr.axs_event_id = v_ev
      where s.id = v_snap;
    else
      update public.axs_probe set snapshot_id = -1 where axs_event_id = v_ev and request_id = v_rid;
    end if;
  end loop;

  update public.axs_events e
  set is_axs_primary = p.is_axs_primary, probe_status = p.status, probed_at = p.checked_at
  from public.axs_probe p
  where p.axs_event_id = e.axs_event_id
    and p.status in ('axs_ok','not_axs','inconclusive')
    and (e.probe_status is distinct from p.status or e.probed_at is distinct from p.checked_at);

  -- Only a FRESH pending (fired < 10 min ago) counts as genuinely in-flight.
  if exists (select 1 from public.axs_probe
             where request_id is not null and checked_at is null
               and fired_at > now() - interval '10 minutes') then
    return query select 'in_flight'::text, null::text, 'awaiting prior response'::text; return;
  end if;

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
    and (
      p.axs_event_id is null
      or p.last_reason = 'veritix'
      or p.last_reason = 'axs_v2'
      or p.fired_at is null
      or p.fired_at < now() - interval '30 minutes'
    )
  order by
    case when p.axs_event_id is null or p.status='retry' then 0 else 1 end,
    coalesce(p.attempts,0), coalesce(e.last_pulled_at, 'epoch'::timestamptz), e.axs_event_id
  limit 1;

  if v_ev is null then
    return query select 'done'::text, null::text, 'all events terminal / fresh / backed-off'::text; return;
  end if;

  select net.http_get(
    url := 'https://ticketsdata.com/fetch',
    params := jsonb_build_object(
      'username',  public.get_app_secret(p_name => 'TICKETSDATA_USERNAME'),
      'password',  public.get_app_secret(p_name => 'TICKETSDATA_PASSWORD'),
      'event_url', v_url, 'platform', 'axs'),
    timeout_milliseconds := 100000
  ) into v_rid;

  insert into public.axs_probe (axs_event_id, request_id, fired_at, attempts, status)
  values (v_ev, v_rid, now(), 1, 'pending')
  on conflict (axs_event_id) do update
    set request_id=excluded.request_id, fired_at=now(),
        attempts=public.axs_probe.attempts+1, status='pending',
        checked_at=null, status_code=null, snapshot_id=null;

  return query select 'fired'::text, v_ev, ('rid='||v_rid)::text;
end $function$;
