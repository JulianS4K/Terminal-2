-- Make AXS a first-class source in the canonical AQ hub.
--
-- aq_event_map carried vivid/sh/sg/tm/sd ids but no AXS. Add axs_event_id; set
-- it on the 66 events already in the hub; INSERT the 109 AXS-mapped events that
-- the curated import never created (aq_source='axs', deterministic PK
-- 'AXS'<id>), so the hub is complete for AXS (this incompleteness is what made
-- the Eric Church/Red Rocks tab empty). Teach match_to_aq_event_id an AXS
-- direct-id tier, and point the registry's aq_short_event_id at the new rows.

-- 1) column + index
alter table public.aq_event_map add column if not exists axs_event_id text;
create index if not exists aq_event_map_axs_event_idx
  on public.aq_event_map (axs_event_id) where axs_event_id is not null;

-- 2) populate the 66 events already in the hub
update public.aq_event_map a
set axs_event_id = e.axs_event_id
from public.axs_events e
where e.tevo_event_id = a.tevo_event_id
  and e.tevo_event_id is not null and e.axs_event_id is not null
  and a.axs_event_id is null;

-- 3) insert the 109 AXS-mapped events missing from the hub (latest snapshot per
-- event for name/venue/date; aq_source='axs'; id auto from the sequence)
insert into public.aq_event_map
  (aq_short_event_id, event_name, venue_name, event_date, performer,
   venue_short_id, tevo_event_id, axs_event_id, aq_source, imported_at)
select distinct on (e.axs_event_id)
  'AXS' || e.axs_event_id,
  s.event_name, s.venue_name,
  s.occurs_at_local::timestamp,
  s.event_name,
  (select m.venue_short_id from public.aq_venue_map m where m.tevo_venue_id = s.tevo_venue_id limit 1),
  e.tevo_event_id, e.axs_event_id, 'axs', now()
from public.axs_events e
join public.axs_event_snapshots s on s.axs_event_id = e.axs_event_id
where e.tevo_event_id is not null
  and s.event_name is not null and s.venue_name is not null
  and not exists (select 1 from public.aq_event_map a where a.tevo_event_id = e.tevo_event_id)
order by e.axs_event_id, s.captured_at desc
on conflict (aq_short_event_id) do nothing;

-- 4) point the registry's aq_short_event_id at the (new or existing) hub rows
update public.axs_events e
set aq_short_event_id = a.aq_short_event_id
from public.aq_event_map a
where a.axs_event_id = e.axs_event_id and e.aq_short_event_id is null;

-- 5) match_to_aq_event_id: add an AXS direct-id tier (axs ids are numeric text)
create or replace function public.match_to_aq_event_id(p_source text, p_source_event_id bigint, p_event_name text, p_venue_name text, p_event_date timestamp with time zone, p_lat numeric DEFAULT NULL::numeric, p_lon numeric DEFAULT NULL::numeric, p_source_venue_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(aq_short_event_id text, confidence numeric, match_method text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_aq_id          text;
  v_venue_short_id text;
BEGIN
  IF p_source_event_id IS NOT NULL AND p_source IN ('tevo', 'evo') THEN
    SELECT a.aq_short_event_id INTO v_aq_id
    FROM public.aq_event_map a
    WHERE a.tevo_event_id = p_source_event_id LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 1.00::numeric(3,2), 'tier0_tevo_id'::text; RETURN;
    END IF;
  END IF;

  IF p_source_event_id IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
    WHERE (p_source IN ('vivid')              AND a.vivid_event_id = p_source_event_id)
       OR (p_source IN ('seatgeek','sg')      AND a.sg_event_id    = p_source_event_id)
       OR (p_source IN ('stubhub','sh')       AND a.sh_event_id    = p_source_event_id)
       OR (p_source IN ('ticketmaster','tm')  AND a.tm_event_id    = p_source_event_id)
       OR (p_source IN ('axs')                AND a.axs_event_id   = p_source_event_id::text)
    LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 1.00::numeric(3,2), 'tier1_direct_id'::text; RETURN;
    END IF;
  END IF;

  IF p_source_venue_id IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT m.venue_short_id INTO v_venue_short_id FROM public.aq_venue_map m
    WHERE (p_source IN ('tickpick')         AND m.tickpick_venue_id = p_source_venue_id)
       OR (p_source IN ('seatgeek','sg')    AND m.sg_venue_id       = p_source_venue_id)
       OR (p_source IN ('tevo','evo')       AND m.tevo_venue_id     = p_source_venue_id)
    LIMIT 1;
    IF v_venue_short_id IS NOT NULL THEN
      SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
      WHERE a.venue_short_id = v_venue_short_id
        AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                          AND p_event_date + interval '6 hours'
      ORDER BY abs(extract(epoch FROM (a.event_date::timestamptz - p_event_date))) LIMIT 1;
      IF v_aq_id IS NOT NULL THEN
        RETURN QUERY SELECT v_aq_id, 0.93::numeric(3,2), 'tier1_5_venue_id_date'::text; RETURN;
      END IF;
    END IF;
  END IF;

  IF p_venue_name IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
    WHERE lower(trim(a.venue_name)) = lower(trim(p_venue_name))
      AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                        AND p_event_date + interval '6 hours'
    ORDER BY abs(extract(epoch FROM (a.event_date::timestamptz - p_event_date))) LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 0.95::numeric(3,2), 'tier2_venue_exact_date'::text; RETURN;
    END IF;
  END IF;

  IF p_venue_name IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id FROM public.aq_event_map a
    WHERE similarity(lower(coalesce(a.venue_name,'')), lower(coalesce(p_venue_name,''))) >= 0.7
      AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                        AND p_event_date + interval '6 hours'
    ORDER BY similarity(lower(a.venue_name), lower(p_venue_name)) DESC,
             abs(extract(epoch FROM (a.event_date::timestamptz - p_event_date))) LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 0.80::numeric(3,2), 'tier3_venue_fuzzy_date'::text; RETURN;
    END IF;
  END IF;

  IF p_lat IS NOT NULL AND p_lon IS NOT NULL AND p_event_date IS NOT NULL THEN
    SELECT a.aq_short_event_id INTO v_aq_id
    FROM public.aq_event_map a
    JOIN public.venue_assets va ON lower(trim(va.venue_name)) = lower(trim(a.venue_name))
    WHERE va.latitude  BETWEEN p_lat - 0.01 AND p_lat + 0.01
      AND va.longitude BETWEEN p_lon - 0.02 AND p_lon + 0.02
      AND a.event_date::timestamptz BETWEEN p_event_date - interval '6 hours'
                                        AND p_event_date + interval '6 hours'
    ORDER BY (2 * 6371000 * asin(sqrt(
       power(sin(radians((va.latitude  - p_lat)/2)), 2)
       + cos(radians(p_lat)) * cos(radians(va.latitude))
         * power(sin(radians((va.longitude - p_lon)/2)), 2)
    ))) LIMIT 1;
    IF v_aq_id IS NOT NULL THEN
      RETURN QUERY SELECT v_aq_id, 0.85::numeric(3,2), 'tier4_coord_date'::text; RETURN;
    END IF;
  END IF;

  RETURN;
END;
$function$;
