-- Migration 20261123194030 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) + D0 (the feed's views) · writes:primary_poll_cadence(new),primary_poll_price_band(new),primary_poll_qty_band(new),primary_poll_config(+listing_grace,+due_slack,+retry_after,+max_slowdown_steps),primary_poll_event(+median_price,+listed_quantity,+poll_interval),primary_poll_interval()(new),primary_poll_due()(new),primary_poll_ingest()(replaced),v_primary_poll_events_feed(replaced, four columns added at the end),v_primary_poll_listings_feed(replaced, same columns) · reads:primary_poll_listing,primary_poll_source · pre:20261123192030
--
-- THE BOX-OFFICE POLL: EACH EVENT ON ITS OWN CADENCE, SET BY ITS DATE, ITS MEDIAN PRICE AND THE TICKETS LISTED.
-- Operator 2026-11-23: "create update cadances based on event date and median price", then "Also adjust
-- cadance based on a qty listed".
--
-- Until now every event was read at every run (every 30 minutes): a game five months away as often as
-- tonight's. Now each event has its own interval, worked out each time it is polled:
--
--   1. BY DATE (primary_poll_cadence, a ladder, fastest first):
--        up to 2 days away   every 30 minutes
--        up to 7 days        every hour
--        up to 30 days       every 3 hours
--        up to 90 days       every 6 hours
--        further             every 12 hours
--   2. THEN BY PRICE (primary_poll_price_band): the median of what a buyer pays for a ticket, over the event's
--      listings that are sent, moves it along the ladder:
--        median 150 or more  one step faster
--        50 to 150           no change
--        under 50            one step slower
--   3. THEN BY QUANTITY (primary_poll_qty_band): the tickets listed, added up over the same listings, move it
--      again:
--        2,000 or more       one step faster   (more on sale: more that changes between reads)
--        250 to 2,000        no change
--        under 250           one step slower   (little or nothing to send)
--      The operator named the input, not the direction: more listed = faster follows the price rule (more at
--      stake, read more often). To turn it round, swap the two step_shift values.
--   The two moves add up, never go past either end of the ladder, and together never slow an event by more
--   than max_slowdown_steps (1): a cheap game tomorrow with few seats left is read every hour, not every three.
--   An event with no date starts on the slowest step; one never read successfully has no price and no quantity and keeps its date step.
--   All three tables are plain rows: to change a cadence, change a row. No code and no deploy.
--
-- HOW IT RUNS. The workers still wake every 30 minutes (PRIMARY_POLL_INTERVAL_SECONDS, the fastest step) and
-- read each source's list of events, which is one page and finds new events at once. They ask
-- primary_poll_due() which of the listed events are due and read only those. An event is due when it is new,
-- or when its last attempt is older than its interval less due_slack (10 minutes: a run takes minutes, so an
-- event read at 0:02 must count as due at the 0:30 run). The interval is taken at the moment of asking too,
-- so an event that has come within a faster step is not kept waiting on its old one.
-- A failed poll is tried again at the event's cadence and no later than retry_after (30 minutes).
--
-- THE FEED'S AGE LIMIT FOLLOWS THE EVENT. Listings leave while the event's last good poll is no older than its
-- own interval plus listing_grace (10 minutes). So a far-off game read every 12 hours is not withheld between
-- reads, and a poll that does not run is still noticed: one grace after it was due. An event not yet given an
-- interval falls back to listing_max_age (35 minutes), as before.
--
-- /primary/events gains, at the end: median_price, poll_every_minutes, next_poll_at, listed_quantity.
--
-- Read-only towards the sources (RULE 2).
--
-- rollback: re-apply primary_poll_ingest() from 20261123192030 and the two views from 20261123190030 /
--           20261123192030 (after DROP VIEW public.v_primary_poll_events_feed);
--           DROP FUNCTION public.primary_poll_due(text, jsonb); DROP FUNCTION public.primary_poll_interval(date, numeric, integer);
--           DROP TABLE public.primary_poll_cadence, public.primary_poll_price_band, public.primary_poll_qty_band;
--           ALTER TABLE public.primary_poll_event DROP COLUMN median_price, DROP COLUMN listed_quantity, DROP COLUMN poll_interval;
--           ALTER TABLE public.primary_poll_config DROP COLUMN listing_grace, DROP COLUMN due_slack, DROP COLUMN retry_after,
--           DROP COLUMN max_slowdown_steps.

CREATE TABLE IF NOT EXISTS public.primary_poll_cadence (
  step          smallint PRIMARY KEY CHECK (step > 0),               -- 1 is the fastest
  poll_every    interval NOT NULL CHECK (poll_every >= interval '5 minutes' AND poll_every <= interval '7 days'),
  days_out_max  integer UNIQUE CHECK (days_out_max >= 0)              -- events up to this many days away start here; NULL: any further
);
INSERT INTO public.primary_poll_cadence (step, poll_every, days_out_max) VALUES
  (1, interval '30 minutes', 2), (2, interval '1 hour', 7), (3, interval '3 hours', 30),
  (4, interval '6 hours', 90), (5, interval '12 hours', NULL)
ON CONFLICT (step) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.primary_poll_price_band (
  median_min  numeric PRIMARY KEY CHECK (median_min >= 0),            -- the band holds medians from here up to the next band
  step_shift  smallint NOT NULL CHECK (step_shift BETWEEN -3 AND 3)   -- negative: faster
);
INSERT INTO public.primary_poll_price_band (median_min, step_shift) VALUES (0, 1), (50, 0), (150, -1)
ON CONFLICT (median_min) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.primary_poll_qty_band (
  qty_min     integer PRIMARY KEY CHECK (qty_min >= 0),               -- the band holds quantities from here up to the next band
  step_shift  smallint NOT NULL CHECK (step_shift BETWEEN -3 AND 3)   -- negative: faster
);
INSERT INTO public.primary_poll_qty_band (qty_min, step_shift) VALUES (0, 1), (250, 0), (2000, -1)
ON CONFLICT (qty_min) DO NOTHING;

ALTER TABLE public.primary_poll_cadence    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.primary_poll_price_band ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.primary_poll_qty_band   ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.primary_poll_cadence, public.primary_poll_price_band, public.primary_poll_qty_band FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.primary_poll_cadence, public.primary_poll_price_band, public.primary_poll_qty_band TO service_role;

ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS listing_grace interval NOT NULL DEFAULT interval '10 minutes';
ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS due_slack     interval NOT NULL DEFAULT interval '10 minutes';
ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS retry_after   interval NOT NULL DEFAULT interval '30 minutes';
ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS max_slowdown_steps smallint NOT NULL DEFAULT 1 CHECK (max_slowdown_steps >= 0);

ALTER TABLE public.primary_poll_event ADD COLUMN IF NOT EXISTS median_price  numeric;
ALTER TABLE public.primary_poll_event ADD COLUMN IF NOT EXISTS listed_quantity integer;
ALTER TABLE public.primary_poll_event ADD COLUMN IF NOT EXISTS poll_interval interval;

-- An event's interval: its step on the ladder by its date, moved by its median price and by the tickets
-- listed, kept on the ladder.
CREATE OR REPLACE FUNCTION public.primary_poll_interval(p_event_date date, p_median numeric, p_listed integer)
 RETURNS interval
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH ends AS (SELECT min(step) AS first, max(step) AS last FROM public.primary_poll_cadence),
  by_date AS (
    SELECT CASE WHEN p_event_date IS NULL THEN ends.last
                ELSE coalesce((SELECT min(c.step) FROM public.primary_poll_cadence c
                                WHERE c.days_out_max >= greatest(p_event_date - CURRENT_DATE, 0)), ends.last) END AS step
      FROM ends),
  by_price AS (
    SELECT coalesce((SELECT b.step_shift FROM public.primary_poll_price_band b
                      WHERE b.median_min <= p_median ORDER BY b.median_min DESC LIMIT 1), 0) AS shift),
  by_qty AS (
    SELECT coalesce((SELECT b.step_shift FROM public.primary_poll_qty_band b
                      WHERE b.qty_min <= p_listed ORDER BY b.qty_min DESC LIMIT 1), 0) AS shift)
  SELECT c.poll_every
    FROM ends, by_date, by_price, by_qty, public.primary_poll_cadence c
   WHERE c.step = greatest(ends.first, least(ends.last, by_date.step
           + least(by_price.shift + by_qty.shift, coalesce((SELECT g.max_slowdown_steps FROM public.primary_poll_config g), 1))))
$function$;

-- Of the events a source lists (p_event_ids, a JSON array of ids), the ones to read now.
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
   WHERE t.source_event_id IS NULL OR t.poll_attempt_at IS NULL OR t.poll_interval IS NULL
      OR t.poll_attempt_at <= now() - least(t.poll_interval, public.primary_poll_interval(t.event_date, t.median_price, t.listed_quantity))
                                    + (SELECT c.due_slack FROM public.primary_poll_config c)
$function$;

CREATE OR REPLACE FUNCTION public.primary_poll_ingest(p_source text, p_events jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  e jsonb; v_id text; v_ok boolean; v_n integer; v_median numeric; v_qty integer;
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
      UPDATE public.primary_poll_event t
         SET poll_status = 'ok', poll_ok_at = now(), poll_error = NULL, listing_count = v_n, median_price = v_median,
             listed_quantity = v_qty, poll_interval = public.primary_poll_interval(t.event_date, v_median, v_qty)
       WHERE t.source = p_source AND t.source_event_id = v_id;
      v_ok_n := v_ok_n + 1; v_listings := v_listings + v_n;
    ELSE
      -- a failed poll is tried again at the event's own cadence, and no later than retry_after
      UPDATE public.primary_poll_event t
         SET poll_status = 'failed', poll_error = left(coalesce(e->>'error', 'poll failed'), 300), listing_count = 0,
             poll_interval = least(public.primary_poll_interval(t.event_date, t.median_price, t.listed_quantity),
                                   (SELECT c.retry_after FROM public.primary_poll_config c))
       WHERE t.source = p_source AND t.source_event_id = v_id;
      v_failed := v_failed + 1;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('events', v_events, 'ok', v_ok_n, 'failed', v_failed, 'listings', v_listings);
END $function$;

REVOKE ALL ON FUNCTION public.primary_poll_ingest(text, jsonb), public.primary_poll_due(text, jsonb),
  public.primary_poll_interval(date, numeric, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.primary_poll_ingest(text, jsonb), public.primary_poll_due(text, jsonb),
  public.primary_poll_interval(date, numeric, integer) TO service_role;

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
       lower(concat_ws(' ', t.name, t.venue_name, t.venue_city)) AS search_text,
       t.median_price,
       (extract(epoch FROM t.poll_interval) / 60)::integer AS poll_every_minutes,
       t.poll_attempt_at + t.poll_interval AS next_poll_at,
       t.listed_quantity
  FROM public.primary_poll_event t
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
 CROSS JOIN LATERAL (SELECT (t.poll_status = 'ok' AND t.poll_ok_at > now() - coalesce(t.poll_interval + (SELECT c.listing_grace FROM public.primary_poll_config c), (SELECT c.listing_max_age FROM public.primary_poll_config c))) AS fresh) c
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
       t.poll_ok_at AS as_of,
       l.tax,
       l.order_fee,
       l.price_estimated
  FROM public.primary_poll_listing l
  JOIN public.primary_poll_event t ON t.source = l.source AND t.source_event_id = l.source_event_id
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
 WHERE t.poll_status = 'ok' AND t.poll_ok_at > now() - coalesce(t.poll_interval + (SELECT c.listing_grace FROM public.primary_poll_config c), (SELECT c.listing_max_age FROM public.primary_poll_config c))
   AND NOT l.obstructed
   AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);

REVOKE ALL ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed TO service_role;

NOTIFY pgrst, 'reload schema';
