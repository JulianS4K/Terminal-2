-- Migration 20261117180000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tm_discovery_quota(new),tm_discovery_query(new),tm_discovery_event(new),tm_discovery_audit(new),tm_venue_xref(new),tm_attraction_xref(new),tm_discovery_call_allowed()(new),tm_discovery_plan()(new),tm_discovery_tick()(new),tm_discovery_match()(new),v_tm_discovery_link(new view),cron:tm_discovery_tick_hourly(new) · reads:vault.decrypted_secrets('TMR CLIENT ID'),app.ticketmaster.com/discovery/v2 (GET, pgsql-http),events,venue_timezone,aq_performer_map · pre:20261117171000
--
-- MAPPING PROGRAM — TICKETMASTER'S OWN CATALOGUE (DISCOVERY API), UNDER A HARD CALL BUDGET.
--
-- Operator 2026-11-18 (via the hub session): incorporate the Ticketmaster Discovery API into the mapper, with a
-- STRICT limit of 100 GET calls a day, enforced in code. The key is the vault entry 'TMR CLIENT ID' (an Apigee
-- consumer key; the other TMR entries are the broker login and are never touched). Discovery is Ticketmaster's own
-- event catalogue: the TM event id, name, local date and time, the TM venue (id, name, city, state), the attractions
-- (teams / performers with TM ids), classification, status, public on-sale and presales. No prices, no inventory.
--
-- What this migration does, all read-only upstream (RULE 2 — the only call is extensions.http GET to
-- app.ticketmaster.com; no other method, no other host):
--   tm_discovery_call_allowed()   THE BUDGET. One row per UTC day in tm_discovery_quota; every call increments it under
--                                 a row lock before the GET is made; at 100 the call is refused and the refusal counted.
--                                 The cap is the smaller of the row's cap and 100 — it cannot be raised by data.
--                                 Ticketmaster's own 5,000/day quota is not our budget; 100 is.
--   tm_discovery_plan()           the query plan: one query per classification segment (Sports, Music, Arts & Theatre)
--                                 per week for the next 13 weeks, US, size=200, sorted by date — 39 queries, each paged
--                                 (Discovery caps size × page at 1,000: at most 5 pages a query), refreshed weekly. A
--                                 first fill is ~100–150 calls over two or three days; a steady week ~40 a day at most.
--                                 tm_discovery_query is data: add a venue, keyword or state query by hand when needed.
--   tm_discovery_tick(calls)      hourly at :27, four calls a run (96 a day at most, under the budget): the due query's
--                                 next page lands in tm_discovery_event (the key lives only in the request; the stored
--                                 query, the audit and the error text never carry it).
--   tm_discovery_match(limit)     TM event -> TEvo event: the TM venue through tm_venue_xref (built here: equal
--                                 normalised name in the same city, else learned from matched events), the same local
--                                 date, a fitting name (xmap_name_fits with the attractions as performers), the same
--                                 hour as a tiebreak; one candidate or nothing; one TM event per TEvo event. The TM
--                                 attractions are paired with TEvo performers by name in tm_attraction_xref, reusable.
-- WHAT IT DOES NOT DO — the hub. aq_event_map.tm_event_id is bigint and holds a numeric Ticketmaster id space
-- (1947355, 4995770, …: 712 upcoming rows); Discovery ids are strings ('G5diZ_o6tFFbU', '3B006511E9208636') and do
-- not fit. Writing them into the hub needs a decision: a text column on the hub (hub DDL — an operator call, long cron
-- transactions read aq_event_map around the clock) or the spine (a text id column, with the internal key). Until then
-- the TEvo match lives on tm_discovery_event and in v_tm_discovery_link, and the resolver can take it from there.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. tables ─────────────────────────
CREATE TABLE IF NOT EXISTS public.tm_discovery_quota (
  day          date PRIMARY KEY,                       -- UTC day
  calls        int NOT NULL DEFAULT 0,
  refused      int NOT NULL DEFAULT 0,
  cap          int NOT NULL DEFAULT 100 CHECK (cap BETWEEN 0 AND 100),
  last_call_at timestamptz
);
COMMENT ON TABLE public.tm_discovery_quota IS 'Ticketmaster Discovery GET calls per UTC day; tm_discovery_call_allowed() counts before every call and refuses at 100 (the hard budget, operator 2026-11-18). Mig 20261117180000.';

CREATE TABLE IF NOT EXISTS public.tm_discovery_query (
  query_id      bigserial PRIMARY KEY,
  label         text UNIQUE NOT NULL,                  -- e.g. seg:Sports:2026-11-16
  params        jsonb NOT NULL,                        -- the Discovery parameters WITHOUT the key
  priority      int NOT NULL DEFAULT 5,
  active        boolean NOT NULL DEFAULT true,
  refresh_hours int NOT NULL DEFAULT 168,
  page          int NOT NULL DEFAULT 0,                -- the next page to fetch (0-based, as Discovery counts)
  total_pages   int,                                   -- from the last page landed; NULL = not yet known
  events_seen   int NOT NULL DEFAULT 0,
  tries         int NOT NULL DEFAULT 0,
  last_ok_at    timestamptz,                           -- the last COMPLETE pass
  last_page_at  timestamptz,
  last_error    text,
  last_error_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.tm_discovery_event (
  tm_event_id      text PRIMARY KEY,
  name             text,
  url              text,
  local_date       date,
  local_time       time,
  start_utc        timestamptz,
  date_tbd         boolean,
  time_tba         boolean,
  status_code      text,                               -- onsale | offsale | cancelled | postponed | rescheduled
  tm_venue_id      text,
  venue_name       text,
  venue_city       text,
  venue_state      text,
  venue_country    text,
  venue_timezone   text,
  attractions      jsonb,                              -- [{"id": "...", "name": "..."}]
  attraction_names text[],
  segment          text,
  genre            text,
  sub_genre        text,
  public_onsale    timestamptz,
  presales         jsonb,
  ticket_limit     text,
  products         int,
  is_product       boolean NOT NULL DEFAULT false,     -- parking / packages / add-ons listed as events
  raw              jsonb,
  first_seen_at    timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),
  tevo_event_id    bigint,
  tevo_match_method text,
  tevo_matched_at  timestamptz
);
CREATE INDEX IF NOT EXISTS tm_discovery_event_date_idx ON public.tm_discovery_event (local_date);
CREATE INDEX IF NOT EXISTS tm_discovery_event_venue_idx ON public.tm_discovery_event (tm_venue_id);
CREATE INDEX IF NOT EXISTS tm_discovery_event_tevo_idx ON public.tm_discovery_event (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
COMMENT ON TABLE public.tm_discovery_event IS 'Ticketmaster''s own catalogue (Discovery API) as landed by tm_discovery_tick, with our TEvo match (tm_discovery_match). Catalogue and ids only: Discovery carries no prices or inventory. Mig 20261117180000.';

CREATE TABLE IF NOT EXISTS public.tm_venue_xref (
  tm_venue_id   text PRIMARY KEY,
  name          text,
  city          text,
  state         text,
  country       text,
  tevo_venue_id bigint,
  method        text,                                  -- manual | norm_city | matched_events
  events        int,
  derived_at    timestamptz
);
CREATE TABLE IF NOT EXISTS public.tm_attraction_xref (
  tm_attraction_id  text PRIMARY KEY,
  name              text,
  tevo_performer_id bigint,
  method            text,                              -- manual | name
  derived_at        timestamptz
);
CREATE TABLE IF NOT EXISTS public.tm_discovery_audit (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  run_id      uuid NOT NULL,
  action      text NOT NULL,                           -- call | refused | match | drop | venue_xref | attraction_xref
  target      text,
  target_key  text,
  new_tevo    bigint,
  note        text
);
CREATE INDEX IF NOT EXISTS tm_discovery_audit_run_idx ON public.tm_discovery_audit (run_id);

DO $rls$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['tm_discovery_quota', 'tm_discovery_query', 'tm_discovery_event', 'tm_venue_xref', 'tm_attraction_xref', 'tm_discovery_audit'] LOOP
    IF NOT (SELECT c.relrowsecurity FROM pg_class c WHERE c.oid = ('public.' || t)::regclass) THEN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    END IF;
    IF has_table_privilege('anon', 'public.' || t, 'SELECT, INSERT, UPDATE, DELETE') OR has_table_privilege('authenticated', 'public.' || t, 'SELECT, INSERT, UPDATE, DELETE') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    END IF;
    IF NOT has_table_privilege('service_role', 'public.' || t, 'SELECT') THEN
      EXECUTE format('GRANT SELECT ON public.%I TO service_role', t);
    END IF;
  END LOOP;
END
$rls$;

-- ───────────────────────── 2. the budget ─────────────────────────
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
   WHERE q.day = current_date AND q.calls < least(q.cap, 100)       -- 100 is the ceiling whatever the row says
  RETURNING true INTO v_ok;
  IF v_ok IS NULL THEN
    UPDATE public.tm_discovery_quota SET refused = refused + 1 WHERE day = current_date;
    RETURN false;
  END IF;
  RETURN true;
END $function$;
COMMENT ON FUNCTION public.tm_discovery_call_allowed() IS 'Counts one Ticketmaster Discovery call against today''s budget (hard cap 100) and says whether it may be made. Call it before every GET; a refusal is counted too. Mig 20261117180000.';

-- ───────────────────────── 3. the plan ─────────────────────────
-- a query per classification segment per week for the next p_weeks weeks; past weeks go inactive
CREATE OR REPLACE FUNCTION public.tm_discovery_plan(p_weeks integer DEFAULT 13)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int;
BEGIN
  WITH weeks AS (
    SELECT (date_trunc('week', current_date::timestamp)::date + 7 * w) AS wk FROM generate_series(0, greatest(p_weeks, 1) - 1) w),
  segs AS (SELECT unnest(ARRAY['Sports', 'Music', 'Arts & Theatre']) AS seg),
  ins AS (
    INSERT INTO public.tm_discovery_query (label, params, priority)
    SELECT 'seg:' || s.seg || ':' || w.wk,
           jsonb_build_object('classificationName', s.seg, 'countryCode', 'US', 'size', '200', 'sort', 'date,asc',
                              'startDateTime', to_char(w.wk, 'YYYY-MM-DD') || 'T00:00:00Z',
                              'endDateTime', to_char(w.wk + 6, 'YYYY-MM-DD') || 'T23:59:59Z'),
           CASE WHEN s.seg = 'Sports' THEN 1 ELSE 3 END + (w.wk - date_trunc('week', current_date::timestamp)::date) / 7   -- sooner weeks first
      FROM segs s CROSS JOIN weeks w
    ON CONFLICT (label) DO NOTHING
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  UPDATE public.tm_discovery_query q SET active = false
   WHERE q.active AND q.label LIKE 'seg:%' AND (q.params->>'endDateTime')::timestamptz < now() - interval '1 day';
  RETURN v_n;
END $function$;

-- ───────────────────────── 4. the collector ─────────────────────────
-- one step: up to p_calls GETs (budgeted), each the next page of the most due query; then the match
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

    IF NOT public.tm_discovery_call_allowed() THEN
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

  IF v_landed > 0 THEN v_match := public.tm_discovery_match(5000); END IF;
  RETURN jsonb_build_object('run_id', v_run, 'calls', v_calls, 'landed', v_landed, 'events', v_events, 'errors', v_errors, 'refused', v_refused, 'matched', v_match,
                            'budget_today', (SELECT jsonb_build_object('calls', calls, 'refused', refused, 'cap', least(cap, 100)) FROM public.tm_discovery_quota WHERE day = current_date));
END $function$;

-- ───────────────────────── 5. the match ─────────────────────────
CREATE OR REPLACE FUNCTION public.tm_discovery_match(p_limit integer DEFAULT 5000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE v_run uuid := gen_random_uuid(); v_n int := 0; v_k int;
BEGIN
  -- 1. venues: a TM venue new to the xref pairs with the one TEvo venue of the same normalised name in its city
  DROP TABLE IF EXISTS _tm_tv;
  CREATE TEMP TABLE _tm_tv ON COMMIT DROP AS
  SELECT s.venue_id, s.nm, s.city, s.st, public.catalog_venue_norm(s.nm, s.city, s.st, true) AS norm
    FROM (SELECT e.venue_id, min(e.venue_name) AS nm,
                 lower(trim(regexp_replace(min(e.venue_location), ',\s*[^,]*$', ''))) AS city,
                 upper(trim(regexp_replace(min(e.venue_location), '^.*,\s*', ''))) AS st
            FROM public.events e
           WHERE e.venue_id IS NOT NULL AND e.venue_location LIKE '%,%' AND e.state IS DISTINCT FROM 'ignored'
             AND e.occurs_at_local >= to_char(now() - interval '1 day', 'YYYY-MM-DD')
           GROUP BY e.venue_id) s
   WHERE coalesce(s.st, '') <> '';
  CREATE INDEX ON _tm_tv (st, city, norm);
  INSERT INTO public.tm_venue_xref (tm_venue_id, name, city, state, country, tevo_venue_id, method, derived_at)
  SELECT d.tm_venue_id, d.venue_name, d.venue_city, d.venue_state, d.venue_country, NULL, NULL, NULL
    FROM (SELECT DISTINCT ON (tm_venue_id) tm_venue_id, venue_name, venue_city, venue_state, venue_country
            FROM public.tm_discovery_event WHERE tm_venue_id IS NOT NULL ORDER BY tm_venue_id, last_seen_at DESC) d
  ON CONFLICT (tm_venue_id) DO NOTHING;
  WITH cand AS (
    SELECT x.tm_venue_id, min(t.venue_id) AS tevo_venue_id, count(DISTINCT t.venue_id) AS n
      FROM public.tm_venue_xref x
      JOIN _tm_tv t ON t.st = upper(trim(x.state)) AND t.city = lower(trim(x.city))
                   AND t.norm = public.catalog_venue_norm(x.name, x.city, x.state, true) AND t.norm <> ''
     WHERE x.tevo_venue_id IS NULL AND coalesce(x.state, '') <> ''
     GROUP BY x.tm_venue_id),
  upd AS (
    UPDATE public.tm_venue_xref x SET tevo_venue_id = c.tevo_venue_id, method = 'norm_city', derived_at = now()
      FROM cand c WHERE c.tm_venue_id = x.tm_venue_id AND c.n = 1
    RETURNING x.tm_venue_id, x.tevo_venue_id)
  INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
  SELECT v_run, 'venue_xref', 'tm_venue_xref', u.tm_venue_id, 'tevo_venue ' || u.tevo_venue_id || ' via norm_city' FROM upd u;

  -- 2. attractions: by equal normalised name with a TEvo performer (one), reusable
  INSERT INTO public.tm_attraction_xref (tm_attraction_id, name)
  SELECT DISTINCT a->>'id', a->>'name'
    FROM public.tm_discovery_event d, jsonb_array_elements(coalesce(d.attractions, '[]'::jsonb)) a
   WHERE coalesce(a->>'id', '') <> ''
  ON CONFLICT (tm_attraction_id) DO NOTHING;
  WITH perf AS (
    SELECT public.event_mapper_norm_name(p.performer_name) AS nm, min(p.tevo_performer_id) AS pid, count(DISTINCT p.tevo_performer_id) AS n
      FROM public.aq_performer_map p WHERE p.tevo_performer_id IS NOT NULL AND coalesce(p.performer_name, '') <> ''
     GROUP BY 1),
  upd AS (
    UPDATE public.tm_attraction_xref x SET tevo_performer_id = pf.pid, method = 'name', derived_at = now()
      FROM perf pf WHERE x.tevo_performer_id IS NULL AND pf.n = 1 AND pf.nm <> '' AND pf.nm = public.event_mapper_norm_name(x.name)
    RETURNING x.tm_attraction_id, x.tevo_performer_id)
  INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
  SELECT v_run, 'attraction_xref', 'tm_attraction_xref', u.tm_attraction_id, 'tevo_performer ' || u.tevo_performer_id || ' via name' FROM upd u;

  -- 3. events: same TEvo venue (through the xref), same local date, a fitting name; the same hour as a tiebreak
  DROP TABLE IF EXISTS _tm_todo;
  CREATE TEMP TABLE _tm_todo ON COMMIT DROP AS
  SELECT d.tm_event_id, d.name, d.attraction_names, d.local_date, d.start_utc, x.tevo_venue_id
    FROM public.tm_discovery_event d
    JOIN public.tm_venue_xref x ON x.tm_venue_id = d.tm_venue_id AND x.tevo_venue_id IS NOT NULL
   WHERE d.tevo_event_id IS NULL AND NOT d.is_product AND d.local_date IS NOT NULL
     AND d.local_date BETWEEN current_date - 1 AND current_date + 400
     AND coalesce(d.status_code, 'onsale') NOT IN ('cancelled', 'canceled')
     AND coalesce(d.name, '') <> ''
   ORDER BY d.local_date LIMIT greatest(p_limit, 0);
  IF (SELECT count(*) FROM _tm_todo) = 0 THEN RETURN 0; END IF;
  DROP TABLE IF EXISTS _tm_ev;
  CREATE TEMP TABLE _tm_ev ON COMMIT DROP AS
  SELECT e.id, e.name, e.venue_id, e.primary_performer_name, left(e.occurs_at_local, 10)::date AS day, public.tevo_event_utc(e.occurs_at_local, e.venue_id) AS utc
    FROM public.events e
   WHERE e.state IS DISTINCT FROM 'ignored' AND e.venue_id IN (SELECT DISTINCT tevo_venue_id FROM _tm_todo)
     AND e.occurs_at_local >= to_char(current_date - 1, 'YYYY-MM-DD') AND e.occurs_at_local < to_char(current_date + 401, 'YYYY-MM-DD')
     AND e.name !~* '(parking|tailgate|shuttle|package|hospitality|\mvip\M|suites?\M)'
     AND NOT EXISTS (SELECT 1 FROM public.tm_discovery_event o WHERE o.tevo_event_id = e.id);
  CREATE INDEX ON _tm_ev (venue_id, day);
  WITH cand AS (
    SELECT t.tm_event_id, e.id AS tevo_event_id,
           (t.start_utc IS NOT NULL AND e.utc IS NOT NULL AND abs(extract(epoch FROM e.utc - t.start_utc)) <= 3600) AS same_hour
      FROM _tm_todo t
      JOIN _tm_ev e ON e.venue_id = t.tevo_venue_id AND e.day = t.local_date
     WHERE public.xmap_name_fits(t.name, t.attraction_names, e.name, CASE WHEN coalesce(e.primary_performer_name, '') <> '' THEN ARRAY[e.primary_performer_name] END)),
  per AS (
    SELECT c.tm_event_id, count(*) AS n, min(c.tevo_event_id) AS one,
           count(*) FILTER (WHERE c.same_hour) AS n_hour, min(c.tevo_event_id) FILTER (WHERE c.same_hour) AS one_hour
      FROM cand c GROUP BY c.tm_event_id),
  pick AS (
    SELECT p.tm_event_id,
           CASE WHEN p.n = 1 THEN p.one WHEN p.n_hour = 1 THEN p.one_hour END AS tevo_event_id,
           CASE WHEN p.n = 1 THEN 'venue_date_name' WHEN p.n_hour = 1 THEN 'venue_time_name' END AS method
      FROM per p),
  ok AS (
    SELECT * FROM pick p WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.tm_event_id <> p.tm_event_id)),
  upd AS (
    UPDATE public.tm_discovery_event d SET tevo_event_id = ok.tevo_event_id, tevo_match_method = ok.method, tevo_matched_at = now()
      FROM ok WHERE d.tm_event_id = ok.tm_event_id AND d.tevo_event_id IS NULL
    RETURNING d.tm_event_id, d.tevo_event_id, d.tevo_match_method)
  INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, new_tevo, note)
  SELECT v_run, 'match', 'tm_discovery_event', u.tm_event_id, u.tevo_event_id, u.tevo_match_method FROM upd u;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- 4. venues learned from the matches: a TM venue whose matched events all sit at one TEvo venue (two or more)
  WITH learn AS (
    SELECT d.tm_venue_id, min(e.venue_id) AS tevo_venue_id, count(*) AS n
      FROM public.tm_discovery_event d JOIN public.events e ON e.id = d.tevo_event_id AND e.venue_id IS NOT NULL
     WHERE d.tm_venue_id IS NOT NULL
     GROUP BY d.tm_venue_id HAVING count(DISTINCT e.venue_id) = 1 AND count(*) >= 2),
  upd AS (
    UPDATE public.tm_venue_xref x SET tevo_venue_id = l.tevo_venue_id, method = 'matched_events', events = l.n, derived_at = now()
      FROM learn l WHERE l.tm_venue_id = x.tm_venue_id AND x.tevo_venue_id IS NULL
    RETURNING x.tm_venue_id, x.tevo_venue_id, x.events)
  INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
  SELECT v_run, 'venue_xref', 'tm_venue_xref', u.tm_venue_id, format('tevo_venue %s via matched_events (%s)', u.tevo_venue_id, u.events) FROM upd u;
  GET DIAGNOSTICS v_k = ROW_COUNT;
  UPDATE public.tm_venue_xref x SET events = s.n FROM (SELECT d.tm_venue_id, count(*) n FROM public.tm_discovery_event d WHERE d.tevo_event_id IS NOT NULL GROUP BY 1) s
   WHERE s.tm_venue_id = x.tm_venue_id AND x.events IS DISTINCT FROM s.n;
  RETURN v_n;
END $function$;
COMMENT ON FUNCTION public.tm_discovery_match(integer) IS
  'Ticketmaster Discovery event -> TEvo event: the TM venue through tm_venue_xref (equal normalised name in the city, else learned from matched events), the same local date, a fitting name (attractions as performers), the same hour as a tiebreak; one candidate or nothing; one TM event per TEvo event. Attractions pair with TEvo performers by name (tm_attraction_xref). Mig 20261117180000.';

REVOKE ALL ON FUNCTION public.tm_discovery_call_allowed(), public.tm_discovery_plan(integer), public.tm_discovery_tick(integer), public.tm_discovery_match(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tm_discovery_call_allowed(), public.tm_discovery_plan(integer), public.tm_discovery_tick(integer), public.tm_discovery_match(integer) TO service_role;

-- ───────────────────────── 6. review view ─────────────────────────
CREATE OR REPLACE VIEW public.v_tm_discovery_link AS
SELECT d.tm_event_id, d.name AS tm_name, d.local_date, d.local_time, d.status_code, d.segment, d.genre, d.venue_name, d.venue_city, d.venue_state,
       d.tm_venue_id, x.tevo_venue_id, x.method AS venue_method,
       d.tevo_event_id, d.tevo_match_method, e.name AS evo_name, e.occurs_at_local AS evo_start,
       d.public_onsale, jsonb_array_length(coalesce(d.presales, '[]'::jsonb)) AS presales, d.ticket_limit, d.url
  FROM public.tm_discovery_event d
  LEFT JOIN public.tm_venue_xref x ON x.tm_venue_id = d.tm_venue_id
  LEFT JOIN public.events e ON e.id = d.tevo_event_id;
COMMENT ON VIEW public.v_tm_discovery_link IS 'Ticketmaster Discovery events with their venue xref and TEvo match, for review. Mig 20261117180000.';
REVOKE ALL ON public.v_tm_discovery_link FROM anon, authenticated;
GRANT SELECT ON public.v_tm_discovery_link TO service_role;

-- ───────────────────────── 7. cron ─────────────────────────
-- hourly at :27, four calls a run: 96 a day at most, under the budget of 100 that tm_discovery_call_allowed enforces
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tm_discovery_tick_hourly') THEN PERFORM cron.unschedule('tm_discovery_tick_hourly'); END IF;
  PERFORM cron.schedule('tm_discovery_tick_hourly', '27 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '300s'; SELECT public.tm_discovery_tick(4); COMMIT;$j$);
END
$cron$;

COMMIT;

-- VERIFY:
--   SELECT * FROM tm_discovery_quota ORDER BY day DESC LIMIT 3;                     -- calls / refused today (cap 100)
--   SELECT label, page, total_pages, events_seen, last_ok_at, last_error FROM tm_discovery_query ORDER BY priority, label LIMIT 20;
--   SELECT segment, count(*), count(tevo_event_id) FROM tm_discovery_event WHERE local_date >= current_date GROUP BY 1;
--   SELECT method, count(*) FROM tm_venue_xref GROUP BY 1;
--   SELECT * FROM v_tm_discovery_link WHERE tevo_event_id IS NOT NULL ORDER BY random() LIMIT 20;
