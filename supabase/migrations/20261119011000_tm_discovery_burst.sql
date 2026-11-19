-- Migration 20261119011000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tm_discovery_call_allowed(),tm_discovery_tick(),tm_discovery_query(+day: rows),cron:tm_discovery_burst(temporary) · reads:vault.decrypted_secrets('TMR CLIENT ID'),app.ticketmaster.com/discovery/v2 (GET) · pre:20261118223540
--
-- Operator 2026-11-19 ~01:10 UTC: "use all 5000 only today, use em and map em".
--
-- 1. LOOP FIX. tm_discovery_tick() picked "a pass in progress" as total_pages IS NOT NULL AND page < total_pages.
--    A finished pass resets page to 0 but keeps total_pages, so the query it just finished matched again at once:
--    from 2026-11-18 21:30 to 2026-11-19 00:27 every call re-read seg:Sports:2026-11-16 (3 passes, 14 calls) and
--    the other 38 queries never ran. A pass is now in progress only past page 0.
--
-- 2. ONE-DAY BUDGET. tm_discovery_call_allowed() allows 4,900 calls on the 2026-11-19 (UTC) counter until
--    2026-11-19 06:20 UTC, then the 100 ceiling applies again by itself (the code below needs no revert).
--    Ticketmaster's own quota is 5,000 per rolling day resetting 06:25 UTC; 24 were already used in that
--    window when this was written, so 4,900 keeps a margin under Ticketmaster's limit.
--
-- 3. DAY-BY-DAY SWEEP (US, then Canada too — operator "Us and Canada only"). The weekly plan queries hit Discovery's 1,000-result paging ceiling on busy weeks (a busy
--    Saturday alone is ~370 Sports, ~690 Music, ~810 Arts & Theatre US events). One query per segment per UTC day
--    for the next 400 days, soonest first, ahead of the weekly plan (priority -1000 + day). They run once
--    (refresh_hours = 876000): after the sweep they are never due again, so they cannot eat the 100/day budget.
--
-- 4. TEMPORARY CRON tm_discovery_burst: every minute, tm_discovery_tick(60) (the advisory lock skips a run while
--    the previous one is still going). At 06:20 UTC it switches off the day: queries that did not finish and
--    unschedules itself. tm_discovery_match() runs after every tick that landed a page — the mapping.
--
-- GET only (RULE 2), the key stays in the request; nothing else changes.

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.tm_discovery_call_allowed()
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ok boolean;
BEGIN
  INSERT INTO public.tm_discovery_quota (day) VALUES (current_date) ON CONFLICT (day) DO NOTHING;
  UPDATE public.tm_discovery_quota q
     SET calls = q.calls + 1, last_call_at = now()
   WHERE q.day = current_date
     AND q.calls < CASE WHEN current_date = date '2026-11-19' AND now() < timestamptz '2026-11-19 06:20:00+00'
                        THEN 4900                         -- operator 2026-11-19: one day only
                        ELSE least(q.cap, 100) END        -- 100 is the ceiling whatever the row says
  RETURNING true INTO v_ok;
  IF v_ok IS NULL THEN
    UPDATE public.tm_discovery_quota SET refused = refused + 1 WHERE day = current_date;
    RETURN false;
  END IF;
  RETURN true;
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
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('tm_discovery_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another tm_discovery_tick is running');
  END IF;
  PERFORM public.tm_discovery_plan(13);

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'TMR CLIENT ID' LIMIT 1;
  IF v_key IS NULL OR length(trim(v_key)) < 16 THEN
    INSERT INTO public.tm_discovery_audit (run_id, action, note) VALUES (v_run, 'refused', 'no usable key in the vault (TMR CLIENT ID)');
    RETURN jsonb_build_object('run_id', v_run, 'error', 'no usable key');
  END IF;
  v_key := trim(v_key);

  FOR i IN 1..greatest(coalesce(p_calls, 0), 0) LOOP
    -- the most due query: a pass in progress (past page 0) first, then the stalest complete one past its refresh
    SELECT * INTO q FROM public.tm_discovery_query y
     WHERE y.active AND y.tries < 10
       AND (y.last_error_at IS NULL OR y.last_error_at < now() - interval '30 minutes')
       AND (y.total_pages IS NOT NULL AND y.page > 0 AND y.page < y.total_pages
            OR y.last_ok_at IS NULL
            OR y.last_ok_at < now() - make_interval(hours => y.refresh_hours))
     ORDER BY (y.total_pages IS NOT NULL AND y.page > 0) DESC, y.priority, y.last_ok_at NULLS FIRST, y.query_id
     LIMIT 1 FOR UPDATE SKIP LOCKED;
    EXIT WHEN NOT FOUND;

    IF NOT public.tm_discovery_call_allowed() THEN
      INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
      VALUES (v_run, 'refused', 'tm_discovery_query', q.label, 'daily Discovery call budget reached');
      v_refused := v_refused + 1;
      EXIT;
    END IF;
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
  RETURN jsonb_build_object('run_id', v_run, 'calls', v_calls, 'landed', v_landed, 'events', v_events, 'errors', v_errors, 'refused', v_refused, 'matched', v_match,
                            'budget_today', (SELECT jsonb_build_object('calls', calls, 'refused', refused, 'cap', least(cap, 100)) FROM public.tm_discovery_quota WHERE day = current_date));
END $function$;

REVOKE ALL ON FUNCTION public.tm_discovery_call_allowed(), public.tm_discovery_tick(integer) FROM PUBLIC, anon, authenticated;

-- the day-by-day sweep: one query per segment per UTC day for the next 400 days, soonest first, run once
INSERT INTO public.tm_discovery_query (label, params, priority, refresh_hours)
SELECT 'day:' || s.seg || ':' || d::date,
       jsonb_build_object('classificationName', s.seg, 'countryCode', 'US', 'size', '200', 'sort', 'date,asc',
                          'startDateTime', to_char(d, 'YYYY-MM-DD') || 'T00:00:00Z',
                          'endDateTime', to_char(d, 'YYYY-MM-DD') || 'T23:59:59Z'),
       -1000 + (d::date - date '2026-11-19'),
       876000
  FROM generate_series(date '2026-11-19', date '2026-11-19' + 399, interval '1 day') d
 CROSS JOIN unnest(ARRAY['Sports', 'Music', 'Arts & Theatre']) s(seg)
ON CONFLICT (label) DO NOTHING;

-- operator 2026-11-19 ~01:15 UTC: "Us and Canada only" — the same sweep for Canada (Discovery takes one country per
-- query), same date priority so both countries advance day by day; nothing outside US/CA is queried
INSERT INTO public.tm_discovery_query (label, params, priority, refresh_hours)
SELECT 'day:CA:' || s.seg || ':' || d::date,
       jsonb_build_object('classificationName', s.seg, 'countryCode', 'CA', 'size', '200', 'sort', 'date,asc',
                          'startDateTime', to_char(d, 'YYYY-MM-DD') || 'T00:00:00Z',
                          'endDateTime', to_char(d, 'YYYY-MM-DD') || 'T23:59:59Z'),
       -1000 + (d::date - date '2026-11-19'),
       876000
  FROM generate_series(date '2026-11-19', date '2026-11-19' + 399, interval '1 day') d
 CROSS JOIN unnest(ARRAY['Sports', 'Music', 'Arts & Theatre']) s(seg)
ON CONFLICT (label) DO NOTHING;

DO $$ BEGIN
  PERFORM cron.unschedule('tm_discovery_burst') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tm_discovery_burst');
  PERFORM cron.schedule('tm_discovery_burst', '* * * * *', $cmd$
    DO $b$ BEGIN
      IF now() >= timestamptz '2026-11-19 06:20:00+00' THEN
        UPDATE public.tm_discovery_query SET active = false WHERE label LIKE 'day:%' AND last_ok_at IS NULL;
        PERFORM cron.unschedule('tm_discovery_burst');
      ELSE
        PERFORM public.tm_discovery_tick(60);
      END IF;
    END $b$;
  $cmd$);
END $$;

COMMIT;

-- VERIFY: SELECT day, calls, refused FROM tm_discovery_quota ORDER BY day DESC LIMIT 2;
--   SELECT count(*) FILTER (WHERE last_ok_at IS NOT NULL), count(*) FROM tm_discovery_query WHERE label LIKE 'day:%';
--   SELECT count(*), count(tevo_event_id) FROM tm_discovery_event WHERE local_date >= current_date;
--   after 06:20 UTC: no cron job tm_discovery_burst; unfinished day: queries inactive; the cap is 100 again.
