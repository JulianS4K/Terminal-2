-- Migration 20261124230030 · level:data-collection · lane:A1 (box-office collector) + D0 (the feed's view) · writes:primary_poll_config(+split_over_limit),primary_poll_listing(+order_limit),primary_poll_listing_piece(new),primary_poll_limit()(new),primary_poll_pieces()(new),primary_poll_split_event()(new),primary_poll_ingest()(replaced),v_primary_poll_listings_feed(re-created, same columns: listings over their limit are sent as their pieces) · reads:primary_poll_event,primary_poll_source · pre:20261124041030,20261124203030
-- Already applied to prod · via MCP 2026-11-24 (operator: "when done test what we're pushing out against the new fixes and then apply and merge and send to main"; the view again the same day without the three split columns, operator: "dont add these, split_of, split_part, split_parts, just add a -\"listing number\" as a suffix on the split listing id and call it a day"); re-apply is a no-op.
--
-- A LISTING THAT HOLDS MORE TICKETS THAN ONE ORDER MAY TAKE IS SENT AS SEVERAL LISTINGS.
-- Operator 2026-11-24: "when a listing goes over qty limit make the next set a seperate listing in API to
-- broadcast, for all 3 sources, so if 4 is max and listing is 5, split 5th into a listing of a single. first test
-- that on existing listing data."; then, on the test's findings: "split GA, and 2 is a good rule."; then, while
-- it was being built: "take into account inability to leave single behind, in those cases push out one above
-- limit."; and on the first version, which sent three columns naming the block a piece came from: "dont add
-- these, split_of, split_part, split_parts, just add a -"listing number" as a suffix on the split listing id and
-- call it a day".
--
-- THE LIMIT of a listing (primary_poll_limit): the most one order may take of it.
--   the order cap is the event's own (order_max: the Timberwolves' 6, an AXS event's 4 to 14) or, where the box
--   office gives none (SI Tickets), the listing's own figure;
--   where the listing says which quantities may be bought, the limit is the largest of them within the cap. So a
--   Timberwolves block of 7 that sells 1 to 5 or all 7 (the site will not leave a single seat) has a limit of 5,
--   not 6; and a resale block that sells whole only and is over the cap has none, and is left as it is.
--
-- THE SPLIT (primary_poll_pieces), for a listing over its limit:
--   seats that are numbered are first cut where the numbers break, so every listing sent is seats that sit
--   together (rule 2 of the test: every SI Tickets block over its limit, and a quarter of the AXS ones, were a
--   row's seats with gaps; SI's own limit turned out to be the longest run of adjoining seats in the row). Where
--   a block's seats are all odd or all even, neighbours are 2 apart: the Greek Theatre numbers one side odd and
--   the other even, and 454 of its blocks would otherwise have gone out as single seats. Then
--   each run longer than the limit is cut into sets of the limit, the last set holding what is left: 7 seats
--   with a limit of 4 are a listing of 4 and a listing of 3;
--   no single seat is left behind: a box office will not sell seats that leave one on its own, so where what is
--   left would be one seat it stays with the set before it, which then goes out one over the limit. 9 seats with
--   a limit of 4 are a listing of 4 and a listing of 5; 5 seats with a limit of 4 stay one listing of 5. Such a
--   listing's max_per_order is still the limit. A seat that has no neighbour in the block to begin with (seats
--   1 to 4 and 6) is a listing of one: there is nothing to keep it with;
--   a listing with no usable seat numbers (general admission; a block whose seats are not whole numbers, or not
--   one a ticket) is cut by count alone: 13,014 general admission tickets with a limit of 10 are 1,301 listings
--   of 10 and one of 4. Their pieces carry no seat numbers, and the last may be a single ticket: general
--   admission has no seat to strand.
--
-- WHAT A PIECE CARRIES. listing_id is the box office's id with "-<n>" after it: -1, -2 and so on (stable while
-- the block does not change; no box office's own id held a hyphen when this was written). Nothing else marks a
-- piece: the feed's columns are the ones it had. quantity, seat_low, seat_high and seats are the piece's own;
-- allowed_quantities keeps the listing's quantities that fit the piece; max_per_order is the piece's quantity,
-- or the limit for the piece that is one over it. Price, fee, tax and the rest are the listing's. max_per_order
-- is now filled for every listing whose limit is known (AXS listings carried none), and is never more than the
-- limit.
--
-- WHERE. The pieces are worked out once, when an event's read is stored (primary_poll_split_event, called by
-- primary_poll_ingest), and kept in primary_poll_listing_piece; the feed's view sends them in place of their
-- listing. Working them out in the view at every request was tried first and took 4 to 5 seconds for a page of
-- a whole source at the AXS watch's volume (60,000 listings); from the table it is a plain join.
-- primary_poll_listing keeps the box office's blocks as read, with their limit in order_limit, and so do the
-- history tables (mig 20261124203030) and the event's own listing_count: the tickets add up the same either
-- way. Splitting never costs the feed a read: if it fails for an event, its listings go out unsplit.
-- primary_poll_config.split_over_limit (true): false sends the blocks unsplit again, at once.
--
-- Tested on the live listings before it was written (2026-11-24, read-only, before the no-single rule): 13,068
-- seated listings over their limit became 37,319, every ticket accounted for (SI Tickets 527 -> 1,246;
-- Timberwolves 1,667 -> 4,256; AXS 10,874 -> 31,817). The finished rules were run over the live listings again
-- before the apply, which is where the odd-and-even numbering was found.
--
-- rollback: UPDATE primary_poll_config SET split_over_limit = false (the feed is as before).
--           To remove: re-apply primary_poll_ingest() from 20261124203030 and
--           v_primary_poll_listings_feed from 20261124041030; DROP FUNCTION
--           primary_poll_split_event(text, text), primary_poll_pieces(jsonb, integer, integer),
--           primary_poll_limit(jsonb, integer, integer); DROP TABLE primary_poll_listing_piece;
--           ALTER TABLE primary_poll_listing DROP COLUMN order_limit.

ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS split_over_limit boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.primary_poll_config.split_over_limit IS
  'true: GET /primary/listings sends a listing over its order limit as several listings (mig 20261124230030)';

ALTER TABLE public.primary_poll_listing ADD COLUMN IF NOT EXISTS order_limit integer;
COMMENT ON COLUMN public.primary_poll_listing.order_limit IS
  'the most one order may take of this listing (primary_poll_limit), set when the event''s read is stored; null where none is known';

-- the listings a listing over its limit is sent as; rewritten with the event's listings at every read
CREATE TABLE IF NOT EXISTS public.primary_poll_listing_piece (
  source           text    NOT NULL,
  source_event_id  text    NOT NULL,
  listing_id       text    NOT NULL,
  part             integer NOT NULL,
  parts            integer NOT NULL,
  quantity         integer NOT NULL,
  seats            jsonb,
  seat_low         text,
  seat_high        text,
  PRIMARY KEY (source, source_event_id, listing_id, part),
  FOREIGN KEY (source, source_event_id, listing_id)
    REFERENCES public.primary_poll_listing (source, source_event_id, listing_id) ON DELETE CASCADE
);
ALTER TABLE public.primary_poll_listing_piece ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.primary_poll_listing_piece FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.primary_poll_listing_piece TO service_role;

-- The most one order may take of a listing: the largest quantity it sells within the order cap; the cap itself
-- where the listing names no quantities; null where there is no cap, or nothing it sells fits the cap.
CREATE OR REPLACE FUNCTION public.primary_poll_limit(p_allowed jsonb, p_max_per_order integer, p_order_max integer)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  SELECT CASE
           WHEN jsonb_typeof(p_allowed) = 'array' AND jsonb_array_length(p_allowed) > 0
           THEN (SELECT max(q.v::integer) FROM jsonb_array_elements_text(p_allowed) q(v)
                  WHERE q.v ~ '^[0-9]{1,6}$' AND q.v::integer > 0
                    AND (coalesce(p_order_max, p_max_per_order) IS NULL OR q.v::integer <= coalesce(p_order_max, p_max_per_order)))
           ELSE nullif(greatest(coalesce(p_order_max, p_max_per_order), 0), 0)
         END
$function$;

-- The listings a listing over its limit is sent as. Call it only with p_limit > 0 and p_quantity > p_limit.
-- It can answer one piece (5 seats together, limit 4): the listing is then sent as it is.
CREATE OR REPLACE FUNCTION public.primary_poll_pieces(p_seats jsonb, p_quantity integer, p_limit integer)
 RETURNS TABLE (part integer, parts integer, quantity integer, seats jsonb, seat_low text, seat_high text)
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
AS $function$
  WITH s AS (       -- the seat numbers, where they are whole numbers
    SELECT CASE WHEN t.seat ~ '^[0-9]{1,9}$' THEN t.seat::integer END AS n
      FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_seats) = 'array' THEN p_seats ELSE '[]'::jsonb END) t(seat)),
  ok AS (           -- usable: one a ticket, every one a number, none twice
    SELECT (count(*) = p_quantity AND count(s.n) = p_quantity AND count(DISTINCT s.n) = p_quantity) AS seated FROM s),
  by AS (           -- neighbours are 2 apart where the block's seats are all odd or all even (a theatre that
                    -- numbers one side odd and the other even), else 1 apart
    SELECT CASE WHEN count(DISTINCT s.n % 2) = 1 AND count(*) > 1 THEN 2 ELSE 1 END AS step FROM s, ok WHERE ok.seated),
  run AS (          -- seats that sit together: the numbers without a break
    SELECT min(x.n) AS lo, count(*)::integer AS len
      FROM (SELECT s.n, s.n / by.step - row_number() OVER (ORDER BY s.n) AS g FROM s, ok, by WHERE ok.seated) x
     GROUP BY x.g),
  cut AS (          -- how many sets a run makes: one fewer where the last would be a single seat
    SELECT run.lo, run.len,
           (run.len + p_limit - 1) / p_limit
             - CASE WHEN p_limit > 1 AND run.len > p_limit AND run.len % p_limit = 1 THEN 1 ELSE 0 END AS sets
      FROM run),
  piece AS (        -- every set is the limit; the last holds what is left, which may be one over it
    SELECT (cut.lo + (k - 1) * p_limit * by.step)::bigint AS ord,
           CASE WHEN k = cut.sets THEN cut.len - (k - 1) * p_limit ELSE p_limit END AS size, true AS seated, by.step
      FROM cut, by, generate_series(1, cut.sets) k
    UNION ALL       -- no usable seat numbers: by count alone
    SELECT k::bigint, least(p_limit, p_quantity - (k - 1) * p_limit), false, 1
      FROM ok, generate_series(1, (p_quantity + p_limit - 1) / p_limit) k
     WHERE NOT ok.seated)
  SELECT row_number() OVER (ORDER BY piece.ord)::integer, (count(*) OVER ())::integer, piece.size,
         CASE WHEN piece.seated THEN (SELECT jsonb_agg(v::text ORDER BY v)
                                        FROM generate_series(piece.ord, piece.ord + (piece.size - 1) * piece.step, piece.step) v) END,
         CASE WHEN piece.seated THEN piece.ord::text END,
         CASE WHEN piece.seated THEN (piece.ord + (piece.size - 1) * piece.step)::text END
    FROM piece
   WHERE p_limit > 0
$function$;

-- Sets the limit of every listing of an event and writes the pieces of the ones over it. Called by
-- primary_poll_ingest() when a read is stored; returns the number of pieces.
-- jit is off inside it: the planner prices the pieces function as millions of rows and would compile the
-- statement at every call, half a second for an event of 300 listings against a few milliseconds without.
CREATE OR REPLACE FUNCTION public.primary_poll_split_event(p_source text, p_event_id text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET jit TO 'off'
AS $function$
DECLARE
  v_n integer;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: primary_poll_split_event is service-only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.primary_poll_listing l
     SET order_limit = public.primary_poll_limit(l.allowed_quantities, l.max_per_order, t.order_max)
    FROM public.primary_poll_event t
   WHERE t.source = l.source AND t.source_event_id = l.source_event_id
     AND l.source = p_source AND l.source_event_id = p_event_id;
  DELETE FROM public.primary_poll_listing_piece x WHERE x.source = p_source AND x.source_event_id = p_event_id;
  INSERT INTO public.primary_poll_listing_piece (source, source_event_id, listing_id, part, parts, quantity, seats, seat_low, seat_high)
  SELECT l.source, l.source_event_id, l.listing_id, x.part, x.parts, x.quantity, x.seats, x.seat_low, x.seat_high
    FROM public.primary_poll_listing l
   CROSS JOIN LATERAL public.primary_poll_pieces(l.seats, l.quantity, l.order_limit) x
   WHERE l.source = p_source AND l.source_event_id = p_event_id
     AND NOT l.obstructed AND l.order_limit > 0 AND l.quantity > l.order_limit
     AND x.parts > 1;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.primary_poll_limit(jsonb, integer, integer), public.primary_poll_pieces(jsonb, integer, integer),
  public.primary_poll_split_event(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.primary_poll_limit(jsonb, integer, integer), public.primary_poll_pieces(jsonb, integer, integer),
  public.primary_poll_split_event(text, text) TO service_role;

-- The ingest, as 20261124203030 left it, plus one call: when a good read is stored, its listings are split.
CREATE OR REPLACE FUNCTION public.primary_poll_ingest(p_source text, p_events jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e jsonb; v_id text; v_ok boolean; v_n integer; v_median numeric; v_qty integer; v_every interval;
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
      -- over the listings that are sent: the median of what a buyer pays for a ticket, and the tickets listed.
      -- With the date they set the cadence. No listings is a quantity of 0; listings that carry no quantity
      -- leave it unknown (null), which moves nothing.
      SELECT count(*), round((percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(l.all_in_price, l.price)))::numeric, 2),
             CASE WHEN count(*) = 0 THEN 0 ELSE sum(l.quantity)::integer END
        INTO v_n, v_median, v_qty
        FROM public.primary_poll_listing l
       WHERE l.source = p_source AND l.source_event_id = v_id AND NOT l.obstructed;
      SELECT public.primary_poll_interval(t.event_date, v_median, v_qty) INTO v_every
        FROM public.primary_poll_event t WHERE t.source = p_source AND t.source_event_id = v_id;
      UPDATE public.primary_poll_event t
         SET poll_status = 'ok', poll_ok_at = now(), poll_error = NULL, listing_count = v_n, median_price = v_median,
             listed_quantity = v_qty, poll_interval = v_every,
             next_poll_at = public.primary_poll_next(v_every, t.next_poll_at)
       WHERE t.source = p_source AND t.source_event_id = v_id;
      -- a listing over its order limit gets its pieces, which the feed sends in its place (mig 20261124230030).
      -- Like the history below, it never costs the feed a read: if it fails, the listings go out unsplit.
      BEGIN
        PERFORM public.primary_poll_split_event(p_source, v_id);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'primary_poll_split_event(%, %) failed: %', p_source, v_id, SQLERRM;
      END;
      -- the book as read, its figures and the day's row are kept (mig 20261124203030). The history never costs
      -- the feed a read: if keeping it fails, the read stands and the failure is a warning in the database log.
      BEGIN
        PERFORM public.primary_poll_keep_history(p_source, v_id);
      EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'primary_poll_keep_history(%, %) failed: %', p_source, v_id, SQLERRM;
      END;
      v_ok_n := v_ok_n + 1; v_listings := v_listings + v_n;
    ELSE
      -- a failed poll is tried again at the event's own cadence, in a window no longer than retry_after
      SELECT least(public.primary_poll_interval(t.event_date, t.median_price, t.listed_quantity),
                   (SELECT c.retry_after FROM public.primary_poll_config c)) INTO v_every
        FROM public.primary_poll_event t WHERE t.source = p_source AND t.source_event_id = v_id;
      UPDATE public.primary_poll_event t
         SET poll_status = 'failed', poll_error = left(coalesce(e->>'error', 'poll failed'), 300), listing_count = 0,
             poll_interval = v_every, next_poll_at = public.primary_poll_next(v_every, t.next_poll_at)
       WHERE t.source = p_source AND t.source_event_id = v_id;
      v_failed := v_failed + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('events', v_events, 'ok', v_ok_n, 'failed', v_failed, 'listings', v_listings);
END $function$;

REVOKE ALL ON FUNCTION public.primary_poll_ingest(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.primary_poll_ingest(text, jsonb) TO service_role;

-- GET /primary/listings: as 20261124041030 left it (the listings of the events whose last poll succeeded within the
-- age limit, without the obstructed-view ones), with a listing over its limit sent as its pieces. The same 33
-- columns, in the same order. Dropped first: the first version of this migration added three columns, which a
-- CREATE OR REPLACE cannot take away. Nothing depends on the view.
DROP VIEW IF EXISTS public.v_primary_poll_listings_feed;
CREATE VIEW public.v_primary_poll_listings_feed
WITH (security_invoker = true) AS
SELECT l.source,
       l.source_event_id AS event_id,
       t.name AS event_name,
       t.tevo_event_id,
       t.event_date,
       t.start_local_time,
       CASE WHEN p.part IS NOT NULL THEN l.listing_id || '-' || p.part ELSE l.listing_id END AS listing_id,
       l.market,
       l.area,
       l.section,
       l.seat_row,
       CASE WHEN p.part IS NOT NULL THEN p.seat_low ELSE l.seat_low END AS seat_low,
       CASE WHEN p.part IS NOT NULL THEN p.seat_high ELSE l.seat_high END AS seat_high,
       CASE WHEN p.part IS NOT NULL THEN p.seats ELSE l.seats END AS seats,
       CASE WHEN p.part IS NOT NULL THEN p.quantity ELSE l.quantity END AS quantity,
       CASE WHEN p.part IS NOT NULL AND jsonb_typeof(l.allowed_quantities) = 'array'
            THEN (SELECT jsonb_agg(q.v ORDER BY q.i) FROM jsonb_array_elements(l.allowed_quantities) WITH ORDINALITY q(v, i)
                   WHERE jsonb_typeof(q.v) = 'number' AND (q.v #>> '{}')::numeric <= least(l.order_limit, p.quantity))
            ELSE l.allowed_quantities END AS allowed_quantities,
       CASE WHEN p.part IS NOT NULL THEN least(l.order_limit, p.quantity)
            WHEN l.order_limit IS NOT NULL THEN least(l.order_limit, l.quantity)
            ELSE l.max_per_order END AS max_per_order,
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
  LEFT JOIN public.primary_poll_listing_piece p
         ON p.source = l.source AND p.source_event_id = l.source_event_id AND p.listing_id = l.listing_id
        AND (SELECT c.split_over_limit FROM public.primary_poll_config c)
 WHERE t.poll_status = 'ok' AND NOT public.primary_poll_ended(t.start_utc, t.event_date) AND now() < greatest(t.poll_ok_at + (SELECT c.listing_max_age FROM public.primary_poll_config c), t.next_poll_at + (SELECT c.listing_grace FROM public.primary_poll_config c))
   AND NOT l.obstructed
   AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);

REVOKE ALL ON public.v_primary_poll_listings_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_primary_poll_listings_feed TO service_role;

-- The listings already stored get their limit and their pieces now, so the feed is split from this moment and not
-- from each event's next read.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT DISTINCT l.source, l.source_event_id FROM public.primary_poll_listing l LOOP
    PERFORM public.primary_poll_split_event(r.source, r.source_event_id);
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
