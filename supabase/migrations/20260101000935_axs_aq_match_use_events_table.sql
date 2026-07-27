-- Fix: axs_aq_match matched only aq_event_map, which is INCOMPLETE.
--
-- Eric Church @ Red Rocks (Jul 6/7/8 2026) exists in public.events (3360484/
-- 3360483/3360482) but NOT in aq_event_map, so the AXS pulls (1400127/129/130)
-- couldn't map — two stayed null and one (1400130) false-matched a stale
-- aq_event_map Red Rocks row (3267061). public.events is the authoritative,
-- complete TEvo event list, so match against it: the snapshot's pegged
-- tevo_venue_id == events.venue_id is the strongest signal (exact venue), then
-- date (±window) + event-name trigram. aq_short_event_id is looked up from
-- aq_event_map when the matched tevo event happens to have one.

create or replace function public.axs_aq_match(
  p_axs_event_id text,
  p_date_window_hours int default 48,
  p_min_score numeric default 0.45)
returns table(tevo_event_id bigint, aq_short_event_id text, confidence numeric, method text)
language plpgsql stable set search_path = public, extensions, pg_temp as $$
declare
  v_name text; v_venue text; v_date timestamptz; v_tevo_venue bigint;
begin
  select event_name, venue_name, occurs_at_local::timestamptz, tevo_venue_id
    into v_name, v_venue, v_date, v_tevo_venue
  from public.axs_event_snapshots
  where axs_event_id = p_axs_event_id and event_name is not null and venue_name is not null
  order by captured_at desc limit 1;
  if v_venue is null or v_date is null then return; end if;

  return query
  with cand as (
    select ev.id as tid,
           case when v_tevo_venue is not null and ev.venue_id = v_tevo_venue then 1.0
                when lower(btrim(ev.venue_name)) = lower(btrim(v_venue)) then 0.95
                else similarity(lower(coalesce(ev.venue_name,'')), lower(v_venue)) end as vscore,
           greatest(similarity(lower(coalesce(ev.name,'')), lower(coalesce(v_name,''))), 0) as nscore,
           abs(extract(epoch from (ev.occurs_at_local::timestamptz - v_date)))/3600.0 as dh
    from public.events ev
    where ev.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'   -- guard the text->ts cast
      and ev.occurs_at_local::timestamptz between v_date - make_interval(hours=>p_date_window_hours)
                                              and v_date + make_interval(hours=>p_date_window_hours)
      and ( (v_tevo_venue is not null and ev.venue_id = v_tevo_venue)
            or lower(btrim(ev.venue_name)) = lower(btrim(v_venue))
            or similarity(lower(coalesce(ev.venue_name,'')), lower(v_venue)) >= 0.6 )
  ),
  scored as (
    select *, (0.45*vscore + 0.40*nscore + 0.15*greatest(0, 1 - dh/p_date_window_hours)) as score
    from cand
  )
  select s.tid,
         (select a.aq_short_event_id from public.aq_event_map a where a.tevo_event_id = s.tid limit 1),
         round(s.score::numeric,3),
         (case when s.vscore=1 and s.nscore>=0.5 then 'venue_id_name_date'
               when s.vscore=1 then 'venue_id_date'
               when s.nscore>=0.5 then 'venue_name_date'
               else 'venue_date_proximity' end)::text
  from scored s where s.score >= p_min_score
  order by s.score desc, s.dh asc limit 1;
end $$;

-- re-map every snapshotted AXS event with the corrected matcher (fixes missing +
-- the 1400130-style false matches).
do $$
declare r record;
begin
  for r in select distinct axs_event_id from public.axs_event_snapshots loop
    perform public.axs_apply_aq(r.axs_event_id);
  end loop;
end $$;
