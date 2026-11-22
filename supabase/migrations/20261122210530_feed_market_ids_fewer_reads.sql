-- Migration 20261122210530 · level:data-collection · lane:D0 (outbound feed; reads the A1 mapping program's tables) · writes:feed_market_ids(replaced) · reads:tm_discovery_event,axs_export_event,sg_events_canonical,event_xmap,aq_event_map,vivid_catalog_event,tickpick_catalog_event · pre:20261122035530
--
-- feed_market_ids READS THE CROSS-MAP ONCE PER EVENT INSTEAD OF UP TO FOUR TIMES.
-- Measured on prod 2026-11-22, the day it went live: with the data not in memory, one call for a
-- 5,000-row AXS page ran past the API's 8-second statement limit, and GET /axs/events?limit=5000
-- and GET /tm/events?limit=1000 answered 502 on a first read. Every read in the function is an
-- index probe, so the time is the number of probes: per id, the feed's own row, then event_xmap
-- by the feed's key, by its primary key (twice) and by the EVO event.
--
-- NOW. The cross-map row found by the feed's own key is carried along, not looked up again, and
-- the lookup by EVO event is skipped when that row already is the EVO event's row (tevo_event_id
-- is unique in event_xmap, so it is the same row). One or two probes of event_xmap per id.
-- The answer is unchanged: same columns, same order of sources (hub, the EVO event's cross-map
-- row, the Vivid / TickPick catalogue, the feed's own cross-map row). Checked read-only on prod
-- against the function this replaces, for each of the four sources.
-- routers/feed_xmap.py also asks in chunks of 500 ids and repeats a failed chunk once.
--
-- rollback: re-apply feed_market_ids from 20261122035530.

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
    -- each id asked for: the EVO event its own feed matched, and its cross-map row (x_*), read once
    SELECT e.tm_event_id AS sid, e.tevo_event_id AS tevo, x.xmap_id IS NOT NULL AS has_x, x.tevo_event_id AS x_tevo,
           x.sg_event_id AS x_sg, x.vivid_event_id AS x_vivid, x.tp_event_id AS x_tp, x.gt_event_id AS x_gt,
           x.axs_event_id AS x_axs, x.tm_event_seq AS x_tm
      FROM public.tm_discovery_event e
      LEFT JOIN public.event_xmap x ON x.tm_event_seq = e.tm_seq
     WHERE p_source = 'ticketmaster' AND e.tm_event_id = ANY (p_ids)
    UNION ALL
    SELECT a.axs_event_id::text, a.tevo_event_id, x.xmap_id IS NOT NULL, x.tevo_event_id,
           x.sg_event_id, x.vivid_event_id, x.tp_event_id, x.gt_event_id, x.axs_event_id, x.tm_event_seq
      FROM public.axs_export_event a
      LEFT JOIN public.event_xmap x ON x.axs_event_id = a.axs_event_id
     WHERE p_source = 'axs' AND a.axs_event_id = ANY (v_nums)
    UNION ALL
    SELECT g.sg_event_id::text, g.tevo_event_id, x.xmap_id IS NOT NULL, x.tevo_event_id,
           x.sg_event_id, x.vivid_event_id, x.tp_event_id, x.gt_event_id, x.axs_event_id, x.tm_event_seq
      FROM public.sg_events_canonical g
      LEFT JOIN public.event_xmap x ON x.sg_event_id = g.sg_event_id
     WHERE p_source = 'seatgeek' AND g.sg_event_id = ANY (v_nums)
    UNION ALL
    SELECT n::text, n, false, NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint, NULL::bigint
      FROM unnest(v_nums) n WHERE p_source = 'tevo'),
  k AS MATERIALIZED (
    -- evo: the feed's own match, else the cross-map's. same: the feed's cross-map row IS the EVO event's row
    SELECT o.*, coalesce(o.tevo, o.x_tevo) AS evo,
           (o.has_x AND o.x_tevo IS NOT NULL AND o.x_tevo = coalesce(o.tevo, o.x_tevo)) AS same
      FROM own o),
  hub AS (
    -- one hub row per EVO event, chosen as v_tm_discovery_markets chooses it
    SELECT DISTINCT ON (a.tevo_event_id) a.tevo_event_id, a.aq_short_event_id, a.sg_event_id, a.sh_event_id,
           a.vivid_event_id, a.gotickets_event_id, a.tp_event_id, a.axs_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id IN (SELECT k.evo FROM k WHERE k.evo IS NOT NULL)
     ORDER BY a.tevo_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at,
              num_nonnulls(a.sg_event_id, a.sh_event_id, a.vivid_event_id, a.gotickets_event_id,
                           a.tp_event_id, a.axs_event_id) DESC, a.aq_short_event_id)
  SELECT k.sid,
         k.evo,
         CASE WHEN p_source = 'ticketmaster' THEN k.sid
              ELSE coalesce((SELECT t.tm_event_id FROM public.tm_discovery_event t
                              WHERE t.tevo_event_id = k.evo
                              ORDER BY (t.source = 'ticketmaster') DESC NULLS LAST, t.local_date, t.tm_event_id LIMIT 1),
                            (SELECT t.tm_event_id FROM public.tm_discovery_event t
                              WHERE t.tm_seq = coalesce(xt.tm_event_seq, k.x_tm))) END,
         CASE WHEN p_source = 'seatgeek' THEN k.sid::bigint
              ELSE coalesce(hub.sg_event_id, xt.sg_event_id, k.x_sg) END,
         hub.sh_event_id,
         coalesce(hub.vivid_event_id, xt.vivid_event_id, CASE WHEN k.same THEN k.x_vivid END,
                  (SELECT min(v.vivid_event_id) FROM public.vivid_catalog_event v WHERE v.tevo_event_id = k.evo),
                  k.x_vivid),
         coalesce(hub.tp_event_id, xt.tp_event_id, CASE WHEN k.same THEN k.x_tp END,
                  (SELECT min(c.tp_event_id) FROM public.tickpick_catalog_event c WHERE c.tevo_event_id = k.evo),
                  k.x_tp),
         coalesce(hub.gotickets_event_id, xt.gt_event_id, k.x_gt),
         CASE WHEN p_source = 'axs' THEN k.sid
              ELSE coalesce(hub.axs_event_id, xt.axs_event_id::text, k.x_axs::text) END,
         hub.aq_short_event_id
    FROM k
    LEFT JOIN hub ON hub.tevo_event_id = k.evo
    -- the EVO event's cross-map row, only when it is not the row already held
    LEFT JOIN public.event_xmap xt ON xt.tevo_event_id = k.evo AND NOT k.same;
END $function$;

REVOKE ALL ON FUNCTION public.feed_market_ids(text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.feed_market_ids(text, text[]) TO service_role;

NOTIFY pgrst, 'reload schema';
