-- Migration 20261128020000 · level:data-collection · lane:a1 (ProVenue watch) · writes:provenue_capture_event()(replace),provenue_watch_budget()(replace),provenue_watch_tick()(replace) · reads:provenue_watch_poll,net._http_response
--
-- The ProVenue watch's first live reads (operator 2026-11-28: "starter plan on to test") found two faults.
--
-- 1. A seat that is not a number failed the parse. The Rays sell companion seats as '1C,2C' (CHALK126, "companion
--    seat in an ada compliant location"). provenue_capture_event sorted seats with
--    CASE WHEN bool_and(s ~ '^[0-9]+$') THEN array_agg(s ORDER BY s::int) ELSE array_agg(s ORDER BY s) END, and
--    Postgres computes every aggregate in a CASE before choosing the branch, so '1C'::int ran anyway. The sort is now
--    one aggregate whose cast sits in a per-row CASE: numbers numerically, then the rest as text. A listing of only
--    numbered seats gets the same id as before.
--
-- 2. One response the settle could not take failed the whole tick. The tick rolled back, so the other three
--    responses of that batch stayed unsettled and nothing fired again: every tick from 01:40 UTC failed on the same
--    row. Each settle now runs in its own sub-transaction; an error becomes that read's outcome — 'settle_error' for
--    a 200 (tickets.dev billed it, so the budget counts it), else 'error' — and the tick carries on. A game whose
--    capture we could not settle waits empty_every (1 day) before it is read again, so a parse fault cannot bill the
--    same game every retry_after.
--
-- Nothing is lost by the stall: the four unsettled responses are still in net._http_response (ttl 6 h) and settle
-- on the first tick after this applies.

BEGIN;

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

CREATE OR REPLACE FUNCTION public.provenue_watch_budget()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'daily_cap', c.daily_cap, 'hourly_cap', c.hourly_cap,
    -- only a success is billed, so the caps count successes and what is still in flight; a capture that came back
    -- and our settle could not take (settle_error) was billed too
    'billed_today', (SELECT count(*) FROM public.provenue_watch_poll p
                      WHERE p.fired_at >= date_trunc('day', now()) AND (p.checked_at IS NULL OR p.outcome IN ('ok', 'empty', 'not_on_sale', 'settle_error'))),
    'billed_last_hour', (SELECT count(*) FROM public.provenue_watch_poll p
                          WHERE p.fired_at >= now() - interval '1 hour' AND (p.checked_at IS NULL OR p.outcome IN ('ok', 'empty', 'not_on_sale', 'settle_error'))),
    'in_flight', (SELECT count(*) FROM public.provenue_watch_poll p WHERE p.checked_at IS NULL),
    'captures_remaining', (SELECT p.captures_remaining FROM public.provenue_watch_poll p
                            WHERE p.captures_remaining IS NOT NULL ORDER BY p.checked_at DESC LIMIT 1),
    'quota_exceeded_at', (SELECT max(p.checked_at) FROM public.provenue_watch_poll p WHERE p.outcome = 'quota_exceeded'),
    'games_in_horizon', (SELECT count(*) FROM public.v_provenue_watch_games g
                          WHERE (c.horizon_days IS NULL OR g.game_time_utc < now() + make_interval(days => c.horizon_days))
                            AND (c.clubs IS NULL OR g.home_abbrev = ANY (c.clubs))),
    -- what a read costs in wall time, and what max_in_flight can therefore carry an hour (mig 20261126163000's
    -- lesson: size from the measured read)
    'response_p50_s', m.p50, 'response_p90_s', m.p90,
    'per_hour_at_in_flight', CASE WHEN m.p50 > 0 THEN floor(3600 / m.p50 * c.max_in_flight) END)
    FROM public.provenue_watch_config c
    CROSS JOIN LATERAL (
      SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY x.response_s))::numeric, 1) AS p50,
             round((percentile_cont(0.9) WITHIN GROUP (ORDER BY x.response_s))::numeric, 1) AS p90
        FROM (SELECT p.response_s FROM public.provenue_watch_poll p
               WHERE p.response_s IS NOT NULL ORDER BY p.checked_at DESC LIMIT 200) x) m
$function$;

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

REVOKE ALL ON FUNCTION public.provenue_capture_event(jsonb, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provenue_watch_budget() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.provenue_watch_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.provenue_watch_budget() TO service_role;
GRANT EXECUTE ON FUNCTION public.provenue_watch_tick() TO service_role;

COMMIT;
