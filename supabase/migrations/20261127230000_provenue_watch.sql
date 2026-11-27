-- Migration 20261127230000 · level:data-collection · lane:a1 (ProVenue watch) · writes:provenue_watch_config(new),provenue_watch_poll(new),v_provenue_watch_games(new),provenue_capture_event()(new),provenue_watch_game()(new),provenue_watch_settle_one()(new),provenue_watch_budget()(new),provenue_watch_tick()(new),primary_poll_listing.notes(new),cron provenue_watch_tick_30s(new) · reads:mlb_ticket_game,vault tickets.dev,net._http_response
--
-- The ProVenue watch: MLB box-office seats read through tickets.dev's capture.
--
-- WHY. Fourteen MLB clubs sell their own seats on ProVenue (tickets.com — mlb.tickets.com / mpv.tickets.com), and
-- ProVenue refuses connections from our cloud (RESOURCES_BIBLE §1, the s4k-tickets-com-probe run). tickets.dev reads
-- those pages for us: GET /v1/capture/provenue?url=<the club's own event page> returns every unsold seat block with
-- section, row, seat numbers, the quantities that can be bought, face, fee and total — the same shape the other box
-- offices we poll already feed. Operator 2026-11-27: "go ahead and build the provenue reader".
--
-- WHAT IT READS. The MLB schedule we already hold: mlb_ticket_game rows whose primary seller is ProVenue
-- (primary_seller = 'provenue', primary_event_id = the page's pid), regular season, MLB only (sport_id 1), on sale,
-- not started, inside horizon_days. No catalogue lookup: tickets.dev's /v1/events does not index ProVenue yet, and
-- our schedule already carries the page URL and the EVO id, so a capture joins to EVO with no matching.
--
-- WHAT IT WRITES. primary_poll_event / primary_poll_listing as source 'provenue' through the shared
-- primary_poll_ingest — the same capture replacement, history, cadence bookkeeping and feed the AXS watch uses.
-- The EVO id comes from the schedule (method 'mlb_schedule'); primary_poll_map never touches this source, it is
-- not in venue_primary_box_office. Each read is one row in provenue_watch_poll.
--
-- HOW IT PACES. Every game once every `every` (1 h), soonest game first, until the plan runs out: daily_cap and
-- hourly_cap are set to the tickets.dev plan the operator buys (Starter 1,000/month = ~33/day and 50/hour;
-- Developer 10,000 = ~330/day, 300/hour; Production 50,000 = ~1,650/day, 1,000/hour; Scale 250,000 = ~8,300/day,
-- 2,500/hour), and horizon_days to how far ahead that reaches (≈ 0.1 / 1 / 5 / 25 days at 13 games a day). Only a
-- success is billed (tickets.dev: "Failed requests are never charged"), so the caps count successes and reads in
-- flight. The balance tickets.dev returns on every capture (Tickets-Captures-Remaining) stops the watch at
-- quota_reserve; a 429 quota_exceeded stops it for an hour; 429 rate_limited / 5xx hold it to one read in flight.
--
-- THE LISTING KEY. tickets.dev sends listingId empty for ProVenue. A listing is one block of unsold seats, so its
-- key is section | row | first-last seat | ticket type: two blocks in one row at one price (229 N seats 1-7 and
-- 15-21) stay apart, and a block keeps its key when its price moves. Seats come in any order ("10,9,8,7,…") and
-- are sorted. allowed_quantities = sellableQuantities; max_per_order = its largest value. listingNotes is kept on
-- the row (notes) and read for obstructed views ("Obstructed View - Foul Pole", "Foulpole in Sightline").
--
-- THE VENUE MAP is not asked for (includeVenueMaps=false, tickets.dev's default): it is most of the response, the
-- same on every read, and adds capture time.
--
-- RULE 2. One verb: net.http_get against api.tickets.dev's /v1/capture read. Nothing is bought, held or sent to
-- ProVenue; tickets.dev reads the public page. The key is vault secret 'tickets.dev', read at call time, never
-- stored. RULE 1: authored only — the watch ships DISABLED (provenue_watch_config.enabled = false) and the cron
-- only settles until the operator turns it on.

BEGIN;

-- ---------------------------------------------------------------- the notes a box office prints on a listing
ALTER TABLE public.primary_poll_listing ADD COLUMN IF NOT EXISTS notes text;

-- ---------------------------------------------------------------- config (one row)
CREATE TABLE IF NOT EXISTS public.provenue_watch_config (
  id              boolean PRIMARY KEY DEFAULT true CHECK (id),
  enabled         boolean  NOT NULL DEFAULT false,
  every           interval NOT NULL DEFAULT interval '1 hour',      -- each game read once per this
  due_slack       interval NOT NULL DEFAULT interval '2 minutes',   -- a read this early still counts as on time
  retry_after     interval NOT NULL DEFAULT interval '10 minutes',  -- after a read that did not succeed
  horizon_days    integer  NOT NULL DEFAULT 1 CHECK (horizon_days BETWEEN 0 AND 400),
  daily_cap       integer  NOT NULL DEFAULT 33 CHECK (daily_cap >= 0),   -- billed reads (successes + in flight) per UTC day
  hourly_cap      integer  NOT NULL DEFAULT 50 CHECK (hourly_cap >= 0),  -- the plan's throughput
  quota_reserve   integer  NOT NULL DEFAULT 25 CHECK (quota_reserve >= 0),
  max_in_flight   integer  NOT NULL DEFAULT 4 CHECK (max_in_flight BETWEEN 1 AND 50),
  fires_per_tick  integer  NOT NULL DEFAULT 4 CHECK (fires_per_tick BETWEEN 1 AND 50),
  fire_timeout_ms integer  NOT NULL DEFAULT 120000,
  stale_after     interval NOT NULL DEFAULT interval '5 minutes',   -- no response by then = lost
  upstream_errors_max integer NOT NULL DEFAULT 3,                   -- of the last 10 reads: hold to one in flight
  clubs           text[],                                           -- home_abbrev to read; NULL = every ProVenue club
  note            text
);
INSERT INTO public.provenue_watch_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------- the ledger: one row per read
CREATE TABLE IF NOT EXISTS public.provenue_watch_poll (
  request_id         bigint PRIMARY KEY,
  pid                text NOT NULL,                 -- ProVenue's event id = primary_poll_event.source_event_id
  mlb_game_id        text,
  fired_at           timestamptz NOT NULL DEFAULT now(),
  checked_at         timestamptz,
  status_code        integer,
  outcome            text,                          -- ok | not_on_sale | event_not_found | capture_failed | rate_limited | quota_exceeded | auth | lost | bad_body | error
  error              text,
  listings           integer,
  tickets            integer,
  captures_remaining bigint
);
CREATE INDEX IF NOT EXISTS provenue_watch_poll_pid_idx ON public.provenue_watch_poll (pid, fired_at DESC);
CREATE INDEX IF NOT EXISTS provenue_watch_poll_open_idx ON public.provenue_watch_poll (fired_at) WHERE checked_at IS NULL;
ALTER TABLE public.provenue_watch_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provenue_watch_poll ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------- the games we may read
CREATE OR REPLACE VIEW public.v_provenue_watch_games AS
SELECT DISTINCT ON (g.primary_event_id)
       g.primary_event_id AS pid, g.mlb_game_id, g.ticket_url, g.game_time_utc, g.game_date, g.game_time_local,
       g.time_zone_local, g.home_abbrev, g.away_abbrev, g.home_name, g.away_name, g.venue_name, g.venue_city,
       g.tevo_event_id, g.on_sale_start
  FROM public.mlb_ticket_game g
 WHERE g.primary_seller = 'provenue'
   AND g.primary_event_id ~ '^[0-9]+$'
   AND g.sport_id = 1 AND g.game_type = 'R'
   AND g.removed_at IS NULL
   AND g.ticket_url ~* '^https://(mlb|mpv)\.tickets\.com/'
   AND g.game_time_utc > now()
   -- on_sale_start is the schedule's Eastern wall time
   AND (g.on_sale_start IS NULL OR g.on_sale_start <= (now() AT TIME ZONE 'America/New_York'))
 ORDER BY g.primary_event_id, g.game_time_utc;
REVOKE ALL ON public.v_provenue_watch_games FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------- a capture -> one primary_poll_ingest event
-- Pure. p_body is tickets.dev's snapshot; p_game the schedule row (name and fallbacks when the body lacks them).
CREATE OR REPLACE FUNCTION public.provenue_capture_event(p_body jsonb, p_pid text, p_game jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH l AS (
    SELECT x AS j,
           -- seats sorted: numerically when every seat is a number, else as text
           (SELECT CASE WHEN bool_and(s ~ '^[0-9]+$') THEN array_agg(s ORDER BY s::int) ELSE array_agg(s ORDER BY s) END
              FROM unnest(string_to_array(regexp_replace(coalesce(x->>'seats', ''), '\s', '', 'g'), ',')) s
             WHERE s <> '') AS seats,
           (SELECT array_agg(q::int ORDER BY q::int)
              FROM unnest(string_to_array(regexp_replace(coalesce(x->>'sellableQuantities', ''), '\s', '', 'g'), ',')) q
             WHERE q ~ '^[0-9]+$') AS qtys
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'listings') = 'array' THEN p_body->'listings' ELSE '[]'::jsonb END) x
  ), r AS (
    SELECT jsonb_strip_nulls(jsonb_build_object(
             'id', concat_ws('|', l.j->>'section', l.j->>'row',
                             coalesce(l.seats[1] || '-' || l.seats[array_length(l.seats, 1)], 'q' || (l.j->>'quantity')),
                             coalesce(nullif(l.j->>'ticketType', ''), 'Regular Ticket')),
             'market', 'primary',
             'section', nullif(l.j->>'section', ''),
             'row', nullif(l.j->>'row', ''),
             'seat_low', l.seats[1],
             'seat_high', l.seats[array_length(l.seats, 1)],
             'seats', to_jsonb(l.seats),
             'qty', CASE WHEN l.j->>'quantity' ~ '^[0-9]+$' THEN (l.j->>'quantity')::int END,
             'allowed_quantities', to_jsonb(l.qtys),
             'max_per_order', l.qtys[array_length(l.qtys, 1)],
             'price', CASE WHEN jsonb_typeof(l.j->'ticketPrice') = 'number' THEN (l.j->>'ticketPrice')::numeric END,
             'fee', CASE WHEN jsonb_typeof(l.j->'fee') = 'number' THEN (l.j->>'fee')::numeric END,
             'all_in', CASE WHEN jsonb_typeof(l.j->'totalPrice') = 'number' THEN (l.j->>'totalPrice')::numeric END,
             'area', nullif(l.j->>'group', ''),
             'ticket_type', nullif(l.j->>'ticketType', ''),
             'obstructed', coalesce(l.j->>'listingNotes', '') ~* '(obstruct|sightline|foul ?pole|limited view|partial view)',
             'ga', CASE WHEN l.j->>'section' ~* '^(STAND|SRO|GA)' OR l.j->>'row' ~* '^SRO'
                          OR coalesce(l.j->>'listingNotes', '') ~* 'standing room' THEN true END,
             'ada', CASE WHEN coalesce(l.j->>'listingNotes', '') || ' ' || coalesce(l.j->>'ticketType', '')
                              ~* '(wheelchair|\mada\M|accessible|companion)' THEN true END,
             'notes', nullif(l.j->>'listingNotes', '')
           )) AS row
      FROM l
     WHERE coalesce(l.j->>'section', '') <> ''
  )
  SELECT jsonb_strip_nulls(jsonb_build_object(
           'id', p_pid,
           'name', coalesce(nullif(p_body->>'eventName', ''), p_game->>'name'),
           'local_date', coalesce(substring(p_body->>'eventDateLocal' FROM '^\d{4}-\d{2}-\d{2}'), p_game->>'local_date'),
           'local_time', coalesce(substring(p_body->>'eventDateLocal' FROM 'T(\d{2}:\d{2})'), p_game->>'local_time'),
           'start_utc', coalesce(nullif(p_body->>'eventDateUtc', ''), p_game->>'start_utc'),
           'timezone', coalesce(nullif(p_body->>'venueTimezone', ''), p_game->>'timezone'),
           'venue', coalesce(nullif(p_body->>'venueName', ''), p_game->>'venue'),
           'city', coalesce(nullif(p_body->>'venueCity', ''), p_game->>'city'),
           'state', nullif(p_body->>'venueState', ''),
           'url', p_game->>'url',
           'total_available', CASE WHEN jsonb_typeof(p_body#>'{stats,ticketCount}') = 'number' THEN (p_body#>>'{stats,ticketCount}')::int END,
           'price_min', CASE WHEN jsonb_typeof(p_body#>'{stats,getInPrice}') = 'number' THEN (p_body#>>'{stats,getInPrice}')::numeric END,
           'price_max', CASE WHEN jsonb_typeof(p_body#>'{stats,maxPrice}') = 'number' THEN (p_body#>>'{stats,maxPrice}')::numeric END,
           'ok', true))
         || jsonb_build_object('listings', coalesce((SELECT jsonb_agg(r.row) FROM r), '[]'::jsonb))
$function$;

-- ---------------------------------------------------------------- the schedule row, in the shape the parse wants
CREATE OR REPLACE FUNCTION public.provenue_watch_game(p_pid text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_strip_nulls(jsonb_build_object(
           'name', g.away_name || ' at ' || g.home_name,
           'local_date', g.game_date::text,
           'local_time', substring(g.game_time_local::text FROM 'T?(\d{2}:\d{2})'),
           'start_utc', g.game_time_utc,
           'venue', g.venue_name, 'city', g.venue_city, 'url', g.ticket_url,
           'tevo_event_id', g.tevo_event_id, 'mlb_game_id', g.mlb_game_id))
    FROM public.mlb_ticket_game g
   WHERE g.primary_event_id = p_pid AND g.primary_seller = 'provenue'
   ORDER BY g.removed_at NULLS FIRST, g.game_time_utc
   LIMIT 1
$function$;

-- ---------------------------------------------------------------- settle one response
CREATE OR REPLACE FUNCTION public.provenue_watch_settle_one(p_pid text, p_status integer, p_body jsonb,
                                                            p_timed_out boolean, p_error text, p_headers jsonb DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_game jsonb := coalesce(public.provenue_watch_game(p_pid), '{}'::jsonb);
  v_code text := p_body#>>'{error,code}';
  v_remaining bigint;
  v_event jsonb; v_outcome text; v_err text; v_listings integer; v_tickets integer;
BEGIN
  -- the balance: a header on every capture response (pg_net keeps header names as sent; look both ways)
  SELECT CASE WHEN v ~ '^[0-9]+$' THEN v::bigint END INTO v_remaining
    FROM (SELECT coalesce(p_headers->>'Tickets-Captures-Remaining', p_headers->>'tickets-captures-remaining') AS v) h;

  IF coalesce(p_timed_out, false) OR p_status IS NULL THEN
    v_outcome := 'capture_failed'; v_err := coalesce(p_error, 'timed out');
  ELSIF p_status = 200 AND jsonb_typeof(p_body->'listings') = 'array' THEN
    v_event := public.provenue_capture_event(p_body, p_pid, v_game);
    v_listings := jsonb_array_length(v_event->'listings');
    v_tickets := (v_event->>'total_available')::integer;
    v_outcome := CASE WHEN v_listings = 0 AND coalesce(p_body->>'note', '') <> '' THEN 'not_on_sale' ELSE 'ok' END;
    v_err := nullif(p_body->>'note', '');
  ELSIF p_status = 200 THEN
    v_outcome := 'bad_body'; v_err := 'a 200 without a listings array';
  ELSIF v_code IN ('rate_limited', 'quota_exceeded') THEN
    v_outcome := v_code; v_err := p_body#>>'{error,message}';
  ELSIF p_status IN (401, 402) THEN
    v_outcome := 'auth'; v_err := coalesce(v_code, 'http ' || p_status);
  ELSIF v_code = 'event_not_found' OR p_status = 404 THEN
    v_outcome := 'event_not_found'; v_err := coalesce(p_body#>>'{error,message}', 'event_not_found');
  ELSE
    v_outcome := CASE WHEN p_status >= 500 THEN 'capture_failed' ELSE 'error' END;
    v_err := coalesce(v_code, '') || ' http ' || p_status || coalesce(': ' || (p_body#>>'{error,message}'), '');
  END IF;

  IF v_event IS NOT NULL THEN
    PERFORM public.primary_poll_ingest('provenue', jsonb_build_array(v_event));
    -- the notes the box office prints, kept on the rows just written
    UPDATE public.primary_poll_listing pl SET notes = x->>'notes'
      FROM jsonb_array_elements(v_event->'listings') x
     WHERE pl.source = 'provenue' AND pl.source_event_id = p_pid AND pl.listing_id = x->>'id' AND x ? 'notes';
  ELSIF v_outcome IN ('event_not_found', 'capture_failed', 'bad_body', 'error') AND v_game ? 'name' THEN
    -- the page answered and could not be read: a failed read of THIS game (the capture survives one, as for AXS).
    -- Capacity, quota and key errors are ours, not the game's, and leave its capture alone.
    PERFORM public.primary_poll_ingest('provenue', jsonb_build_array(
              public.provenue_capture_event('{}'::jsonb, p_pid, v_game) - 'listings'
              || jsonb_build_object('ok', false, 'error', left(v_outcome || ': ' || coalesce(v_err, ''), 300), 'listings', '[]'::jsonb)));
  END IF;

  -- the EVO id is the schedule's: written fill-only, or refreshed when it is ours
  IF v_game ? 'tevo_event_id' THEN
    UPDATE public.primary_poll_event e
       SET tevo_event_id = (v_game->>'tevo_event_id')::bigint, tevo_match_method = 'mlb_schedule', tevo_matched_at = now()
     WHERE e.source = 'provenue' AND e.source_event_id = p_pid
       AND (e.tevo_event_id IS NULL OR e.tevo_match_method = 'mlb_schedule')
       AND e.tevo_event_id IS DISTINCT FROM (v_game->>'tevo_event_id')::bigint;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object('outcome', v_outcome, 'error', left(v_err, 300), 'listings', v_listings,
                                              'tickets', v_tickets, 'captures_remaining', v_remaining));
END $function$;

-- ---------------------------------------------------------------- the budget, readable
CREATE OR REPLACE FUNCTION public.provenue_watch_budget()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'daily_cap', c.daily_cap, 'hourly_cap', c.hourly_cap,
    -- only a success is billed, so the caps count successes and what is still in flight
    'billed_today', (SELECT count(*) FROM public.provenue_watch_poll p
                      WHERE p.fired_at >= date_trunc('day', now()) AND (p.checked_at IS NULL OR p.outcome IN ('ok', 'not_on_sale'))),
    'billed_last_hour', (SELECT count(*) FROM public.provenue_watch_poll p
                          WHERE p.fired_at >= now() - interval '1 hour' AND (p.checked_at IS NULL OR p.outcome IN ('ok', 'not_on_sale'))),
    'in_flight', (SELECT count(*) FROM public.provenue_watch_poll p WHERE p.checked_at IS NULL),
    'captures_remaining', (SELECT p.captures_remaining FROM public.provenue_watch_poll p
                            WHERE p.captures_remaining IS NOT NULL ORDER BY p.checked_at DESC LIMIT 1),
    'quota_exceeded_at', (SELECT max(p.checked_at) FROM public.provenue_watch_poll p WHERE p.outcome = 'quota_exceeded'),
    'games_in_horizon', (SELECT count(*) FROM public.v_provenue_watch_games g
                          WHERE g.game_time_utc < now() + make_interval(days => c.horizon_days)
                            AND (c.clubs IS NULL OR g.home_abbrev = ANY (c.clubs))))
    FROM public.provenue_watch_config c
$function$;

-- ---------------------------------------------------------------- the tick: settle, then fire what is due
CREATE OR REPLACE FUNCTION public.provenue_watch_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.provenue_watch_config%ROWTYPE;
  v_budget jsonb; v_key text; v_slots integer; v_errors integer; v_room integer;
  v_fired integer := 0; v_settled integer := 0; v_lost integer := 0;
  w record; t record; r jsonb; v_rid bigint;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('provenue_watch_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another provenue_watch_tick is running');
  END IF;
  SELECT * INTO v_cfg FROM public.provenue_watch_config;

  -- 1. settle every request whose response has landed
  FOR w IN SELECT p.request_id, p.pid, hr.status_code, hr.content, hr.timed_out, hr.error_msg, to_jsonb(hr)->'headers' AS headers
             FROM public.provenue_watch_poll p JOIN net._http_response hr ON hr.id = p.request_id
            WHERE p.checked_at IS NULL
            ORDER BY p.fired_at
  LOOP
    r := public.provenue_watch_settle_one(w.pid, w.status_code, public.safe_jsonb(w.content),
                                          coalesce(w.timed_out, false), w.error_msg, w.headers);
    UPDATE public.provenue_watch_poll p
       SET checked_at = now(), status_code = w.status_code, outcome = r->>'outcome', error = r->>'error',
           listings = (r->>'listings')::integer, tickets = (r->>'tickets')::integer,
           captures_remaining = (r->>'captures_remaining')::bigint
     WHERE p.request_id = w.request_id;
    v_settled := v_settled + 1;
  END LOOP;

  -- the feeds show a source's events of its current run (v_primary_poll_events_feed joins primary_poll_source on
  -- current_run = last_run): every upcoming ProVenue game we have read joins the run whenever a read settles
  IF v_settled > 0 THEN
    PERFORM public.primary_poll_run_done('provenue', 'provenue-' || to_char(clock_timestamp(), 'YYYYMMDD"T"HH24MISS.US'),
              coalesce((SELECT jsonb_agg(e.source_event_id) FROM public.primary_poll_event e
                          JOIN public.v_provenue_watch_games g ON g.pid = e.source_event_id
                         WHERE e.source = 'provenue'), '[]'::jsonb));
  END IF;

  -- no response by stale_after: pg_net gave up. Lost is ours, not the game's: retried after retry_after.
  UPDATE public.provenue_watch_poll p SET checked_at = now(), outcome = 'lost', error = 'no response within stale_after'
   WHERE p.checked_at IS NULL AND p.fired_at < now() - v_cfg.stale_after
     AND NOT EXISTS (SELECT 1 FROM net._http_response hr WHERE hr.id = p.request_id);
  GET DIAGNOSTICS v_lost = ROW_COUNT;

  -- the ledger keeps 14 days
  DELETE FROM public.provenue_watch_poll p WHERE p.fired_at < now() - interval '14 days';

  IF NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'paused', true);
  END IF;

  -- 2. the room: plan caps, the balance, the upstream's health, what is in flight
  v_budget := public.provenue_watch_budget();
  IF (v_budget->>'quota_exceeded_at')::timestamptz > now() - interval '1 hour' THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'held', 'quota_exceeded in the last hour');
  END IF;
  IF (v_budget->>'captures_remaining')::bigint <= v_cfg.quota_reserve THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'held', 'captures_remaining at reserve',
                              'captures_remaining', v_budget->'captures_remaining');
  END IF;
  v_room := least(v_cfg.daily_cap - (v_budget->>'billed_today')::integer,
                  v_cfg.hourly_cap - (v_budget->>'billed_last_hour')::integer);
  SELECT count(*) FILTER (WHERE x.outcome IN ('rate_limited', 'capture_failed', 'lost')) INTO v_errors
    FROM (SELECT p.outcome FROM public.provenue_watch_poll p WHERE p.checked_at IS NOT NULL ORDER BY p.checked_at DESC LIMIT 10) x;
  v_slots := least(v_cfg.max_in_flight - (v_budget->>'in_flight')::integer, v_cfg.fires_per_tick, v_room);
  IF v_errors >= v_cfg.upstream_errors_max THEN v_slots := least(v_slots, 1 - (v_budget->>'in_flight')::integer); END IF;
  IF v_slots <= 0 THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'room', v_room,
                              'in_flight', v_budget->'in_flight', 'upstream_errors', v_errors);
  END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'tickets.dev';
  IF coalesce(v_key, '') = '' THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', 0, 'held', 'vault secret tickets.dev missing');
  END IF;

  -- 3. fire: due = no read in flight, no success within `every`, no attempt within retry_after; never read first,
  --    then the soonest game
  FOR t IN
    SELECT g.pid, g.mlb_game_id, g.ticket_url, last.ok_at
      FROM public.v_provenue_watch_games g
      LEFT JOIN LATERAL (
        SELECT max(p.fired_at) FILTER (WHERE p.outcome IN ('ok', 'not_on_sale')) AS ok_at,
               max(p.fired_at) AS any_at,
               bool_or(p.checked_at IS NULL) AS in_flight
          FROM public.provenue_watch_poll p WHERE p.pid = g.pid) last ON true
     WHERE g.game_time_utc < now() + make_interval(days => v_cfg.horizon_days)
       AND (v_cfg.clubs IS NULL OR g.home_abbrev = ANY (v_cfg.clubs))
       AND NOT coalesce(last.in_flight, false)
       AND (last.ok_at IS NULL OR last.ok_at <= now() - v_cfg.every + v_cfg.due_slack)
       AND (last.any_at IS NULL OR last.any_at <= now() - v_cfg.retry_after
            OR (last.ok_at IS NOT NULL AND last.any_at = last.ok_at))
     ORDER BY last.ok_at NULLS FIRST, g.game_time_utc, g.pid
     LIMIT v_slots
  LOOP
    SELECT net.http_get(
      url := 'https://api.tickets.dev/v1/capture/provenue',
      params := jsonb_build_object('url', t.ticket_url, 'includeVenueMaps', 'false'),
      headers := jsonb_build_object('x-api-key', v_key),
      timeout_milliseconds := v_cfg.fire_timeout_ms) INTO v_rid;
    INSERT INTO public.provenue_watch_poll (request_id, pid, mlb_game_id) VALUES (v_rid, t.pid, t.mlb_game_id);
    v_fired := v_fired + 1;
  END LOOP;

  RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'fired', v_fired, 'room', v_room - v_fired,
                            'upstream_errors', v_errors, 'captures_remaining', v_budget->'captures_remaining');
END $function$;

REVOKE ALL ON FUNCTION public.provenue_capture_event(jsonb, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provenue_watch_game(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provenue_watch_settle_one(text, integer, jsonb, boolean, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provenue_watch_budget() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provenue_watch_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.provenue_watch_budget() TO service_role;
GRANT EXECUTE ON FUNCTION public.provenue_watch_tick() TO service_role;

-- the cron settles every 30 s; it fires only while provenue_watch_config.enabled
SELECT cron.schedule('provenue_watch_tick_30s', '30 seconds', $$SELECT public.provenue_watch_tick()$$);

COMMIT;
