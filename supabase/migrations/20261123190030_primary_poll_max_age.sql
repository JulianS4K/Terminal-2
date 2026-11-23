-- Migration 20261123190030 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) + D0 (the feed's views) · writes:primary_poll_config(new),v_primary_poll_events_feed(replaced),v_primary_poll_listings_feed(replaced) · reads:primary_poll_event,primary_poll_listing,primary_poll_source · pre:20261123171030
-- Already applied to prod · via MCP 2026-11-23 (operator: "reduce polling to 30 mins"); re-apply is a no-op.
--
-- THE BOX-OFFICE POLL RUNS EVERY 30 MINUTES; THE FEED'S AGE LIMIT FOLLOWS IT AND IS NOW A SETTING.
-- Operator 2026-11-23: "reduce polling to 30 mins".
--
-- The feed sends an event's listings only while its last good poll is recent: that is what withholds them when
-- a poll does not run. The limit was written into the two views as 15 minutes, right for a poll every 10. With
-- a poll every 30 it would withhold every listing for half of each cycle. The limit moves to one row,
-- primary_poll_config.listing_max_age, 35 minutes: one 30-minute cycle plus the run's own time. Both views
-- read it. The poll's own interval is PRIMARY_POLL_INTERVAL_SECONDS on each worker's service (now 1800).
--
-- IF THE INTERVAL CHANGES AGAIN, change this row with it (interval + about 5 minutes): too short and listings
-- drop out between polls; too long and a poll that did not run goes unnoticed for longer.
--   UPDATE public.primary_poll_config SET listing_max_age = interval '15 minutes';   -- back to a poll every 10
--
-- Read-only towards the sources (RULE 2). The views keep their columns; only the limit's origin changes.
--
-- rollback: re-apply the two views from 20261123171030; DROP TABLE public.primary_poll_config.

CREATE TABLE IF NOT EXISTS public.primary_poll_config (
  id               boolean PRIMARY KEY DEFAULT true CHECK (id),      -- one row
  listing_max_age  interval NOT NULL DEFAULT interval '35 minutes'
                   CHECK (listing_max_age >= interval '1 minute' AND listing_max_age <= interval '6 hours'),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.primary_poll_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.primary_poll_config ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.primary_poll_config FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.primary_poll_config TO service_role;

-- GET /primary/events: every upcoming event of each source's last completed pull, with whether its listings
-- may be sent and, if not, why.
CREATE OR REPLACE VIEW public.v_primary_poll_events_feed
WITH (security_invoker = true) AS
SELECT t.source,
       t.source_event_id AS event_id,
       t.name,
       t.event_date,
       t.start_local_time,
       t.start_utc,
       t.timezone,
       t.venue_name,
       t.venue_city,
       t.venue_state,
       t.ticket_url,
       t.offer_id,
       t.order_min,
       t.order_max,
       t.total_available,
       t.price_min,
       t.price_max,
       t.currency,
       c.fresh AS listings_available,
       CASE WHEN c.fresh THEN t.listing_count END AS listing_count,
       CASE WHEN c.fresh THEN t.poll_ok_at END AS listings_as_of,
       CASE WHEN c.fresh THEN NULL
            WHEN t.poll_status = 'failed' THEN 'poll_failed'
            WHEN t.poll_status = 'pending' THEN 'not_polled'
            ELSE 'poll_stale' END AS listings_withheld,
       t.tevo_event_id,
       t.tevo_match_method,
       CASE WHEN t.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || t.tevo_event_id END AS terminal_path,
       t.poll_attempt_at AS last_poll_at,
       t.first_seen_at,
       t.last_seen_at,
       lower(concat_ws(' ', t.name, t.venue_name, t.venue_city)) AS search_text
  FROM public.primary_poll_event t
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
 CROSS JOIN LATERAL (SELECT (t.poll_status = 'ok' AND t.poll_ok_at > now() - (SELECT c.listing_max_age FROM public.primary_poll_config c)) AS fresh) c
 WHERE t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1;

-- GET /primary/listings: the listings of the events whose last poll succeeded within the age limit, without the
-- obstructed-view ones.
CREATE OR REPLACE VIEW public.v_primary_poll_listings_feed
WITH (security_invoker = true) AS
SELECT l.source,
       l.source_event_id AS event_id,
       t.name AS event_name,
       t.tevo_event_id,
       t.event_date,
       t.start_local_time,
       l.listing_id,
       l.market,
       l.area,
       l.section,
       l.seat_row,
       l.seat_low,
       l.seat_high,
       l.seats,
       l.quantity,
       l.allowed_quantities,
       l.max_per_order,
       t.order_min,
       t.order_max,
       l.price,
       l.fee,
       l.all_in_price,
       l.price_includes_tax,
       t.currency,
       l.ticket_type,
       l.delivery,
       l.ada,
       l.aisle,
       l.general_admission,
       t.poll_ok_at AS as_of
  FROM public.primary_poll_listing l
  JOIN public.primary_poll_event t ON t.source = l.source AND t.source_event_id = l.source_event_id
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
 WHERE t.poll_status = 'ok' AND t.poll_ok_at > now() - (SELECT c.listing_max_age FROM public.primary_poll_config c)
   AND NOT l.obstructed
   AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);

REVOKE ALL ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed TO service_role;

NOTIFY pgrst, 'reload schema';
