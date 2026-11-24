-- Migration 20261124041030 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) + D0 (the feed's views) · writes:primary_poll_config(+no_start_ends_after),primary_poll_ended()(new),primary_poll_due()(replaced),v_primary_poll_events_feed(replaced, same columns),v_primary_poll_listings_feed(replaced, same columns) · reads:primary_poll_event,primary_poll_listing,primary_poll_source · pre:20261123194030
-- Already applied to prod · via MCP 2026-11-24 (operator: "fix the game day wart, end it at tipoff"); re-apply is a no-op.
--
-- THE BOX-OFFICE POLL: AN EVENT IS OVER FOR US WHEN IT STARTS.
-- Operator 2026-11-24: "fix the game day wart, end it at tipoff".
--
-- THE WART. Mig 20261123194030 reads an event every 10 minutes on the day of the event, and counts
-- yesterday's date as that day so an evening game stays covered past midnight UTC. So a game that had
-- been played was still "on its day": the Timberwolves' site kept listing the Nets game of 2026-11-23, its
-- page served no seats any more, and the worker waited 45 seconds for it every 10 minutes.
--
-- NOW. An event that has started is not read again and its listings are not sent:
--   * with a start time (start_utc): from that moment, tip-off;
--   * without one: from no_start_ends_after (32 hours) after 00:00 UTC of its date, which is the end of
--     the evening on the US west coast. (SI Tickets' events get a start time from the client in the same
--     pull request: the stadium's time zone is known.)
--   primary_poll_ended(start_utc, event_date) says which.
--   primary_poll_due() no longer returns a started event the database already knows (an event it has
--   never seen is still read once).
--   Both feeds: a started event has listings_available = false, listings_withheld = 'event_started', and
--   no row in /primary/listings. We do not refresh what we no longer read, so we do not send it.
--   Nothing else changes: the views keep their columns, the ladder and the slots are as they were.
--
-- Read-only towards the sources (RULE 2).
--
-- rollback: re-apply primary_poll_due() and the two views from 20261123194030;
--           DROP FUNCTION public.primary_poll_ended(timestamptz, date);
--           ALTER TABLE public.primary_poll_config DROP COLUMN no_start_ends_after.

ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS no_start_ends_after interval NOT NULL DEFAULT interval '32 hours'
  CHECK (no_start_ends_after >= interval '24 hours');

-- Has the event started? With a start time, at that time. Without one, no_start_ends_after past 00:00 UTC of
-- its date. An event with neither is never over.
CREATE OR REPLACE FUNCTION public.primary_poll_ended(p_start_utc timestamptz, p_event_date date)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN p_start_utc IS NOT NULL THEN p_start_utc <= now()
              WHEN p_event_date IS NOT NULL
                THEN (p_event_date::timestamp AT TIME ZONE 'UTC')
                     + coalesce((SELECT c.no_start_ends_after FROM public.primary_poll_config c), interval '32 hours') <= now()
              ELSE false END
$function$;

-- Of the events a source lists (p_event_ids, a JSON array of ids), the ones to read now: the new ones, and of
-- the ones that have not started, those whose slot has come and those that have moved onto a faster step
-- whose interval has already passed.
CREATE OR REPLACE FUNCTION public.primary_poll_due(p_source text, p_event_ids jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT coalesce(jsonb_agg(x.id ORDER BY x.id), '[]'::jsonb)
    FROM jsonb_array_elements_text(p_event_ids) x(id)
    LEFT JOIN public.primary_poll_event t ON t.source = p_source AND t.source_event_id = x.id
    LEFT JOIN LATERAL (SELECT public.primary_poll_interval(t.event_date, t.median_price, t.listed_quantity) AS every) live ON true
   CROSS JOIN (SELECT c.due_slack FROM public.primary_poll_config c) cfg
   WHERE t.source_event_id IS NULL
      OR (NOT public.primary_poll_ended(t.start_utc, t.event_date)
          AND (t.poll_attempt_at IS NULL OR t.next_poll_at IS NULL OR t.poll_interval IS NULL
               OR t.next_poll_at <= now() + cfg.due_slack
               OR (live.every < t.poll_interval AND t.poll_attempt_at + live.every <= now() + cfg.due_slack)))
$function$;

REVOKE ALL ON FUNCTION public.primary_poll_due(text, jsonb), public.primary_poll_ended(timestamptz, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.primary_poll_due(text, jsonb), public.primary_poll_ended(timestamptz, date) TO service_role;

-- GET /primary/events: every upcoming event of each source's last completed pull, with whether its listings
-- may be sent and, if not, why. A started event's are not (event_started).
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
            WHEN public.primary_poll_ended(t.start_utc, t.event_date) THEN 'event_started'
            WHEN t.poll_status = 'failed' THEN 'poll_failed'
            WHEN t.poll_status = 'pending' THEN 'not_polled'
            ELSE 'poll_stale' END AS listings_withheld,
       t.tevo_event_id,
       t.tevo_match_method,
       CASE WHEN t.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || t.tevo_event_id END AS terminal_path,
       t.poll_attempt_at AS last_poll_at,
       t.first_seen_at,
       t.last_seen_at,
       lower(concat_ws(' ', t.name, t.venue_name, t.venue_city)) AS search_text,
       t.median_price,
       (extract(epoch FROM t.poll_interval) / 60)::integer AS poll_every_minutes,
       t.next_poll_at,
       t.listed_quantity
  FROM public.primary_poll_event t
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
 CROSS JOIN LATERAL (SELECT (t.poll_status = 'ok' AND NOT public.primary_poll_ended(t.start_utc, t.event_date) AND now() < greatest(t.poll_ok_at + (SELECT c.listing_max_age FROM public.primary_poll_config c), t.next_poll_at + (SELECT c.listing_grace FROM public.primary_poll_config c))) AS fresh) c
 WHERE t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1;

-- GET /primary/listings: the listings of the events that have not started and whose last poll succeeded within
-- the age limit, without the obstructed-view ones.
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
       t.poll_ok_at AS as_of,
       l.tax,
       l.order_fee,
       l.price_estimated
  FROM public.primary_poll_listing l
  JOIN public.primary_poll_event t ON t.source = l.source AND t.source_event_id = l.source_event_id
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
 WHERE t.poll_status = 'ok' AND NOT public.primary_poll_ended(t.start_utc, t.event_date) AND now() < greatest(t.poll_ok_at + (SELECT c.listing_max_age FROM public.primary_poll_config c), t.next_poll_at + (SELECT c.listing_grace FROM public.primary_poll_config c))
   AND NOT l.obstructed
   AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);

REVOKE ALL ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed TO service_role;

NOTIFY pgrst, 'reload schema';
