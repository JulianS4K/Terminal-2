-- AXS's internal event id is unique within a venue, not across AXS.
--
-- mig 20261128020030 stored onsale.flags.events[0] and treated two of our events sharing one
-- value as proof of a served-inventory collision. That premise is wrong, and the mechanism's
-- very first new finding is what disproved it:
--
--   axs_event_internal 2393
--     1622982  Sabrina Cast Reunion 30 Year Anniversary Live  Royal Oak Music Theatre 12-03
--     1704681  Jhene Aiko Presents: Ark to Agartha            T-Mobile Arena          04-30
--
-- Different venues, different dates, 40 listings against 620, different content hashes,
-- $39.50-357.27 against $59.50-2274.97. Nothing is shared; the id is simply reused by a
-- different box office. Both proven collisions happen to sit at ONE venue -- 5263 and 5217,
-- both Toyota Center -- which is exactly why the assumption survived unexamined.
--
-- Nothing was wrongly parked, but only by luck: the settle also demands a time or title
-- mismatch, and neither of these tripped one. Had one tripped, a real event would have been
-- parked and its inventory pulled from the CRM -- the same shape as the Red Rocks episode
-- earlier tonight, where a rule that looked decisive was not correctly scoped.
--
-- Both the view and the settle now require the same VENUE as well as the same id. Venue is
-- the right scope rather than the AXS client name because it is what we already hold on
-- primary_poll_event; the two known collisions are unaffected, since each pair shares one.

BEGIN;

-- dropped and recreated rather than replaced: CREATE OR REPLACE VIEW can only append
-- columns, and venue_name belongs beside the id it scopes, not tacked on the end.
DROP VIEW IF EXISTS public.v_axs_event_collisions;
CREATE VIEW public.v_axs_event_collisions AS
  SELECT t.axs_event_internal,
         t.venue_name,
         count(*)                                          AS events,
         array_agg(t.source_event_id ORDER BY t.start_utc) AS source_event_ids,
         array_agg(t.name            ORDER BY t.start_utc) AS names,
         array_agg(t.start_utc       ORDER BY t.start_utc) AS starts,
         count(*) FILTER (WHERE t.collision_paused)        AS already_paused
    FROM public.primary_poll_event t
   WHERE t.source = 'axs' AND t.axs_event_internal IS NOT NULL
   GROUP BY t.axs_event_internal, t.venue_name
  HAVING count(*) > 1;

REVOKE ALL ON public.v_axs_event_collisions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_event_collisions TO service_role;

DO $surgery$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
  old_chk CONSTANT text :=
    '    SELECT EXISTS (SELECT 1 FROM public.primary_poll_event o' || E'\n' ||
    '                    WHERE o.source = ''axs'' AND o.axs_event_internal = v_internal' || E'\n' ||
    '                      AND o.source_event_id <> p_event_id AND o.watch)';
  new_chk CONSTANT text :=
    '    -- mig 20261128060030: the id is unique within a venue, not across AXS' || E'\n' ||
    '    SELECT EXISTS (SELECT 1 FROM public.primary_poll_event o' || E'\n' ||
    '                    JOIN public.primary_poll_event me' || E'\n' ||
    '                      ON me.source = ''axs'' AND me.source_event_id = p_event_id' || E'\n' ||
    '                    WHERE o.source = ''axs'' AND o.axs_event_internal = v_internal' || E'\n' ||
    '                      AND o.source_event_id <> p_event_id AND o.watch' || E'\n' ||
    '                      AND o.venue_name IS NOT DISTINCT FROM me.venue_name)';
  n int;
BEGIN
  IF position('o.venue_name IS NOT DISTINCT FROM me.venue_name' in src) > 0 THEN
    RAISE NOTICE 'the settle already scopes the collision to a venue; nothing to do';
    RETURN;
  END IF;
  n := (length(src) - length(replace(src, old_chk, ''))) / length(old_chk);
  IF n <> 1 THEN RAISE EXCEPTION 'settle collision check matched % times, expected 1', n; END IF;
  EXECUTE replace(src, old_chk, new_chk);
END $surgery$;

DO $verify$
DECLARE
  src text := pg_get_functiondef('public.axs_watch_settle_one(text,integer,jsonb,boolean,text,boolean,text)'::regprocedure);
BEGIN
  IF position('o.venue_name IS NOT DISTINCT FROM me.venue_name' in src) = 0 THEN
    RAISE EXCEPTION 'read-back: the settle does not scope the collision to a venue';
  END IF;
END $verify$;

COMMIT;
