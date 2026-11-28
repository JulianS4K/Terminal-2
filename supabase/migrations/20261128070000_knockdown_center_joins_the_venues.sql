-- Migration 20261128070000 · level:data-collection · lane:a1 (AXS watch venue set) · writes:axs_watch_venue(+Knockdown Center) · reads:axs_export_event,axs_watch_config
--
-- ============================================================================
-- Migration 20261128070000 — Knockdown Center joins the watched venue set
--
-- Lane:     a1 (AXS watch)
-- pre:      20261127020000 (Opry House, the same shape)
--
-- READ-ONLY UPSTREAM (RULE 2): nothing here calls a market.
--
-- Operator 2026-11-28: "add Knockdown Center to axs event queue list where axs is primary
-- provider".
--
-- ── WHAT IT IS ────────────────────────────────────────────────────────────
-- Knockdown Center, AXS venue 126624, Queens NY. Music only. The export carries 5 live
-- events:
--
--   1636866  LCD Soundsystem                 2026-12-10 20:00   axs_ticketed, ticketer 'axs'
--   1636869  LCD Soundsystem                 2026-12-11 20:00   axs_ticketed, ticketer 'axs'
--   1636872  LCD Soundsystem                 2026-12-12 20:00   axs_ticketed, ticketer 'axs'
--   1636873  LCD Soundsystem                 2026-12-13 20:00   axs_ticketed, ticketer 'axs'
--   1156765  Anna von Hausswolff (resched.)  2027-01-22 19:00   NOT axs_ticketed, ticketer NULL
--
-- ── "WHERE AXS IS PRIMARY PROVIDER" IS WHAT OMITTING trust_axs_sold MEANS ──
-- The operator's qualifier is already the default rule, so it needs no new mechanism. A venue
-- without trust_axs_sold admits only events whose export row says AXS sells them, so the four
-- LCD Soundsystem nights join and 1156765 does not. That event is a reschedule moved from
-- Elsewhere - The Hall and its ticketer is NULL; AXS is not its primary provider, and this
-- migration deliberately does NOT override that. If it should be polled later, that is a
-- trust_axs_sold decision for the whole venue and a separate operator call — the same line
-- Nissan Stadium sits behind (mig 20261127020000).
--
-- Shape: enabled, keep_all, quota 0 — the same as the other 29. keep_all is required, not
-- cosmetic: "LCD Soundsystem" matches neither keep_regex nor sports_keep_regex, so without it
-- the keep rules would admit none of these four. It matches no exclude_regex either, so
-- nothing else stands in the way. Catalogue rows cost no reads (mig 20261126060000); watched
-- places come only from the fill's soonest-first backfill.
--
-- ── THE CONSEQUENCE, WHICH IS SMALL ───────────────────────────────────────
-- 5 export events against Opry House's 333, so this is nothing like that add. The list is full
-- at target_events (341), so the four gain places only as other events pass and free them, and
-- they stop being candidates after 2026-12-13. No quota is needed and none is given.
--
-- ── ONE THING TO WATCH, BECAUSE WE JUST SPENT A DAY ON IT ─────────────────
-- Four nights of the SAME act at ONE venue is precisely the shape that produced the TSO
-- collision (AXS internal event 5263 served under both 1579099 and 1579101) and the Disney /
-- for KING + COUNTRY one (5217). A same-title multi-night run is where TicketsData has been
-- handing us one performance's seats under several of our event ids.
--
-- This is now caught rather than hoped about: 20261128020030 records AXS's own internal event
-- id per event and 20261128030030 parks, withholds and frees the slot of any event that shares
-- one with another watched event at the same venue (venue-scoped by 20261128060030, because
-- the internal id is assigned per box office). So if TicketsData repeats the defect on this
-- run, v_axs_event_collisions shows it and the feed stops publishing those seats by itself.
-- Check that view after the four have had a read each.
--
-- ── ROLLBACK ──────────────────────────────────────────────────────────────
-- DELETE FROM public.axs_watch_venue WHERE axs_venue_id = 126624;
-- (then the next axs_watch_fill retires its watched events and axs_catalogue_fill drops its
--  catalogue rows)
-- ============================================================================

BEGIN;

DO $guard$
DECLARE v_events integer; v_ticketed integer; v_name text; v_excluded integer;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE coalesce(e.axs_ticketed, false)), max(e.venue_name)
    INTO v_events, v_ticketed, v_name
    FROM public.axs_export_event e
   WHERE e.venue_id = 126624 AND e.gone_at IS NULL AND e.removed_utc IS NULL;
  IF coalesce(v_events, 0) = 0 THEN
    RAISE EXCEPTION 'venue 126624 has no live export events — check the id before adding it';
  END IF;
  IF v_name IS DISTINCT FROM 'Knockdown Center' THEN
    RAISE EXCEPTION 'venue 126624 is "%", not Knockdown Center', v_name;
  END IF;
  -- the operator asked for the venue "where axs is primary provider": without at least one
  -- such event the add would admit nothing at all and should not be made silently.
  IF coalesce(v_ticketed, 0) = 0 THEN
    RAISE EXCEPTION
      'the export says AXS tickets none of venue 126624''s % live events — it would need trust_axs_sold, which is a separate operator decision',
      v_events;
  END IF;
  SELECT count(*) INTO v_excluded
    FROM public.axs_export_event e CROSS JOIN public.axs_watch_config c
   WHERE e.venue_id = 126624 AND e.gone_at IS NULL AND e.removed_utc IS NULL
     AND coalesce(e.axs_ticketed, false) AND e.event_title ~* c.exclude_regex;
  RAISE NOTICE 'Knockdown Center (126624): % live export events, % AXS-ticketed, % of those on the exclude list',
    v_events, v_ticketed, v_excluded;
END $guard$;

INSERT INTO public.axs_watch_venue (axs_venue_id, venue_name, quota, enabled, keep_all, trust_axs_sold, note, set_by)
VALUES (126624, 'Knockdown Center', 0, true, true, false,
        'operator 2026-11-28 "add Knockdown Center to axs event queue list where axs is primary provider"; trust_axs_sold deliberately false, so only the export''s AXS-ticketed events join (the four LCD Soundsystem nights 12/10-12/13, not the rescheduled Anna von Hausswolff whose ticketer is null). keep_all is required: the titles match no keep_regex. Same-act multi-night run — watch v_axs_event_collisions (mig 20261128070000)',
        'claude-opus-5')
ON CONFLICT (axs_venue_id) DO UPDATE
   SET enabled = true, keep_all = true, venue_name = EXCLUDED.venue_name,
       note = EXCLUDED.note, set_by = EXCLUDED.set_by;

COMMIT;
