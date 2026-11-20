-- Migration 20261118001000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tm_discovery_quota(+burst_calls,tm_limit,tm_available,tm_reset_at),tm_discovery_tick()(replaced: p_burst, p_seconds, TM's own counters read from the response),tm_discovery_burst_allowed()(new),tm_discovery_plan_states()(new),tm_discovery_burst(new),tm_discovery_burst_tick()(new),cron:tm_discovery_burst_1min(new, one-shot: removes itself) · reads:vault.decrypted_secrets('TMR CLIENT ID'),app.ticketmaster.com/discovery/v2 (GET, pgsql-http) · pre:20261117190000
--
-- MAPPING PROGRAM — TICKETMASTER DISCOVERY: ONE BURN-DOWN HOUR, ONCE, UNDER TICKETMASTER'S OWN COUNTER.
--
-- Operator 2026-11-18 22:2xZ: "if an hour before quota reset there is over 4000 calls remaining use them all to
-- poll more events" — "just once today". Ticketmaster's answer to a probe GET at 22:22Z carried its own counters:
-- Rate-Limit 5000, Rate-Limit-Available 4992, Rate-Limit-Reset 2026-11-19 06:25:48Z. So the window is
-- 05:25–06:24:30Z on 2026-11-19, and the test is Ticketmaster's number, not ours.
--
-- The 100-a-day code budget (mig 20261117180000) is NOT changed: `tm_discovery_call_allowed()` still counts the
-- hourly drip and refuses at 100. The burst is a second, separately counted path (`burst_calls`), allowed only
-- while the `Rate-Limit-Available` header Ticketmaster sent on the previous response is above a reserve of 10,
-- and only by `tm_discovery_burst_tick()` inside the one window in `tm_discovery_burst` (a single row, done once).
--
-- What this migration does (all GET, all read-only upstream — RULE 2; the key still travels only in the request):
--   1. `tm_discovery_quota` learns Ticketmaster's counters: `tm_limit`, `tm_available`, `tm_reset_at` are read from
--      the Rate-Limit-* headers of EVERY response the tick gets (drip or burst) and kept on today's row;
--      `burst_calls` counts the burst separately from the drip's `calls`.
--   2. `tm_discovery_tick(p_calls, p_burst = false, p_seconds = 240)`: as before for the drip (the one-argument call
--      the hourly cron makes resolves to it). With p_burst the per-call gate is `tm_discovery_burst_allowed()`
--      (TM's available > 10) instead of the daily budget, a 50 ms pause keeps under TM's 5 requests a second, the
--      state plan is extended first, and the match is left to the hourly tick (a per-minute run must not time out
--      and roll back pages that were paid for). Either mode stops after p_seconds.
--   3. `tm_discovery_plan_states(p_weeks)`: the queries that give a burst something to fetch — the three segments ×
--      13 weeks × the 50 US states + DC (`stateCode`), and Canada nationally; priority after the national queries.
--      Discovery caps size × page at 1,000, so a national segment-week can never show more than 1,000 events; the
--      state cut is how the rest of the catalogue is reached. The queries stay: the drip works through them after.
--   4. `tm_discovery_burst_tick()` + cron `tm_discovery_burst_1min` ('* 5,6 * * *'): waits for the window; at its
--      start reads Ticketmaster's available count (a one-call probe through the drip if the last reading is older
--      than two hours); arms only when it is above `min_available` (4000); then each minute spends
--      ceil(remaining / minutes left) + 5 calls, at most 150, for at most 45 s. At the window's end — or when it
--      does not arm — it marks the row done and UNSCHEDULES ITSELF. Nothing of this runs again unless an operator
--      inserts another window row and schedules the job again.
--
-- Apply: `BEGIN;` / `COMMIT;` stripped; between Discovery ticks (:27). Harness: tests/sql/tm_discovery (section F).

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. Ticketmaster's own counters on the quota row ─────────────────────────
ALTER TABLE public.tm_discovery_quota
  ADD COLUMN IF NOT EXISTS burst_calls  int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tm_limit     int,
  ADD COLUMN IF NOT EXISTS tm_available int,
  ADD COLUMN IF NOT EXISTS tm_reset_at  timestamptz;
COMMENT ON COLUMN public.tm_discovery_quota.burst_calls IS 'Calls made by the one-time burst path (tm_discovery_burst_tick), counted apart from the drip''s 100-a-day `calls`. Mig 20261118001000.';
COMMENT ON COLUMN public.tm_discovery_quota.tm_available IS 'Ticketmaster''s Rate-Limit-Available header from the last response — its count of the key''s calls left before tm_reset_at. Mig 20261118001000.';

-- the burst gate: Ticketmaster's own count of what is left, above a reserve of 10; counted as a burst call
CREATE OR REPLACE FUNCTION public.tm_discovery_burst_allowed()
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ok boolean;
BEGIN
  INSERT INTO public.tm_discovery_quota (day) VALUES (current_date) ON CONFLICT (day) DO NOTHING;
  UPDATE public.tm_discovery_quota q
     SET burst_calls = q.burst_calls + 1, last_call_at = now(), tm_available = q.tm_available - 1
   WHERE q.day = current_date AND q.tm_available > 10
  RETURNING true INTO v_ok;
  IF v_ok IS NULL THEN
    UPDATE public.tm_discovery_quota SET refused = refused + 1 WHERE day = current_date;
    RETURN false;
  END IF;
  RETURN true;
END $function$;
COMMENT ON FUNCTION public.tm_discovery_burst_allowed() IS 'The burst path''s per-call gate: Ticketmaster''s own Rate-Limit-Available (as last reported, decremented per call) must be above 10. Counts burst_calls; a refusal is counted too. Mig 20261118001000.';

-- ───────────────────────── 2. the state plan ─────────────────────────
CREATE OR REPLACE FUNCTION public.tm_discovery_plan_states(p_weeks integer DEFAULT 13)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int;
BEGIN
  WITH weeks AS (
    SELECT (date_trunc('week', current_date::timestamp)::date + 7 * w) AS wk, w FROM generate_series(0, greatest(p_weeks, 1) - 1) w),
  segs AS (SELECT unnest(ARRAY['Sports', 'Music', 'Arts & Theatre']) AS seg),
  places AS (
    SELECT 'US' AS cc, unnest(ARRAY['AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO',
                                     'MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY']) AS st
    UNION ALL SELECT 'CA', NULL),
  ins AS (
    INSERT INTO public.tm_discovery_query (label, params, priority)
    SELECT CASE WHEN p.st IS NULL THEN 'ca:' || s.seg || ':' || w.wk ELSE 'st:' || s.seg || ':' || p.st || ':' || w.wk END,
           jsonb_build_object('classificationName', s.seg, 'countryCode', p.cc, 'size', '200', 'sort', 'date,asc',
                              'startDateTime', to_char(w.wk, 'YYYY-MM-DD') || 'T00:00:00Z',
                              'endDateTime', to_char(w.wk + 6, 'YYYY-MM-DD') || 'T23:59:59Z')
             || CASE WHEN p.st IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('stateCode', p.st) END,
           CASE WHEN p.st IS NULL THEN 8 ELSE 9 END + CASE WHEN s.seg = 'Sports' THEN 0 ELSE 1 END + w.w   -- after the national queries; sooner weeks first
      FROM segs s CROSS JOIN weeks w CROSS JOIN places p
    ON CONFLICT (label) DO NOTHING
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  UPDATE public.tm_discovery_query q SET active = false
   WHERE q.active AND (q.label LIKE 'st:%' OR q.label LIKE 'ca:%') AND (q.params->>'endDateTime')::timestamptz < now() - interval '1 day';
  RETURN v_n;
END $function$;
COMMENT ON FUNCTION public.tm_discovery_plan_states(integer) IS 'Discovery queries per segment × week × US state (+ Canada nationally), priority after the national plan — what a burst spends its calls on; the drip works through them afterwards. Mig 20261118001000.';

-- ───────────────────────── 3. the tick: drip or burst, Ticketmaster's counters read from every response ─────────────────────────
DROP FUNCTION IF EXISTS public.tm_discovery_tick(integer);
CREATE OR REPLACE FUNCTION public.tm_discovery_tick(p_calls integer DEFAULT 4, p_burst boolean DEFAULT false, p_seconds integer DEFAULT 240)
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
  v_t0     timestamptz := clock_timestamp();
  v_avail  int;
  v_limit  int;
  v_reset  timestamptz;
  i        int;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('tm_discovery_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another tm_discovery_tick is running');
  END IF;
  PERFORM public.tm_discovery_plan(13);
  IF p_burst THEN PERFORM public.tm_discovery_plan_states(13); END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'TMR CLIENT ID' LIMIT 1;
  IF v_key IS NULL OR length(trim(v_key)) < 16 THEN
    INSERT INTO public.tm_discovery_audit (run_id, action, note) VALUES (v_run, 'refused', 'no usable key in the vault (TMR CLIENT ID)');
    RETURN jsonb_build_object('run_id', v_run, 'error', 'no usable key');
  END IF;
  v_key := trim(v_key);

  FOR i IN 1..greatest(coalesce(p_calls, 0), 0) LOOP
    EXIT WHEN clock_timestamp() - v_t0 > make_interval(secs => greatest(coalesce(p_seconds, 240), 1));
    -- the most due query: a pass in progress first, then the stalest complete one past its refresh
    SELECT * INTO q FROM public.tm_discovery_query y
     WHERE y.active AND y.tries < 10
       AND (y.last_error_at IS NULL OR y.last_error_at < now() - interval '30 minutes')
       AND (y.total_pages IS NOT NULL AND y.page < y.total_pages
            OR y.last_ok_at IS NULL
            OR y.last_ok_at < now() - make_interval(hours => y.refresh_hours))
     ORDER BY (y.total_pages IS NOT NULL AND y.page > 0) DESC, y.priority, y.last_ok_at NULLS FIRST, y.query_id
     LIMIT 1 FOR UPDATE SKIP LOCKED;
    EXIT WHEN NOT FOUND;

    IF p_burst THEN
      -- the burst: Ticketmaster's own count of what is left must be above the reserve (mig 20261118001000)
      IF NOT public.tm_discovery_burst_allowed() THEN
        INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
        VALUES (v_run, 'refused', 'tm_discovery_query', q.label, 'burst: Ticketmaster reports no more than the reserve of 10 calls left');
        v_refused := v_refused + 1;
        EXIT;
      END IF;
      PERFORM pg_sleep(0.05);                                                    -- under TM's 5 requests a second
    ELSIF NOT public.tm_discovery_call_allowed() THEN
      INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
      VALUES (v_run, 'refused', 'tm_discovery_query', q.label, 'daily budget of 100 Discovery calls reached');
      v_refused := v_refused + 1;
      EXIT;
    END IF;
    v_calls := v_calls + 1;

    -- the request: the key travels only here
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
    -- Ticketmaster's counters, from every response (mig 20261118001000)
    SELECT max(CASE WHEN lower(h.field) = 'rate-limit-available' THEN h.value::int END),
           max(CASE WHEN lower(h.field) = 'rate-limit' THEN h.value::int END),
           max(CASE WHEN lower(h.field) = 'rate-limit-reset' THEN to_timestamp(h.value::numeric / 1000) END)
      INTO v_avail, v_limit, v_reset
      FROM unnest(coalesce(v_resp.headers, ARRAY[]::extensions.http_header[])) h
     WHERE h.value ~ '^\d+$';
    IF v_avail IS NOT NULL THEN
      INSERT INTO public.tm_discovery_quota (day) VALUES (current_date) ON CONFLICT (day) DO NOTHING;
      UPDATE public.tm_discovery_quota SET tm_available = v_avail, tm_limit = coalesce(v_limit, tm_limit), tm_reset_at = coalesce(v_reset, tm_reset_at) WHERE day = current_date;
    END IF;
    j := public.safe_jsonb(v_resp.content);
    IF v_resp.status <> 200 OR j IS NULL OR j->'page' IS NULL THEN
      UPDATE public.tm_discovery_query SET tries = tries + 1, last_error = format('http %s %s', v_resp.status, left(coalesce(v_resp.content, ''), 200)), last_error_at = now()
       WHERE query_id = q.query_id;
      INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note) VALUES (v_run, 'call', 'tm_discovery_query', q.label, format('page %s: http %s', q.page, v_resp.status));
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    -- land the page
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
      -- an event whose local date moved is matched again
      tevo_event_id     = CASE WHEN t.local_date IS DISTINCT FROM EXCLUDED.local_date THEN NULL ELSE t.tevo_event_id END,
      tevo_match_method = CASE WHEN t.local_date IS DISTINCT FROM EXCLUDED.local_date THEN NULL ELSE t.tevo_match_method END,
      tevo_matched_at   = CASE WHEN t.local_date IS DISTINCT FROM EXCLUDED.local_date THEN NULL ELSE t.tevo_matched_at END;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_pages := least(coalesce((j->'page'->>'totalPages')::int, 1), 5);      -- Discovery refuses size × page beyond 1,000
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

  -- the match: the drip's business; a burst run leaves it to the hourly tick (a per-minute run that timed out
  -- would roll back pages already paid for)
  IF v_landed > 0 AND NOT p_burst THEN v_match := public.tm_discovery_match(5000); END IF;
  RETURN jsonb_build_object('run_id', v_run, 'burst', p_burst, 'calls', v_calls, 'landed', v_landed, 'events', v_events, 'errors', v_errors, 'refused', v_refused, 'matched', v_match,
                            'seconds', round(extract(epoch FROM clock_timestamp() - v_t0))::int,
                            'budget_today', (SELECT jsonb_build_object('calls', calls, 'burst_calls', burst_calls, 'refused', refused, 'cap', least(cap, 100),
                                                                       'tm_available', tm_available, 'tm_limit', tm_limit, 'tm_reset_at', tm_reset_at)
                                               FROM public.tm_discovery_quota WHERE day = current_date));
END $function$;
COMMENT ON FUNCTION public.tm_discovery_tick(integer, boolean, integer) IS
  'One step of the Ticketmaster Discovery collector: up to p_calls GETs (each the next page of the most due query), for at most p_seconds. The drip (p_burst false, the hourly cron) is gated by tm_discovery_call_allowed() — 100 a day; a burst (p_burst true, only tm_discovery_burst_tick inside its one window) by tm_discovery_burst_allowed() — Ticketmaster''s own Rate-Limit-Available above 10, read from every response. The key travels only in the request. Migs 20261117180000 / 20261118001000.';

-- ───────────────────────── 4. the one window ─────────────────────────
CREATE TABLE IF NOT EXISTS public.tm_discovery_burst (
  id             int PRIMARY KEY CHECK (id = 1),
  window_start   timestamptz NOT NULL,
  window_end     timestamptz NOT NULL,
  min_available  int NOT NULL DEFAULT 4000,        -- arm only when Ticketmaster reports more than this left
  max_per_minute int NOT NULL DEFAULT 150,
  armed          boolean NOT NULL DEFAULT false,
  armed_at       timestamptz,
  available_at_arm int,
  done           boolean NOT NULL DEFAULT false,
  done_at        timestamptz,
  done_reason    text,
  runs           int NOT NULL DEFAULT 0,
  calls          int NOT NULL DEFAULT 0,
  events         int NOT NULL DEFAULT 0,
  last_result    jsonb,
  note           text
);
COMMENT ON TABLE public.tm_discovery_burst IS 'The one Ticketmaster Discovery burn-down window (operator 2026-11-18: "if an hour before quota reset there is over 4000 calls remaining use them all to poll more events" — "just once today"). One row; tm_discovery_burst_tick() runs it and removes its own cron when it is done. Mig 20261118001000.';
INSERT INTO public.tm_discovery_burst (id, window_start, window_end, note)
VALUES (1, '2026-11-19 05:25:00+00', '2026-11-19 06:24:30+00', 'Ticketmaster Rate-Limit-Reset 2026-11-19 06:25:48Z (probe at 22:22Z: 4992 of 5000 left); operator 2026-11-18, once')
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.tm_discovery_burst_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  b        public.tm_discovery_burst;
  v_avail  int;
  v_read   timestamptz;
  v_mins   int;
  v_n      int;
  v_res    jsonb;
BEGIN
  SELECT * INTO b FROM public.tm_discovery_burst WHERE id = 1 FOR UPDATE;
  IF NOT FOUND OR b.done THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tm_discovery_burst_1min') THEN PERFORM cron.unschedule('tm_discovery_burst_1min'); END IF;
    RETURN jsonb_build_object('state', 'done');
  END IF;
  IF now() < b.window_start THEN RETURN jsonb_build_object('state', 'waiting', 'window_start', b.window_start); END IF;
  IF now() >= b.window_end THEN
    UPDATE public.tm_discovery_burst SET done = true, done_at = now(), done_reason = CASE WHEN b.armed THEN 'window closed' ELSE 'window closed without arming' END WHERE id = 1;
    INSERT INTO public.tm_discovery_audit (run_id, action, note) VALUES (gen_random_uuid(), 'burst', format('window closed: %s runs, %s calls, %s events', b.runs, b.calls, b.events));
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tm_discovery_burst_1min') THEN PERFORM cron.unschedule('tm_discovery_burst_1min'); END IF;
    RETURN jsonb_build_object('state', 'closed', 'runs', b.runs, 'calls', b.calls, 'events', b.events);
  END IF;

  -- in the window: Ticketmaster's count of what is left, read within the last two hours — else one probe call through the drip
  SELECT tm_available, last_call_at INTO v_avail, v_read FROM public.tm_discovery_quota WHERE day = current_date;
  IF NOT b.armed AND (v_avail IS NULL OR v_read IS NULL OR v_read < now() - interval '2 hours') THEN
    v_res := public.tm_discovery_tick(1, false, 20);
    SELECT tm_available INTO v_avail FROM public.tm_discovery_quota WHERE day = current_date;
    IF v_avail IS NULL THEN
      UPDATE public.tm_discovery_burst SET runs = runs + 1, last_result = jsonb_build_object('state', 'no reading', 'probe', v_res) WHERE id = 1;
      RETURN jsonb_build_object('state', 'no reading', 'probe', v_res - 'run_id');
    END IF;
  END IF;
  IF NOT b.armed THEN
    IF v_avail <= b.min_available THEN
      UPDATE public.tm_discovery_burst SET done = true, done_at = now(), done_reason = format('not armed: Ticketmaster reports %s left, the rule needs more than %s', v_avail, b.min_available), runs = runs + 1 WHERE id = 1;
      INSERT INTO public.tm_discovery_audit (run_id, action, note) VALUES (gen_random_uuid(), 'burst', format('not armed: %s left, more than %s needed', v_avail, b.min_available));
      IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tm_discovery_burst_1min') THEN PERFORM cron.unschedule('tm_discovery_burst_1min'); END IF;
      RETURN jsonb_build_object('state', 'not armed', 'available', v_avail, 'min_available', b.min_available);
    END IF;
    UPDATE public.tm_discovery_burst SET armed = true, armed_at = now(), available_at_arm = v_avail WHERE id = 1;
    INSERT INTO public.tm_discovery_audit (run_id, action, note) VALUES (gen_random_uuid(), 'burst', format('armed: Ticketmaster reports %s left until %s', v_avail, (SELECT tm_reset_at FROM public.tm_discovery_quota WHERE day = current_date)));
  END IF;

  -- spend: the remainder spread over the minutes left, a little ahead, capped per minute and at 45 seconds
  v_mins := greatest(1, ceil(extract(epoch FROM b.window_end - now()) / 60)::int);
  v_n := least(b.max_per_minute, greatest(1, ceil((v_avail - 10)::numeric / v_mins)::int + 5));
  v_res := public.tm_discovery_tick(v_n, true, 45);
  UPDATE public.tm_discovery_burst
     SET runs = runs + 1, calls = calls + coalesce((v_res->>'calls')::int, 0), events = events + coalesce((v_res->>'events')::int, 0), last_result = v_res - 'run_id'
   WHERE id = 1;
  RETURN jsonb_build_object('state', 'spending', 'asked', v_n, 'minutes_left', v_mins) || (v_res - 'run_id');
END $function$;
COMMENT ON FUNCTION public.tm_discovery_burst_tick() IS 'Runs the one burn-down window in tm_discovery_burst each minute: waits, arms when Ticketmaster reports more than min_available left, spends the remainder evenly (≤ max_per_minute a run, 45 s), and at the window''s end marks the row done and unschedules its own cron. Mig 20261118001000.';

REVOKE ALL ON public.tm_discovery_burst FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.tm_discovery_burst TO service_role;
REVOKE ALL ON FUNCTION public.tm_discovery_burst_allowed(), public.tm_discovery_plan_states(integer), public.tm_discovery_tick(integer, boolean, integer), public.tm_discovery_burst_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tm_discovery_burst_allowed(), public.tm_discovery_plan_states(integer), public.tm_discovery_tick(integer, boolean, integer), public.tm_discovery_burst_tick() TO service_role;

-- ───────────────────────── 5. the one-shot cron: every minute of 05:00–06:59Z, gone when the window is done ─────────────────────────
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tm_discovery_burst_1min') THEN PERFORM cron.unschedule('tm_discovery_burst_1min'); END IF;
  PERFORM cron.schedule('tm_discovery_burst_1min', '* 5,6 * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '240s'; SELECT public.tm_discovery_burst_tick(); COMMIT;$j$);
END
$cron$;

COMMIT;
