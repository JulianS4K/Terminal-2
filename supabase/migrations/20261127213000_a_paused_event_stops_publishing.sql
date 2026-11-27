-- A paused event stops publishing.
--
-- Operator 2026-11-27: "Stop publishing when paused", after pausing the two Trans-Siberian
-- Orchestra shows at Toyota Center (axs 1579099, 1579101) and finding them still serving 295
-- listing rows each.
--
-- THE GAP. The system's own model already says a parked event is read once a day and NOT
-- published, and the thin-inventory path achieves that -- but only incidentally, by DELETING
-- the capture in settle (mig 20261127000000). A park applied any other way, such as an
-- operator pausing an event by hand, leaves the capture in place, and the feed happily keeps
-- serving it. Worse, mig 20261126213000 made the publish window band-relative:
--   now() < GREATEST(poll_ok_at + GREATEST(listing_max_age, poll_interval + listing_grace), ...)
-- so lengthening an event's band to the 1-day parked interval LENGTHENS its publish window to
-- about a day. Pausing an event therefore made it publish stale data for longer, which is the
-- exact opposite of what "pause" means.
--
-- THE FIX is the parked test itself, the same one axs_watch_fill, axs_queue_claim and the
-- monitor all use -- cadence_pinned AND poll_interval >= no_tickets_every -- added as a guard
-- to both feed views, so "parked" means "not published" by construction rather than as a side
-- effect of deleting rows. Nothing is deleted; the capture stays and the event resumes
-- publishing the moment the pause is lifted.
--
-- REASON PRECEDENCE: the new 'paused' arm sits AFTER 'thin_inventory' in the events feed, so a
-- thin-parked event keeps the more specific reason it already reports and the CRM contract for
-- those rows does not change. 'paused' is therefore only ever a deliberate operator pause.
-- This adds a seventh value to listings_withheld; docs/crm_primary_feed_axs_changes.md is
-- updated in the same change.
--
-- Guarded in-place surgery on both views, each recreated with ITS OWN reloptions: the events
-- feed is security_invoker=true and the listings feed is NULL, and swapping them would change
-- who the views run as. Verified before and after.

DO $surgery$
DECLARE
  v_ev text; v_li text; v_new text;
  v_guard CONSTANT text :=
    '(COALESCE(t.cadence_pinned, false) AND t.poll_interval >= ( SELECT pc.no_tickets_every FROM axs_watch_config pc))';
  v_case  CONSTANT text := E'            WHEN (COALESCE(t.cadence_pinned, false) AND t.poll_interval >= ( SELECT pc.no_tickets_every\n               FROM axs_watch_config pc)) THEN \'paused\'::text\n';
  v_else  CONSTANT text := E'            ELSE \'poll_stale\'::text';
  v_fresh CONSTANT text := ') AS fresh';
  v_where CONSTANT text := 'AND ((t.event_date IS NULL) OR (t.event_date >= (CURRENT_DATE - 1))))';
BEGIN
  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass)   INTO v_ev;
  SELECT pg_get_viewdef('v_primary_poll_listings_feed'::regclass) INTO v_li;

  IF v_ev ~ 'cadence_pinned' OR v_li ~ 'cadence_pinned' THEN
    RAISE NOTICE 'a parked guard is already present; nothing to do';
    RETURN;
  END IF;
  IF (length(v_ev) - length(replace(v_ev, v_fresh, ''))) / length(v_fresh) <> 1
     OR (length(v_ev) - length(replace(v_ev, v_else, ''))) / length(v_else) <> 1 THEN
    RAISE EXCEPTION 'events feed: expected the fresh and poll_stale anchors exactly once each';
  END IF;
  IF (length(v_li) - length(replace(v_li, v_where, ''))) / length(v_where) <> 1 THEN
    RAISE EXCEPTION 'listings feed: expected the event_date anchor exactly once';
  END IF;

  -- events feed: the guard joins the `fresh` expression, and a reason is reported for it
  v_new := replace(v_ev, v_fresh, ' AND NOT ' || v_guard || v_fresh);
  v_new := replace(v_new, v_else, v_case || v_else);
  EXECUTE 'CREATE OR REPLACE VIEW public.v_primary_poll_events_feed AS ' || v_new;

  -- listings feed: a parked event contributes no rows at all
  v_new := replace(v_li, v_where, 'AND NOT ' || v_guard || ' ' || v_where);
  EXECUTE 'CREATE OR REPLACE VIEW public.v_primary_poll_listings_feed AS ' || v_new;

  -- read back: both guards in, each view keeping its own reloptions
  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass)   INTO v_ev;
  SELECT pg_get_viewdef('v_primary_poll_listings_feed'::regclass) INTO v_li;
  IF v_ev !~ 'cadence_pinned' OR v_li !~ 'cadence_pinned' THEN
    RAISE EXCEPTION 'read-back: the parked guard is missing from one of the feed views';
  END IF;
  IF v_ev !~ 'paused' THEN
    RAISE EXCEPTION 'read-back: the paused reason is missing from the events feed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'v_primary_poll_events_feed'
                   AND reloptions @> ARRAY['security_invoker=true']) THEN
    RAISE EXCEPTION 'read-back: the events feed lost security_invoker=true';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'v_primary_poll_listings_feed'
               AND reloptions IS NOT NULL) THEN
    RAISE EXCEPTION 'read-back: the listings feed gained reloptions it did not have';
  END IF;
END $surgery$;
