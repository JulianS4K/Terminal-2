-- Migration 20261123192030 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) + D0 (the feed's listings view) · writes:primary_poll_listing(+tax,+order_fee,+price_estimated),primary_poll_ingest()(replaced),v_primary_poll_listings_feed(replaced, three columns added at the end) · reads:primary_poll_event,primary_poll_source,primary_poll_config · pre:20261123190030
--
-- THE BOX-OFFICE FEED: ONE MEANING FOR PRICE, AND FEES AND TAX AS THEIR OWN FIELDS.
-- Operator 2026-11-23: "check if it returns fees and taxes for both", then "derive it, 20% fee holds, build
-- all three".
--
-- WHAT WAS WRONG. `price` was the price before fees and tax for SI Tickets and the all-in total for the
-- Timberwolves, rounded to the dollar: section 201 row Q read 55 where the cart says 42.00 + 8.40 fees + 5.05
-- tax = 55.45. SI Tickets' tax was only inside all_in_price, and its fee field was the listing's own figure
-- (2.68), not the one in the all-in total (2.84).
--
-- NOW, FOR EVERY SOURCE, PER TICKET:  price + fee + tax = all_in_price
--   price            before fees and tax
--   fee              the box office's fee
--   tax              (new)
--   all_in_price     what the buyer pays
--   order_fee        (new) a fee charged once an order, not per ticket: SI Tickets, 0.30
--   price_estimated  (new) true where price, fee and tax were worked out from the all-in total, not read
-- SI Tickets: all read from the page. Timberwolves: the site gives only the all-in total (to the cent for the
-- team's own seats, to the dollar for resale); price, fee and tax are derived from it (fee = 20% of the price,
-- confirmed by the operator; tax = 12.025% of the price, from the operator's cart of 2026-11-23) and
-- price_estimated is true. The arithmetic is in core/primary_poll_browser.py.
--
-- Three nullable columns, the ingest function re-created to store them, and the listings view with the three
-- columns added at its end (a view can only gain columns there). A worker that does not send them yet stores
-- nulls and false. Read-only towards the sources (RULE 2).
--
-- rollback: re-apply primary_poll_ingest() from 20261123171030; DROP VIEW public.v_primary_poll_listings_feed
--           and re-apply it from 20261123190030; ALTER TABLE public.primary_poll_listing DROP COLUMN tax,
--           DROP COLUMN order_fee, DROP COLUMN price_estimated.

ALTER TABLE public.primary_poll_listing ADD COLUMN IF NOT EXISTS tax numeric;
ALTER TABLE public.primary_poll_listing ADD COLUMN IF NOT EXISTS order_fee numeric;
ALTER TABLE public.primary_poll_listing ADD COLUMN IF NOT EXISTS price_estimated boolean NOT NULL DEFAULT false;

-- One batch from the worker: [{id, name, local_date, local_time, start_utc, timezone, venue, city, state, url,
-- offer_id, order_min, order_max, total_available, price_min, price_max, ok, error, listings: [...]}].
-- A listing now also carries tax, order_fee and price_estimated (this migration).
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
          area, ticket_type, delivery, ada, obstructed, aisle, general_admission, tax, order_fee, price_estimated)
      SELECT DISTINCT ON (l->>'id') p_source, v_id, l->>'id', l->>'market', l->>'section', l->>'row', l->>'seat_low',
             l->>'seat_high', CASE WHEN jsonb_typeof(l->'seats') = 'array' THEN l->'seats' END, (l->>'qty')::integer,
             CASE WHEN jsonb_typeof(l->'allowed_quantities') = 'array' THEN l->'allowed_quantities' END,
             (l->>'max_per_order')::integer, (l->>'price')::numeric, (l->>'fee')::numeric, (l->>'all_in')::numeric,
             (l->>'price_includes_tax')::boolean, l->>'area', l->>'ticket_type', l->>'delivery', (l->>'ada')::boolean,
             coalesce((l->>'obstructed')::boolean, false), (l->>'aisle')::boolean, (l->>'ga')::boolean,
             (l->>'tax')::numeric, (l->>'order_fee')::numeric, coalesce((l->>'price_estimated')::boolean, false)
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

REVOKE ALL ON FUNCTION public.primary_poll_ingest(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.primary_poll_ingest(text, jsonb) TO service_role;

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
       t.poll_ok_at AS as_of,
       l.tax,
       l.order_fee,
       l.price_estimated
  FROM public.primary_poll_listing l
  JOIN public.primary_poll_event t ON t.source = l.source AND t.source_event_id = l.source_event_id
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
 WHERE t.poll_status = 'ok' AND t.poll_ok_at > now() - (SELECT c.listing_max_age FROM public.primary_poll_config c)
   AND NOT l.obstructed
   AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);

REVOKE ALL ON public.v_primary_poll_listings_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_primary_poll_listings_feed TO service_role;

NOTIFY pgrst, 'reload schema';
