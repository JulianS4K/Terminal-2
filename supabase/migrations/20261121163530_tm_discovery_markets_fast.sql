-- Migration 20261121163530 · level:data-collection · lane:D0 (outbound feed; reads the A1 mapping program's tables) · writes:v_tm_discovery_markets · reads:tm_discovery_event,events,aq_event_map,event_xmap,vivid_catalog_event,tickpick_catalog_event,sg_events_canonical · pre:20261118220530
--
-- GET /tm/markets ANSWERS A WIDE REQUEST INSTEAD OF TIMING OUT.
-- Reported 2026-11-21 by a reader of the feed: the call answered 502 after about nine seconds
-- whenever one request covered many events (no filter, or a one-month window), and took 5 to 8
-- seconds for one week.
--
-- WHY. The view looked up every event's Vivid Seats and TickPick id in those sites' catalogue
-- tables (600 MB and 260 MB), one event at a time, whether or not the id was already known: about
-- 4 ms an event, so 5,800 paired events ran past the API's statement time limit. Those lookups are
-- only the last resort. On 2026-11-21 the hub or the cross-map already had the Vivid id for every
-- event the catalogue had one for, and the TickPick id for all but one. The view was also built
-- on a WITH query read twice, so a date filter did not reduce the work.
--
-- NOW. The same columns and the same values, with:
--   - the catalogue asked only when neither the hub (aq_event_map) nor the cross-map (event_xmap)
--     has the id, and
--   - no WITH query, so a date, state or status filter is applied to tm_discovery_event first.
--   - a fixed choice between two hub rows of the same source and import time. Four EVO events
--     have such a pair (3147083, 3241126, 3369656, 3470573); which one was read used to be left
--     to chance, so the ids could differ between two calls. Now: the row with more ids, then
--     the lower Automatiq id.
-- Checked on prod, read-only: the new query returns the same 5,821 rows as the old view, all
-- columns equal, apart from those tied events.
-- Measured on prod, read-only, before this was applied: every paired event (5,821) in 2.6 seconds
-- where the old view did not finish in the limit.
--
-- Read-only, as before. Nothing here calls Ticketmaster or any other site (RULE 2).
-- The view is replaced only where it exists: tm_discovery_event's own migration (20261117180000)
-- is live on prod but not on main, and a build from zero must not fail here.
--
-- rollback: re-apply v_tm_discovery_markets from 20261118220530.

DO $do$
BEGIN
  IF to_regclass('public.tm_discovery_event') IS NULL OR to_regclass('public.event_xmap') IS NULL THEN
    RAISE NOTICE 'tm_discovery_event / event_xmap are not here yet: v_tm_discovery_markets is not replaced';
    RETURN;
  END IF;

  EXECUTE $v$
    CREATE OR REPLACE VIEW public.v_tm_discovery_markets
    WITH (security_invoker = true) AS
    SELECT m.tm_event_id,
           m.name,
           m.local_date AS event_date,
           to_char(m.local_time, 'HH24:MI') AS start_local_time,
           m.status_code AS status,
           m.segment,
           m.genre,
           m.venue_name,
           m.venue_city,
           m.venue_state,
           m.url AS ticketmaster_url,
           m.tevo_event_id,
           ev.name AS tevo_event_name,
           m.tevo_match_method,
           i.seatgeek_event_id,
           sg.sg_url AS seatgeek_url,
           i.vivid_event_id,
           i.tickpick_event_id,
           hub.sh_event_id AS stubhub_event_id,
           i.gotickets_event_id,
           i.axs_event_id,
           hub.aq_short_event_id,
           num_nonnulls(i.seatgeek_event_id, i.vivid_event_id, i.tickpick_event_id, hub.sh_event_id,
                        i.gotickets_event_id, i.axs_event_id) AS sites_paired,
           '/terminal/event.html?event=' || m.tevo_event_id AS terminal_path,
           greatest(m.tevo_matched_at, x.updated_at) AS changed_at
      FROM public.tm_discovery_event m
      -- one hub row per EVO event, the curated one first (as the MLB feed reads it)
      LEFT JOIN (SELECT DISTINCT ON (a.tevo_event_id) a.tevo_event_id, a.aq_short_event_id, a.sg_event_id,
                        a.sh_event_id, a.vivid_event_id, a.gotickets_event_id, a.tp_event_id, a.axs_event_id
                   FROM public.aq_event_map a
                  WHERE a.tevo_event_id IS NOT NULL
                  ORDER BY a.tevo_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at,
                           -- two hub rows of the same source and import: the fuller one, then by id,
                           -- so the same row is read on every call
                           num_nonnulls(a.sg_event_id, a.sh_event_id, a.vivid_event_id, a.gotickets_event_id,
                                        a.tp_event_id, a.axs_event_id) DESC, a.aq_short_event_id) hub
             ON hub.tevo_event_id = m.tevo_event_id
      LEFT JOIN public.event_xmap x ON x.tevo_event_id = m.tevo_event_id
      -- each id: the hub's, else the cross-map's, else (Vivid Seats and TickPick) that site's
      -- catalogue matched to the same EVO event. The catalogue is read only when the first two
      -- are empty. OFFSET 0 keeps this evaluated once per event.
      CROSS JOIN LATERAL (
        SELECT coalesce(hub.sg_event_id, x.sg_event_id) AS seatgeek_event_id,
               coalesce(hub.vivid_event_id, x.vivid_event_id,
                        (SELECT min(v.vivid_event_id) FROM public.vivid_catalog_event v
                          WHERE v.tevo_event_id = m.tevo_event_id)) AS vivid_event_id,
               coalesce(hub.tp_event_id, x.tp_event_id,
                        (SELECT min(t.tp_event_id) FROM public.tickpick_catalog_event t
                          WHERE t.tevo_event_id = m.tevo_event_id)) AS tickpick_event_id,
               coalesce(hub.gotickets_event_id, x.gt_event_id) AS gotickets_event_id,
               coalesce(hub.axs_event_id, x.axs_event_id::text) AS axs_event_id
        OFFSET 0) i
      LEFT JOIN public.events ev ON ev.id = m.tevo_event_id
      LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = i.seatgeek_event_id
     WHERE m.tevo_event_id IS NOT NULL AND m.local_date >= CURRENT_DATE - 1
  $v$;

  EXECUTE 'REVOKE ALL ON public.v_tm_discovery_markets FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT SELECT ON public.v_tm_discovery_markets TO service_role';
END
$do$;

NOTIFY pgrst, 'reload schema';
