-- Migration 20261124203030 · level:data-collection · lane:A1 · writes:primary_poll_listings_snapshots(new),primary_poll_event_metrics(new),primary_poll_section_metrics(new),primary_poll_event_daily(new),primary_poll_config(+keep_history,+history_skip_listings),primary_poll_keep_history()(new),primary_poll_ingest()(replaced),retention_policy(+3 rows) · reads:primary_poll_listing,primary_poll_event · pre:20261123194030,20260705153000
-- Already applied to prod · via MCP 2026-11-24 (operator: "apply"); re-apply is a no-op.
--
-- THE BOX-OFFICE POLL KEEPS ITS HISTORY, ON THE SAME LADDER AS EVO AND GOTICKETS.
-- Operator 2026-11-24: "Look at the retention systems of both Evo and gotickets and copy".
--
-- Until now the poll kept the newest pull only: each read replaced an event's listings and nothing older
-- survived. EVO and GoTickets keep theirs on a ladder (RESOURCES_BIBLE 2.14), swept by one engine
-- (retention_policy + retention_tick(), hourly):
--   raw listings   listings_snapshots / gotickets_listings_snapshots          15 days
--   per capture    event_metrics 120 days, section_metrics 60 days            (EVO, computed at ingest)
--   per day        event_listing_snapshot_daily, venue_section_price_daily    forever
-- This migration is that ladder for the box offices we read ourselves:
--   primary_poll_listings_snapshots   every listing of every good read                        15 days
--   primary_poll_event_metrics        one row an event a read: tickets, listings, prices     120 days
--   primary_poll_section_metrics      one row a section and market an event a read            60 days
--   primary_poll_event_daily          one row an event a UTC day: its last read of the day    forever
--
-- WHICH OF THE TWO RAW SHAPES. EVO's raw table is change-only (a ticket group is written when new, changed or
-- an hour old) and has to be read through a helper; GoTickets' holds the whole book at every capture, so the
-- rows of one captured_at ARE the book (PROJECT_BIBLE, the listings_snapshots row). The box offices are read
-- every 30 or 60 minutes, where change-only would save little, so this follows GoTickets: the whole book at
-- every good read. A read that found nothing on sale writes no listing rows and a metrics row of zero, so,
-- unlike GoTickets, an empty book is on record. A failed read writes nothing.
-- Keeping the history never costs the feed a read: if it fails, the read is stored all the same and the
-- failure is a warning in the database log.
--
-- SIZE. 2026-11-24, SI Tickets and the Timberwolves: 15,738 listings over 39 events, read 24 to 48 times a day:
-- about 590,000 listing rows a day, 9 million at the 15-day limit; their metrics are about 1,400 and 50,000 rows
-- a day. The AXS watch (mig 20261124190000, live the same evening: 200 events read through this same ingest)
-- adds more than both: its first 27 events on sale carried 10,285 listings, so with some 120 of the 200 on
-- sale it is about 1.2 million listing rows a day, 18 million at the limit. Together about 27 million rows:
-- small beside gotickets_listings_snapshots (316 million), but the operator's call; hence the second switch.
--
-- The figures are over the listings the feed sends (obstructed-view ones are counted apart), with a ticket
-- priced at what the buyer pays (all_in_price, or price where a source gives no total): the same basis as
-- primary_poll_event.median_price, which price_median equals.
--
-- SWITCHES. primary_poll_config.keep_history (true): false stops all the writing. history_skip_listings
-- (empty): the sources named there keep their figures (per read, per section, per day) and not their raw
-- listings: UPDATE primary_poll_config SET history_skip_listings = '{axs}' takes the AXS watch's 1.2 million
-- rows a day out and keeps its history of counts and prices. The three policy rows' `enabled` is the sweep's
-- own switch, as for every table in retention_policy. No cron is added or changed.
--
-- rollback: re-apply primary_poll_ingest() from 20261123194030; DELETE the three retention_policy rows;
--           DROP FUNCTION primary_poll_keep_history(text, text); DROP the four tables;
--           ALTER TABLE primary_poll_config DROP COLUMN keep_history.

ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS keep_history boolean NOT NULL DEFAULT true;
COMMENT ON COLUMN public.primary_poll_config.keep_history IS
  'true: every good read is copied to primary_poll_listings_snapshots and its figures to the metrics tables (mig 20261124203030)';
ALTER TABLE public.primary_poll_config ADD COLUMN IF NOT EXISTS history_skip_listings text[] NOT NULL DEFAULT '{}';
COMMENT ON COLUMN public.primary_poll_config.history_skip_listings IS
  'sources whose raw listings are not copied to primary_poll_listings_snapshots; their figures are still kept (mig 20261124203030)';

-- the whole book at every good read: the rows of one (source, source_event_id, captured_at) are that book
CREATE TABLE IF NOT EXISTS public.primary_poll_listings_snapshots (
  source            text        NOT NULL,
  source_event_id   text        NOT NULL,
  captured_at       timestamptz NOT NULL,
  listing_id        text        NOT NULL,
  tevo_event_id     bigint,                -- the EVO event the box-office event was matched to at that read
  market            text,
  area              text,
  section           text,
  seat_row          text,
  seat_low          text,
  seat_high         text,
  seats             jsonb,
  quantity          integer,
  max_per_order     integer,
  price             numeric,
  fee               numeric,
  tax               numeric,
  all_in_price      numeric,
  order_fee         numeric,
  price_estimated   boolean,
  ticket_type       text,
  general_admission boolean,
  obstructed        boolean,
  ada               boolean,
  PRIMARY KEY (source, source_event_id, captured_at, listing_id)
);
CREATE INDEX IF NOT EXISTS primary_poll_ls_captured_idx ON public.primary_poll_listings_snapshots (captured_at);
CREATE INDEX IF NOT EXISTS primary_poll_ls_tevo_idx ON public.primary_poll_listings_snapshots (tevo_event_id, captured_at DESC)
  WHERE tevo_event_id IS NOT NULL;

-- one row an event a good read, over the listings the feed sends
CREATE TABLE IF NOT EXISTS public.primary_poll_event_metrics (
  source             text        NOT NULL,
  source_event_id    text        NOT NULL,
  captured_at        timestamptz NOT NULL,
  tevo_event_id      bigint,
  tickets_count      integer,              -- tickets listed; null where the listings carry no quantity
  groups_count       integer     NOT NULL, -- listings
  sections_count     integer     NOT NULL,
  median_group_size  numeric,
  price_min          numeric,              -- what the buyer pays a ticket: all-in where known
  price_p25          numeric,
  price_median       numeric,
  price_mean         numeric,
  price_p75          numeric,
  price_p90          numeric,
  price_max          numeric,
  base_median        numeric,              -- the median price before fees and tax
  primary_groups     integer     NOT NULL, -- the box office's own seats
  primary_tickets    integer,
  primary_median     numeric,
  resale_groups      integer     NOT NULL, -- seats resold on the same site
  resale_tickets     integer,
  resale_median      numeric,
  ga_tickets         integer,              -- tickets in general admission blocks
  obstructed_groups  integer     NOT NULL, -- obstructed-view listings: never sent, and in no figure above
  obstructed_tickets integer,
  PRIMARY KEY (source, source_event_id, captured_at)
);
CREATE INDEX IF NOT EXISTS primary_poll_em_captured_idx ON public.primary_poll_event_metrics (captured_at);

-- one row a section and market an event a good read ('' where a listing names none)
CREATE TABLE IF NOT EXISTS public.primary_poll_section_metrics (
  source           text        NOT NULL,
  source_event_id  text        NOT NULL,
  captured_at      timestamptz NOT NULL,
  section          text        NOT NULL,
  market           text        NOT NULL,
  tickets_count    integer,
  groups_count     integer     NOT NULL,
  price_min        numeric,
  price_median     numeric,
  price_mean       numeric,
  price_max        numeric,
  PRIMARY KEY (source, source_event_id, captured_at, section, market)
);
CREATE INDEX IF NOT EXISTS primary_poll_sm_captured_idx ON public.primary_poll_section_metrics (captured_at);

-- one row an event a UTC day: the day's last good read, and the range of tickets seen that day. Kept forever.
CREATE TABLE IF NOT EXISTS public.primary_poll_event_daily (
  source           text        NOT NULL,
  source_event_id  text        NOT NULL,
  day              date        NOT NULL,
  captured_at      timestamptz NOT NULL,   -- the read the figures are from
  captures         integer     NOT NULL DEFAULT 1,
  tevo_event_id    bigint,
  tickets_count    integer,
  tickets_low      integer,                -- the fewest and the most tickets of any read that day
  tickets_high     integer,
  groups_count     integer     NOT NULL,
  sections_count   integer     NOT NULL,
  price_min        numeric,
  price_median     numeric,
  price_max        numeric,
  primary_tickets  integer,
  resale_tickets   integer,
  ga_tickets       integer,
  PRIMARY KEY (source, source_event_id, day)
);

ALTER TABLE public.primary_poll_listings_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.primary_poll_event_metrics      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.primary_poll_section_metrics    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.primary_poll_event_daily        ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.primary_poll_listings_snapshots, public.primary_poll_event_metrics,
  public.primary_poll_section_metrics, public.primary_poll_event_daily FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.primary_poll_listings_snapshots, public.primary_poll_event_metrics,
  public.primary_poll_section_metrics, public.primary_poll_event_daily TO service_role;

-- Copies an event's stored listings (just read) to the history tables. Called by primary_poll_ingest().
CREATE OR REPLACE FUNCTION public.primary_poll_keep_history(p_source text, p_event_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_at   timestamptz := now();             -- the read's own time: primary_poll_event.poll_ok_at
  v_tevo bigint;
  v_skip text[];
  m      public.primary_poll_event_metrics%ROWTYPE;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: primary_poll_keep_history is service-only' USING ERRCODE = '42501';
  END IF;
  IF NOT coalesce((SELECT c.keep_history FROM public.primary_poll_config c), false) THEN
    RETURN;
  END IF;
  SELECT c.history_skip_listings INTO v_skip FROM public.primary_poll_config c;
  SELECT t.tevo_event_id INTO v_tevo
    FROM public.primary_poll_event t WHERE t.source = p_source AND t.source_event_id = p_event_id;

  INSERT INTO public.primary_poll_listings_snapshots (source, source_event_id, captured_at, listing_id, tevo_event_id,
      market, area, section, seat_row, seat_low, seat_high, seats, quantity, max_per_order, price, fee, tax,
      all_in_price, order_fee, price_estimated, ticket_type, general_admission, obstructed, ada)
  SELECT l.source, l.source_event_id, v_at, l.listing_id, v_tevo, l.market, l.area, l.section, l.seat_row, l.seat_low,
         l.seat_high, l.seats, l.quantity, l.max_per_order, l.price, l.fee, l.tax, l.all_in_price, l.order_fee,
         l.price_estimated, l.ticket_type, l.general_admission, l.obstructed, l.ada
    FROM public.primary_poll_listing l
   WHERE l.source = p_source AND l.source_event_id = p_event_id
     AND NOT (p_source = ANY (coalesce(v_skip, '{}')))
  ON CONFLICT DO NOTHING;

  SELECT p_source, p_event_id, v_at, v_tevo,
         CASE WHEN count(*) FILTER (WHERE s.sent) = 0 THEN 0 ELSE sum(s.quantity) FILTER (WHERE s.sent) END,
         count(*) FILTER (WHERE s.sent),
         count(DISTINCT coalesce(s.section, '')) FILTER (WHERE s.sent),
         (percentile_cont(0.5) WITHIN GROUP (ORDER BY s.quantity) FILTER (WHERE s.sent))::numeric,
         min(s.paid) FILTER (WHERE s.sent),
         round((percentile_cont(0.25) WITHIN GROUP (ORDER BY s.paid) FILTER (WHERE s.sent))::numeric, 2),
         round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY s.paid) FILTER (WHERE s.sent))::numeric, 2),
         round((avg(s.paid) FILTER (WHERE s.sent))::numeric, 2),
         round((percentile_cont(0.75) WITHIN GROUP (ORDER BY s.paid) FILTER (WHERE s.sent))::numeric, 2),
         round((percentile_cont(0.9)  WITHIN GROUP (ORDER BY s.paid) FILTER (WHERE s.sent))::numeric, 2),
         max(s.paid) FILTER (WHERE s.sent),
         round((percentile_cont(0.5) WITHIN GROUP (ORDER BY s.price) FILTER (WHERE s.sent))::numeric, 2),
         count(*) FILTER (WHERE s.sent AND s.market IS DISTINCT FROM 'resale'),
         sum(s.quantity) FILTER (WHERE s.sent AND s.market IS DISTINCT FROM 'resale'),
         round((percentile_cont(0.5) WITHIN GROUP (ORDER BY s.paid)
                FILTER (WHERE s.sent AND s.market IS DISTINCT FROM 'resale'))::numeric, 2),
         count(*) FILTER (WHERE s.sent AND s.market = 'resale'),
         sum(s.quantity) FILTER (WHERE s.sent AND s.market = 'resale'),
         round((percentile_cont(0.5) WITHIN GROUP (ORDER BY s.paid) FILTER (WHERE s.sent AND s.market = 'resale'))::numeric, 2),
         sum(s.quantity) FILTER (WHERE s.sent AND s.general_admission),
         count(*) FILTER (WHERE NOT s.sent),
         sum(s.quantity) FILTER (WHERE NOT s.sent)
    INTO m
    FROM (SELECT l.*, NOT l.obstructed AS sent, coalesce(l.all_in_price, l.price) AS paid
            FROM public.primary_poll_listing l
           WHERE l.source = p_source AND l.source_event_id = p_event_id) s;
  INSERT INTO public.primary_poll_event_metrics SELECT m.* ON CONFLICT DO NOTHING;

  INSERT INTO public.primary_poll_section_metrics (source, source_event_id, captured_at, section, market, tickets_count,
      groups_count, price_min, price_median, price_mean, price_max)
  SELECT p_source, p_event_id, v_at, coalesce(l.section, ''), coalesce(l.market, ''), sum(l.quantity), count(*),
         min(coalesce(l.all_in_price, l.price)),
         round((percentile_cont(0.5) WITHIN GROUP (ORDER BY coalesce(l.all_in_price, l.price)))::numeric, 2),
         round(avg(coalesce(l.all_in_price, l.price))::numeric, 2), max(coalesce(l.all_in_price, l.price))
    FROM public.primary_poll_listing l
   WHERE l.source = p_source AND l.source_event_id = p_event_id AND NOT l.obstructed
   GROUP BY 4, 5
  ON CONFLICT DO NOTHING;

  INSERT INTO public.primary_poll_event_daily AS d (source, source_event_id, day, captured_at, captures, tevo_event_id,
      tickets_count, tickets_low, tickets_high, groups_count, sections_count, price_min, price_median, price_max,
      primary_tickets, resale_tickets, ga_tickets)
  VALUES (p_source, p_event_id, (v_at AT TIME ZONE 'UTC')::date, v_at, 1, v_tevo, m.tickets_count, m.tickets_count,
      m.tickets_count, m.groups_count, m.sections_count, m.price_min, m.price_median, m.price_max, m.primary_tickets,
      m.resale_tickets, m.ga_tickets)
  ON CONFLICT (source, source_event_id, day) DO UPDATE SET
      captures = d.captures + 1,
      tickets_low = least(d.tickets_low, EXCLUDED.tickets_count),
      tickets_high = greatest(d.tickets_high, EXCLUDED.tickets_count),
      captured_at = EXCLUDED.captured_at, tevo_event_id = EXCLUDED.tevo_event_id,
      tickets_count = EXCLUDED.tickets_count, groups_count = EXCLUDED.groups_count,
      sections_count = EXCLUDED.sections_count, price_min = EXCLUDED.price_min, price_median = EXCLUDED.price_median,
      price_max = EXCLUDED.price_max, primary_tickets = EXCLUDED.primary_tickets,
      resale_tickets = EXCLUDED.resale_tickets, ga_tickets = EXCLUDED.ga_tickets
    WHERE EXCLUDED.captured_at > d.captured_at;
END $function$;

REVOKE ALL ON FUNCTION public.primary_poll_keep_history(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.primary_poll_keep_history(text, text) TO service_role;

-- The ingest, as 20261123194030 left it, plus one call: after a good read is stored, its history is kept.
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

-- The sweep: one row a table in the engine EVO and GoTickets use (retention_tick(), hourly at :44). The daily
-- table is not listed: it is kept forever, as event_listing_snapshot_daily is.
INSERT INTO public.retention_policy (table_name, ts_column, keep_days, enabled, batch_rows, budget_seconds, priority, notes)
VALUES
  ('primary_poll_listings_snapshots', 'captured_at', 15, true, 50000, 30, 25,
   'Box-office poll, every listing of every good read - 15d, mirroring listings_snapshots / gotickets_listings_snapshots '
   '(mig 20261124203030, operator 2026-11-24: "Look at the retention systems of both Evo and gotickets and copy"). '
   'About 590k rows a day for SI Tickets and the Timberwolves at seed time, and about 1.2M more for the AXS watch; '
   'primary_poll_config.history_skip_listings names sources to leave out, keep_history = false stops all writing.'),
  ('primary_poll_section_metrics', 'captured_at', 60, true, 50000, 20, 45,
   'Box-office poll, per section and market per read - 60d, mirroring section_metrics (mig 20261124203030).'),
  ('primary_poll_event_metrics', 'captured_at', 120, true, 20000, 15, 55,
   'Box-office poll, per event per read - 120d, mirroring event_metrics (mig 20261124203030). The day''s last read '
   'is kept forever in primary_poll_event_daily.')
ON CONFLICT (table_name) DO NOTHING;

NOTIFY pgrst, 'reload schema';
