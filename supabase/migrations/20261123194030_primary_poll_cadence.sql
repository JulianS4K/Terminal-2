-- Migration 20261123194030 · level:data-collection · lane:A1 (data plane; routed to this session by the operator) + D0 (the feed's views) · writes:primary_poll_cadence(new),primary_poll_price_band(new),primary_poll_qty_band(new),primary_poll_config(+listing_grace,+due_slack,+retry_after,+max_slowdown_steps),primary_poll_event(+median_price,+listed_quantity,+poll_interval),primary_poll_interval()(new),primary_poll_due()(new),primary_poll_ingest()(replaced),v_primary_poll_events_feed(replaced, four columns added at the end),v_primary_poll_listings_feed(replaced, same columns) · reads:primary_poll_listing,primary_poll_source · pre:20261123192030
--
-- THE BOX-OFFICE POLL: EACH EVENT ON ITS OWN CADENCE, AT A RANDOM SLOT INSIDE IT.
-- Operator 2026-11-23: "create update cadances based on event date and median price"; "Also adjust cadance
-- based on a qty listed"; "Let's set longest interval to 1 hour"; "Add the poll randomizer into the interval, by
-- allocating a set interval by ranking then assign slots within that interval, say 10 mins, ranking being our
-- cadance"; "Redraw every cycle, just poll the data. For events day of draw every 10 mins if ... game is on
-- weekend and up to 5 days away it hits the 2 day cadance"; "Include Friday".
--
-- Until now every event was read at every run (every 30 minutes): a game five months away as often as
-- tonight's. Now each event has its own interval, worked out each time it is polled:
--
--   1. BY DATE (primary_poll_cadence, a ladder, fastest first):
--        the day of the event                                  every 10 minutes
--        up to 2 days away, or a Friday, Saturday or Sunday event
--        up to 5 days away                                     every 30 minutes
--        further                                               every hour (the longest interval)
--      The 10-minute step is for the day of the event only (date_only): price and quantity neither put an
--      event on it nor take one off it. The dates are the database's (UTC), so a US evening game is "the day
--      of" from the evening before, local time, until it is over.
--   2. THEN BY PRICE (primary_poll_price_band): the median of what a buyer pays for a ticket, over the event's
--      listings that are sent, moves it between the other steps:
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
--   The two moves add up, stay between the 30-minute and the one-hour step, and together never slow an event
--   by more than max_slowdown_steps (1). An event with no date starts on the slowest step; one never read
--   successfully has no price and no quantity and keeps its date step.
--   All three tables are plain rows: to change a cadence, change a row. No code and no deploy.
--
-- THE RANDOM SLOT. The interval is the ranking; inside it the read falls on a slot drawn at random.
-- Time is cut into windows as long as the event's interval (an hourly event: 12:00-13:00, 13:00-14:00, ...) and
-- each window into slots of primary_poll_config.slot (10 minutes): 6 slots in an hour, 3 in 30 minutes, 1 in 10.
-- An event is read once a window. When it has been read, a slot of the NEXT window is drawn for it
-- (primary_poll_next(), redrawn every cycle) and stored as next_poll_at. So two reads of an hourly event are
-- between 10 and 110 minutes apart, one hour on average; events on the same cadence no longer arrive together.
--
-- HOW IT RUNS. The workers wake every 10 minutes (PRIMARY_POLL_INTERVAL_SECONDS = 600, one slot) and read each
-- source's list of events, which is one page and finds new events at once. They ask primary_poll_due() which
-- of the listed events are due and read only those. An event is due when it is new, when its slot has come
-- (next_poll_at, less due_slack: a wake a minute early still takes it), or when it has moved onto a faster
-- step and that step's interval has passed since its last read (a game is not kept waiting on its old slot the
-- day it starts being read every 10 minutes). A failed poll is drawn a slot the same way, in a window no
-- longer than retry_after (30 minutes).
--
-- THE FEED'S AGE LIMIT FOLLOWS THE EVENT. Listings leave while the event's last poll was good and its next slot
-- is not more than listing_grace (20 minutes: one wake and one run) behind us; and always for listing_max_age
-- (35 minutes) after a good read, as before. So an hourly game is not withheld between reads, and a poll that
-- does not run is still noticed.
--
-- /primary/events gains, at the end: median_price, poll_every_minutes, next_poll_at, listed_quantity.
-- writes also: primary_poll_cadence(+weekend_days_out_max,+date_only), primary_poll_config(+slot,+weekend_days), primary_poll_event(+next_poll_at), primary_poll_next()(new).
--
-- Read-only towards the sources (RULE 2).
--
-- rollback: re-apply primary_poll_ingest() from 20261123192030 and the two views from 20261123190030 /
--           20261123192030 (after DROP VIEW public.v_primary_poll_events_feed);
--           DROP FUNCTION public.primary_poll_due(text, jsonb); DROP FUNCTION public.primary_poll_interval(date, numeric, integer);
--           DROP FUNCTION public.primary_poll_next(interval, timestamptz);
--           DROP TABLE public.primary_poll_cadence, public.primary_poll_price_band, public.primary_poll_qty_band;
--           ALTER TABLE public.primary_poll_event DROP COLUMN median_price, DROP COLUMN listed_quantity, DROP COLUMN poll_interval,
--           DROP COLUMN next_poll_at;
--           ALTER TABLE public.primary_poll_config DROP COLUMN listing_grace, DROP COLUMN due_slack, DROP COLUMN retry_after,
--           DROP COLUMN max_slowdown_steps, DROP COLUMN slot, DROP COLUMN weekend_days.

CREATE TABLE IF NOT EXISTS public.primary_poll_cadence (
  step          smallint PRIMARY KEY CHECK (step > 0),               -- 1 is the fastest
  poll_every    interval NOT NULL CHECK (poll_every >= interval '5 minutes' AND poll_every <= interval '7 days'),
  days_out_max  integer UNIQUE CHECK (days_out_max >= 0),             -- events up to this many days away start here; NULL: any further
  weekend_days_out_max integer CHECK (weekend_days_out_max >= 0),     -- ... and a weekend event (primary_poll_config.weekend_days) from this many days away; NULL: as days_out_max
  date_only     boolean NOT NULL DEFAULT false                        -- only the date puts an event here; price and quantity never move it on or off
);
INSERT INTO public.primary_poll_cadence (step, poll_every, days_out_max, weekend_days_out_max, date_only) VALUES
  (1, interval '10 minutes', 0, NULL, true), (2, interval '30 minutes', 2, 5, false), (3, interval '1 hour', NULL, NULL, false)
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

ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS listing_grace interval NOT NULL DEFAULT interval '20 minutes';
ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS due_slack     interval NOT NULL DEFAULT interval '1 minute';
ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS retry_after   interval NOT NULL DEFAULT interval '30 minutes';
ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS max_slowdown_steps smallint NOT NULL DEFAULT 1 CHECK (max_slowdown_steps >= 0);
ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS slot          interval NOT NULL DEFAULT interval '10 minutes' CHECK (slot >= interval '1 minute');
-- the days of the week that count as the weekend: 1 Monday ... 5 Friday, 6 Saturday, 7 Sunday (operator: "Include Friday")
ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS weekend_days  smallint[] NOT NULL DEFAULT '{5,6,7}';

ALTER TABLE public.primary_poll_event ADD COLUMN IF NOT EXISTS median_price  numeric;
ALTER TABLE public.primary_poll_event ADD COLUMN IF NOT EXISTS listed_quantity integer;
ALTER TABLE public.primary_poll_event ADD COLUMN IF NOT EXISTS poll_interval interval;
ALTER TABLE public.primary_poll_event ADD COLUMN IF NOT EXISTS next_poll_at  timestamptz;

-- An event's interval: its step on the ladder by its date (a Friday, Saturday or Sunday event may start a step
-- sooner), then moved by its median price and by the tickets listed, between the steps that are not date_only.
-- An event on a date_only step (the day of the event) stays on it.
CREATE OR REPLACE FUNCTION public.primary_poll_interval(p_event_date date, p_median numeric, p_listed integer)
 RETURNS interval
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH ends AS (SELECT coalesce(min(step) FILTER (WHERE NOT date_only), min(step)) AS first, max(step) AS last
                  FROM public.primary_poll_cadence),
  day AS (SELECT greatest(p_event_date - CURRENT_DATE, 0) AS days_out,
                 coalesce(extract(isodow FROM p_event_date)::smallint
                          = ANY (coalesce((SELECT g.weekend_days FROM public.primary_poll_config g), '{5,6,7}')), false) AS weekend),
  by_date AS (
    SELECT CASE WHEN p_event_date IS NULL THEN ends.last
                ELSE coalesce((SELECT min(c.step) FROM public.primary_poll_cadence c
                                WHERE CASE WHEN day.weekend THEN greatest(c.days_out_max, c.weekend_days_out_max)
                                           ELSE c.days_out_max END >= day.days_out), ends.last) END AS step
      FROM ends, day),
  by_price AS (
    SELECT coalesce((SELECT b.step_shift FROM public.primary_poll_price_band b
                      WHERE b.median_min <= p_median ORDER BY b.median_min DESC LIMIT 1), 0) AS shift),
  by_qty AS (
    SELECT coalesce((SELECT b.step_shift FROM public.primary_poll_qty_band b
                      WHERE b.qty_min <= p_listed ORDER BY b.qty_min DESC LIMIT 1), 0) AS shift)
  SELECT c.poll_every
    FROM ends, by_date, by_price, by_qty, public.primary_poll_cadence c
   WHERE c.step = CASE WHEN (SELECT d.date_only FROM public.primary_poll_cadence d WHERE d.step = by_date.step)
                       THEN by_date.step
                       ELSE greatest(ends.first, least(ends.last, by_date.step
                              + least(by_price.shift + by_qty.shift,
                                      coalesce((SELECT g.max_slowdown_steps FROM public.primary_poll_config g), 1)))) END
$function$;

-- When an event is read next: a slot drawn at random in the window after the one it was scheduled in.
-- Windows are p_interval long, counted from the epoch; slots are primary_poll_config.slot long. p_scheduled is
-- the slot the read just made was drawn for: counting from it, not from now, a read that ran a few minutes
-- late does not skip a window. Without one, or with one more than an interval old, the count is from now.
CREATE OR REPLACE FUNCTION public.primary_poll_next(p_interval interval, p_scheduled timestamptz)
 RETURNS timestamptz
 LANGUAGE sql
 VOLATILE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH n AS (SELECT extract(epoch FROM p_interval) AS i,
                    extract(epoch FROM coalesce((SELECT c.slot FROM public.primary_poll_config c), interval '10 minutes')) AS s,
                    extract(epoch FROM CASE WHEN p_scheduled IS NULL OR p_scheduled < now() - p_interval OR p_scheduled > now()
                                            THEN now() ELSE p_scheduled END) AS base)
  SELECT to_timestamp((floor(n.base / n.i) + 1) * n.i + floor(random() * greatest(floor(n.i / n.s), 1)) * n.s)
    FROM n
$function$;

-- Of the events a source lists (p_event_ids, a JSON array of ids), the ones to read now: the new ones, the
-- ones whose slot has come, and the ones that have moved onto a faster step whose interval has already passed.
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
   WHERE t.source_event_id IS NULL OR t.poll_attempt_at IS NULL OR t.next_poll_at IS NULL OR t.poll_interval IS NULL
      OR t.next_poll_at <= now() + cfg.due_slack
      OR (live.every < t.poll_interval AND t.poll_attempt_at + live.every <= now() + cfg.due_slack)
$function$;

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

REVOKE ALL ON FUNCTION public.primary_poll_ingest(text, jsonb), public.primary_poll_due(text, jsonb),
  public.primary_poll_interval(date, numeric, integer), public.primary_poll_next(interval, timestamptz)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.primary_poll_ingest(text, jsonb), public.primary_poll_due(text, jsonb),
  public.primary_poll_interval(date, numeric, integer), public.primary_poll_next(interval, timestamptz)
  TO service_role;

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
       t.next_poll_at,
       t.listed_quantity
  FROM public.primary_poll_event t
  JOIN public.primary_poll_source s ON s.source = t.source AND s.current_run = t.last_run
 CROSS JOIN LATERAL (SELECT (t.poll_status = 'ok' AND now() < greatest(t.poll_ok_at + (SELECT c.listing_max_age FROM public.primary_poll_config c), t.next_poll_at + (SELECT c.listing_grace FROM public.primary_poll_config c))) AS fresh) c
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
 WHERE t.poll_status = 'ok' AND now() < greatest(t.poll_ok_at + (SELECT c.listing_max_age FROM public.primary_poll_config c), t.next_poll_at + (SELECT c.listing_grace FROM public.primary_poll_config c))
   AND NOT l.obstructed
   AND (t.event_date IS NULL OR t.event_date >= CURRENT_DATE - 1);

REVOKE ALL ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_primary_poll_events_feed, public.v_primary_poll_listings_feed TO service_role;

NOTIFY pgrst, 'reload schema';
