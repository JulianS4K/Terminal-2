-- A non-transferable event leaves the API altogether.
--
-- Operator 2026-11-27, after mig 20261127240000 landed: "if non_transferable remove from
-- polled and dont send out in api to crm".
--
-- 20261127240000 did the first half -- the event leaves the polled set and carries no
-- listings -- but it still went out as an event row with listings_withheld =
-- 'non_transferable'. That was a deliberate choice at the time, so a CRM consumer could tell
-- "do not sell this" from "catalogue only". The operator wants it gone instead, which is the
-- stronger reading: an event whose tickets can never be resold is not a row the CRM has any
-- use for, and a row that is present but unsellable is an invitation to try.
--
-- So the guard moves from the reason ladder to the WHERE clause of BOTH feeds, and the
-- now-unreachable 'non_transferable' arm is taken out rather than left to imply a value that
-- can never appear. listings_withheld goes back to seven values; the eighth, introduced one
-- migration ago, never reached a consumer.
--
-- The listings feed already returned nothing for these events, because the settle deletes the
-- capture. The guard is added there too so the exclusion holds by construction rather than as
-- a consequence of the delete -- the same reasoning as mig 20261127213000's parked guard.
--
-- Both views recreated with their own reloptions (events feed security_invoker=true,
-- listings feed NULL), captured and restored explicitly.

BEGIN;

DO $surgery$
DECLARE
  v_ev text; v_li text; v_ev_opts text[]; v_li_opts text[]; v_new text; n int;
  dead_arm CONSTANT text := E'            WHEN COALESCE(t.non_transferable, false) THEN \'non_transferable\'::text\n';
  where_old CONSTANT text := '((t.event_date IS NULL) OR (t.event_date >= (CURRENT_DATE - 1)))';
  where_new CONSTANT text := '(NOT COALESCE(t.non_transferable, false)) AND ((t.event_date IS NULL) OR (t.event_date >= (CURRENT_DATE - 1)))';
BEGIN
  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass)   INTO v_ev;
  SELECT pg_get_viewdef('v_primary_poll_listings_feed'::regclass) INTO v_li;
  SELECT reloptions INTO v_ev_opts FROM pg_class WHERE relname = 'v_primary_poll_events_feed';
  SELECT reloptions INTO v_li_opts FROM pg_class WHERE relname = 'v_primary_poll_listings_feed';

  IF v_ev ~ 'NOT COALESCE\(t\.non_transferable' THEN
    RAISE NOTICE 'the feeds already exclude non-transferable events; nothing to do';
    RETURN;
  END IF;

  -- events feed: drop the unreachable reason, then exclude the row
  n := (length(v_ev) - length(replace(v_ev, dead_arm, ''))) / length(dead_arm);
  IF n <> 1 THEN RAISE EXCEPTION 'events feed: the non_transferable arm matched % times, expected 1', n; END IF;
  v_new := replace(v_ev, dead_arm, '');
  n := (length(v_new) - length(replace(v_new, where_old, ''))) / length(where_old);
  IF n <> 1 THEN RAISE EXCEPTION 'events feed: the event_date predicate matched % times, expected 1', n; END IF;
  v_new := replace(v_new, where_old, where_new);
  EXECUTE 'CREATE OR REPLACE VIEW public.v_primary_poll_events_feed AS ' || v_new;
  IF v_ev_opts @> ARRAY['security_invoker=true'] THEN
    EXECUTE 'ALTER VIEW public.v_primary_poll_events_feed SET (security_invoker = true)';
  END IF;

  -- listings feed: exclude the row there too, by construction
  n := (length(v_li) - length(replace(v_li, where_old, ''))) / length(where_old);
  IF n <> 1 THEN RAISE EXCEPTION 'listings feed: the event_date predicate matched % times, expected 1', n; END IF;
  v_new := replace(v_li, where_old, where_new);
  EXECUTE 'CREATE OR REPLACE VIEW public.v_primary_poll_listings_feed AS ' || v_new;
  IF v_li_opts @> ARRAY['security_invoker=true'] THEN
    EXECUTE 'ALTER VIEW public.v_primary_poll_listings_feed SET (security_invoker = true)';
  END IF;

  -- read back
  SELECT pg_get_viewdef('v_primary_poll_events_feed'::regclass)   INTO v_ev;
  SELECT pg_get_viewdef('v_primary_poll_listings_feed'::regclass) INTO v_li;
  IF v_ev !~ 'NOT COALESCE\(t\.non_transferable' OR v_li !~ 'NOT COALESCE\(t\.non_transferable' THEN
    RAISE EXCEPTION 'read-back: a feed is still missing the non-transferable guard';
  END IF;
  IF v_ev ~ '''non_transferable''::text' THEN
    RAISE EXCEPTION 'read-back: the unreachable non_transferable reason is still in the events feed';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = 'v_primary_poll_events_feed'
                   AND reloptions @> ARRAY['security_invoker=true']) THEN
    RAISE EXCEPTION 'read-back: the events feed lost security_invoker=true';
  END IF;
  IF (SELECT reloptions FROM pg_class WHERE relname = 'v_primary_poll_listings_feed')
       IS DISTINCT FROM v_li_opts THEN
    RAISE EXCEPTION 'read-back: the listings feed reloptions changed';
  END IF;
  -- and nothing marked non-transferable reaches either feed
  IF EXISTS (SELECT 1 FROM public.v_primary_poll_events_feed f
              JOIN public.primary_poll_event t
                ON t.source = 'axs' AND t.source_event_id = f.event_id
             WHERE f.source = 'axs' AND t.non_transferable) THEN
    RAISE EXCEPTION 'read-back: a non-transferable event is still in the events feed';
  END IF;
  IF EXISTS (SELECT 1 FROM public.v_primary_poll_listings_feed f
              JOIN public.primary_poll_event t
                ON t.source = 'axs' AND t.source_event_id = f.event_id
             WHERE f.source = 'axs' AND t.non_transferable) THEN
    RAISE EXCEPTION 'read-back: a non-transferable event is still in the listings feed';
  END IF;
END $surgery$;

COMMIT;
