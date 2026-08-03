-- ============================================================================
-- Migration 20260727180000 — classify AXS FlashSeats as resale
--
-- Lane:     A1 (data plane — AXS ingest pipeline)
-- Touches:  axs_ingest_snapshot() (W) — v2 seat src classification
-- Pre-reqs: 20260727120000 (dual-format axs_ingest_snapshot)
--
-- WHY: FlashSeats is AXS's resale / ticket-transfer channel. Verified live on
-- Five Finger Death Punch @ Red Rocks (axs 1286674): AXS's own map shows
-- "Sec Right, Row 25, Seat 13 · Resale · $188.25", and that seat arrives in the
-- feed as seatType='FLASHSEATS'. But the v2 classifier only marked a seat resale
-- when the joined offerType contained 'resale' — and for this event every
-- offerType is 'Single', so all ~316 FlashSeats resale seats were mislabeled
-- 'primary' (seats_resale = 0). Operator directive 2026-08-03: track FlashSeats
-- as resale, officially.
--
-- FIX: v2 src = 'resale' when the offerType says resale OR seatType='FLASHSEATS'.
-- Side effect (desired): getin = min(price) filtered to src='primary', so it now
-- reflects the cheapest PRIMARY seat, not a resale posting. veritix path
-- (offerID '9…' rule) is unchanged. This is a CREATE OR REPLACE of the whole
-- function; only the v2 branch of the src CASE changed.
-- ============================================================================

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
    case when v_is_new then
           -- FlashSeats = AXS resale/transfer; treat as resale even when
           -- offerType reads 'Single' (operator directive 2026-08-03).
           case when lower(coalesce(otype.offer_type,'')) like '%resale%'
                     or it->>'seatType' = 'FLASHSEATS'
                then 'resale' else 'primary' end
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
      'veritix',
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

  perform public.axs_persist_blocks(v_snap);

  update public.axs_events set tevo_venue_id = coalesce(tevo_venue_id, v_tevo_venue)
    where axs_event_id = p_axs_event_id;
  perform public.axs_apply_aq(p_axs_event_id);

  return v_snap;
end $function$;
