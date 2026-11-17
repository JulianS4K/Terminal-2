-- Migration 20260901002033 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_aq_sync_source_event_ids" (version 20260901002033) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration — aq_sync_source_event_ids(): every listing source's id, maintained
--             in one place
--
-- Lane:     xref+macro
-- Touches:  aq_event_map (W), sg_events_canonical (R), gotickets_event (R),
--           seatdata_event_xref (R), axs_events (R)
-- Pre-reqs: xref_aq_event_map_gotickets_event_id
--
-- Operator directive: all listing sources should refer to the mapping table for
-- their respective source ids, so mapping is maintained in one place.
--
-- THE PROBLEM THIS SOLVES
-- Every listing/sales surface currently keeps its OWN denormalised link to
-- TEvo -- gotickets_event.tevo_event_id, sg_events_canonical.tevo_event_id,
-- seatdata_event_xref.tevo_event_id, axs_events.tevo_event_id -- and the hub is
-- updated, if at all, by whichever mapper happened to touch it. The result is
-- that the hub silently falls behind the sources it is supposed to be the
-- registry FOR. Measured at the time of writing, links held on a source table
-- but absent from the hub:
--     SeatGeek  3,855      GoTickets  3,350      SeatData 241      AXS 41
-- ~7,500 links that no lane joining through the hub can see.
--
-- The one source that does NOT drift is TicketsData, at 13,843 / 13,843 =
-- 100%, and it is the only one carrying aq_short_event_id -- the hub key
-- PROJECT_BIBLE §0 prescribes. That is the pattern; everything else reaches
-- the hub through sparsely-populated source-id columns.
--
-- WHAT THIS FUNCTION DOES
-- Pulls each source's established links INTO the hub, so the hub becomes the
-- maintained record rather than a lagging copy. Idempotent, and safe to run on
-- a cron or at the tail of any mapper.
--
-- WHAT IT DELIBERATELY DOES NOT DO
-- It only writes where a hub row for that event ALREADY EXISTS. Of the ~7,500
-- drifted links, just 509 clear that bar; the other 6,978 have no hub row at
-- all, because the hub holds 11,271 rows against a 15,893-event catalogue.
-- Creating those rows would expand a shared cross-lane table by ~60% and is a
-- separate, deliberate decision -- not something to slip into a sync job.
-- Those links are reported, not invented.
--
-- GUARDS (identical for every source)
--   * unambiguous only: a tevo_event_id mapping to more than one source id is
--     skipped rather than resolved arbitrarily -- a wrong id on the hub
--     propagates to every lane that joins through it.
--   * never overwrites a non-NULL value; fills gaps only.
--   * writes by tevo_event_id, so where several hub rows share one event (490
--     known fan-out groups) all of them receive the id, which is correct --
--     they are duplicate registrations of the same event.
--
-- Cross-lane: aq_event_map is the shared AQ hub (A1 surface). Additive
-- gap-filling under explicit operator direction. Flagged to bot_chat.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.aq_sync_source_event_ids()
RETURNS TABLE(source text, ids_written integer, skipped_no_hub_row integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  n int; m int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'aq_sync_source_event_ids: caller % not authorized', current_user;
  END IF;

  -- ── SeatGeek ─────────────────────────────────────────────────────────────
  WITH src AS (
    SELECT tevo_event_id, min(sg_event_id) AS sid
      FROM public.sg_events_canonical
     WHERE tevo_event_id IS NOT NULL AND sg_event_id IS NOT NULL
     GROUP BY tevo_event_id
    HAVING count(DISTINCT sg_event_id) = 1
  )
  UPDATE public.aq_event_map a SET sg_event_id = src.sid
    FROM src
   WHERE a.tevo_event_id = src.tevo_event_id AND a.sg_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  SELECT count(*) INTO m FROM public.sg_events_canonical c
   WHERE c.tevo_event_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.sg_event_id = c.sg_event_id)
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.tevo_event_id = c.tevo_event_id);
  source := 'seatgeek'; ids_written := n; skipped_no_hub_row := m; RETURN NEXT;

  -- ── GoTickets ────────────────────────────────────────────────────────────
  WITH src AS (
    SELECT tevo_event_id, min(gt_event_id) AS sid
      FROM public.gotickets_event
     WHERE tevo_event_id IS NOT NULL
     GROUP BY tevo_event_id
    HAVING count(*) = 1
  )
  UPDATE public.aq_event_map a SET gotickets_event_id = src.sid
    FROM src
   WHERE a.tevo_event_id = src.tevo_event_id AND a.gotickets_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  SELECT count(*) INTO m FROM public.gotickets_event g
   WHERE g.tevo_event_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.gotickets_event_id = g.gt_event_id)
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.tevo_event_id = g.tevo_event_id);
  source := 'gotickets'; ids_written := n; skipped_no_hub_row := m; RETURN NEXT;

  -- ── SeatData ─────────────────────────────────────────────────────────────
  WITH src AS (
    SELECT tevo_event_id, min(sd_event_id) AS sid
      FROM public.seatdata_event_xref
     WHERE tevo_event_id IS NOT NULL AND sd_event_id IS NOT NULL
     GROUP BY tevo_event_id
    HAVING count(DISTINCT sd_event_id) = 1
  )
  UPDATE public.aq_event_map a SET sd_event_id = src.sid
    FROM src
   WHERE a.tevo_event_id = src.tevo_event_id AND a.sd_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  SELECT count(*) INTO m FROM public.seatdata_event_xref s
   WHERE s.tevo_event_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.sd_event_id = s.sd_event_id)
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.tevo_event_id = s.tevo_event_id);
  source := 'seatdata'; ids_written := n; skipped_no_hub_row := m; RETURN NEXT;

  -- ── AXS (axs_event_id is text on the hub) ────────────────────────────────
  WITH src AS (
    SELECT tevo_event_id, min(axs_event_id::text) AS sid
      FROM public.axs_events
     WHERE tevo_event_id IS NOT NULL AND axs_event_id IS NOT NULL
     GROUP BY tevo_event_id
    HAVING count(DISTINCT axs_event_id) = 1
  )
  UPDATE public.aq_event_map a SET axs_event_id = src.sid
    FROM src
   WHERE a.tevo_event_id = src.tevo_event_id AND a.axs_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  SELECT count(*) INTO m FROM public.axs_events x
   WHERE x.tevo_event_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.axs_event_id = x.axs_event_id::text)
     AND NOT EXISTS (SELECT 1 FROM public.aq_event_map a WHERE a.tevo_event_id = x.tevo_event_id);
  source := 'axs'; ids_written := n; skipped_no_hub_row := m; RETURN NEXT;
END;
$function$;

REVOKE ALL ON FUNCTION public.aq_sync_source_event_ids() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.aq_sync_source_event_ids() IS
  'Pulls each listing source''s established event-id links INTO aq_event_map so the hub is the maintained registry rather than a lagging copy of per-source denormalised tevo_event_id columns. Unambiguous links only; never overwrites; writes only where a hub row for the event already exists. The skipped_no_hub_row column reports links that cannot be recorded because the hub has no row for that event -- creating those rows is a separate, deliberate decision.';
;
