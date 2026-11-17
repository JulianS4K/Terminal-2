-- Three defects in the ingest shipped by mig 20260915180000, all found by driving the backfill
-- harder than the 20-pages-per-tick cron ever would, plus the operator's "only poll for future
-- dates".
--
-- ============================================================================================
-- DEFECT 1 -- the enqueue runs off the end of a catalogue
-- ============================================================================================
-- Only the DRAIN learns total_entries, and only the drain sets backfill_done_at. The enqueue
-- walks backfill_page forward with no idea where the catalogue ends, so it keeps firing pages
-- past the last one AND never yields to the next country, because the condition that would move
-- it on is written by a function that has not run yet.
--
-- Under the 4-minute cron (drain, then 20 pages) the leak is bounded at 19 wasted pages per
-- country per backfill, which is why the verification run did not show it. Driving CA in one
-- 150-page burst walked the cursor to page 174 of a 46-page catalogue: 128 requests spent on
-- nothing, and US still on page 1 behind it.
--
-- This is the same shape as the starvation rule in PROJECT_BIBLE: the predicate that removes
-- finished work has to be evaluated by the writer, not by a different function on a later tick.
-- The fix gives the enqueue the same completion test the drain uses and lets it set done_at
-- itself.
--
-- ============================================================================================
-- DEFECT 2 -- the pacing was fiction, and TEvo rate-limits
-- ============================================================================================
-- The original loop called pg_sleep(0.4) between net.http_get() calls, which reads like 2.5
-- requests/second. It is not. pg_net QUEUES a request and dispatches it when the transaction
-- COMMITS, so every request in the batch leaves together at the end regardless of how long the
-- enqueue slept. The sleep paced nothing; it only made the enqueue slow.
--
-- MEASURED: a 20-page burst -> 20x HTTP 200. A 173-page burst -> 134x 200 and 39x 429
-- {"error":{"code":429,"message":"Too Many Requests"}}. TEvo sends no Retry-After and no
-- X-RateLimit-* headers on the 429, so the client cannot read the limit off the response and has
-- to carry its own ceiling.
--
-- The sleep is removed (it bought nothing and cost 0.4s/page of transaction time) and replaced
-- with two real limits: a hard per-transaction burst ceiling at the measured-safe 20, and an
-- in-flight guard that declines to fire while an earlier batch is still undrained. Going faster
-- now means more transactions, which is the thing that actually spreads the requests out in time.
--
-- ============================================================================================
-- DEFECT 3 -- a rate-limited page was lost silently, forever
-- ============================================================================================
-- The worst of the three. The drain stamped drained_at on a 429 exactly as it does on a 200, and
-- backfill_page had already advanced past it, so nothing would ever ask for that page again. The
-- run would end with backfill_done_at set and a hole in the middle of the catalogue that no
-- counter anywhere would report.
--
-- MEASURED: CA backfill pages 42 and 43 were 429'd in the burst above. ~200 Canadian events were
-- already unreachable by the time the defect was noticed -- not hypothetically, actually gone.
--
-- A response is now only FINISHED if it was a 200. Anything else stays retryable, and the enqueue
-- re-fires those pages BEFORE advancing any cursor, re-signing the stored query string so the
-- retry is the identical request. Four attempts, then the row is retired and counted -- a page
-- that cannot be fetched is a fact to surface, not to bury. And backfill_done_at is now withheld
-- while any page of that country is still owed, so "done" cannot be declared over a hole.
--
-- ============================================================================================
-- OPERATOR: "also only poll for future dates"
-- ============================================================================================
-- Already true on the wire -- both modes send occurs_at.gte=<today> -- and the daily delta pass
-- sends it alongside updated_at.gte, so a past event that gets edited is not pulled back in.
-- What was missing is the defence in depth the country filter already had: the drain trusted the
-- server-side date filter completely. A silently-ignored filter is a failure this project has hit
-- before, which is the whole reason country_code is re-asserted on the way in, so occurs_at_local
-- is now re-asserted the same way.
--
-- This does not touch the ~9,000 past events already in the mirror from earlier collectors; it
-- only guarantees this ingest adds no more.

BEGIN;

-- --------------------------------------------------------------------------------------------
-- pending: attempt tracking
-- --------------------------------------------------------------------------------------------
ALTER TABLE public.tevo_event_pull_pending
  ADD COLUMN IF NOT EXISTS attempts   int NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS retired_at timestamptz;

COMMENT ON COLUMN public.tevo_event_pull_pending.attempts IS
  'Fetch attempt number for this (country, mode, page). A retry inserts a NEW row with attempts+1 rather than mutating the old one, so the failure history stays readable (mig 20260915200000).';
COMMENT ON COLUMN public.tevo_event_pull_pending.retired_at IS
  'Set when this attempt has been superseded by a retry, or when the page has exhausted its attempts. A row with retired_at IS NULL and a non-200 status_code is a page still owed (mig 20260915200000).';

-- Attempts already on the clock: everything fired before this migration was attempt 1.
CREATE INDEX IF NOT EXISTS tevo_event_pull_pending_owed_idx
  ON public.tevo_event_pull_pending (country, mode, page)
  WHERE retired_at IS NULL AND drained_at IS NOT NULL AND status_code IS DISTINCT FROM 200;

-- --------------------------------------------------------------------------------------------
-- enqueue
-- --------------------------------------------------------------------------------------------
-- The old one-argument signature has to GO, not merely be superseded. Leaving it in place beside
-- a two-argument version whose second parameter has a default makes tevo_event_pull_enqueue(20)
-- -- which is exactly what cron 653 calls -- ambiguous, and Postgres resolves that by refusing.
DROP FUNCTION IF EXISTS public.tevo_event_pull_enqueue(int);

CREATE OR REPLACE FUNCTION public.tevo_event_pull_enqueue(
  p_pages        int DEFAULT 20,
  p_max_inflight int DEFAULT 40)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  -- 20 is the measured-safe burst; 173 drew 39 rate-limit rejections. The ceiling is applied
  -- silently to the loop but reported in the return value, so a caller that asked for more can
  -- see it was refused rather than assume it was honoured.
  c_burst_max constant int := 20;
  c_attempt_max constant int := 4;

  v_token  text := public.get_app_secret('TEVO_API_TOKEN');
  v_secret text := public.get_app_secret('TEVO_SECRET');
  v_pages  int := least(greatest(coalesce(p_pages,0), 0), c_burst_max);
  v_fired int := 0; v_retried int := 0; v_inflight int := 0; v_retired int := 0;
  v_country text; v_mode text; v_page int; v_since date;
  v_bf_done timestamptz; v_daily_done timestamptz; v_daily_page int; v_wm date;
  v_bf_total int; v_daily_total int;
  v_qs text; v_req bigint;
  r record;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'tevo_event_pull_enqueue: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;
  IF v_token IS NULL OR v_secret IS NULL THEN
    RETURN jsonb_build_object('error','TEVO credentials unavailable','fired',0);
  END IF;

  -- In-flight guard. pg_net dispatches this whole transaction's requests at COMMIT, so the only
  -- way to keep the request rate down is to keep the batches small AND refuse to pile a new batch
  -- on top of one that has not come back yet.
  SELECT count(*) INTO v_inflight
    FROM public.tevo_event_pull_pending WHERE drained_at IS NULL;
  IF v_inflight >= p_max_inflight THEN
    RETURN jsonb_build_object('fired',0,'retried',0,'inflight',v_inflight,
                              'skipped','inflight_cap');
  END IF;

  -- ------------------------------------------------------------------------------------------
  -- Phase 0: pages still owed, BEFORE any cursor moves.
  -- ------------------------------------------------------------------------------------------
  -- A page the cursor has passed can only come back this way, so owed work has to outrank new
  -- work -- otherwise the retry queue is starved by a catalogue walk that always has another page
  -- to offer. The stored qs is re-signed and re-fired verbatim: a retry that rebuilt the query
  -- string could quietly ask a different question than the one that failed.
  FOR r IN
    SELECT DISTINCT ON (q.country, q.mode, q.page)
           q.request_id, q.country, q.mode, q.page, q.qs, q.attempts
      FROM public.tevo_event_pull_pending q
      LEFT JOIN public.tevo_event_pull_state s ON s.country = q.country
     WHERE q.retired_at IS NULL
       AND q.drained_at IS NOT NULL
       AND q.status_code IS DISTINCT FROM 200
       -- never retry a page beyond the catalogue's end: those were the overrun of defect 1 and
       -- there is nothing there to fetch
       AND (q.mode <> 'backfill' OR s.backfill_total_pages IS NULL
            OR q.page <= s.backfill_total_pages)
       AND (q.mode <> 'daily'    OR s.daily_total_pages    IS NULL
            OR q.page <= s.daily_total_pages)
     ORDER BY q.country, q.mode, q.page, q.request_id DESC
     LIMIT v_pages
  LOOP
    IF r.attempts >= c_attempt_max THEN
      UPDATE public.tevo_event_pull_pending
         SET retired_at = now() WHERE request_id = r.request_id;
      v_retired := v_retired + 1;
      CONTINUE;
    END IF;

    SELECT net.http_get(
      url := 'https://api.ticketevolution.com/v9/events?' || r.qs,
      headers := jsonb_build_object(
        'X-Token', v_token,
        'X-Signature', public.tevo_sign_get('/v9/events', r.qs, v_secret),
        'Accept', 'application/vnd.ticketevolution.api+json; version=9'),
      timeout_milliseconds := 25000) INTO v_req;

    INSERT INTO public.tevo_event_pull_pending
      (request_id, country, mode, page, qs, attempts)
    VALUES (v_req, r.country, r.mode, r.page, r.qs, r.attempts + 1);

    -- supersede every earlier attempt at this page, not just the one this row came from
    UPDATE public.tevo_event_pull_pending
       SET retired_at = now()
     WHERE country = r.country AND mode = r.mode AND page = r.page
       AND request_id <> v_req AND retired_at IS NULL;

    v_retried := v_retried + 1;
  END LOOP;

  -- ------------------------------------------------------------------------------------------
  -- Phase 1: the catalogue walk.
  -- ------------------------------------------------------------------------------------------
  WHILE (v_fired + v_retried) < v_pages LOOP
    v_country := NULL;

    SELECT s.country, s.backfill_done_at, s.backfill_page, s.daily_done_at, s.daily_page,
           s.daily_watermark, s.backfill_total_pages, s.daily_total_pages
      INTO v_country, v_bf_done, v_page, v_daily_done, v_daily_page, v_wm,
           v_bf_total, v_daily_total
      FROM public.tevo_event_pull_state s
     WHERE s.backfill_done_at IS NULL
        OR s.daily_done_at IS NULL
        OR s.daily_done_at::date < current_date
     ORDER BY (s.backfill_done_at IS NULL) DESC, s.country
     LIMIT 1;

    EXIT WHEN v_country IS NULL;

    IF v_bf_done IS NULL THEN
      v_mode := 'backfill';

      -- DEFECT 1. The enqueue now applies the same completion test the drain does, so it stops at
      -- the end of the catalogue instead of walking past it, and yields to the next country in
      -- THIS transaction rather than on some later tick.
      IF v_bf_total IS NOT NULL AND v_page > v_bf_total THEN
        -- ...but not over a hole. A country with a page still owed is not done, however far the
        -- cursor has travelled.
        IF EXISTS (SELECT 1 FROM public.tevo_event_pull_pending q
                    WHERE q.country = v_country AND q.mode = 'backfill'
                      AND q.retired_at IS NULL
                      AND (q.drained_at IS NULL OR q.status_code IS DISTINCT FROM 200)
                      AND q.page <= v_bf_total)
        THEN
          EXIT;  -- owed pages exist but were not retryable this pass; let the next call take them
        END IF;
        UPDATE public.tevo_event_pull_state
           SET backfill_done_at = now(), updated_at = now() WHERE country = v_country;
        CONTINUE;
      END IF;
    ELSE
      v_mode := 'daily';
      v_page := v_daily_page;
      IF v_daily_done IS NULL OR v_daily_done::date < current_date THEN
        IF v_page = 1 THEN
          v_since := current_date - 1;
          UPDATE public.tevo_event_pull_state
             SET daily_watermark = v_since, daily_started_at = now(), daily_done_at = NULL,
                 daily_total_pages = NULL, updated_at = now()
           WHERE country = v_country;
          v_daily_total := NULL;
        ELSE
          v_since := coalesce(v_wm, current_date - 1);
        END IF;
      ELSE
        v_since := coalesce(v_wm, current_date - 1);
      END IF;

      IF v_daily_total IS NOT NULL AND v_page > v_daily_total THEN
        UPDATE public.tevo_event_pull_state
           SET daily_done_at = now(), daily_page = 1, updated_at = now()
         WHERE country = v_country;
        CONTINUE;
      END IF;
    END IF;

    -- ALPHABETICAL. tevo_sign_get signs the literal query string, so the ordering is part of the
    -- signature and cannot be rearranged for readability. occurs_at.gte is what keeps this to
    -- future dates -- it is not optional and it is not cosmetic.
    v_qs := 'country_code=' || v_country
         || '&occurs_at.gte=' || to_char(current_date,'YYYY-MM-DD')
         || '&page=' || v_page
         || '&per_page=100'
         || CASE WHEN v_mode = 'daily'
                 THEN '&updated_at.gte=' || to_char(v_since,'YYYY-MM-DD') ELSE '' END;

    SELECT net.http_get(
      url := 'https://api.ticketevolution.com/v9/events?' || v_qs,
      headers := jsonb_build_object(
        'X-Token', v_token,
        'X-Signature', public.tevo_sign_get('/v9/events', v_qs, v_secret),
        'Accept', 'application/vnd.ticketevolution.api+json; version=9'),
      timeout_milliseconds := 25000) INTO v_req;

    INSERT INTO public.tevo_event_pull_pending (request_id, country, mode, page, qs, attempts)
    VALUES (v_req, v_country, v_mode, v_page, v_qs, 1);

    IF v_mode = 'backfill' THEN
      UPDATE public.tevo_event_pull_state
         SET backfill_page = v_page + 1, updated_at = now() WHERE country = v_country;
    ELSE
      UPDATE public.tevo_event_pull_state
         SET daily_page = v_page + 1, updated_at = now() WHERE country = v_country;
    END IF;

    v_fired := v_fired + 1;
    -- no pg_sleep here. See DEFECT 2: it paced nothing, because pg_net dispatches at commit.
  END LOOP;

  RETURN jsonb_build_object(
    'fired', v_fired, 'retried', v_retried, 'retired', v_retired,
    'inflight_before', v_inflight,
    'burst_ceiling', c_burst_max, 'requested', p_pages);
END $fn$;

REVOKE ALL ON FUNCTION public.tevo_event_pull_enqueue(int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tevo_event_pull_enqueue(int, int) TO service_role;



-- --------------------------------------------------------------------------------------------
-- drain
-- --------------------------------------------------------------------------------------------
-- Replaced whole (plpgsql has no partial patch). Four changes against mig 20260915180000, each
-- marked at its site: skip superseded retry attempts, re-assert the future-date filter on the way
-- in, withhold backfill_done_at while a page is owed, and report the owed/abandoned backlog.

CREATE OR REPLACE FUNCTION public.tevo_event_pull_drain(p_max int DEFAULT 200)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_ev int := 0; v_vn int := 0; v_tz int := 0; v_pf int := 0;
  v_resp int := 0; v_err int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'tevo_event_pull_drain: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _pg (
    request_id bigint, country text, mode text, page int,
    status_code int, total_entries int, payload jsonb
  ) ON COMMIT DROP;
  DELETE FROM _pg;

  INSERT INTO _pg
  SELECT p.request_id, p.country, p.mode, p.page, r.status_code,
         CASE WHEN r.status_code = 200 AND left(ltrim(r.content),1) = '{'
              THEN (r.content::jsonb->>'total_entries')::int END,
         CASE WHEN r.status_code = 200 AND left(ltrim(r.content),1) = '{'
                   AND jsonb_typeof(r.content::jsonb->'events') = 'array'
              THEN r.content::jsonb->'events' ELSE '[]'::jsonb END
  FROM public.tevo_event_pull_pending p
  JOIN net._http_response r ON r.id = p.request_id
  -- retired_at means a later attempt at this page has already been fired; draining the superseded
  -- attempt would resurrect a stale 429 as though it were current news
  WHERE p.drained_at IS NULL AND p.retired_at IS NULL
  ORDER BY p.request_id
  LIMIT p_max;

  SELECT count(*), count(*) FILTER (WHERE status_code <> 200) INTO v_resp, v_err FROM _pg;
  IF v_resp = 0 THEN
    RETURN jsonb_build_object('responses',0,'events_upserted',0);
  END IF;

  DROP TABLE IF EXISTS _ev;
  CREATE TEMP TABLE _ev ON COMMIT DROP AS
  SELECT DISTINCT ON ((e.value->>'id')::bigint)
         (e.value->>'id')::bigint                              AS id,
          e.value->>'name'                                     AS name,
          left(e.value->>'occurs_at_local', 19)                AS occurs_at_local,
          coalesce(e.value->>'state','shown')                  AS state,
         (e.value->'venue'->>'id')::bigint                     AS venue_id,
          e.value->'venue'->>'name'                            AS venue_name,
          e.value->'venue'->>'location'                        AS venue_location,
          e.value->'venue'->>'time_zone'                       AS venue_tz,
          e.value->'venue'->'address'->>'country_code'         AS country_code,
          e.value->'venue'->'address'->>'locality'             AS venue_city,
          e.value->'venue'->'address'->>'region'               AS venue_region,
          nullif(e.value->'venue'->'address'->>'latitude','')::numeric  AS lat,
          nullif(e.value->'venue'->'address'->>'longitude','')::numeric AS lon,
         (e.value->'configuration'->>'id')::int                AS configuration_id,
          e.value->'configuration'->>'name'                    AS configuration_name,
          e.value->'configuration'->>'fanvenues_key'           AS fanvenues_key,
          e.value->'configuration'->'seating_chart'->>'large'  AS chart_large,
          e.value->'configuration'->'seating_chart'->>'medium' AS chart_medium,
          e.value->'category'->>'slug'                         AS category_slug,
          e.value->'category'->>'id'                           AS category_id,
          e.value->'category'->>'name'                         AS category_name,
          e.value->'category'->'parent'->>'name'               AS parent_category_name,
          nullif(e.value->>'popularity_score','')::numeric      AS pop,
          nullif(e.value->>'long_term_popularity_score','')::numeric AS lt_pop,
          e.value->'performances'                              AS performances
    FROM _pg g
    CROSS JOIN LATERAL jsonb_array_elements(g.payload) e(value)
   WHERE (e.value->>'id') IS NOT NULL
     AND (e.value->'venue'->>'id') IS NOT NULL
     AND e.value->>'occurs_at_local' ~ '^\d{4}-\d{2}-\d{2}'
     -- defence in depth: country_code is filtered server-side, but a silently-ignored filter is
     -- exactly the failure this project has hit before, so re-assert it on the way in
     AND coalesce(e.value->'venue'->'address'->>'country_code','') IN ('US','CA')
     -- OPERATOR: "also only poll for future dates". occurs_at.gte is sent on every request in
     -- both modes, so this should never exclude anything -- which is precisely the argument that
     -- was made for the country filter before it was re-asserted here too. A server-side filter
     -- that stops being honoured is silent, and the mirror is what would carry the damage.
     AND left(e.value->>'occurs_at_local', 10)::date >= current_date;

  -- event <-> performer cross-reference, flattened from performances[]
  DROP TABLE IF EXISTS _perf;
  CREATE TEMP TABLE _perf ON COMMIT DROP AS
  SELECT v.id AS event_id,
         (p.value->'performer'->>'id')::bigint AS performer_id,
          p.value->'performer'->>'name'        AS performer_name,
          p.value->'performer'->>'slug'        AS performer_slug,
         (p.value->>'primary')::boolean        AS is_primary
    FROM _ev v
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(v.performances)='array' THEN v.performances ELSE '[]'::jsonb END) p(value)
   WHERE (p.value->'performer'->>'id') IS NOT NULL;

  INSERT INTO public.events
    (id, name, occurs_at_local, state, venue_id, venue_name, venue_location,
     configuration_id, configuration_name, fanvenues_key,
     seating_chart_large, seating_chart_medium, event_type,
     popularity_score, long_term_popularity_score,
     primary_performer_id, primary_performer_name, performer_ids, last_seen)
  SELECT v.id, v.name, v.occurs_at_local, v.state, v.venue_id, v.venue_name, v.venue_location,
         v.configuration_id, v.configuration_name, nullif(v.fanvenues_key,''),
         v.chart_large, v.chart_medium, v.category_slug, v.pop, v.lt_pop,
         (SELECT p.performer_id FROM _perf p
           WHERE p.event_id = v.id ORDER BY p.is_primary DESC NULLS LAST, p.performer_id LIMIT 1),
         (SELECT p.performer_name FROM _perf p
           WHERE p.event_id = v.id ORDER BY p.is_primary DESC NULLS LAST, p.performer_id LIMIT 1),
         (SELECT array_agg(DISTINCT p.performer_id) FROM _perf p WHERE p.event_id = v.id),
         now()
    FROM _ev v
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    occurs_at_local = EXCLUDED.occurs_at_local,
    state = EXCLUDED.state,
    venue_id = EXCLUDED.venue_id,
    venue_name = EXCLUDED.venue_name,
    venue_location = EXCLUDED.venue_location,
    configuration_id = coalesce(EXCLUDED.configuration_id, events.configuration_id),
    configuration_name = coalesce(EXCLUDED.configuration_name, events.configuration_name),
    fanvenues_key = coalesce(EXCLUDED.fanvenues_key, events.fanvenues_key),
    seating_chart_large = coalesce(EXCLUDED.seating_chart_large, events.seating_chart_large),
    seating_chart_medium = coalesce(EXCLUDED.seating_chart_medium, events.seating_chart_medium),
    event_type = coalesce(EXCLUDED.event_type, events.event_type),
    popularity_score = coalesce(EXCLUDED.popularity_score, events.popularity_score),
    long_term_popularity_score = coalesce(EXCLUDED.long_term_popularity_score,
                                          events.long_term_popularity_score),
    primary_performer_id = coalesce(EXCLUDED.primary_performer_id, events.primary_performer_id),
    primary_performer_name = coalesce(EXCLUDED.primary_performer_name, events.primary_performer_name),
    performer_ids = coalesce(EXCLUDED.performer_ids, events.performer_ids),
    last_seen = now();
  GET DIAGNOSTICS v_ev = ROW_COUNT;

  INSERT INTO public.venue_assets
    (tevo_venue_id, venue_name, city, state, country, latitude, longitude, source, fetched_at)
  SELECT DISTINCT ON (v.venue_id)
         v.venue_id, v.venue_name, nullif(v.venue_city,''), nullif(v.venue_region,''),
         v.country_code, v.lat, v.lon, 'tevo_v9_events', now()
    FROM _ev v WHERE v.venue_id IS NOT NULL
  ON CONFLICT (tevo_venue_id) DO UPDATE SET
    venue_name = coalesce(EXCLUDED.venue_name, venue_assets.venue_name),
    city       = coalesce(EXCLUDED.city,       venue_assets.city),
    state      = coalesce(EXCLUDED.state,      venue_assets.state),
    country    = coalesce(EXCLUDED.country,    venue_assets.country),
    latitude   = coalesce(venue_assets.latitude,  EXCLUDED.latitude),
    longitude  = coalesce(venue_assets.longitude, EXCLUDED.longitude),
    fetched_at = now();
  GET DIAGNOSTICS v_vn = ROW_COUNT;

  -- venue_timezone is derived elsewhere by counting observations; a single payload must never
  -- overwrite that, so this only FILLS a missing zone.
  INSERT INTO public.venue_timezone (tevo_venue_id, iana_tz, source, venue_name, derived_at)
  SELECT DISTINCT ON (v.venue_id) v.venue_id, v.venue_tz, 'tevo_v9_events', v.venue_name, now()
    FROM _ev v
   WHERE v.venue_id IS NOT NULL AND nullif(v.venue_tz,'') IS NOT NULL
  ON CONFLICT (tevo_venue_id) DO UPDATE SET
    iana_tz    = coalesce(venue_timezone.iana_tz, EXCLUDED.iana_tz),
    venue_name = coalesce(venue_timezone.venue_name, EXCLUDED.venue_name);
  GET DIAGNOSTICS v_tz = ROW_COUNT;

  INSERT INTO public.performer_metadata
    (performer_id, name, slug, category_id, category_name, parent_category_name, fetched_at)
  SELECT DISTINCT ON (p.performer_id)
         p.performer_id, p.performer_name, p.performer_slug,
         v.category_id, v.category_name, v.parent_category_name, now()
    FROM _perf p JOIN _ev v ON v.id = p.event_id
   WHERE p.performer_id IS NOT NULL
  ON CONFLICT (performer_id) DO UPDATE SET
    name                 = coalesce(EXCLUDED.name, performer_metadata.name),
    slug                 = coalesce(EXCLUDED.slug, performer_metadata.slug),
    category_id          = coalesce(performer_metadata.category_id, EXCLUDED.category_id),
    category_name        = coalesce(performer_metadata.category_name, EXCLUDED.category_name),
    parent_category_name = coalesce(performer_metadata.parent_category_name,
                                    EXCLUDED.parent_category_name),
    fetched_at           = now();
  GET DIAGNOSTICS v_pf = ROW_COUNT;

  UPDATE public.tevo_event_pull_pending p
     SET drained_at = now(), status_code = g.status_code, total_entries = g.total_entries,
         events_seen = (SELECT count(*) FROM _ev),
         events_upserted = v_ev
    FROM _pg g WHERE g.request_id = p.request_id;

  -- Completion is decided by the page count the API itself reports, not by a page coming back
  -- short: a short page mid-run would end the walk early and the gap would be silent.
  UPDATE public.tevo_event_pull_state s
     SET backfill_total_pages = ceil(g.total_entries::numeric / 100)::int,
         last_total_entries   = g.total_entries,
         -- DEFECT 3 (mig 20260915200000): "done" is a claim that every page landed, so it is
         -- withheld while any page of this country is still owed. Without this the run ends with
         -- done_at set over a hole that no counter anywhere reports.
         backfill_done_at     = CASE WHEN s.backfill_page > ceil(g.total_entries::numeric / 100)::int
                                      AND NOT EXISTS (
                                            SELECT 1 FROM public.tevo_event_pull_pending q
                                             WHERE q.country = s.country AND q.mode = 'backfill'
                                               AND q.retired_at IS NULL
                                               AND (q.drained_at IS NULL
                                                    OR q.status_code IS DISTINCT FROM 200)
                                               AND q.page <= ceil(g.total_entries::numeric / 100)::int)
                                     THEN now() ELSE s.backfill_done_at END,
         updated_at = now()
    FROM (SELECT country, max(total_entries) total_entries FROM _pg
           WHERE mode='backfill' AND status_code=200 AND total_entries IS NOT NULL
           GROUP BY country) g
   WHERE s.country = g.country;

  UPDATE public.tevo_event_pull_state s
     SET daily_total_pages = ceil(g.total_entries::numeric / 100)::int,
         daily_done_at     = CASE WHEN s.daily_page > ceil(g.total_entries::numeric / 100)::int
                                  THEN now() ELSE s.daily_done_at END,
         daily_page        = CASE WHEN s.daily_page > ceil(g.total_entries::numeric / 100)::int
                                  THEN 1 ELSE s.daily_page END,
         updated_at = now()
    FROM (SELECT country, max(total_entries) total_entries FROM _pg
           WHERE mode='daily' AND status_code=200 AND total_entries IS NOT NULL
           GROUP BY country) g
   WHERE s.country = g.country;

  RETURN jsonb_build_object(
    'responses', v_resp, 'non_200', v_err,
    'events_upserted', v_ev, 'venues_upserted', v_vn,
    'timezones_filled', v_tz, 'performers_upserted', v_pf,
    -- a non-200 is not a finished page; surface the backlog rather than letting it sit silently
    'pages_owed', (SELECT count(*) FROM public.tevo_event_pull_pending q
                    WHERE q.retired_at IS NULL AND q.drained_at IS NOT NULL
                      AND q.status_code IS DISTINCT FROM 200),
    'pages_abandoned', (SELECT count(*) FROM public.tevo_event_pull_pending q
                         WHERE q.retired_at IS NOT NULL AND q.attempts >= 4
                           AND q.status_code IS DISTINCT FROM 200));
END $fn$;

REVOKE ALL ON FUNCTION public.tevo_event_pull_drain(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tevo_event_pull_drain(int) TO service_role;

COMMIT;
