-- Migration 20260629180000 · lane:A1 (DB — AXS↔TEvo matcher) · writes (DDL):axs_aq_match() [CREATE OR REPLACE, add name-overlap guard]; on run:axs_events/axs_event_snapshots/axs_section_snapshots/axs_seat_snapshots (clear one false-matched link) + axs_tevo_search_attempts (reset 1 row) · reads:events, axs_event_snapshots · pre:20260623120000 (axs_to_tevo bridge) · auth:operator-approved 2026-06-29 (julian@s4kent.com — "fix it": event 3318517 AXS listings count whipsawing)
--
-- WHY ------------------------------------------------------------------------
-- AXS listings count for tevo_event_id 3318517 (Blues Traveler @ Red Rocks 7/4) was
-- whipsawing between ~2,000 and ~300 because TWO different AXS events were both linked
-- to it: axs 1342092 = Blues Traveler 7/4 (correct), and axs 1413462 = ANDREA GIBSON
-- 7/5 (wrong — a different artist the next night). The downstream metric reads the
-- latest snapshot per tevo_event_id, so it bounced between the two events' inventories.
--
-- ROOT CAUSE: axs_aq_match scores 0.45*venue + 0.40*name + 0.15*date_proximity with
-- min_score 0.45, so a SAME-VENUE event inside the 48h window clears the bar on
-- venue+date ALONE (0.45 + up to 0.15) even with ZERO name overlap. Andrea Gibson
-- (Red Rocks, +24.5h from Blues Traveler) scored ~0.52 with name contributing 0 →
-- false match. TEvo has no Andrea Gibson event (no 7/5 event at Red Rocks at all), so
-- nothing should have matched.
--
-- FIX ------------------------------------------------------------------------
-- (1) Add a name-overlap GUARD to axs_aq_match: a candidate must have name similarity
--     >= 0.20, UNLESS it is the exact same venue AND within 2h (essentially the same
--     showtime — allows a genuine match whose AXS/TEvo names are formatted differently).
--     This mirrors the SeatGeek matcher's off-date/name reject. Blues Traveler→Blues
--     Traveler (nscore≈1) still matches; Andrea Gibson→Blues Traveler (nscore≈0, +24.5h)
--     is now rejected. Everything else in the function is unchanged.
-- (2) Clear the existing false link for axs 1413462 across all rows axs_apply_aq writes
--     (events/snapshots/sections/seats) so the metric stabilizes immediately, and reset
--     its search-attempt row so the (now-guarded) bridge re-evaluates it cleanly. With
--     the guard, the 6h axs_aq_backfill cron will NOT re-link it to Blues Traveler/Eric
--     Church; it stays unmapped until TEvo actually has an Andrea Gibson event.
--
-- SAFETY ---------------------------------------------------------------------
-- axs_aq_match is STABLE/SECURITY INVOKER — plain CREATE OR REPLACE preserves grants.
-- The guard only rejects near-zero-name matches (the false-match class); same-artist
-- matches (incl. legit venue+date multi-night, name sim high) are unaffected. Data
-- cleanup is scoped to axs_event_id='1413462'. Idempotent/reversible.
--
-- ROLLBACK -------------------------------------------------------------------
--   Re-CREATE OR REPLACE axs_aq_match without the guard clause (prior body). The data
--   unlink is not auto-reversible by name (it was wrong); re-running axs_apply_aq('1413462')
--   under the OLD function would re-create the false link.

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
    -- NAME-OVERLAP GUARD: reject near-zero-name matches (cross-artist venue+date
    -- collisions) unless it is the exact same venue within ~2h (same showtime).
    and (s.nscore >= 0.20 or (s.vscore >= 0.999 and s.dh <= 2))
  order by s.score desc, s.dh asc limit 1;
end $function$;

-- Clear the Andrea Gibson (axs 1413462) false link to tevo 3318517 everywhere axs_apply_aq writes it.
UPDATE public.axs_section_snapshots SET tevo_event_id = NULL
  WHERE snapshot_id IN (SELECT id FROM public.axs_event_snapshots WHERE axs_event_id = '1413462');
UPDATE public.axs_seat_snapshots SET tevo_event_id = NULL
  WHERE snapshot_id IN (SELECT id FROM public.axs_event_snapshots WHERE axs_event_id = '1413462');
UPDATE public.axs_event_snapshots SET tevo_event_id = NULL, aq_short_event_id = NULL
  WHERE axs_event_id = '1413462';
UPDATE public.axs_events SET tevo_event_id = NULL, aq_short_event_id = NULL
  WHERE axs_event_id = '1413462';
-- Reset its attempt row so the now-guarded bridge re-evaluates it cleanly.
DELETE FROM public.axs_tevo_search_attempts WHERE axs_event_id = '1413462';
