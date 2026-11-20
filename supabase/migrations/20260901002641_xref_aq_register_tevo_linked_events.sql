-- Migration 20260901002641 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_aq_register_tevo_linked_events" (version 20260901002641) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration — register the 6,153 tevo-linked events missing from the AQ hub
--
-- Lane:     xref+macro
-- Touches:  aq_event_map (W - inserts), events (R), sg_events_canonical (R),
--           gotickets_event (R), seatdata_event_xref (R), axs_events (R)
-- Pre-reqs: 20260901002033 (aq_sync_source_event_ids)
--
-- Operator directive 2026-09-01: create hub rows for events that already carry
-- a source link but have no row in the hub.
--
-- WHY THESE ARE NOT SYNTHETICS
-- All 6,153 resolve to a real row in `events` with a parseable local date --
-- verified, zero exceptions. Each is a TEvo event we already hold, already
-- linked from at least one listing source (SeatGeek, GoTickets, SeatData or
-- AXS). What was missing was only the registry entry. So these are keyed to the
-- actual event, not guessed from a name/venue/date collision the way
-- create_system_aq_event's fallback necessarily is.
--
-- ID SCHEME -- deliberate, and different from create_system_aq_event
-- Keeps the documented SYS-<10 hex> shape (PROJECT_BIBLE §7) so nothing
-- pattern-matching on it breaks, but hashes the TEVO EVENT ID rather than
-- name|venue|date:
--     'SYS-' || substring(md5('tevo:' || tevo_event_id) from 1 for 10)
-- create_system_aq_event hashes name|venue|date-to-the-minute, which is the
-- right key when the event is unknown but produces a DUPLICATE whenever the hub
-- already holds that event under a different time convention -- exactly the
-- fault that required migration 20260831230958 to unlink 8 rows earlier today.
-- Here the tevo_event_id is known, so hashing it gives exactly one hub row per
-- event and cannot collide with an existing name/venue/date hash.
--
-- aq_source = 'tevo_registry' marks the population so it stays identifiable and
-- removable as a set, distinct from 'aq_curated', 'system_seed' and 'evo_only'.
--
-- Hub grows 11,271 -> ~17,424 rows (+55%). That is the intended effect: the hub
-- has been under-covering our own 15,893-event catalogue, which is why ~7,500
-- source links were invisible to every lane joining through it.
--
-- Event date is stored as LOCAL wall clock to match the hub's existing
-- convention (verified earlier: 92% of hub rows match their linked event's
-- occurs_at_local time exactly), NOT as UTC.
--
-- Cross-lane: aq_event_map is the shared AQ hub (A1 surface). Insert-only,
-- ON CONFLICT DO NOTHING, under explicit operator direction. Flagged to bot_chat.
-- ============================================================================

WITH need AS (
  SELECT c.tevo_event_id FROM public.sg_events_canonical c WHERE c.tevo_event_id IS NOT NULL
  UNION
  SELECT g.tevo_event_id FROM public.gotickets_event g WHERE g.tevo_event_id IS NOT NULL
  UNION
  SELECT s.tevo_event_id FROM public.seatdata_event_xref s WHERE s.tevo_event_id IS NOT NULL
  UNION
  SELECT x.tevo_event_id FROM public.axs_events x WHERE x.tevo_event_id IS NOT NULL
), gap AS (
  SELECT n.tevo_event_id
    FROM need n
   WHERE NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.tevo_event_id = n.tevo_event_id)
)
INSERT INTO public.aq_event_map (
  aq_short_event_id, event_name, venue_name, event_date, state,
  tevo_event_id, aq_source, imported_at
)
SELECT 'SYS-' || substring(md5('tevo:' || e.id::text) FROM 1 FOR 10),
       e.name,
       e.venue_name,
       substring(e.occurs_at_local FROM 1 FOR 19)::timestamp,
       e.state,
       e.id,
       'tevo_registry',
       now()
  FROM gap
  JOIN public.events e ON e.id = gap.tevo_event_id
 WHERE e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
ON CONFLICT (aq_short_event_id) DO NOTHING;

-- Post-condition: the new rows must not have introduced duplicate tevo links
-- beyond the pre-existing fan-out baseline of 490 groups.
DO $chk$
DECLARE v_groups int; v_orphan int;
BEGIN
  SELECT count(*) INTO v_groups FROM (
    SELECT tevo_event_id FROM public.aq_event_map
     WHERE tevo_event_id IS NOT NULL GROUP BY tevo_event_id HAVING count(*) > 1) z;
  IF v_groups > 490 THEN
    RAISE EXCEPTION 'aq_register_tevo_linked_events: fan-out grew to % groups (baseline 490)', v_groups;
  END IF;

  SELECT count(*) INTO v_orphan FROM public.aq_event_map a
   WHERE a.aq_source = 'tevo_registry'
     AND NOT EXISTS (SELECT 1 FROM public.events e WHERE e.id = a.tevo_event_id);
  IF v_orphan > 0 THEN
    RAISE EXCEPTION 'aq_register_tevo_linked_events: % row(s) point at a non-existent event', v_orphan;
  END IF;
END $chk$;
;
