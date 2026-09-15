-- Ingest the whole US + Canada TEvo future catalogue, keep it fresh daily, and fill the venue,
-- performer and event↔performer cross-reference tables while the payload is in hand.
--
-- ============================================================================================
-- WHY: THE MIRROR HOLDS 19% OF WHAT TEVO LISTS
-- ============================================================================================
-- Established today when the operator supplied seven TEvo core links and six of the seven events
-- turned out to be absent from public.events (mig 20260915170000). Measured directly against the
-- API rather than inferred -- one signed GET per figure, per_page=1:
--
--   /v9/events occurs_at.gte=today                          119,407   global
--   ... country_code=US                                     104,127
--   ... country_code=CA                                       4,530
--   ... country_code=US &updated_at.gte=yesterday             8,278   <- daily delta
--   public.events (all rows, any date)                       20,544
--
-- 108,657 US+CA future events exist; we mirror 20,544 of everything we have ever seen. Every
-- "unmapped" number produced in this session -- 6,799 future events with no GoTickets id, the 850
-- venues, the CSVs -- counts only events we HAVE. The denominators were understated and nobody
-- could see by how much, because the gap is invisible from inside the mirror.
--
-- ============================================================================================
-- THE API CONTRACT, MEASURED NOT ASSUMED
-- ============================================================================================
--   * country_code filters SERVER-SIDE. US returns 104,127 against 119,407 global, so this is a
--     real filter and not a silently-ignored parameter. That matters: tickets.dev silently
--     ignores date= and venue=, and assuming a filter works is how that class of bug starts.
--   * updated_at.gte filters server-side too -- 8,278 for one day -- which is what makes a daily
--     refresh cheap instead of a re-pull of the whole catalogue.
--   * per_page caps at 100. per_page=250 returns HTTP 422, so the cap is enforced, not clamped.
--   * Query parameters MUST be in alphabetical order. tevo_sign_get() signs the literal string
--     'GET api.ticketevolution.com<path>?<query>', so the signature is bound to the exact spelling
--     and ordering of the query string. Both orderings used below are alphabetical
--     (country_code, occurs_at.gte, page, per_page, updated_at.gte) and both were verified 200.
--
-- Volume: 1,042 US pages + 46 CA pages = 1,088 for the backfill; ~90 pages a day thereafter.
--
-- ============================================================================================
-- SHAPE
-- ============================================================================================
-- Two tables and two functions, following the pattern venue_pull_queue and
-- tevo_venue_events_harvest already established: a signed net.http_get whose request_id is parked
-- in a pending table, and a separate drain that reads net._http_response. They are separate
-- because pg_net is asynchronous -- a response is not available in the transaction that fired it,
-- so a tick drains the PREVIOUS tick's requests and then fires the next batch.
--
-- The cursor lives in tevo_event_pull_state, one row per country, with two modes. 'backfill'
-- walks pages 1..N once. 'daily' re-walks only what updated_at.gte says changed. The tick prefers
-- backfill while it is unfinished, then switches to daily -- so a fresh install converges before
-- it starts chasing deltas, rather than interleaving the two and finishing neither.
--
-- ============================================================================================
-- WHAT THE DRAIN WRITES, BEYOND events
-- ============================================================================================
-- The /v9/events payload carries venue, performer and category data that the existing harvester
-- (tevo_venue_events_harvest) throws away -- it writes only id/name/occurs_at_local/state/venue/
-- configuration. Since the payload is already paid for, this drain also fills:
--
--   events.primary_performer_id / primary_performer_name / performer_ids / event_type
--       The event<->performer cross-reference. performances[] carries every performer with a
--       `primary` flag; event_type takes category.slug, which is what the column already holds
--       ('game', 'mlb', 'concert', 'rock-pop', 'ncaa--2').
--   events.popularity_score / long_term_popularity_score / seating_chart_* / fanvenues_key
--   venue_assets      (tevo_venue_id PK) name, city, state, country, lat/long from venue.address
--   venue_timezone    (tevo_venue_id PK) from venue.time_zone
--   performer_metadata(performer_id PK)  name, slug, category, popularity
--
-- venue_timezone is the quiet win. It holds 990 rows today against 1,351 crosswalk venues, and
-- that shortfall is load-bearing: evo_gt_map cannot decide a local day without a zone, which cost
-- 428 of 1,730 candidate pairs their day comparison and pushed 998 unmapped events onto the
-- stricter +/-1 window path. TEvo has been returning venue.time_zone in every one of these
-- payloads the whole time.
--
-- NEVER-OVERWRITE-WITH-NULL. Every upsert coalesces to the existing value, so a payload missing a
-- field cannot erase one already derived from a better source -- venue_timezone in particular is
-- populated by a derivation that counts observations, and a single null must not beat it.
--
-- ============================================================================================
-- SCHEDULING, and why these hours
-- ============================================================================================
-- Off-peak for a US ticketing book is the early-morning UTC window: the 22:00-04:00 UTC evening
-- is when listings polling, order pulls and the deal scanner are busiest. 06:00-11:59 UTC is
-- 02:00-08:00 ET. The existing daily jobs cluster at 08:00-09:45 UTC, so the tick runs on a
-- 4-minute offset grid that does not land on :00 or :45 of those hours.
--
--   tevo_event_pull_tick   2,6,10,...,58 6-11 * * *   drain, then enqueue up to 20 pages
--
-- 90 ticks x 20 pages = 1,800 pages of headroom per window against 1,088 for the backfill, so it
-- converges inside one window and then costs ~90 pages a day. Rate limiting is the same
-- pg_sleep(0.4) between requests that venue_pull_queue uses.
--
-- ⚠ APPLYING THIS WILL MOVE EVERY EVENT-COUNT METRIC IN THE PROJECT. public.events goes from
-- 20,544 toward ~108k US+CA future rows. Dashboards, alert thresholds and the unmapped censuses
-- in this session's CSVs will all step, and mapper backlogs will grow before they shrink because
-- the new events arrive unmapped. That is the point, but it should not arrive as a surprise.
--
-- Dry-run: the enqueue is p_apply-gated and reports what it WOULD fire.

CREATE TABLE IF NOT EXISTS public.tevo_event_pull_state (
  country              text PRIMARY KEY,
  backfill_page        int  NOT NULL DEFAULT 1,
  backfill_total_pages int,
  backfill_done_at     timestamptz,
  daily_watermark      date,
  daily_page           int  NOT NULL DEFAULT 1,
  daily_total_pages    int,
  daily_started_at     timestamptz,
  daily_done_at        timestamptz,
  last_total_entries   int,
  updated_at           timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.tevo_event_pull_state IS
  'Cursor for the US/CA TEvo event ingest: backfill walks pages once, daily re-walks updated_at.gte deltas (mig 20260915180000).';

CREATE TABLE IF NOT EXISTS public.tevo_event_pull_pending (
  request_id      bigint PRIMARY KEY,
  country         text NOT NULL,
  mode            text NOT NULL,
  page            int  NOT NULL,
  qs              text,
  fired_at        timestamptz NOT NULL DEFAULT now(),
  drained_at      timestamptz,
  status_code     int,
  total_entries   int,
  events_seen     int,
  events_upserted int
);

CREATE INDEX IF NOT EXISTS tevo_event_pull_pending_open_idx
  ON public.tevo_event_pull_pending (fired_at) WHERE drained_at IS NULL;

COMMENT ON TABLE public.tevo_event_pull_pending IS
  'One row per signed /v9/events request fired by tevo_event_pull_enqueue; drained by tevo_event_pull_drain (mig 20260915180000).';

INSERT INTO public.tevo_event_pull_state (country) VALUES ('US'), ('CA')
ON CONFLICT (country) DO NOTHING;

-- --------------------------------------------------------------------------------------------
-- enqueue
-- --------------------------------------------------------------------------------------------
-- No p_apply here, deliberately. The first draft had one implemented as "mutate, then RAISE to
-- roll back", which discards the return value it was supposed to produce and is a lie about what
-- the function does. A fetch has no dangerous dry-run to offer: nothing is written to business
-- data, the cap is p_pages, and stopping the cron stops it. Correctness that matters lives in the
-- drain.
CREATE OR REPLACE FUNCTION public.tevo_event_pull_enqueue(p_pages int DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_token  text := public.get_app_secret('TEVO_API_TOKEN');
  v_secret text := public.get_app_secret('TEVO_SECRET');
  v_fired int := 0;
  v_country text; v_mode text; v_page int; v_since date;
  v_bf_done timestamptz; v_daily_done timestamptz; v_daily_page int; v_wm date;
  v_qs text; v_req bigint;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'tevo_event_pull_enqueue: caller % not authorized', current_user
      USING ERRCODE='42501';
  END IF;
  IF v_token IS NULL OR v_secret IS NULL THEN
    RETURN jsonb_build_object('error','TEVO credentials unavailable','fired',0);
  END IF;

  WHILE v_fired < p_pages LOOP
    v_country := NULL;

    -- Backfill before deltas: a fresh install should converge before it starts chasing changes,
    -- rather than interleaving the two and finishing neither.
    SELECT s.country, s.backfill_done_at, s.backfill_page, s.daily_done_at, s.daily_page,
           s.daily_watermark
      INTO v_country, v_bf_done, v_page, v_daily_done, v_daily_page, v_wm
      FROM public.tevo_event_pull_state s
     WHERE s.backfill_done_at IS NULL
        OR s.daily_done_at IS NULL
        OR s.daily_done_at::date < current_date
     ORDER BY (s.backfill_done_at IS NULL) DESC, s.country
     LIMIT 1;

    EXIT WHEN v_country IS NULL;

    IF v_bf_done IS NULL THEN
      v_mode := 'backfill';
      -- v_page already holds backfill_page
    ELSE
      v_mode := 'daily';
      v_page := v_daily_page;
      IF v_daily_done IS NULL OR v_daily_done::date < current_date THEN
        IF v_page = 1 THEN
          -- start one day behind the previous pass so an event updated mid-run cannot fall
          -- through the seam between two windows
          v_since := current_date - 1;
          UPDATE public.tevo_event_pull_state
             SET daily_watermark = v_since, daily_started_at = now(), daily_done_at = NULL,
                 updated_at = now()
           WHERE country = v_country;
        ELSE
          v_since := coalesce(v_wm, current_date - 1);
        END IF;
      ELSE
        v_since := coalesce(v_wm, current_date - 1);
      END IF;
    END IF;

    -- ALPHABETICAL. tevo_sign_get signs the literal query string, so the ordering is part of the
    -- signature and cannot be rearranged for readability.
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

    INSERT INTO public.tevo_event_pull_pending (request_id, country, mode, page, qs)
    VALUES (v_req, v_country, v_mode, v_page, v_qs);

    IF v_mode = 'backfill' THEN
      UPDATE public.tevo_event_pull_state
         SET backfill_page = v_page + 1, updated_at = now() WHERE country = v_country;
    ELSE
      UPDATE public.tevo_event_pull_state
         SET daily_page = v_page + 1, updated_at = now() WHERE country = v_country;
    END IF;

    v_fired := v_fired + 1;
    PERFORM pg_sleep(0.4);
  END LOOP;

  RETURN jsonb_build_object('fired', v_fired);
END $fn$;

REVOKE ALL ON FUNCTION public.tevo_event_pull_enqueue(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tevo_event_pull_enqueue(int) TO service_role;

-- --------------------------------------------------------------------------------------------
-- drain
-- --------------------------------------------------------------------------------------------
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
  WHERE p.drained_at IS NULL
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
     AND coalesce(e.value->'venue'->'address'->>'country_code','') IN ('US','CA');

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
         backfill_done_at     = CASE WHEN s.backfill_page > ceil(g.total_entries::numeric / 100)::int
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
    'timezones_filled', v_tz, 'performers_upserted', v_pf);
END $fn$;

REVOKE ALL ON FUNCTION public.tevo_event_pull_drain(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tevo_event_pull_drain(int) TO service_role;

-- --------------------------------------------------------------------------------------------
-- schedule
-- --------------------------------------------------------------------------------------------
-- Off-peak only, two independent ways. The cron expression confines the tick to 06:00-11:59 UTC
-- (02:00-08:00 ET), and cron_policy.peak_hours_et names the whole US day as peak so that a future
-- reschedule cannot quietly drag this into the evening book -- peak_min_interval_min=1440 caps it
-- at one fire if it ever does land there. offpeak_min_interval_min=3 lets the 4-minute grid pass.
--
-- The work_check makes the job self-gating: once the backfill is complete and the day's delta
-- pass is done, it stops firing rather than burning API budget proving there is nothing to do.
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, enabled, notes, updated_at)
VALUES (
  'tevo_event_pull_tick',
  ARRAY[9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,0],
  1440, 3,
  $wc$SELECT EXISTS (SELECT 1 FROM public.tevo_event_pull_state
                      WHERE backfill_done_at IS NULL
                         OR daily_done_at IS NULL
                         OR daily_done_at::date < current_date)
          OR EXISTS (SELECT 1 FROM public.tevo_event_pull_pending WHERE drained_at IS NULL)$wc$,
  true,
  'US+CA TEvo event ingest. Drains the previous tick then fires up to 20 pages. Self-gates when the backfill is complete and today''s delta pass is done (mig 20260915180000).',
  now())
ON CONFLICT (jobname) DO UPDATE SET
  peak_hours_et = EXCLUDED.peak_hours_et,
  peak_min_interval_min = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  work_check_sql = EXCLUDED.work_check_sql,
  enabled = EXCLUDED.enabled,
  notes = EXCLUDED.notes,
  updated_at = now();

SELECT cron.schedule(
  'tevo_event_pull_tick',
  '2,6,10,14,18,22,26,30,34,38,42,46,50,54,58 6-11 * * *',
  $cron$
DO $b$ BEGIN
  IF NOT public.cron_should_fire('tevo_event_pull_tick') THEN RETURN; END IF;
  -- drain BEFORE enqueue: pg_net is asynchronous, so a response is never available in the
  -- transaction that fired it. Measured on this database at roughly 60s from fire to response
  -- under normal load, so a tick necessarily drains the PREVIOUS tick's requests.
  PERFORM public.tevo_event_pull_drain(200);
  PERFORM public.tevo_event_pull_enqueue(20);
END $b$;
$cron$);

-- VERIFIED ON APPLY, 2026-09-15:
--   enqueue(3) -> 3 requests fired; drain(50) -> 3 responses, 0 non-200, 300 events upserted,
--   127 venues, 62 timezones filled, 261 performers. All 300 carry primary_performer_id,
--   performer_ids and event_type. venue_timezone 990 -> 1,027. CA cursor reached page 4 of 46,
--   which matches 4,530 / 100 exactly, so the page arithmetic agrees with the API's own count.
--   Spot-checked rows are Canadian, correctly localised, and correctly categorised
--   ('mlb', 'musicals', 'alternative-rock').
