-- Map AXS events to the canonical AQ event hub (aq_event_map -> tevo_event_id).
--
-- AXS gives us event_name + venue_name + local date per pull (no shared id with
-- aq_event_map), so we match by venue + date + name like the SG matcher — but
-- with a WIDER date window (AXS local date vs TEvo date can differ by a day on
-- reschedules/TZ; e.g. Ray LaMontagne/Ryman is 09-05 on AXS, 09-04 in AQ) plus
-- event-name trigram disambiguation. Resolves both tevo_event_id (canonical) and
-- tevo_venue_id (from the axs_venues peg) and back-fills the snapshot rows.

alter table public.axs_events add column if not exists aq_short_event_id text;

-- ---- matcher: best aq_event_map row for an AXS event's latest snapshot -------
create or replace function public.axs_aq_match(
  p_axs_event_id text,
  p_date_window_hours int default 48,
  p_min_score numeric default 0.45)
returns table(tevo_event_id bigint, aq_short_event_id text, confidence numeric, method text)
language plpgsql stable set search_path = public, extensions, pg_temp as $$
declare
  v_name text; v_venue text; v_date timestamptz;
begin
  select event_name, venue_name, occurs_at_local::timestamptz
    into v_name, v_venue, v_date
  from public.axs_event_snapshots
  where axs_event_id = p_axs_event_id and event_name is not null and venue_name is not null
  order by captured_at desc limit 1;
  if v_venue is null or v_date is null then return; end if;

  return query
  with cand as (
    select a.tevo_event_id, a.aq_short_event_id, a.event_name,
           case when lower(btrim(a.venue_name))=lower(btrim(v_venue)) then 1.0
                else similarity(lower(coalesce(a.venue_name,'')), lower(v_venue)) end as vscore,
           greatest(similarity(lower(coalesce(a.event_name,'')), lower(coalesce(v_name,''))), 0) as nscore,
           abs(extract(epoch from (a.event_date::timestamptz - v_date)))/3600.0 as dh
    from public.aq_event_map a
    where a.tevo_event_id is not null
      and (lower(btrim(a.venue_name))=lower(btrim(v_venue))
           or similarity(lower(coalesce(a.venue_name,'')), lower(v_venue)) >= 0.6)
      and a.event_date::timestamptz between v_date - make_interval(hours=>p_date_window_hours)
                                        and v_date + make_interval(hours=>p_date_window_hours)
  ),
  scored as (
    select *, (0.45*vscore + 0.40*nscore + 0.15*greatest(0, 1 - dh/p_date_window_hours)) as score
    from cand
  )
  select s.tevo_event_id, s.aq_short_event_id, round(s.score::numeric,3),
         (case when s.vscore=1 and s.dh<=6 then 'venue_exact_date'
               when s.nscore>=0.5 then 'venue_name_date'
               else 'venue_date_proximity' end)::text
  from scored s where s.score >= p_min_score
  order by s.score desc, s.dh asc limit 1;
end $$;

-- ---- apply: resolve + propagate tevo_event_id across the snapshot rows -------
create or replace function public.axs_apply_aq(p_axs_event_id text)
returns bigint
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_tevo bigint; v_aq text; v_snap bigint;
begin
  select m.tevo_event_id, m.aq_short_event_id into v_tevo, v_aq
  from public.axs_aq_match(p_axs_event_id) m;
  if v_tevo is null then return null; end if;
  select id into v_snap from public.axs_event_snapshots
   where axs_event_id = p_axs_event_id order by captured_at desc limit 1;
  update public.axs_event_snapshots  set tevo_event_id=v_tevo, aq_short_event_id=v_aq where id=v_snap;
  update public.axs_section_snapshots set tevo_event_id=v_tevo where snapshot_id=v_snap;
  update public.axs_seat_snapshots    set tevo_event_id=v_tevo where snapshot_id=v_snap;
  update public.axs_events set tevo_event_id=v_tevo, aq_short_event_id=v_aq where axs_event_id=p_axs_event_id;
  return v_tevo;
end $$;

-- ---- backfill: map every snapshotted-but-unmapped event ---------------------
create or replace function public.axs_aq_backfill(p_limit int default 1000)
returns table(axs_event_id text, tevo_event_id bigint)
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r record; v_tevo bigint;
begin
  for r in
    select distinct e.axs_event_id
    from public.axs_events e
    join public.axs_event_snapshots s on s.axs_event_id = e.axs_event_id
    where e.tevo_event_id is null
    limit p_limit
  loop
    v_tevo := public.axs_apply_aq(r.axs_event_id);
    if v_tevo is not null then
      axs_aq_backfill.axs_event_id := r.axs_event_id;
      axs_aq_backfill.tevo_event_id := v_tevo;
      return next;
    end if;
  end loop;
end $$;

-- ---- ingest v3: peg venue from axs_venues + auto AQ-map on persist ----------
create or replace function public.axs_ingest_snapshot(p_response_id bigint, p_axs_event_id text)
returns bigint
language plpgsql security definer set search_path = public, net, extensions, pg_temp as $$
declare
  v_content jsonb; v_body jsonb; v_meta jsonb;
  v_tevo_event bigint; v_tevo_venue bigint; v_event_url text; v_snap bigint;
begin
  select content::jsonb into v_content from net._http_response where id = p_response_id;
  if v_content is null then return null; end if;
  v_body := v_content->'body';
  v_meta := v_body->'meta';
  if (v_meta->>'api') is distinct from 'veritix' then return null; end if;

  select tevo_event_id, tevo_venue_id, event_url
    into v_tevo_event, v_tevo_venue, v_event_url
  from public.axs_events where axs_event_id = p_axs_event_id;

  -- peg venue from axs_venues by the pull's venue name (registry id is usually null)
  if v_tevo_venue is null then
    select tevo_venue_id into v_tevo_venue from public.axs_venues
    where axs_name_norm = public.venue_norm(v_meta->>'venue') and tevo_venue_id is not null limit 1;
  end if;

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

  -- persist the venue peg back to the registry, then AQ-map the event
  update public.axs_events set tevo_venue_id = coalesce(tevo_venue_id, v_tevo_venue)
    where axs_event_id = p_axs_event_id;
  perform public.axs_apply_aq(p_axs_event_id);

  drop table if exists _axs_seats;
  drop table if exists _axs_secmap;
  return v_snap;
end $$;

-- backfill existing snapshots now
select public.axs_aq_backfill();
