-- Migration 20261122031530 · level:data-collection · lane:D0 (outbound feed; reads the A1 data plane's tables) · writes:v_axs_events_feed(new),v_seatgeek_primary_feed(new) · reads:axs_export_event,sg_events_canonical,events · pre:20261103090000 (axs_export_event)
--
-- AXS EVENTS AND SEATGEEK-PRIMARY EVENTS AS TWO OUTBOUND FEEDS.
-- Operator 2026-11-22: "Also push out axs and SeatGeek primary in API and announce in news".
--
-- Two views for the sub finder API's read-only routes (routers/primary_feed.py), next to the Ticketmaster feed:
--   v_axs_events_feed        GET /axs/events       every live upcoming AXS event we hold (axs_export_event, from
--                            TicketsData's AXS export), with `axs_primary`: AXS itself sells it (48,233 of 139,836
--                            on 2026-11-22). The rest are events AXS lists and another ticketer sells. The route
--                            serves the primary ones unless asked otherwise. With the EVO event each matched.
--   v_seatgeek_primary_feed  GET /seatgeek/events  the upcoming events where SeatGeek is the primary ticketer
--                            (SeatGeek's own flag `is_open`: Dallas Cowboys, Washington Commanders and so on),
--                            from the SeatGeek events we hold (sg_events_canonical). Only 45 on 2026-11-22: we
--                            hold SeatGeek's record for about 4,300 upcoming events, not its whole catalogue.
-- `changed_at` is when a row was first seen or matched. No prices and no inventory in either.
--
-- Read-only: nothing here calls AXS, SeatGeek or TicketsData (RULE 2).
-- Each view is created only where its table exists, so a build from zero does not fail here.
--
-- rollback: DROP VIEW public.v_axs_events_feed; DROP VIEW public.v_seatgeek_primary_feed;

DO $do$
DECLARE
  v_unaccent text := coalesce((SELECT quote_ident(n.nspname) || '.unaccent'
                                 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                                WHERE p.proname = 'unaccent' AND p.pronargs = 1
                                  AND p.proargtypes[0] = 'text'::regtype
                                ORDER BY n.nspname LIMIT 1), '');
BEGIN
  IF to_regclass('public.axs_export_event') IS NOT NULL AND to_regclass('public.events') IS NOT NULL THEN
    EXECUTE replace($v$
      CREATE OR REPLACE VIEW public.v_axs_events_feed
      WITH (security_invoker = true) AS
      SELECT a.axs_event_id,
             a.event_title AS name,
             a.headliner,
             a.performers,
             a.tour_title,
             a.major_category AS category,
             a.genre,
             a.status,
             CASE WHEN a.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' THEN left(a.event_date_local, 10)::date END AS event_date,
             CASE WHEN a.event_date_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}' THEN substr(a.event_date_local, 12, 5) END AS start_local_time,
             a.event_date_utc AS start_utc,
             a.event_timezone AS timezone,
             coalesce(a.is_tba, false) AS time_tba,
             a.venue_id AS axs_venue_id,
             a.venue_name,
             a.venue_city,
             a.venue_state,
             a.venue_country,
             a.announce_utc,
             a.onsale_utc,
             a.presale_utc,
             a.event_url AS ticket_url,
             a.ticketer,
             coalesce(a.axs_ticketed, false) AS axs_primary,
             a.tevo_event_id,
             ev.name AS tevo_event_name,
             a.match_method AS tevo_match_method,
             CASE WHEN a.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || a.tevo_event_id END AS terminal_path,
             a.first_seen_utc AS first_seen_at,
             a.last_seen_utc AS last_seen_at,
             greatest(a.first_synced_at, a.matched_at) AS changed_at,
             lower(@UNACCENT@(concat_ws(' ', a.event_title, a.headliner, array_to_string(a.performers, ' '), a.venue_name, a.venue_city))) AS search_text
        FROM public.axs_export_event a
        LEFT JOIN public.events ev ON ev.id = a.tevo_event_id
       WHERE a.gone_at IS NULL AND a.removed_utc IS NULL
         AND (a.event_date_utc IS NULL OR a.event_date_utc >= now() - interval '1 day')
    $v$, '@UNACCENT@', v_unaccent);
    EXECUTE 'REVOKE ALL ON public.v_axs_events_feed FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT SELECT ON public.v_axs_events_feed TO service_role';
  ELSE
    RAISE NOTICE 'axs_export_event is not here: v_axs_events_feed is not created';
  END IF;

  IF to_regclass('public.sg_events_canonical') IS NOT NULL AND to_regclass('public.events') IS NOT NULL THEN
    EXECUTE replace($v$
      CREATE OR REPLACE VIEW public.v_seatgeek_primary_feed
      WITH (security_invoker = true) AS
      SELECT g.sg_event_id,
             g.sg_event_name AS name,
             g.sg_category AS category,
             g.raw_event_jsonb->>'status' AS status,
             g.sg_event_date AS event_date,
             CASE WHEN g.raw_event_jsonb->>'datetime_local' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}'
                  THEN substr(g.raw_event_jsonb->>'datetime_local', 12, 5) END AS start_local_time,
             g.sg_datetime_utc AS start_utc,
             coalesce(g.raw_event_jsonb->>'time_tbd' = 'true', false) AS time_tba,
             (SELECT jsonb_agg(p->>'name') FROM jsonb_array_elements(
                CASE WHEN jsonb_typeof(g.raw_event_jsonb->'performers') = 'array' THEN g.raw_event_jsonb->'performers' ELSE '[]'::jsonb END) p) AS performers,
             g.sg_venue_id,
             g.sg_venue_name AS venue_name,
             coalesce(g.sg_venue_city, g.raw_event_jsonb->'venue'->>'city') AS venue_city,
             coalesce(g.sg_venue_state, g.raw_event_jsonb->'venue'->>'state') AS venue_state,
             coalesce(g.sg_venue_country, g.raw_event_jsonb->'venue'->>'country') AS venue_country,
             g.sg_url AS ticket_url,
             g.raw_event_jsonb->>'open_id' AS seatgeek_open_id,
             true AS seatgeek_primary,
             g.tevo_event_id,
             ev.name AS tevo_event_name,
             g.match_method AS tevo_match_method,
             CASE WHEN g.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || g.tevo_event_id END AS terminal_path,
             g.created_at AS first_seen_at,
             g.updated_at AS last_seen_at,
             greatest(g.created_at, g.matched_at) AS changed_at,
             lower(@UNACCENT@(concat_ws(' ', g.sg_event_name, g.sg_venue_name, g.raw_event_jsonb->'venue'->>'city'))) AS search_text
        FROM public.sg_events_canonical g
        LEFT JOIN public.events ev ON ev.id = g.tevo_event_id
       WHERE g.raw_event_jsonb->>'is_open' = 'true' AND g.sg_event_date >= CURRENT_DATE - 1
    $v$, '@UNACCENT@', v_unaccent);
    EXECUTE 'REVOKE ALL ON public.v_seatgeek_primary_feed FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT SELECT ON public.v_seatgeek_primary_feed TO service_role';
  ELSE
    RAISE NOTICE 'sg_events_canonical is not here: v_seatgeek_primary_feed is not created';
  END IF;
END
$do$;

NOTIFY pgrst, 'reload schema';
