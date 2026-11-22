-- Migration 20261122015530 · level:data-collection · lane:A1 (data plane — mapping program; routed to this session by the operator) · writes:tm_discovery_query(day: rows refresh_hours; seg: rows active),tm_discovery_plan_days(),tm_discovery_tick() · reads:vault.decrypted_secrets('TMR CLIENT ID'),app.ticketmaster.com/discovery/v2 (GET) · pre:20261121223530
--
-- THE TICKETMASTER COLLECTOR READS EACH EVENT AGAIN ONCE A WEEK, NOT MORE.
-- Operator 2026-11-22: "For changes check the same event only once a week to save tokens".
--
-- BEFORE (20261121223530, one day old). Today's and tomorrow's day queries were re-read every 6 hours, the
-- next two weeks every 20 hours, and every day query every 72 hours: up to 1,250 calls a day, and an event
-- two days out was read about ten times before it happened.
--
-- NOW. A day query is due again 7 days after its last complete read, whichever pass reads it:
--   change     up to 250 calls a day: the day queries a week old, soonest day first.
--   discovery  up to 1,000 calls a day: the days the change budget did not reach that day, and a day that
--              just came inside the 400-day horizon and has never been read.
-- The 39 weekly US queries of the first plan are switched off and no longer planned: they re-read events the
-- day queries already read, so a US event in the next 13 weeks was read twice a week.
-- An event is in exactly one day query, so it is read again once a week. One pass over the 400 days is about
-- 2,700 calls: about 390 a day on average instead of up to 1,250. The two ceilings are unchanged; they are
-- now well above what is used.
-- What it costs: a cancellation or a moved time is seen up to 7 days after Ticketmaster makes it (it was 6
-- hours for today and tomorrow), and a newly listed event is found within 7 days (it was 3).
-- tm_discovery_rounds_left() (20261121223530) is no longer called; it is left in place, unused.
--
-- NOT CHANGED: what is read, how an event is stored, the matcher, the cron. GET only (RULE 2).
--
-- rollback: re-apply tm_discovery_plan_days() and tm_discovery_tick() from 20261121223530;
--           UPDATE tm_discovery_query SET refresh_hours = 72 WHERE label LIKE 'day:%';
--           UPDATE tm_discovery_query SET active = true WHERE label LIKE 'seg:%' AND (params->>'endDateTime')::timestamptz > now();

BEGIN;
SET LOCAL lock_timeout = '10s';

UPDATE public.tm_discovery_query SET refresh_hours = 168 WHERE label LIKE 'day:%' AND refresh_hours <> 168;

-- the 39 weekly queries (US, the next 13 weeks, at most 1,000 events each) read events the day queries
-- already read: with them on, a US event in the next 13 weeks was read twice a week. Switched off, not removed.
UPDATE public.tm_discovery_query SET active = false WHERE label LIKE 'seg:%' AND active;

CREATE OR REPLACE FUNCTION public.tm_discovery_plan_days(p_days integer DEFAULT 400)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_new integer;
BEGIN
  INSERT INTO public.tm_discovery_query (label, params, priority, refresh_hours)
  SELECT 'day:' || CASE WHEN c.cc = 'US' THEN '' ELSE c.cc || ':' END || s.seg || ':' || d::date,
         jsonb_build_object('classificationName', s.seg, 'countryCode', c.cc, 'size', '200', 'sort', 'date,asc',
                            'startDateTime', to_char(d, 'YYYY-MM-DD') || 'T00:00:00Z',
                            'endDateTime', to_char(d, 'YYYY-MM-DD') || 'T23:59:59Z'),
         -1000 + (d::date - date '2026-11-19'),          -- the same scale as 20261119011000: sooner days first
         168                                              -- once a week (operator 2026-11-22)
    FROM generate_series(current_date, current_date + greatest(coalesce(p_days, 400), 1) - 1, interval '1 day') d
   CROSS JOIN unnest(ARRAY['Sports', 'Music', 'Arts & Theatre']) s(seg)
   CROSS JOIN unnest(ARRAY['US', 'CA']) c(cc)
  ON CONFLICT (label) DO NOTHING;
  GET DIAGNOSTICS v_new = ROW_COUNT;
  UPDATE public.tm_discovery_query y SET active = false
   WHERE y.active AND y.label LIKE 'day:%' AND public.tm_discovery_query_day(y.params) < current_date;
  RETURN v_new;
END $function$;

CREATE OR REPLACE FUNCTION public.tm_discovery_tick(p_calls integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run    uuid := gen_random_uuid();
  v_key    text;
  q        public.tm_discovery_query;
  v_url    text;
  v_resp   extensions.http_response;
  j        jsonb;
  v_pages  int;
  v_rows   int;
  v_calls  int := 0;
  v_landed int := 0;
  v_events int := 0;
  v_refused int := 0;
  v_errors int := 0;
  v_match  int := 0;
  i        int;
  v_kind   text;                                   -- which budget pays for this call: 'change' or 'discovery'
  v_started timestamptz := clock_timestamp();
  v_change_left boolean;
  v_disc_left   boolean;
  v_change int := 0;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('tm_discovery_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another tm_discovery_tick is running');
  END IF;
  -- tm_discovery_plan(13), the weekly US queries, is no longer called: the day queries read the same events
  PERFORM public.tm_discovery_plan_days(400);

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'TMR CLIENT ID' LIMIT 1;
  IF v_key IS NULL OR length(trim(v_key)) < 16 THEN
    INSERT INTO public.tm_discovery_audit (run_id, action, note) VALUES (v_run, 'refused', 'no usable key in the vault (TMR CLIENT ID)');
    RETURN jsonb_build_object('run_id', v_run, 'error', 'no usable key');
  END IF;
  v_key := trim(v_key);

  INSERT INTO public.tm_discovery_quota (day) VALUES (current_date) ON CONFLICT (day) DO NOTHING;
  SELECT t.change_calls < least(t.change_cap, 250), t.calls < least(t.cap, 1000)
    INTO v_change_left, v_disc_left FROM public.tm_discovery_quota t WHERE t.day = current_date;

  FOR i IN 1..greatest(coalesce(p_calls, 0), 0) LOOP
    -- 60 calls can outlast the cron's statement timeout when Ticketmaster is slow: stop early and keep what landed
    EXIT WHEN clock_timestamp() - v_started > interval '200 seconds';
    v_kind := NULL;

    -- THE CHANGE PASS (operator 2026-11-21: "change cap to 250"; 2026-11-22: "For changes check the same event
    -- only once a week to save tokens"): re-read the day queries (one UTC day, one segment, one country) whose
    -- last complete read is a week old, soonest day first, until the change budget is spent. An event is in
    -- exactly one day query, so it is read again once a week and no more often.
    IF v_change_left THEN
      SELECT * INTO q FROM public.tm_discovery_query y
       WHERE y.active AND y.tries < 10 AND y.label LIKE 'day:%'
         AND (y.last_error_at IS NULL OR y.last_error_at < now() - interval '30 minutes')
         AND public.tm_discovery_query_day(y.params) >= current_date
         AND (y.total_pages IS NOT NULL AND y.page > 0 AND y.page < y.total_pages
              OR y.last_ok_at IS NULL
              OR y.last_ok_at < now() - interval '7 days')
       ORDER BY (y.total_pages IS NOT NULL AND y.page > 0) DESC, public.tm_discovery_query_day(y.params), y.query_id
       LIMIT 1 FOR UPDATE SKIP LOCKED;
      IF FOUND THEN v_kind := 'change'; END IF;
    END IF;

    -- THE DISCOVERY PASS (operator 2026-11-21: "move out discovery cap to 1000"): the most due query, a pass in
    -- progress (past page 0) first, then the stalest complete one past its refresh. Day queries refresh every
    -- 168 hours like the change pass, so this pass takes the days the change budget did not reach that day
    -- and a day query that has never been read (a day that just came inside the horizon).
    IF v_kind IS NULL AND v_disc_left THEN
      SELECT * INTO q FROM public.tm_discovery_query y
       WHERE y.active AND y.tries < 10
         AND (y.last_error_at IS NULL OR y.last_error_at < now() - interval '30 minutes')
         AND (y.total_pages IS NOT NULL AND y.page > 0 AND y.page < y.total_pages
              OR y.last_ok_at IS NULL
              OR y.last_ok_at < now() - make_interval(hours => y.refresh_hours))
       ORDER BY (y.total_pages IS NOT NULL AND y.page > 0) DESC, y.priority, y.last_ok_at NULLS FIRST, y.query_id
       LIMIT 1 FOR UPDATE SKIP LOCKED;
      IF FOUND THEN v_kind := 'discovery'; END IF;
    END IF;
    EXIT WHEN v_kind IS NULL;

    IF NOT public.tm_discovery_call_allowed(v_kind) THEN
      -- that budget is spent for today: note it once and carry on with the other one
      INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
      VALUES (v_run, 'refused', 'tm_discovery_query', q.label, 'daily Discovery ' || v_kind || ' budget reached');
      v_refused := v_refused + 1;
      IF v_kind = 'change' THEN v_change_left := false; ELSE v_disc_left := false; END IF;
      CONTINUE;
    END IF;
    IF v_kind = 'change' THEN v_change := v_change + 1; END IF;
    v_calls := v_calls + 1;

    v_url := 'https://app.ticketmaster.com/discovery/v2/events.json?' ||
             (SELECT string_agg(extensions.urlencode(k) || '=' || extensions.urlencode(v), '&') FROM jsonb_each_text(q.params || jsonb_build_object('page', q.page::text)) kv(k, v)) ||
             '&apikey=' || extensions.urlencode(v_key);
    PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '30000');
    BEGIN
      v_resp := extensions.http(('GET', v_url, ARRAY[]::extensions.http_header[], NULL, NULL)::extensions.http_request);
    EXCEPTION WHEN OTHERS THEN
      v_resp := NULL;
      UPDATE public.tm_discovery_query SET tries = tries + 1, last_error = left('http: ' || SQLERRM, 300), last_error_at = now() WHERE query_id = q.query_id;
      INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note) VALUES (v_run, 'call', 'tm_discovery_query', q.label, 'page ' || q.page || ': http error ' || left(SQLERRM, 200));
      v_errors := v_errors + 1;
      CONTINUE;
    END;
    j := public.safe_jsonb(v_resp.content);
    IF v_resp.status <> 200 OR j IS NULL OR j->'page' IS NULL THEN
      UPDATE public.tm_discovery_query SET tries = tries + 1, last_error = format('http %s %s', v_resp.status, left(coalesce(v_resp.content, ''), 200)), last_error_at = now()
       WHERE query_id = q.query_id;
      INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note) VALUES (v_run, 'call', 'tm_discovery_query', q.label, format('page %s: http %s', q.page, v_resp.status));
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    WITH ev AS (
      SELECT e FROM jsonb_array_elements(coalesce(j->'_embedded'->'events', '[]'::jsonb)) e WHERE coalesce(e->>'id', '') <> ''),
    x AS (
      SELECT ev.e, ev.e->'_embedded'->'venues'->0 AS v, ev.e->'classifications'->0 AS c,
             (SELECT jsonb_agg(jsonb_build_object('id', a->>'id', 'name', a->>'name')) FROM jsonb_array_elements(coalesce(ev.e->'_embedded'->'attractions', '[]'::jsonb)) a) AS attrs,
             (SELECT array_agg(a->>'name') FROM jsonb_array_elements(coalesce(ev.e->'_embedded'->'attractions', '[]'::jsonb)) a WHERE coalesce(a->>'name', '') <> '') AS attr_names
        FROM ev)
    INSERT INTO public.tm_discovery_event AS t (
      tm_event_id, name, url, local_date, local_time, start_utc, date_tbd, time_tba, status_code,
      tm_venue_id, venue_name, venue_city, venue_state, venue_country, venue_timezone,
      attractions, attraction_names, segment, genre, sub_genre, public_onsale, presales, ticket_limit, products, is_product, raw, last_seen_at)
    SELECT x.e->>'id', x.e->>'name', x.e->>'url',
           CASE WHEN x.e->'dates'->'start'->>'localDate' ~ '^\d{4}-\d\d-\d\d$' THEN (x.e->'dates'->'start'->>'localDate')::date END,
           CASE WHEN x.e->'dates'->'start'->>'localTime' ~ '^\d\d:\d\d' THEN (x.e->'dates'->'start'->>'localTime')::time END,
           CASE WHEN x.e->'dates'->'start'->>'dateTime' ~ '^\d{4}-\d\d-\d\dT' THEN (x.e->'dates'->'start'->>'dateTime')::timestamptz END,
           CASE WHEN jsonb_typeof(x.e->'dates'->'start'->'dateTBD') = 'boolean' THEN (x.e->'dates'->'start'->>'dateTBD')::boolean END,
           CASE WHEN jsonb_typeof(x.e->'dates'->'start'->'timeTBA') = 'boolean' THEN (x.e->'dates'->'start'->>'timeTBA')::boolean END,
           x.e->'dates'->'status'->>'code',
           x.v->>'id', x.v->>'name', x.v->'city'->>'name', x.v->'state'->>'stateCode', x.v->'country'->>'countryCode', x.v->>'timezone',
           x.attrs, x.attr_names, x.c->'segment'->>'name', x.c->'genre'->>'name', x.c->'subGenre'->>'name',
           CASE WHEN x.e->'sales'->'public'->>'startDateTime' ~ '^\d{4}-\d\d-\d\dT' THEN (x.e->'sales'->'public'->>'startDateTime')::timestamptz END,
           x.e->'sales'->'presales', x.e->'ticketLimit'->>'info',
           CASE WHEN jsonb_typeof(x.e->'products') = 'array' THEN jsonb_array_length(x.e->'products') END,
           (coalesce(x.e->>'name', '') ~* '(parking|tailgate|package|shuttle|hospitality|\mvip\M|suites?\M|fan fest|meet (and|&) greet)'
            OR coalesce(x.c->'genre'->>'name', '') ~* 'parking' OR coalesce(x.c->'segment'->>'name', '') ~* 'undefined'),
           x.e - '_links' - 'images' - 'seatmap' - 'promoters' - 'promoter' - 'outlets' - 'ageRestrictions' - 'accessibility',
           now()
      FROM x
    ON CONFLICT (tm_event_id) DO UPDATE SET
      name = EXCLUDED.name, url = EXCLUDED.url, local_date = EXCLUDED.local_date, local_time = EXCLUDED.local_time, start_utc = EXCLUDED.start_utc,
      date_tbd = EXCLUDED.date_tbd, time_tba = EXCLUDED.time_tba, status_code = EXCLUDED.status_code,
      tm_venue_id = EXCLUDED.tm_venue_id, venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city, venue_state = EXCLUDED.venue_state,
      venue_country = EXCLUDED.venue_country, venue_timezone = EXCLUDED.venue_timezone,
      attractions = EXCLUDED.attractions, attraction_names = EXCLUDED.attraction_names, segment = EXCLUDED.segment, genre = EXCLUDED.genre, sub_genre = EXCLUDED.sub_genre,
      public_onsale = EXCLUDED.public_onsale, presales = EXCLUDED.presales, ticket_limit = EXCLUDED.ticket_limit, products = EXCLUDED.products, is_product = EXCLUDED.is_product,
      raw = EXCLUDED.raw, last_seen_at = now(),
      tevo_event_id     = CASE WHEN t.local_date IS DISTINCT FROM EXCLUDED.local_date THEN NULL ELSE t.tevo_event_id END,
      tevo_match_method = CASE WHEN t.local_date IS DISTINCT FROM EXCLUDED.local_date THEN NULL ELSE t.tevo_match_method END,
      tevo_matched_at   = CASE WHEN t.local_date IS DISTINCT FROM EXCLUDED.local_date THEN NULL ELSE t.tevo_matched_at END;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_pages := least(coalesce((j->'page'->>'totalPages')::int, 1), 5);
    UPDATE public.tm_discovery_query y
       SET total_pages = v_pages, events_seen = CASE WHEN q.page = 0 THEN v_rows ELSE y.events_seen + v_rows END,
           page = CASE WHEN q.page + 1 >= v_pages THEN 0 ELSE q.page + 1 END,
           last_ok_at = CASE WHEN q.page + 1 >= v_pages THEN now() ELSE y.last_ok_at END,
           last_page_at = now(), tries = 0, last_error = NULL
     WHERE y.query_id = q.query_id;
    INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
    VALUES (v_run, 'call', 'tm_discovery_query', q.label, format('page %s of %s: %s events', q.page + 1, v_pages, v_rows));
    v_landed := v_landed + 1; v_events := v_events + v_rows;
  END LOOP;

  IF v_landed > 0 THEN v_match := public.tm_discovery_match(5000); END IF;
  RETURN jsonb_build_object('run_id', v_run, 'calls', v_calls, 'change_calls', v_change, 'landed', v_landed, 'events', v_events, 'errors', v_errors,
                            'refused', v_refused, 'matched', v_match,
                            'budget_today', (SELECT jsonb_build_object('discovery_calls', calls, 'discovery_cap', least(cap, 1000),
                                                                       'change_calls', change_calls, 'change_cap', least(change_cap, 250), 'refused', refused)
                                               FROM public.tm_discovery_quota WHERE day = current_date));
END $function$;

REVOKE ALL ON FUNCTION public.tm_discovery_plan_days(integer), public.tm_discovery_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tm_discovery_plan_days(integer), public.tm_discovery_tick(integer) TO service_role;

COMMIT;

-- VERIFY: SELECT refresh_hours, count(*) FROM tm_discovery_query WHERE label LIKE 'day:%' GROUP BY 1;
--   SELECT day, calls, change_calls FROM tm_discovery_quota ORDER BY day DESC LIMIT 8;   -- about 2,700 a week in all
