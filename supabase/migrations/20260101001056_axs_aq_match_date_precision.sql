-- Migration 20260629190000 · lane:A1 (DB — AXS↔TEvo matcher/mapper) · writes (DDL):axs_aq_match() [date-precision guard]; on run:clear+REMAP 6 off-date AXS mislinks via the canonical match_to_aq_event_id/create_system_aq_event mapper; axs_events/axs_event_snapshots/axs_section_snapshots/axs_seat_snapshots/aq_event_map/axs_tevo_search_attempts · reads:events · pre:20260629180000 (name guard) · auth:operator-approved 2026-06-29 (julian@s4kent.com — "do it … use tickets-data event matcher/mapper to assist")
--
-- WHY ------------------------------------------------------------------------
-- After the cross-artist name guard (mig 180000), same-ARTIST multi-night runs still
-- mislinked: an artist plays consecutive nights, TEvo carries one night, and the other
-- nights' AXS events matched it (same venue, identical name, inside axs_aq_match's loose
-- ±48h window). 6 mislinks found (incl. the Andrea Gibson 1413462 cleared in mig 180000):
--   1289522 Vince Gill 8/6→8/7, 1289239 Vince Gill 8/8→8/7, 1240780 Alison Krauss 9/18→9/19,
--   1253401 Nate Smith 6/18→6/17, 1216092 Rod Stewart 2027-09-03→2026-06-16 (444d, legacy),
--   1413462 Andrea Gibson 7/5 (cross-artist, already unlinked).
--
-- FIX (two parts) ------------------------------------------------------------
-- (1) DATE-PRECISION GUARD on axs_aq_match: add `and s.dh <= 12`. A genuine same-event
--     match is only off by the venue tz offset (≤~10h US); adjacent nights are ≥19h
--     apart, so 12h provably separates them without rejecting any real match. This stops
--     the 6h axs-aq-backfill cron (which uses axs_aq_match) from re-creating these links.
-- (2) RE-MAP via the canonical TicketsData/AQ mapper (operator directive). axs_aq_match
--     is AXS-bespoke and ±48h-loose; the hub mapper public.match_to_aq_event_id is ±6h
--     precise across all tiers — the right tool. Clear each mislink, then run the mapper:
--     it returns the CORRECT same-date canonical event if one exists; if none, mint a
--     system_seed canonical id via create_system_aq_event so each night gets its OWN
--     identity (tevo stays NULL → the AXS→TEvo bridge can later attach a real TEvo event)
--     instead of polluting an adjacent night's metric.
--
-- SAFETY: axs_aq_match is STABLE/INVOKER (CREATE OR REPLACE preserves grants). dh≤12 never
-- rejects a real same-event match. match_to_aq_event_id is read-only; create_system_aq_event
-- is md5-idempotent (ON CONFLICT DO NOTHING). Scoped to the 6 known mislinks. Reversible.
-- ROLLBACK: re-CREATE OR REPLACE axs_aq_match without `and s.dh <= 12`.

CREATE OR REPLACE FUNCTION public.axs_aq_match(p_axs_event_id text, p_date_window_hours integer DEFAULT 48, p_min_score numeric DEFAULT 0.45)
 RETURNS TABLE(tevo_event_id bigint, aq_short_event_id text, confidence numeric, method text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
    where ev.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'
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
  from scored s
  where s.score >= p_min_score
    and (s.nscore >= 0.20 or (s.vscore >= 0.999 and s.dh <= 2))   -- name-overlap guard (cross-artist)
    and s.dh <= 12                                                -- date-precision guard (same-artist multi-night)
  order by s.score desc, s.dh asc limit 1;
end $function$;

-- Clear the 6 off-date mislinks everywhere axs_apply_aq propagates tevo_event_id.
UPDATE public.axs_section_snapshots SET tevo_event_id = NULL
  WHERE snapshot_id IN (SELECT id FROM public.axs_event_snapshots
        WHERE axs_event_id IN ('1413462','1216092','1240780','1289522','1253401','1289239'));
UPDATE public.axs_seat_snapshots SET tevo_event_id = NULL
  WHERE snapshot_id IN (SELECT id FROM public.axs_event_snapshots
        WHERE axs_event_id IN ('1413462','1216092','1240780','1289522','1253401','1289239'));
UPDATE public.axs_event_snapshots SET tevo_event_id = NULL, aq_short_event_id = NULL
  WHERE axs_event_id IN ('1413462','1216092','1240780','1289522','1253401','1289239');
UPDATE public.axs_events SET tevo_event_id = NULL, aq_short_event_id = NULL
  WHERE axs_event_id IN ('1413462','1216092','1240780','1289522','1253401','1289239');
DELETE FROM public.axs_tevo_search_attempts
  WHERE axs_event_id IN ('1413462','1216092','1240780','1289522','1253401','1289239');

-- Re-map each via the canonical mapper (±6h precise); mint a system_seed id if no match.
DO $cleanup$
DECLARE r record; v_aq text; v_tevo bigint; v_snap bigint;
BEGIN
  FOR r IN
    SELECT ax.axs_event_id, l.event_name, l.venue_name, l.occurs_at_local, l.tevo_venue_id
    FROM (VALUES ('1413462'),('1216092'),('1240780'),('1289522'),('1253401'),('1289239')) ids(id)
    JOIN public.axs_events ax ON ax.axs_event_id = ids.id
    JOIN LATERAL (
      SELECT s.event_name, s.venue_name, s.occurs_at_local, s.tevo_venue_id
      FROM public.axs_event_snapshots s
      WHERE s.axs_event_id = ax.axs_event_id AND s.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'
        AND s.event_name IS NOT NULL AND s.venue_name IS NOT NULL
      ORDER BY s.captured_at DESC LIMIT 1
    ) l ON true
  LOOP
    SELECT m.aq_short_event_id INTO v_aq
    FROM public.match_to_aq_event_id('axs', r.axs_event_id::bigint, r.event_name, r.venue_name,
                                     r.occurs_at_local::timestamptz, NULL, NULL, r.tevo_venue_id) m
    LIMIT 1;
    IF v_aq IS NULL THEN
      v_aq := public.create_system_aq_event('axs', r.event_name, r.venue_name,
                                            r.occurs_at_local::timestamptz, r.axs_event_id::bigint);
    END IF;
    SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a WHERE a.aq_short_event_id = v_aq LIMIT 1;
    UPDATE public.axs_events SET aq_short_event_id = v_aq, tevo_event_id = v_tevo
      WHERE axs_event_id = r.axs_event_id;
    SELECT id INTO v_snap FROM public.axs_event_snapshots
      WHERE axs_event_id = r.axs_event_id ORDER BY captured_at DESC LIMIT 1;
    UPDATE public.axs_event_snapshots SET aq_short_event_id = v_aq, tevo_event_id = v_tevo WHERE id = v_snap;
    IF v_tevo IS NOT NULL THEN
      UPDATE public.axs_section_snapshots SET tevo_event_id = v_tevo WHERE snapshot_id = v_snap;
      UPDATE public.axs_seat_snapshots    SET tevo_event_id = v_tevo WHERE snapshot_id = v_snap;
    END IF;
  END LOOP;
END $cleanup$;
