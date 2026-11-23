-- Migration 20261123171030 · level:data-collection · lane:D0 (outbound feed in the sub finder API) + A1 (data plane; routed to this session by the operator) · writes:primary_poll_event(new),primary_poll_listing(new),primary_poll_source(new),primary_poll_ingest()(new),primary_poll_source_failed()(new),primary_poll_run_done()(new),v_primary_poll_events_feed(new),v_primary_poll_listings_feed(new) · reads:none · pre:none
--
-- PRIMARY BOX OFFICES WE POLL OURSELVES: EVENTS AND THEIR LISTINGS, AS AN OUTBOUND FEED.
-- Operator 2026-11-23: "look at the n2s api out, we're gonna push the list of events and their respective
-- listings out, if poller fails to run for an event, do not send listing information. build it", then
-- "also dont send obstructed out", "for the api only push out newest pull".
--
-- Two sources to start with, both read by a worker in the web service every 10 minutes
-- (core/primary_poll_sync.py, off unless PRIMARY_POLL_LIVE=1):
--   sitickets     SI Tickets' own box office at Sports Illustrated Stadium (sitickets_client.py)
--   timberwolves  the Minnesota Timberwolves' own ticket site (jump_client.py)
--
-- WHAT IS STORED.
--   primary_poll_event    one row per event the source lists, with the state of its last poll
--   primary_poll_listing  the event's listings as of its last successful poll: section, row, seats, quantity,
--                         the quantities a buyer may take, the order limit, price
--
-- THE RULE THE FEED KEEPS. Listings leave only for an event whose last poll succeeded and is no older than
-- 15 minutes (one 10-minute cycle plus its run time). So:
--   - a poll that fails deletes that event's listings and marks the event 'failed' (primary_poll_ingest);
--   - a source whose event list cannot be read marks every upcoming event of that source 'failed'
--     (primary_poll_source_failed);
--   - a worker that stops altogether marks nothing, and the age limit withholds every listing by itself.
--   The event stays in the events feed either way, with listings_available = false and the reason.
--   A listing the source flags as an obstructed view is stored and never sent.
--
-- ONLY THE NEWEST PULL LEAVES. An event's listings are replaced on every successful poll, so no older listing
-- is kept. The events feed holds the events of the source's last completed pull only: when a run has gone
-- through the source's list, primary_poll_run_done() stamps the events it listed and makes that run the
-- source's current one (primary_poll_source); an event the source no longer lists drops out of both feeds.
-- While a run is under way the feeds keep serving the previous one.
--
-- THE EVO EVENT. primary_poll_event carries tevo_event_id / tevo_match_method / tevo_matched_at for the event
-- mapper to fill (the mapping program's own function, not written here); the poll never touches them, and both
-- feeds return tevo_event_id. Null until the mapper has matched the event.
--
-- Read-only: nothing here calls a source (RULE 2). The two clients are GET only.
-- No prod data is changed: two new tables, two functions, two views.
--
-- rollback: DROP VIEW public.v_primary_poll_listings_feed; DROP VIEW public.v_primary_poll_events_feed;
--           DROP FUNCTION public.primary_poll_ingest(text, jsonb); DROP FUNCTION public.primary_poll_source_failed(text, text);
--           DROP FUNCTION public.primary_poll_run_done(text, text, jsonb);
--           DROP TABLE public.primary_poll_listing; DROP TABLE public.primary_poll_event; DROP TABLE public.primary_poll_source;
--           unset PRIMARY_POLL_LIVE on the web service.

CREATE TABLE IF NOT EXISTS public.primary_poll_event (
  source            text NOT NULL,
  source_event_id   text NOT NULL,
  name              text NOT NULL,
  event_date        date,
  start_local_time  time,
  start_utc         timestamptz,
  timezone          text,
  venue_name        text,
  venue_city        text,
  venue_state       text,
  ticket_url        text,
  offer_id          text,
  order_min         integer,
  order_max         integer,
  total_available   integer,
  price_min         numeric,
  price_max         numeric,
  currency          text NOT NULL DEFAULT 'USD',
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  poll_status       text NOT NULL DEFAULT 'pending' CHECK (poll_status IN ('pending', 'ok', 'failed')),
  poll_attempt_at   timestamptz,
  poll_ok_at        timestamptz,
  poll_error        text,
  listing_count     integer NOT NULL DEFAULT 0,
  last_run          text,                  -- the last completed pull that listed this event
  -- the EVO event, written by the event mapper only (asked by the mapping owner, bot_chat 7245): fill-only,
  -- as vivid_catalog_event / tickpick_catalog_event / tm_discovery_event carry theirs. The poll never sets them.
  tevo_event_id     bigint,
  tevo_match_method text,
  tevo_matched_at   timestamptz,
  PRIMARY KEY (source, source_event_id)
);

-- one row per source: its last completed pull. The feeds serve the events stamped with it.
CREATE TABLE IF NOT EXISTS public.primary_poll_source (
  source       text PRIMARY KEY,
  current_run  text NOT NULL,
  finished_at  timestamptz NOT NULL DEFAULT now(),
  events       integer NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS primary_poll_event_date_idx ON public.primary_poll_event (event_date);

CREATE TABLE IF NOT EXISTS public.primary_poll_listing (
  source              text NOT NULL,
  source_event_id     text NOT NULL,
  listing_id          text NOT NULL,
  market              text,                -- 'primary' (the box office's own seats) or 'resale' (resold on the same site)
  section             text,
  seat_row            text,
  seat_low            text,
  seat_high           text,
  seats               jsonb,               -- every seat number, where the source gives them
  quantity            integer,
  allowed_quantities  jsonb,               -- the quantities a buyer may take from this listing
  max_per_order       integer,
  price               numeric,
  fee                 numeric,
  all_in_price        numeric,
  price_includes_tax  boolean,
  area                text,
  ticket_type         text,
  delivery            text,
  ada                 boolean,
  obstructed          boolean NOT NULL DEFAULT false,
  aisle               boolean,
  general_admission   boolean,
  polled_at           timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (source, source_event_id, listing_id),
  FOREIGN KEY (source, source_event_id) REFERENCES public.primary_poll_event (source, source_event_id) ON DELETE CASCADE
);

ALTER TABLE public.primary_poll_event   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.primary_poll_listing ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.primary_poll_source  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.primary_poll_event, public.primary_poll_listing, public.primary_poll_source FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.primary_poll_event, public.primary_poll_listing, public.primary_poll_source TO service_role;

-- One batch from the worker: [{id, name, local_date, local_time, start_utc, timezone, venue, city, state, url,
-- offer_id, order_min, order_max, total_available, price_min, price_max, ok, error, listings: [...]}].
-- ok = true replaces the event's listings with the ones sent; ok = false deletes them, so a failed poll leaves
-- nothing that could be sent. Returns what it wrote.
CREATE OR REPLACE FUNCTION public.primary_poll_ingest(p_source text, p_events jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e jsonb; v_id text; v_ok boolean; v_n integer;
  v_events integer := 0; v_ok_n integer := 0; v_failed integer := 0; v_listings integer := 0;
BEGIN
  IF coalesce(p_source, '') = '' OR jsonb_typeof(p_events) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'primary_poll_ingest: a source and an array of events are required';
  END IF;
  FOR e IN SELECT x FROM jsonb_array_elements(p_events) x LOOP
    v_id := e->>'id';
    CONTINUE WHEN coalesce(v_id, '') = '' OR coalesce(e->>'name', '') = '';
    v_ok := coalesce((e->>'ok')::boolean, false);
    INSERT INTO public.primary_poll_event AS t (source, source_event_id, name, event_date, start_local_time, start_utc,
        timezone, venue_name, venue_city, venue_state, ticket_url, offer_id, order_min, order_max, total_available,
        price_min, price_max, poll_attempt_at)
    VALUES (p_source, v_id, e->>'name',
        CASE WHEN e->>'local_date' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN (e->>'local_date')::date END,
        CASE WHEN e->>'local_time' ~ '^[0-9]{2}:[0-9]{2}' THEN (e->>'local_time')::time END,
        nullif(e->>'start_utc', '')::timestamptz, e->>'timezone', e->>'venue', e->>'city', e->>'state', e->>'url',
        e->>'offer_id', (e->>'order_min')::integer, (e->>'order_max')::integer, (e->>'total_available')::integer,
        (e->>'price_min')::numeric, (e->>'price_max')::numeric, now())
    ON CONFLICT (source, source_event_id) DO UPDATE SET
        name = EXCLUDED.name, event_date = EXCLUDED.event_date, start_local_time = EXCLUDED.start_local_time,
        start_utc = EXCLUDED.start_utc, timezone = EXCLUDED.timezone, venue_name = EXCLUDED.venue_name,
        venue_city = EXCLUDED.venue_city, venue_state = EXCLUDED.venue_state, ticket_url = EXCLUDED.ticket_url,
        offer_id = EXCLUDED.offer_id, order_min = EXCLUDED.order_min, order_max = EXCLUDED.order_max,
        total_available = EXCLUDED.total_available, price_min = EXCLUDED.price_min, price_max = EXCLUDED.price_max,
        last_seen_at = now(), poll_attempt_at = now();
    DELETE FROM public.primary_poll_listing l WHERE l.source = p_source AND l.source_event_id = v_id;
    v_events := v_events + 1;
    IF v_ok THEN
      INSERT INTO public.primary_poll_listing (source, source_event_id, listing_id, market, section, seat_row, seat_low,
          seat_high, seats, quantity, allowed_quantities, max_per_order, price, fee, all_in_price, price_includes_tax,
          area, ticket_type, delivery, ada, obstructed, aisle, general_admission)
      SELECT DISTINCT ON (l->>'id') p_source, v_id, l->>'id', l->>'market', l->>'section', l->>'row', l->>'seat_low',
             l->>'seat_high', CASE WHEN jsonb_typeof(l->'seats') = 'array' THEN l->'seats' END, (l->>'qty')::integer,
             CASE WHEN jsonb_typeof(l->'allowed_quantities') = 'array' THEN l->'allowed_quantities' END,
             (l->>'max_per_order')::integer, (l->>'price')::numeric, (l->>'fee')::numeric, (l->>'all_in')::numeric,
             (l->>'price_includes_tax')::boolean, l->>'area', l->>'ticket_type', l->>'delivery', (l->>'ada')::boolean,
             coalesce((l->>'obstructed')::boolean, false), (l->>'aisle')::boolean, (l->>'ga')::boolean
        FROM jsonb_array_elements(coalesce(e->'listings', '[]'::jsonb)) l
       WHERE coalesce(l->>'id', '') <> ''
       ORDER BY l->>'id';
      SELECT count(*) INTO v_n FROM public.primary_poll_listing l
       WHERE l.source = p_source AND l.source_event_id = v_id AND NOT l.obstructed;
      UPDATE public.primary_poll_event t SET poll_status = 'ok', poll_ok_at = now(), poll_error = NULL, listing_count = v_n
       WHERE t.source = p_source AND t.source_event_id = v_id;
      v_ok_n := v_ok_n + 1; v_listings := v_listings + v_n;
    ELSE
      UPDATE public.primary_poll_event t
         SET poll_status = 'failed', poll_error = left(coalesce(e->>'error', 'poll failed'), 300), listing_count = 0
       WHERE t.source = p_source AND t.source_event_id = v_id;
      v_failed := v_failed + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('events', v_events, 'ok', v_ok_n, 'failed', v_failed, 'listings', v_listings);
END $function$;

-- The source's event list could not be read, so no event of it was polled this cycle: every upcoming event of
-- the source is marked failed and its listings are deleted.
CREATE OR REPLACE FUNCTION public.primary_poll_source_failed(p_source text, p_error text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  DELETE FROM public.primary_poll_listing l WHERE l.source = p_source;
  UPDATE public.primary_poll_event t
     SET poll_status = 'failed', poll_error = left(coalesce(p_error, 'the event list could not be read'), 300),
         poll_attempt_at = now(), listing_count = 0
   WHERE t.source = p_source AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

-- A run went through the source's whole list: the events it listed (p_event_ids, a JSON array of ids) are
-- stamped with the run and the run becomes the source's current one. From here the feeds serve these events
-- only. An empty list is a valid pull: the source lists nothing, and the feeds then hold nothing for it.
CREATE OR REPLACE FUNCTION public.primary_poll_run_done(p_source text, p_run text, p_event_ids jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  IF coalesce(p_source, '') = '' OR coalesce(p_run, '') = '' OR jsonb_typeof(p_event_ids) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'primary_poll_run_done: a source, a run and an array of event ids are required';
  END IF;
  UPDATE public.primary_poll_event t SET last_run = p_run
   WHERE t.source = p_source
     AND t.source_event_id IN (SELECT jsonb_array_elements_text(p_event_ids));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  INSERT INTO public.primary_poll_source AS s (source, current_run, finished_at, events)
  VALUES (p_source, p_run, now(), v_n)
  ON CONFLICT (source) DO UPDATE SET current_run = EXCLUDED.current_run, finished_at = now(), events = EXCLUDED.events;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.primary_poll_ingest(text, jsonb), public.primary_poll_source_failed(text, text),
  public.primary_poll_run_done(text, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.primary_poll_ingest(text, jsonb), public.primary_poll_source_failed(text, text),
  public.primary_poll_run_done(text, text, jsonb) TO service_role;

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
 CROSS JOIN LATERAL (SELECT (t.poll_status = 'ok' AND t.poll_ok_at > now() - interval '15 minutes') AS fresh) c
 WHERE t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1;

-- GET /primary/listings: the listings of the events whose last poll succeeded within 15 minutes, without the
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
 WHERE t.poll_status = 'ok' AND t.poll_ok_at > now() - interval '15 minutes'
   AND NOT l.obstructed
   AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);

REVOKE ALL ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed TO service_role;

NOTIFY pgrst, 'reload schema';
