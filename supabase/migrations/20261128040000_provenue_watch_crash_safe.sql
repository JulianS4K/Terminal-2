-- Migration 20261128040000 · level:data-collection · lane:a1 (ProVenue watch) · writes:provenue_watch_poll(+id, request_id no longer the key),provenue_capture_event()(replace),provenue_watch_tick()(replace) · reads:net._http_response
--
-- Two faults the ProVenue watch's first day turned up (operator 2026-11-28: "yes re-read phi and stl and fix the id").
--
-- 1. LISTINGS LOST TO A SHARED ID. A listing's id is section|row|first-last seat|ticket type. In the first reads of
--    the Phillies (pid 9803045) and the Cardinals (9798810), 12 and 7 parsed blocks shared an id with another block
--    of the same capture, so the store kept one of each pair: 994 of 1,006 and 1,980 of 1,987. Every other venue's
--    count matched. The re-reads that would have shown which blocks they were were lost in a database restart, so
--    the fix does not depend on the cause: where two blocks of one capture share an id, each gets '~' and the
--    first six characters of the md5 of its own block after it; every other listing keeps its id exactly. A block
--    that repeats word for word keeps its id and is kept once.
--
-- 2. A DATABASE RESTART. The database restarted twice on 2026-11-28 (02:08 and 02:24 UTC). pg_net keeps its
--    responses in a table a crash empties and starts its request ids again from 1, so:
--    - provenue_watch_poll was keyed on request_id, which now repeats: within hours a new read's id meets an old
--      row's and the insert fails the tick. The ledger gets its own key (id); request_id is unique only among the
--      reads still open.
--    - a read in flight at the restart would wait for its id, and the response that next carries that id is
--      someone else's. A read fired before pg_postmaster_start_time() is marked lost ('lost in a database
--      restart') and never settled from a response; the settle writes only the open row of that id.

BEGIN;

ALTER TABLE public.provenue_watch_poll DROP CONSTRAINT IF EXISTS provenue_watch_poll_pkey;
ALTER TABLE public.provenue_watch_poll ADD COLUMN IF NOT EXISTS id bigserial;
ALTER TABLE public.provenue_watch_poll ADD PRIMARY KEY (id);
CREATE UNIQUE INDEX IF NOT EXISTS provenue_watch_poll_open_request_idx ON public.provenue_watch_poll (request_id) WHERE checked_at IS NULL;
CREATE INDEX IF NOT EXISTS provenue_watch_poll_request_idx ON public.provenue_watch_poll (request_id);

CREATE OR REPLACE FUNCTION public.provenue_capture_event(p_body jsonb, p_pid text, p_game jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH l AS (
    SELECT x AS j,
           -- seats sorted: numbers numerically, then anything else ('1C', a companion seat) as text. The cast sits in
           -- a per-row CASE: an aggregate inside a CASE is computed for every branch, so the old
           -- CASE WHEN bool_and(...) THEN array_agg(s ORDER BY s::int) cast '1C' anyway and failed the whole tick
           (SELECT array_agg(s ORDER BY CASE WHEN s ~ '^[0-9]{1,9}$' THEN s::int END, s)
              FROM unnest(string_to_array(regexp_replace(coalesce(x->>'seats', ''), '\s', '', 'g'), ',')) s
             WHERE s <> '') AS seats,
           (SELECT array_agg(q::int ORDER BY q::int)
              FROM unnest(string_to_array(regexp_replace(coalesce(x->>'sellableQuantities', ''), '\s', '', 'g'), ',')) q
             WHERE q ~ '^[0-9]+$') AS qtys
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'listings') = 'array' THEN p_body->'listings' ELSE '[]'::jsonb END) x
  ), lim AS (
    -- the order limit, as the AXS watch sends it (event order_min / order_max): ProVenue prints none, but a club's
    -- cap shows wherever a block holds more seats than can be bought at once (sellableQuantities stops short of the
    -- quantity: the Marlins 9, the Padres 8, the Pirates 14, the Rays 19, the Giants 20). Only then is the most
    -- any block sells the cap; where every block sells whole (the Nationals, up to 33) the cap is unknown: null.
    SELECT min(l.qtys[1]) AS omin,
           CASE WHEN bool_or(l.qtys[array_length(l.qtys, 1)] < (l.j->>'quantity')::int)
                THEN max(l.qtys[array_length(l.qtys, 1)]) END AS omax
      FROM l
     WHERE coalesce(l.j->>'section', '') <> '' AND l.j->>'quantity' ~ '^[0-9]+$'
  ), r AS (
    SELECT concat_ws('|', l.j->>'section', l.j->>'row',
                     coalesce(l.seats[1] || '-' || l.seats[array_length(l.seats, 1)], 'q' || (l.j->>'quantity')),
                     coalesce(nullif(l.j->>'ticketType', ''), 'Regular Ticket')) AS base,
           left(md5(l.j::text), 6) AS tag,
           jsonb_strip_nulls(jsonb_build_object(
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
  ), u AS (
    -- the id is section|row|first-last seat|ticket type. Two blocks of one capture can share it (the first PHI and
    -- STL reads lost 12 and 7 listings that way: the second overwrote the first in the store); then each of them
    -- carries a tag of its own content after a '~', and every other listing keeps its id. A block repeated word
    -- for word (the same tag) is not a second block: it keeps its id and is kept once.
    SELECT DISTINCT ON (id) id, row
      FROM (SELECT CASE WHEN min(r.tag) OVER (PARTITION BY r.base) <> max(r.tag) OVER (PARTITION BY r.base) THEN r.base || '~' || r.tag ELSE r.base END AS id, r.row
              FROM r) x
     ORDER BY id
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
           'order_min', (SELECT lim.omin FROM lim),
           'order_max', (SELECT lim.omax FROM lim),
           'ok', true))
         || jsonb_build_object('listings', coalesce((SELECT jsonb_agg(jsonb_build_object('id', u.id) || u.row ORDER BY u.id) FROM u), '[]'::jsonb))
$function$;

REVOKE ALL ON FUNCTION public.provenue_capture_event(jsonb, text, jsonb) FROM PUBLIC, anon, authenticated;

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
  FOR w IN SELECT p.request_id, p.pid, hr.status_code, hr.content, hr.timed_out, hr.error_msg, to_jsonb(hr)->'headers' AS headers,
                  round(extract(epoch FROM hr.created - p.fired_at)::numeric, 1) AS response_s
             FROM public.provenue_watch_poll p JOIN net._http_response hr ON hr.id = p.request_id
            WHERE p.checked_at IS NULL
              -- a read fired before the database last started lost its response in the restart (pg_net keeps its
              -- responses in a table a crash empties, and starts its ids again), so a response with its id now is
              -- someone else's
              AND p.fired_at >= pg_postmaster_start_time()
            ORDER BY p.fired_at
  LOOP
    -- one response our settle cannot take is that read's failure, never the tick's: before mig 20261128020000 an
    -- error here rolled the whole tick back, so nothing settled or fired again until a fix shipped
    BEGIN
      r := public.provenue_watch_settle_one(w.pid, w.status_code, public.safe_jsonb(w.content),
                                            coalesce(w.timed_out, false), w.error_msg, w.headers);
    EXCEPTION WHEN OTHERS THEN
      r := jsonb_build_object('outcome', CASE WHEN w.status_code = 200 THEN 'settle_error' ELSE 'error' END,
                              'error', left('settle: ' || SQLERRM, 300));
    END;
    UPDATE public.provenue_watch_poll p
       SET checked_at = now(), status_code = w.status_code, outcome = r->>'outcome', error = r->>'error', response_s = w.response_s,
           listings = (r->>'listings')::integer, tickets = (r->>'tickets')::integer,
           captures_remaining = (r->>'captures_remaining')::bigint
     WHERE p.request_id = w.request_id AND p.checked_at IS NULL;
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
  -- or the database restarted after it was fired: its response is gone
  UPDATE public.provenue_watch_poll p
     SET checked_at = now(), outcome = 'lost',
         error = CASE WHEN p.fired_at < pg_postmaster_start_time() THEN 'lost in a database restart' ELSE 'no response within stale_after' END
   WHERE p.checked_at IS NULL
     AND (p.fired_at < pg_postmaster_start_time()
          OR (p.fired_at < now() - v_cfg.stale_after AND NOT EXISTS (SELECT 1 FROM net._http_response hr WHERE hr.id = p.request_id)));
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

  -- 3. fire: due = no read in flight; the stored band has run out (next_poll_at, written by the settle from
  --    `every` or `empty_every`); no attempt within retry_after unless that attempt succeeded. Soonest game first
  --    and nothing else: a near game due again outranks a far one never read (mig 20261127000000 D).
  FOR t IN
    SELECT g.pid, g.mlb_game_id, g.ticket_url
      FROM public.v_provenue_watch_games g
      LEFT JOIN public.primary_poll_event e ON e.source = 'provenue' AND e.source_event_id = g.pid
      LEFT JOIN LATERAL (
        SELECT max(p.fired_at) FILTER (WHERE p.outcome IN ('ok', 'empty', 'not_on_sale')) AS ok_at,
               max(p.fired_at) AS any_at,
               max(p.fired_at) FILTER (WHERE p.outcome = 'settle_error') AS bad_at,
               bool_or(p.checked_at IS NULL) AS in_flight
          FROM public.provenue_watch_poll p WHERE p.pid = g.pid) last ON true
     WHERE (v_cfg.horizon_days IS NULL OR g.game_time_utc < now() + make_interval(days => v_cfg.horizon_days))
       AND (v_cfg.clubs IS NULL OR g.home_abbrev = ANY (v_cfg.clubs))
       AND NOT coalesce(last.in_flight, false)
       -- a billed capture we could not settle waits the sold-out band: retrying it every retry_after would bill again
       AND (last.bad_at IS NULL OR last.bad_at <= now() - v_cfg.empty_every)
       AND (e.source_event_id IS NULL OR e.poll_status IS DISTINCT FROM 'ok' OR e.next_poll_at IS NULL
            OR e.next_poll_at <= now() + v_cfg.due_slack)
       AND (last.any_at IS NULL OR last.any_at <= now() - v_cfg.retry_after
            OR (last.ok_at IS NOT NULL AND last.any_at = last.ok_at))
     ORDER BY g.game_time_utc, g.pid
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

REVOKE ALL ON FUNCTION public.provenue_watch_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.provenue_watch_tick() TO service_role;

COMMIT;
