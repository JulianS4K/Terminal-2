-- Migration 20261121223530 · level:data-collection · lane:A1 (data plane — mapping program; routed to this session by the operator) · writes:tm_discovery_quota(+change_calls,+change_cap,cap check),tm_discovery_query(day: rows refresh_hours),tm_discovery_query_day(new),tm_discovery_rounds_left(new),tm_discovery_call_allowed(text)(new),tm_discovery_call_allowed(),tm_discovery_plan_days(new),tm_discovery_tick(),cron:tm_discovery_tick_hourly(command) · reads:vault.decrypted_secrets('TMR CLIENT ID'),app.ticketmaster.com/discovery/v2 (GET) · pre:20261119011000,20261121171530
--
-- THE TICKETMASTER COLLECTOR RE-READS EVENTS, SO A CHANGE IS FOUND.
-- Operator 2026-11-21: "Fix the tm event discovery to detect for changes, but first move out discovery cap to
-- 1000, and change cap to 250".
--
-- BEFORE. Discovery has no "changed since" call: a cancellation or a moved time is seen only when the event is
-- read again and differs from our copy (the trigger of 20261121171530 then logs it to tm_discovery_change). But
-- the 2,400 day-by-day queries of 2026-11-19 ran once and were never due again, and the 39 weekly queries re-read
-- the next 13 weeks once a week, US only and at most 1,000 events each, under 100 calls a day. From 2026-11-19
-- 02:26 UTC to this migration nothing was read at all, so no change could be found.
--
-- NOW. Two budgets a UTC day, counted before every call as before, each a ceiling in code that data cannot raise:
--   change     250 calls. The day queries nearest to now, soonest first: today and tomorrow every 6 hours (four
--              rounds a UTC day; what the later rounds need is kept back), later days every 20 hours with
--              what is left. On 2026-11-21 today and tomorrow cost 14 calls each, so the four rounds take
--              about 112 and the rest re-reads about the next two weeks once a day.
--   discovery  1,000 calls (was 100). Every day query is due again 72 hours after its last complete read,
--              soonest day first. One pass over the 400 days is about 2,700 calls, so the whole horizon, US and
--              Canada, is read again about every three days: new events are found and changes further out too.
-- The horizon rolls: each tick adds the day queries that have come inside 400 days and switches off the days
-- that are over (tm_discovery_plan_days). The weekly queries are left as they are.
-- The hourly cron keeps its minute (:27) and now asks for up to 60 calls a run instead of 4 (1,440 a day at
-- most, above the two budgets together). A run stops by itself after 200 seconds so a slow Ticketmaster cannot
-- push it past the cron's 300-second limit and undo what it landed.
-- Ticketmaster's own quota is 5,000 calls a rolling day; 1,250 is ours.
--
-- NOT CHANGED: what is read (GET /discovery/v2/events.json, the same parameters, the key only in the request),
-- how an event is stored, and the matcher. GET only (RULE 2).
-- Known limit, unchanged: Discovery returns at most 1,000 events for one query. 8 of the 2,400 day queries hit
-- it on 2026-11-19; the events past the first 1,000 of such a day are not read.
--
-- rollback: UPDATE tm_discovery_query SET refresh_hours = 876000 WHERE label LIKE 'day:%';
--           SELECT cron.alter_job(jobid, command := replace(command, 'tm_discovery_tick(60)', 'tm_discovery_tick(4)'))
--             FROM cron.job WHERE jobname = 'tm_discovery_tick_hourly';
--           re-apply tm_discovery_call_allowed() and tm_discovery_tick() from 20261119011000.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. the two budgets ─────────────────────────
ALTER TABLE public.tm_discovery_quota DROP CONSTRAINT IF EXISTS tm_discovery_quota_cap_check;
ALTER TABLE public.tm_discovery_quota ADD CONSTRAINT tm_discovery_quota_cap_check CHECK (cap BETWEEN 0 AND 1000);
ALTER TABLE public.tm_discovery_quota ALTER COLUMN cap SET DEFAULT 1000;
ALTER TABLE public.tm_discovery_quota ADD COLUMN IF NOT EXISTS change_calls int NOT NULL DEFAULT 0;
ALTER TABLE public.tm_discovery_quota ADD COLUMN IF NOT EXISTS change_cap int NOT NULL DEFAULT 250 CHECK (change_cap BETWEEN 0 AND 250);
UPDATE public.tm_discovery_quota SET cap = 1000 WHERE day = current_date;
COMMENT ON TABLE public.tm_discovery_quota IS 'Ticketmaster Discovery GET calls per UTC day, in two budgets: calls / cap for the discovery pass (ceiling 1,000) and change_calls / change_cap for the change pass (ceiling 250). tm_discovery_call_allowed(kind) counts before every call and refuses at the ceiling (operator 2026-11-21). Migs 20261117180000, 20261121223530.';

-- the UTC day a day query reads (NULL for any other query)
CREATE OR REPLACE FUNCTION public.tm_discovery_query_day(p_params jsonb)
 RETURNS date
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT CASE WHEN p_params->>'startDateTime' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' THEN left(p_params->>'startDateTime', 10)::date END
$function$;

-- how many of the day's four 6-hour rounds (00, 06, 12, 18 UTC) are still to come after the one p_at is in
CREATE OR REPLACE FUNCTION public.tm_discovery_rounds_left(p_at timestamp with time zone)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT greatest(ceil((24 - extract(hour FROM p_at AT TIME ZONE 'utc')) / 6.0)::int - 1, 0)
$function$;

CREATE OR REPLACE FUNCTION public.tm_discovery_call_allowed(p_kind text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ok boolean;
BEGIN
  INSERT INTO public.tm_discovery_quota (day) VALUES (current_date) ON CONFLICT (day) DO NOTHING;
  IF p_kind = 'change' THEN
    UPDATE public.tm_discovery_quota q
       SET change_calls = q.change_calls + 1, last_call_at = now()
     WHERE q.day = current_date AND q.change_calls < least(q.change_cap, 250)   -- 250 is the ceiling whatever the row says
    RETURNING true INTO v_ok;
  ELSE
    UPDATE public.tm_discovery_quota q
       SET calls = q.calls + 1, last_call_at = now()
     WHERE q.day = current_date AND q.calls < least(q.cap, 1000)                -- 1,000 is the ceiling whatever the row says
    RETURNING true INTO v_ok;
  END IF;
  IF v_ok IS NULL THEN
    UPDATE public.tm_discovery_quota SET refused = refused + 1 WHERE day = current_date;
    RETURN false;
  END IF;
  RETURN true;
END $function$;

-- the name the collector called before this migration: the discovery budget
CREATE OR REPLACE FUNCTION public.tm_discovery_call_allowed()
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT public.tm_discovery_call_allowed('discovery')
$function$;

-- ───────────────────────── 2. the day queries roll, and come due again ─────────────────────────
-- one query per segment per UTC day per country (US, CA) for the next p_days days; days that are over go inactive
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
         72
    FROM generate_series(current_date, current_date + greatest(coalesce(p_days, 400), 1) - 1, interval '1 day') d
   CROSS JOIN unnest(ARRAY['Sports', 'Music', 'Arts & Theatre']) s(seg)
   CROSS JOIN unnest(ARRAY['US', 'CA']) c(cc)
  ON CONFLICT (label) DO NOTHING;
  GET DIAGNOSTICS v_new = ROW_COUNT;
  UPDATE public.tm_discovery_query y SET active = false
   WHERE y.active AND y.label LIKE 'day:%' AND public.tm_discovery_query_day(y.params) < current_date;
  RETURN v_new;
END $function$;

-- the day queries of 2026-11-19 were set never to run again; now they come due every 72 hours
UPDATE public.tm_discovery_query SET refresh_hours = 72 WHERE label LIKE 'day:%' AND refresh_hours > 72;

-- ───────────────────────── 3. the tick: a change pass, then the discovery pass ─────────────────────────
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
  v_change_used int;                               -- change calls already counted today, before this run
  v_reserve int;                                   -- change calls kept back for today's remaining 6-hour rounds
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('tm_discovery_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another tm_discovery_tick is running');
  END IF;
  PERFORM public.tm_discovery_plan(13);
  PERFORM public.tm_discovery_plan_days(400);

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'TMR CLIENT ID' LIMIT 1;
  IF v_key IS NULL OR length(trim(v_key)) < 16 THEN
    INSERT INTO public.tm_discovery_audit (run_id, action, note) VALUES (v_run, 'refused', 'no usable key in the vault (TMR CLIENT ID)');
    RETURN jsonb_build_object('run_id', v_run, 'error', 'no usable key');
  END IF;
  v_key := trim(v_key);

  INSERT INTO public.tm_discovery_quota (day) VALUES (current_date) ON CONFLICT (day) DO NOTHING;
  SELECT t.change_calls < least(t.change_cap, 250), t.calls < least(t.cap, 1000), t.change_calls
    INTO v_change_left, v_disc_left, v_change_used FROM public.tm_discovery_quota t WHERE t.day = current_date;
  -- today and tomorrow are re-read every 6 hours. What those rounds still need today is kept back, so the
  -- once-a-day re-reads of later days cannot spend the change budget before the afternoon rounds come.
  SELECT coalesce(sum(greatest(coalesce(y.total_pages, 1), 1)), 0)::int
         * public.tm_discovery_rounds_left(now())
    INTO v_reserve FROM public.tm_discovery_query y
   WHERE y.active AND y.label LIKE 'day:%' AND public.tm_discovery_query_day(y.params) BETWEEN current_date AND current_date + 1;

  FOR i IN 1..greatest(coalesce(p_calls, 0), 0) LOOP
    -- 60 calls can outlast the cron's statement timeout when Ticketmaster is slow: stop early and keep what landed
    EXIT WHEN clock_timestamp() - v_started > interval '200 seconds';
    v_kind := NULL;

    -- THE CHANGE PASS (operator 2026-11-21: "change cap to 250"): re-read the days nearest to now, so a
    -- cancellation or a moved time is seen soon. A day query (one UTC day, one segment, one country) for today or
    -- tomorrow is due every 6 hours, one for a later day every 20 hours; soonest day first. A later day is read
    -- only while the budget, less the reserve for today's remaining 6-hour rounds, allows. Days this pass does
    -- not reach are still re-read by the discovery pass below.
    IF v_change_left THEN
      SELECT * INTO q FROM public.tm_discovery_query y
       WHERE y.active AND y.tries < 10 AND y.label LIKE 'day:%'
         AND (y.last_error_at IS NULL OR y.last_error_at < now() - interval '30 minutes')
         AND public.tm_discovery_query_day(y.params) BETWEEN current_date AND current_date + 60
         AND (public.tm_discovery_query_day(y.params) <= current_date + 1
              OR v_change_used + v_change < (SELECT least(t.change_cap, 250) FROM public.tm_discovery_quota t WHERE t.day = current_date) - v_reserve)
         AND (y.total_pages IS NOT NULL AND y.page > 0 AND y.page < y.total_pages
              OR y.last_ok_at IS NULL
              OR y.last_ok_at < now() - CASE WHEN public.tm_discovery_query_day(y.params) <= current_date + 1
                                             THEN interval '6 hours' ELSE interval '20 hours' END)
       ORDER BY (y.total_pages IS NOT NULL AND y.page > 0) DESC, public.tm_discovery_query_day(y.params), y.query_id
       LIMIT 1 FOR UPDATE SKIP LOCKED;
      IF FOUND THEN v_kind := 'change'; END IF;
    END IF;

    -- THE DISCOVERY PASS (operator 2026-11-21: "move out discovery cap to 1000"): the most due query, a pass in
    -- progress (past page 0) first, then the stalest complete one past its refresh. Day queries refresh every
    -- 72 hours, soonest day first, so the whole 400-day horizon is read again about every three days.
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

REVOKE ALL ON FUNCTION public.tm_discovery_query_day(jsonb), public.tm_discovery_rounds_left(timestamp with time zone), public.tm_discovery_call_allowed(text), public.tm_discovery_call_allowed(),
  public.tm_discovery_plan_days(integer), public.tm_discovery_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tm_discovery_query_day(jsonb), public.tm_discovery_rounds_left(timestamp with time zone), public.tm_discovery_call_allowed(text), public.tm_discovery_call_allowed(),
  public.tm_discovery_plan_days(integer), public.tm_discovery_tick(integer) TO service_role;

-- ───────────────────────── 4. the hourly cron asks for up to 60 calls ─────────────────────────
-- same job, same minute; only the number of calls a run may make changes (4 -> 60)
DO $do$
BEGIN
  IF to_regclass('cron.job') IS NULL THEN
    RAISE NOTICE 'pg_cron is not here: tm_discovery_tick_hourly is not changed';
    RETURN;
  END IF;
  PERFORM cron.alter_job(j.jobid, command := replace(j.command, 'tm_discovery_tick(4)', 'tm_discovery_tick(60)'))
     FROM cron.job j WHERE j.jobname = 'tm_discovery_tick_hourly' AND j.command LIKE '%tm_discovery_tick(4)%';
END
$do$;

COMMIT;

-- VERIFY: SELECT day, calls, cap, change_calls, change_cap, refused FROM tm_discovery_quota ORDER BY day DESC LIMIT 3;
--   SELECT command FROM cron.job WHERE jobname = 'tm_discovery_tick_hourly';
--   SELECT kind, count(*) FROM tm_discovery_change GROUP BY 1;
