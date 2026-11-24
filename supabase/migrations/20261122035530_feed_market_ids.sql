-- Migration 20261122035530 · level:data-collection · lane:D0 (outbound feed; reads the A1 mapping program's tables) · writes:feed_market_ids(new) · reads:tm_discovery_event,axs_export_event,sg_events_canonical,event_xmap,aq_event_map,vivid_catalog_event,tickpick_catalog_event · pre:20261122030530 (tm_discovery_event.source)
--
-- THE SAME EVENT'S ID ON EVERY MARKETPLACE, FOR EVERY EVENT FEED WE SEND OUT.
-- Operator 2026-11-22: "include the cross maps in all event mapping you push out, marketplace id".
-- Until now only GET /tm/markets carried the other sites' ids, and only for Ticketmaster events
-- whose own matcher had found the EVO event. /tm/events, /axs/events, /seatgeek/events and
-- /mlb/events carried the EVO id alone.
--
-- feed_market_ids(p_source, p_ids) answers, for up to 5,000 ids of one feed, one row per id:
--   xmap_tevo_event_id      the EVO event: the feed's own match, else the cross-map's (event_xmap)
--   ticketmaster_event_id   seatgeek_event_id   stubhub_event_id   vivid_event_id
--   tickpick_event_id       gotickets_event_id  axs_event_id       aq_short_event_id (Automatiq)
-- p_source is 'ticketmaster' (tm_event_id), 'axs' (axs_event_id), 'seatgeek' (sg_event_id) or
-- 'tevo' (an EVO event id: the MLB feeds).
--
-- WHERE EACH ID COMES FROM, in this order, exactly as v_tm_discovery_markets reads them (mig
-- 20261121163530) so the two never disagree for an event both serve:
--   1. the hub (aq_event_map) row of the EVO event, the curated one first;
--   2. the cross-map (event_xmap) row of the EVO event;
--   3. Vivid Seats and TickPick only: that site's catalogue matched to the EVO event;
--   4. the cross-map row of the feed's own id (a Ticketmaster, AXS or SeatGeek event the cross-map
--      holds but pairs with no EVO event can still be paired with other sites).
-- StubHub ids and Automatiq ids are held by the hub only.
-- For a feed that is not Ticketmaster's, ticketmaster_event_id is the Ticketmaster event matched to
-- the EVO event (the one Ticketmaster itself sells before a resale page, then the earliest), else
-- the one the cross-map holds.
--
-- The feed routes ask for one page of ids at a time (routers/feed_xmap.py), so a page costs one
-- more database call and the feeds' own views, filters and paging are unchanged.
-- plpgsql, so a build from zero does not fail here while tm_discovery_event's own migration
-- (20261117180000, live on prod) is not on main.
-- Read-only: no upstream call (RULE 2), no write.
--
-- rollback: DROP FUNCTION public.feed_market_ids(text, text[]);

CREATE OR REPLACE FUNCTION public.feed_market_ids(p_source text, p_ids text[])
 RETURNS TABLE (source_id text, xmap_tevo_event_id bigint, ticketmaster_event_id text, seatgeek_event_id bigint,
                stubhub_event_id bigint, vivid_event_id bigint, tickpick_event_id bigint, gotickets_event_id bigint,
                axs_event_id text, aq_short_event_id text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_nums bigint[];
BEGIN
  IF p_source IS NULL OR p_source NOT IN ('ticketmaster', 'axs', 'seatgeek', 'tevo') THEN
    RAISE EXCEPTION 'feed_market_ids: unknown source %', p_source;
  END IF;
  IF coalesce(cardinality(p_ids), 0) > 5000 THEN
    RAISE EXCEPTION 'feed_market_ids: at most 5000 ids a call';
  END IF;
  SELECT array_agg(DISTINCT u::bigint) INTO v_nums FROM unnest(p_ids) u WHERE u ~ '^[0-9]{1,18}$';

  RETURN QUERY
  WITH own AS (
    -- each id asked for: the EVO event its own feed matched, and its cross-map row
    SELECT e.tm_event_id AS sid, e.tevo_event_id AS tevo, x.xmap_id
      FROM public.tm_discovery_event e
      LEFT JOIN public.event_xmap x ON x.tm_event_seq = e.tm_seq
     WHERE p_source = 'ticketmaster' AND e.tm_event_id = ANY (p_ids)
    UNION ALL
    SELECT a.axs_event_id::text, a.tevo_event_id, x.xmap_id
      FROM public.axs_export_event a
      LEFT JOIN public.event_xmap x ON x.axs_event_id = a.axs_event_id
     WHERE p_source = 'axs' AND a.axs_event_id = ANY (v_nums)
    UNION ALL
    SELECT g.sg_event_id::text, g.tevo_event_id, x.xmap_id
      FROM public.sg_events_canonical g
      LEFT JOIN public.event_xmap x ON x.sg_event_id = g.sg_event_id
     WHERE p_source = 'seatgeek' AND g.sg_event_id = ANY (v_nums)
    UNION ALL
    SELECT n::text, n, NULL::bigint FROM unnest(v_nums) n WHERE p_source = 'tevo'),
  k AS MATERIALIZED (
    SELECT o.sid, coalesce(o.tevo, xo.tevo_event_id) AS tevo, o.xmap_id
      FROM own o LEFT JOIN public.event_xmap xo ON xo.xmap_id = o.xmap_id),
  hub AS (
    -- one hub row per EVO event, chosen as v_tm_discovery_markets chooses it
    SELECT DISTINCT ON (a.tevo_event_id) a.tevo_event_id, a.aq_short_event_id, a.sg_event_id, a.sh_event_id,
           a.vivid_event_id, a.gotickets_event_id, a.tp_event_id, a.axs_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IN (SELECT k.tevo FROM k WHERE k.tevo IS NOT NULL)
     ORDER BY a.tevo_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at,
              num_nonnulls(a.sg_event_id, a.sh_event_id, a.vivid_event_id, a.gotickets_event_id,
                           a.tp_event_id, a.axs_event_id) DESC, a.aq_short_event_id)
  SELECT k.sid,
         k.tevo,
         CASE WHEN p_source = 'ticketmaster' THEN k.sid
              ELSE coalesce((SELECT t.tm_event_id FROM public.tm_discovery_event t
                              WHERE t.tevo_event_id = k.tevo
                              ORDER BY (t.source = 'ticketmaster') DESC NULLS LAST, t.local_date, t.tm_event_id LIMIT 1),
                            (SELECT t.tm_event_id FROM public.tm_discovery_event t
                              WHERE t.tm_seq = coalesce(xt.tm_event_seq, xo.tm_event_seq))) END,
         CASE WHEN p_source = 'seatgeek' THEN k.sid::bigint
              ELSE coalesce(hub.sg_event_id, xt.sg_event_id, xo.sg_event_id) END,
         hub.sh_event_id,
         coalesce(hub.vivid_event_id, xt.vivid_event_id,
                  (SELECT min(v.vivid_event_id) FROM public.vivid_catalog_event v WHERE v.tevo_event_id = k.tevo),
                  xo.vivid_event_id),
         coalesce(hub.tp_event_id, xt.tp_event_id,
                  (SELECT min(c.tp_event_id) FROM public.tickpick_catalog_event c WHERE c.tevo_event_id = k.tevo),
                  xo.tp_event_id),
         coalesce(hub.gotickets_event_id, xt.gt_event_id, xo.gt_event_id),
         CASE WHEN p_source = 'axs' THEN k.sid
              ELSE coalesce(hub.axs_event_id, xt.axs_event_id::text, xo.axs_event_id::text) END,
         hub.aq_short_event_id
    FROM k
    LEFT JOIN hub ON hub.tevo_event_id = k.tevo
    LEFT JOIN public.event_xmap xt ON xt.tevo_event_id = k.tevo
    LEFT JOIN public.event_xmap xo ON xo.xmap_id = k.xmap_id;
END $function$;

REVOKE ALL ON FUNCTION public.feed_market_ids(text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_market_ids(text, text[]) TO service_role;

NOTIFY pgrst, 'reload schema';
