-- Migration 20261118220530 · level:data-collection · lane:D0 (outbound feed; reads the A1 mapping program's tables) · writes:v_tm_discovery_feed(new),v_tm_discovery_markets(new) · reads:tm_discovery_event,events,aq_event_map,event_xmap,vivid_catalog_event,tickpick_catalog_event,sg_events_canonical · pre:20261117180000 (tm_discovery)
--
-- TICKETMASTER'S CATALOGUE, AND THE SITES EACH MAPPED EVENT PAIRS TO, AS TWO OUTBOUND FEEDS.
-- Operator 2026-11-18: "add the tmr discovery feed into the mlb api and push out and ping, then add
-- the sites it pairs to vivid, seatgeek, tickpick etc when it maps as a seperate get call for
-- them and announce in news/ping".
--
-- Two views for the sub finder API's read-only routes (routers/tm_feed.py), next to the MLB feed:
--   v_tm_discovery_feed     GET /tm/events   every upcoming Ticketmaster Discovery event we hold
--                           (tm_discovery_event, filled by tm_discovery_tick under its 100-calls-a-day
--                           budget), with the EVO event it matched, if any.
--   v_tm_discovery_markets  GET /tm/markets  one row per event that matched an EVO event, with the
--                           id of the same event on each other site we can pair it to: SeatGeek,
--                           Vivid Seats, TickPick, StubHub, GoTickets, AXS, and our Automatiq id.
--                           Each id is the hub's (aq_event_map) when it has one, else the mapping
--                           program's cross-map (event_xmap), else that site's catalogue matched to
--                           the same EVO event.
-- `changed_at` is when a row last gained something a reader uses: the event was first seen, or it
-- matched (feed); it matched, or its cross-map row changed (markets). Ticketmaster's own changes to
-- an event (status, time) arrive with the weekly re-read and do not move it.
--
-- Read-only. Nothing here calls Ticketmaster or any other site (RULE 2), and nothing is written to
-- the hub: Discovery ids are text and aq_event_map.tm_event_id is numeric, which is still an
-- operator decision (see 20261117180000).
--
-- The views are created only where tm_discovery_event exists: its migration is live on prod but
-- not yet on main, and a build from zero must not fail here.
--
-- rollback: DROP VIEW public.v_tm_discovery_markets; DROP VIEW public.v_tm_discovery_feed;

DO $do$
BEGIN
  IF to_regclass('public.tm_discovery_event') IS NULL OR to_regclass('public.event_xmap') IS NULL THEN
    RAISE NOTICE 'tm_discovery_event / event_xmap are not here yet: the Ticketmaster feed views are not created';
    RETURN;
  END IF;

  EXECUTE $v$
    CREATE OR REPLACE VIEW public.v_tm_discovery_feed
    WITH (security_invoker = true) AS
    SELECT e.tm_event_id,
           e.name,
           e.url AS ticket_url,
           e.local_date AS event_date,
           to_char(e.local_time, 'HH24:MI') AS start_local_time,
           e.start_utc,
           e.date_tbd,
           e.time_tba,
           e.status_code AS status,
           e.segment,
           e.genre,
           e.sub_genre,
           e.tm_venue_id,
           e.venue_name,
           e.venue_city,
           e.venue_state,
           e.venue_country,
           e.venue_timezone,
           e.attraction_names,
           e.public_onsale,
           e.presales,
           e.ticket_limit,
           coalesce(e.is_product, false) AS is_product,
           e.tevo_event_id,
           e.tevo_match_method,
           ev.name AS tevo_event_name,
           ev.occurs_at_local AS tevo_start_local,
           CASE WHEN e.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || e.tevo_event_id END AS terminal_path,
           e.first_seen_at,
           e.last_seen_at,
           greatest(e.first_seen_at, e.tevo_matched_at) AS changed_at
      FROM public.tm_discovery_event e
      LEFT JOIN public.events ev ON ev.id = e.tevo_event_id
     WHERE e.local_date >= CURRENT_DATE - 1
  $v$;

  EXECUTE $v$
    CREATE OR REPLACE VIEW public.v_tm_discovery_markets
    WITH (security_invoker = true) AS
    WITH m AS (
      SELECT e.* FROM public.tm_discovery_event e
       WHERE e.tevo_event_id IS NOT NULL AND e.local_date >= CURRENT_DATE - 1
    ), hub AS (
      -- one hub row per EVO event, the curated one first (as the MLB feed reads it)
      SELECT DISTINCT ON (a.tevo_event_id) a.tevo_event_id, a.aq_short_event_id, a.sg_event_id, a.sh_event_id,
             a.vivid_event_id, a.gotickets_event_id, a.tp_event_id, a.axs_event_id
        FROM public.aq_event_map a
       WHERE a.tevo_event_id IN (SELECT m.tevo_event_id FROM m)
       ORDER BY a.tevo_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at
    ), ids AS (
      SELECT m.tm_event_id,
             coalesce(hub.sg_event_id, x.sg_event_id) AS seatgeek_event_id,
             coalesce(hub.vivid_event_id, x.vivid_event_id, vc.id) AS vivid_event_id,
             coalesce(hub.tp_event_id, x.tp_event_id, tc.id) AS tickpick_event_id,
             hub.sh_event_id AS stubhub_event_id,
             coalesce(hub.gotickets_event_id, x.gt_event_id) AS gotickets_event_id,
             coalesce(hub.axs_event_id, x.axs_event_id::text) AS axs_event_id,
             hub.aq_short_event_id,
             x.updated_at AS xmap_updated_at
        FROM m
        LEFT JOIN hub ON hub.tevo_event_id = m.tevo_event_id
        LEFT JOIN public.event_xmap x ON x.tevo_event_id = m.tevo_event_id
        LEFT JOIN LATERAL (SELECT min(v.vivid_event_id) AS id FROM public.vivid_catalog_event v
                            WHERE v.tevo_event_id = m.tevo_event_id) vc ON true
        LEFT JOIN LATERAL (SELECT min(t.tp_event_id) AS id FROM public.tickpick_catalog_event t
                            WHERE t.tevo_event_id = m.tevo_event_id) tc ON true
    )
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
           i.stubhub_event_id,
           i.gotickets_event_id,
           i.axs_event_id,
           i.aq_short_event_id,
           num_nonnulls(i.seatgeek_event_id, i.vivid_event_id, i.tickpick_event_id, i.stubhub_event_id,
                        i.gotickets_event_id, i.axs_event_id) AS sites_paired,
           '/terminal/event.html?event=' || m.tevo_event_id AS terminal_path,
           greatest(m.tevo_matched_at, i.xmap_updated_at) AS changed_at
      FROM m
      JOIN ids i ON i.tm_event_id = m.tm_event_id
      LEFT JOIN public.events ev ON ev.id = m.tevo_event_id
      LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = i.seatgeek_event_id
  $v$;

  EXECUTE 'REVOKE ALL ON public.v_tm_discovery_feed, public.v_tm_discovery_markets FROM PUBLIC, anon, authenticated';
  EXECUTE 'GRANT SELECT ON public.v_tm_discovery_feed, public.v_tm_discovery_markets TO service_role';
END
$do$;

NOTIFY pgrst, 'reload schema';
