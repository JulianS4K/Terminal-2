-- Migration 20261103090000 · level:data-collection · lane:A1 (AXS ingest) · writes:axs_export_event(new),axs_export_sync(new),axs_export_fire()(new),axs_export_tick()(new),axs_export_match()(new),v_axs_export(new),axs_venue_directory(+cols, upserts),axs_catalog(source axs_export, upserts),axs_primary_tag_refresh()(replaced: other_ticketer rule),cron axs_export_tick_1m(new),cron axs_export_match_15m(new),cron axs_artist_discover_hourly(paused) · reads:net._http_response,venue_assets,events,vault (TicketsData creds) · pre:20261102270000
--
-- ============================================================================
-- AXS catalogue from TicketsData's AXS export (operator 2026-11-03; TicketsData enabled
-- `/events?platform=axs&mode=all` for our Pro account).
--
-- WHAT THE EXPORT IS (probed 2026-11-03, 4 credits)
--   Every live AXS event, paged (limit up to 5000, 1 credit per page, one request at a time,
--   30/min). US: 60,851 events where AXS sells the primary (type=axs_primary) + 850 that AXS lists
--   while another ticketer sells them (type=other_ticketer). Parking excluded by default.
--   Each item carries the AXS event id, type / ticketer / axs_ticketed, title, headliner, AXS
--   performer ids, AXS venue id + name / address / postal code / lat-lon, local + UTC date,
--   timezone, status, announce / onsale / presale times, first / last seen.
--
-- SYNC  (axs_export_tick, every minute except :02/:05/:07, at most ONE request in flight)
--   full         daily: country=US, type=all, limit=2000 (~31 pages ≈ 31 credits, ~31 min).
--                Upcoming rows the run did not see get gone_at (left AXS / played / removed).
--   incremental  hourly between full runs: new_since = previous run start − 30 min.
--   A landed page is upserted, charged (td_charge_credit) and the next page fired; a 429 or a
--   lost response re-fires the same page next minute (5 tries, then the run stops with last_error).
--   Gated by td_budget_ok().
--
-- MATCH  (axs_export_match, every 15 minutes)
--   venue  AXS venue → TEvo venue, kept in axs_venue_directory (+lat/lon/postal/match columns):
--          1 venue_assets within 1 km with name similarity >= 0.35 (closest, then most similar),
--            or within 150 m whatever the name;
--          2 same normalised name in the same state among TEvo events' venues.
--   event  upcoming, US, not gone, not yet matched (or date changed since): TEvo events at the
--          mapped venue on the same local date. One candidate → venue_date; several → closest start
--          time, then title similarity → venue_date_time. Each TEvo event takes one AXS id
--          (best title similarity wins).
--   feed   axs_catalog gets every live US export event (rows whose event left AXS are removed;
--          an export row's TEvo link follows the latest match) (source 'axs_export', axs_ticketed from the
--          export, tevo_event_id when matched). axs_aq_link_tick (:21) then fills
--          aq_event_map.axs_event_id from it, and axs_primary_tag_refresh (:27) tags it:
--          axs_primary → confirmed (basis axs_ticketed); other_ticketer → not_axs
--          (new rule in the replaced tagger below).
--   Catalogue rows from the export are NOT enrolled into axs_events, so no /fetch snapshots follow.
--
-- ARTIST CRAWL PAUSED: the export covers every AXS-sold event; axs_artist_discover_hourly
--   (up to 16 credits/hour) is set inactive. The drain stays on to land requests in flight.
--   Re-enable: SELECT cron.alter_job(jobid, active := true) FROM cron.job WHERE jobname = 'axs_artist_discover_hourly';
--
-- Rollback: SELECT cron.unschedule('axs_export_tick_1m'); SELECT cron.unschedule('axs_export_match_15m');
--   DROP VIEW v_axs_export; DROP FUNCTION axs_export_match(int), axs_export_tick(), axs_export_fire(int);
--   DELETE FROM axs_catalog WHERE source = 'axs_export'; DROP TABLE axs_export_event, axs_export_sync;
--   re-run the axs_primary_tag_refresh() body from mig 20261102260000; re-enable the artist crawl.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.axs_export_event (
  axs_event_id       bigint      PRIMARY KEY,
  type               text,                       -- axs_primary | other_ticketer
  ticketer           text,
  axs_ticketed       boolean,
  status             text,
  event_title        text,
  event_title_clean  text,
  headliner          text,
  performers         text[],
  performer_ids      bigint[],
  tour_title         text,
  genre              text,
  major_category     text,
  age_restriction    text,
  venue_id           bigint,
  venue_name         text,
  venue_address      text,
  venue_city         text,
  venue_state        text,
  venue_country      text,
  venue_postal_code  text,
  venue_lat          numeric,
  venue_lon          numeric,
  event_date_local   text,
  event_date_utc     timestamptz,
  event_timezone     text,
  is_tba             boolean,
  announce_utc       timestamptz,
  onsale_utc         timestamptz,
  presale_utc        timestamptz,
  first_seen_utc     timestamptz,
  last_seen_utc      timestamptz,
  removed_utc        timestamptz,
  event_url          text,
  tevo_event_id      bigint,
  tevo_venue_id      bigint,
  match_method       text,
  matched_date       text,                       -- event_date_local the match was made on
  matched_at         timestamptz,
  first_synced_at    timestamptz NOT NULL DEFAULT now(),
  last_synced_at     timestamptz NOT NULL DEFAULT now(),
  gone_at            timestamptz
);
CREATE INDEX IF NOT EXISTS axs_export_event_venue_idx ON public.axs_export_event (venue_id, event_date_local);
CREATE INDEX IF NOT EXISTS axs_export_event_tevo_idx  ON public.axs_export_event (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS axs_export_event_unmatched_idx ON public.axs_export_event (event_date_local)
  WHERE tevo_event_id IS NULL AND gone_at IS NULL;
COMMENT ON TABLE public.axs_export_event IS
  'Every live AXS event (US) from TicketsData''s AXS export, matched to TEvo events. Synced by axs_export_tick(), matched by axs_export_match() (mig 20261103090000).';
ALTER TABLE public.axs_export_event ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_export_event FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_export_event TO service_role;

CREATE TABLE IF NOT EXISTS public.axs_export_sync (
  id                 int         PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  run_kind           text,                       -- full | incremental | NULL (idle)
  run_started_at     timestamptz,
  run_params         jsonb,
  page               int,
  tries              int         NOT NULL DEFAULT 0,
  pending_request_id bigint,
  pending_since      timestamptz,
  pages_in_run       int         NOT NULL DEFAULT 0,
  rows_in_run        int         NOT NULL DEFAULT 0,
  last_full_started_at timestamptz,
  last_full_done_at  timestamptz,
  last_incr_started_at timestamptz,
  last_incr_done_at  timestamptz,
  last_error         text,
  updated_at         timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.axs_export_sync (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.axs_export_sync ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_export_sync FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_export_sync TO service_role;

ALTER TABLE public.axs_venue_directory
  ADD COLUMN IF NOT EXISTS venue_lat         numeric,
  ADD COLUMN IF NOT EXISTS venue_lon         numeric,
  ADD COLUMN IF NOT EXISTS venue_postal_code text,
  ADD COLUMN IF NOT EXISTS venue_address     text,
  ADD COLUMN IF NOT EXISTS match_method      text,
  ADD COLUMN IF NOT EXISTS match_distance_m  integer;

ALTER TABLE public.axs_catalog DROP CONSTRAINT IF EXISTS axs_catalog_source_check;
ALTER TABLE public.axs_catalog ADD CONSTRAINT axs_catalog_source_check
  CHECK (source IN ('seatgeek_integrated', 'axs_events', 'sitemap', 'axs_artist', 'axs_export'));

-- ---------------------------------------------------------------------------
-- fire one page
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.axs_export_fire(p_page int)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  s     public.axs_export_sync;
  v_req bigint;
BEGIN
  SELECT * INTO s FROM public.axs_export_sync WHERE id = 1;
  SELECT net.http_get(
           url := 'https://ticketsdata.com/events',
           params := coalesce(s.run_params, '{}'::jsonb)
                     || jsonb_build_object('platform', 'axs', 'mode', 'all', 'page', p_page::text,
                          'username', public.get_app_secret(p_name => 'TICKETSDATA_USERNAME'),
                          'password', public.get_app_secret(p_name => 'TICKETSDATA_PASSWORD')),
           timeout_milliseconds := 120000) INTO v_req;
  UPDATE public.axs_export_sync
     SET page = p_page, pending_request_id = v_req, pending_since = now(), updated_at = now()
   WHERE id = 1;
  RETURN v_req;
END $$;
REVOKE ALL ON FUNCTION public.axs_export_fire(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_export_fire(int) TO service_role;

-- ---------------------------------------------------------------------------
-- the driver: land the pending page, fire the next, or start a run
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.axs_export_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  s       public.axs_export_sync;
  r       record;
  j       jsonb;
  v_rows  int := 0;
  v_gone  int := 0;
BEGIN
  SELECT * INTO s FROM public.axs_export_sync WHERE id = 1 FOR UPDATE;

  -- 1. a page is in flight
  IF s.pending_request_id IS NOT NULL THEN
    SELECT x.status_code, x.content INTO r FROM net._http_response x WHERE x.id = s.pending_request_id;
    IF NOT FOUND THEN
      IF s.pending_since > now() - interval '5 minutes' THEN
        RETURN jsonb_build_object('state', 'waiting', 'page', s.page);
      END IF;
      r := NULL;                                           -- lost: retry below
    END IF;

    j := CASE WHEN r IS NOT NULL THEN public.safe_jsonb(r.content) END;
    IF r IS NULL OR r.status_code IS DISTINCT FROM 200 OR jsonb_typeof(j->'body'->'items') IS DISTINCT FROM 'array' THEN
      IF s.tries >= 5 THEN
        UPDATE public.axs_export_sync
           SET run_kind = NULL, pending_request_id = NULL, tries = 0, updated_at = now(),
               last_error = format('%s run stopped on page %s: http %s %s', s.run_kind, s.page,
                                   coalesce(r.status_code::text, 'lost'), left(coalesce(r.content, ''), 200))
         WHERE id = 1;
        RETURN jsonb_build_object('state', 'run_stopped', 'page', s.page);
      END IF;
      UPDATE public.axs_export_sync SET tries = tries + 1, pending_request_id = NULL, updated_at = now() WHERE id = 1;
      PERFORM public.axs_export_fire(s.page);              -- same page again
      RETURN jsonb_build_object('state', 'retry', 'page', s.page, 'http', r.status_code);
    END IF;

    -- landed: upsert the page
    INSERT INTO public.axs_export_event AS e (
      axs_event_id, type, ticketer, axs_ticketed, status, event_title, event_title_clean, headliner,
      performers, performer_ids, tour_title, genre, major_category, age_restriction,
      venue_id, venue_name, venue_address, venue_city, venue_state, venue_country, venue_postal_code,
      venue_lat, venue_lon, event_date_local, event_date_utc, event_timezone, is_tba,
      announce_utc, onsale_utc, presale_utc, first_seen_utc, last_seen_utc, removed_utc, event_url,
      last_synced_at, gone_at)
    SELECT (i->>'event_id')::bigint, i->>'type', i->>'ticketer', (i->>'axs_ticketed')::boolean, i->>'status',
           i->>'event_title', i->>'event_title_clean', i->>'headliner',
           CASE WHEN jsonb_typeof(i->'performers') = 'array'
                THEN ARRAY(SELECT jsonb_array_elements_text(i->'performers')) END,
           CASE WHEN jsonb_typeof(i->'performer_ids') = 'array'
                THEN ARRAY(SELECT (p #>> '{}')::bigint FROM jsonb_array_elements(i->'performer_ids') p
                            WHERE (p #>> '{}') ~ '^\d+$') END,
           i->>'tour_title', i->>'genre', i->>'major_category', i->>'age_restriction',
           (i->>'venue_id')::bigint, i->>'venue_name', i->>'venue_address', i->>'venue_city',
           i->>'venue_state', i->>'venue_country', i->>'venue_postal_code',
           (i->>'venue_lat')::numeric, (i->>'venue_lon')::numeric,
           i->>'event_date_local', (i->>'event_date_utc')::timestamptz, i->>'event_timezone',
           (i->>'is_tba')::boolean, (i->>'announce_utc')::timestamptz, (i->>'onsale_utc')::timestamptz,
           (i->>'presale_utc')::timestamptz, (i->>'first_seen_utc')::timestamptz,
           (i->>'last_seen_utc')::timestamptz, (i->>'removed_utc')::timestamptz, i->>'event_url',
           now(), NULL
      FROM jsonb_array_elements(j->'body'->'items') i
     WHERE (i->>'event_id') ~ '^\d+$'
    ON CONFLICT (axs_event_id) DO UPDATE SET
      type = EXCLUDED.type, ticketer = EXCLUDED.ticketer, axs_ticketed = EXCLUDED.axs_ticketed,
      status = EXCLUDED.status, event_title = EXCLUDED.event_title,
      event_title_clean = EXCLUDED.event_title_clean, headliner = EXCLUDED.headliner,
      performers = EXCLUDED.performers, performer_ids = EXCLUDED.performer_ids,
      tour_title = EXCLUDED.tour_title, genre = EXCLUDED.genre, major_category = EXCLUDED.major_category,
      age_restriction = EXCLUDED.age_restriction, venue_id = EXCLUDED.venue_id,
      venue_name = EXCLUDED.venue_name, venue_address = EXCLUDED.venue_address,
      venue_city = EXCLUDED.venue_city, venue_state = EXCLUDED.venue_state,
      venue_country = EXCLUDED.venue_country, venue_postal_code = EXCLUDED.venue_postal_code,
      venue_lat = EXCLUDED.venue_lat, venue_lon = EXCLUDED.venue_lon,
      event_date_local = EXCLUDED.event_date_local, event_date_utc = EXCLUDED.event_date_utc,
      event_timezone = EXCLUDED.event_timezone, is_tba = EXCLUDED.is_tba,
      announce_utc = EXCLUDED.announce_utc, onsale_utc = EXCLUDED.onsale_utc,
      presale_utc = EXCLUDED.presale_utc, first_seen_utc = EXCLUDED.first_seen_utc,
      last_seen_utc = EXCLUDED.last_seen_utc, removed_utc = EXCLUDED.removed_utc,
      event_url = EXCLUDED.event_url, last_synced_at = now(), gone_at = NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    PERFORM public.td_charge_credit(1, NULL, 'AXS', '/events?mode=all', 200, (j->>'quota_remaining')::int);

    UPDATE public.axs_export_sync
       SET pending_request_id = NULL, tries = 0, pages_in_run = pages_in_run + 1,
           rows_in_run = rows_in_run + v_rows, last_error = NULL, updated_at = now()
     WHERE id = 1;

    IF coalesce((j->'body'->>'has_more')::boolean, false) AND (j->'body'->>'next_page') ~ '^\d+$' THEN
      PERFORM public.axs_export_fire((j->'body'->>'next_page')::int);
      RETURN jsonb_build_object('state', 'page_landed', 'page', s.page, 'rows', v_rows);
    END IF;

    -- run finished
    IF s.run_kind = 'full' THEN
      UPDATE public.axs_export_event e SET gone_at = now()
       WHERE e.gone_at IS NULL AND e.last_synced_at < s.run_started_at;
      GET DIAGNOSTICS v_gone = ROW_COUNT;
      UPDATE public.axs_export_sync SET last_full_done_at = now() WHERE id = 1;
    ELSE
      UPDATE public.axs_export_sync SET last_incr_done_at = now() WHERE id = 1;
    END IF;
    UPDATE public.axs_export_sync SET run_kind = NULL, updated_at = now() WHERE id = 1;
    RETURN jsonb_build_object('state', 'run_done', 'kind', s.run_kind, 'pages', s.pages_in_run + 1,
                              'rows', s.rows_in_run + v_rows, 'gone', v_gone);
  END IF;

  -- 2. idle: start a run when one is due
  IF NOT public.td_budget_ok() THEN
    RETURN jsonb_build_object('state', 'budget_blocked');
  END IF;
  IF s.last_full_started_at IS NULL OR s.last_full_started_at < now() - interval '23 hours' THEN
    UPDATE public.axs_export_sync
       SET run_kind = 'full', run_started_at = now(), last_full_started_at = now(),
           run_params = jsonb_build_object('country', 'US', 'type', 'all', 'limit', '2000'),
           pages_in_run = 0, rows_in_run = 0, tries = 0
     WHERE id = 1;
  ELSIF coalesce(s.last_incr_started_at, s.last_full_started_at) < now() - interval '1 hour' THEN
    UPDATE public.axs_export_sync
       SET run_kind = 'incremental', run_started_at = now(), last_incr_started_at = now(),
           run_params = jsonb_build_object('country', 'US', 'type', 'all', 'limit', '2000',
                          'new_since', to_char(coalesce(s.last_incr_started_at, s.last_full_started_at)
                                               - interval '30 minutes', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
           pages_in_run = 0, rows_in_run = 0, tries = 0
     WHERE id = 1;
  ELSE
    RETURN jsonb_build_object('state', 'idle');
  END IF;
  PERFORM public.axs_export_fire(1);
  RETURN jsonb_build_object('state', 'run_started');
END $$;
REVOKE ALL ON FUNCTION public.axs_export_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_export_tick() TO service_role;

-- ---------------------------------------------------------------------------
-- matcher: AXS venues → TEvo venues, AXS events → TEvo events, then the catalogue
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.axs_export_match(p_limit int DEFAULT 20000)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_venues  int := 0;
  v_vmatch  int := 0;
  v_events  int := 0;
  v_reset   int := 0;
  v_catalog int := 0;
BEGIN
  -- 1. AXS venues seen in the export
  INSERT INTO public.axs_venue_directory AS d
         (axs_venue_id, venue_name, city, state, country, venue_lat, venue_lon, venue_postal_code,
          venue_address, events_seen, axs_ticketed_seen)
  SELECT x.venue_id::text, max(x.venue_name), max(x.venue_city), max(x.venue_state), max(x.venue_country),
         max(x.venue_lat), max(x.venue_lon), max(x.venue_postal_code), max(x.venue_address),
         count(*), count(*) FILTER (WHERE x.axs_ticketed)
    FROM public.axs_export_event x
   WHERE x.venue_id IS NOT NULL AND x.gone_at IS NULL
   GROUP BY x.venue_id
  ON CONFLICT (axs_venue_id) DO UPDATE SET
    venue_name = EXCLUDED.venue_name, city = EXCLUDED.city, state = EXCLUDED.state,
    country = EXCLUDED.country, venue_lat = EXCLUDED.venue_lat, venue_lon = EXCLUDED.venue_lon,
    venue_postal_code = EXCLUDED.venue_postal_code, venue_address = EXCLUDED.venue_address,
    events_seen = greatest(d.events_seen, EXCLUDED.events_seen),
    axs_ticketed_seen = greatest(d.axs_ticketed_seen, EXCLUDED.axs_ticketed_seen),
    last_seen_at = now();
  GET DIAGNOSTICS v_venues = ROW_COUNT;

  -- 2. unmapped AXS venues → TEvo venue
  WITH todo AS (
    SELECT d.axs_venue_id, d.venue_name, d.state, d.venue_lat, d.venue_lon,
           regexp_replace(regexp_replace(lower(d.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') AS norm
      FROM public.axs_venue_directory d
     WHERE d.tevo_venue_id IS NULL AND d.country = 'US'),
  geo AS (
    SELECT DISTINCT ON (t.axs_venue_id) t.axs_venue_id, a.tevo_venue_id,
           round(111320 * sqrt(power(a.latitude - t.venue_lat, 2)
                 + power((a.longitude - t.venue_lon) * cos(radians(t.venue_lat)), 2)))::int AS dist_m,
           similarity(lower(a.venue_name), lower(t.venue_name)) AS sim
      FROM todo t
      JOIN public.venue_assets a
        ON t.venue_lat IS NOT NULL AND a.latitude IS NOT NULL
       AND a.latitude  BETWEEN t.venue_lat - 0.01 AND t.venue_lat + 0.01
       AND a.longitude BETWEEN t.venue_lon - 0.013 AND t.venue_lon + 0.013
     ORDER BY t.axs_venue_id,
              (similarity(lower(a.venue_name), lower(t.venue_name)) >= 0.35) DESC,
              111320 * sqrt(power(a.latitude - t.venue_lat, 2)
                 + power((a.longitude - t.venue_lon) * cos(radians(t.venue_lat)), 2)),
              similarity(lower(a.venue_name), lower(t.venue_name)) DESC),
  geo_ok AS (
    SELECT * FROM geo WHERE (dist_m <= 1000 AND sim >= 0.35) OR dist_m <= 150),
  tv AS (   -- TEvo venues as named on upcoming events, with the state from venue_location
    SELECT DISTINCT e.venue_id,
           regexp_replace(regexp_replace(lower(e.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g') AS norm,
           upper(btrim(reverse(split_part(reverse(e.venue_location), ',', 1)))) AS state
      FROM public.events e
     WHERE e.occurs_at_local >= to_char(now() - interval '1 day', 'YYYY-MM-DD') AND e.venue_id IS NOT NULL),
  byname AS (
    SELECT t.axs_venue_id, min(tv.venue_id) AS tevo_venue_id
      FROM todo t JOIN tv ON tv.norm = t.norm AND tv.state = upper(t.state)
     WHERE NOT EXISTS (SELECT 1 FROM geo_ok g WHERE g.axs_venue_id = t.axs_venue_id)
     GROUP BY t.axs_venue_id HAVING count(DISTINCT tv.venue_id) = 1),
  pick AS (
    SELECT axs_venue_id, tevo_venue_id, 'geo' AS method, dist_m FROM geo_ok
    UNION ALL
    SELECT axs_venue_id, tevo_venue_id, 'name_state', NULL FROM byname)
  UPDATE public.axs_venue_directory d
     SET tevo_venue_id = p.tevo_venue_id, match_method = p.method, match_distance_m = p.dist_m
    FROM pick p WHERE d.axs_venue_id = p.axs_venue_id;
  GET DIAGNOSTICS v_vmatch = ROW_COUNT;

  -- 3. a matched event whose date moved is matched again
  UPDATE public.axs_export_event x
     SET tevo_event_id = NULL, tevo_venue_id = NULL, match_method = NULL, matched_date = NULL, matched_at = NULL
   WHERE x.tevo_event_id IS NOT NULL AND x.matched_date IS DISTINCT FROM x.event_date_local;
  GET DIAGNOSTICS v_reset = ROW_COUNT;

  -- 4. AXS events → TEvo events: same mapped venue, same local date; time then title break ties
  WITH todo AS (
    SELECT x.axs_event_id, x.event_date_local, x.is_tba,
           coalesce(x.event_title_clean, x.event_title) AS title, d.tevo_venue_id
      FROM public.axs_export_event x
      JOIN public.axs_venue_directory d ON d.axs_venue_id = x.venue_id::text AND d.tevo_venue_id IS NOT NULL
     WHERE x.tevo_event_id IS NULL AND x.gone_at IS NULL AND x.venue_country = 'US'
       AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')
     ORDER BY x.event_date_local
     LIMIT greatest(p_limit, 0)),
  cand AS (
    SELECT t.axs_event_id, t.event_date_local, e.id AS tevo_event_id, t.tevo_venue_id,
           count(*) OVER (PARTITION BY t.axs_event_id) AS n_same_day,
           CASE WHEN t.is_tba OR substr(e.occurs_at_local, 12, 5) !~ '^\d\d:\d\d$' THEN 0
                ELSE abs(extract(epoch FROM (substr(e.occurs_at_local, 12, 5)::time
                                             - substr(t.event_date_local, 12, 5)::time)) / 60) END AS dmin,
           similarity(lower(coalesce(e.primary_performer_name, '') || ' ' || coalesce(e.name, '')), lower(t.title)) AS sim
      FROM todo t
      JOIN public.events e ON e.venue_id = t.tevo_venue_id AND left(e.occurs_at_local, 10) = left(t.event_date_local, 10)
     WHERE coalesce(e.state, 'shown') <> 'ignored'),
  best_per_axs AS (
    SELECT DISTINCT ON (axs_event_id) * FROM cand
     WHERE n_same_day = 1 OR dmin <= 90 OR sim >= 0.3
     ORDER BY axs_event_id, dmin, sim DESC),
  best_per_tevo AS (   -- one AXS id per TEvo event, not already taken by another AXS id
    SELECT DISTINCT ON (b.tevo_event_id) b.*
      FROM best_per_axs b
     WHERE NOT EXISTS (SELECT 1 FROM public.axs_export_event o
                        WHERE o.tevo_event_id = b.tevo_event_id AND o.axs_event_id <> b.axs_event_id)
     ORDER BY b.tevo_event_id, b.sim DESC, b.dmin, b.axs_event_id)
  UPDATE public.axs_export_event x
     SET tevo_event_id = b.tevo_event_id, tevo_venue_id = b.tevo_venue_id,
         match_method = CASE WHEN b.n_same_day = 1 THEN 'venue_date' ELSE 'venue_date_time' END,
         matched_date = b.event_date_local, matched_at = now()
    FROM best_per_tevo b WHERE x.axs_event_id = b.axs_event_id;
  GET DIAGNOSTICS v_events = ROW_COUNT;

  -- 5. catalogue feed (every live US upcoming export event)
  INSERT INTO public.axs_catalog AS c
         (axs_event_id, event_url, source, tevo_event_id, event_name, venue_name, event_date,
          axs_ticketed, axs_venue_id)
  SELECT x.axs_event_id::text, coalesce(x.event_url, 'https://www.axs.com/events/' || x.axs_event_id),
         'axs_export', x.tevo_event_id, x.event_title, x.venue_name,
         left(x.event_date_local, 10)::date, x.axs_ticketed, x.venue_id::text
    FROM public.axs_export_event x
   WHERE x.gone_at IS NULL AND x.venue_country = 'US'
     AND x.event_date_local ~ '^\d{4}-\d\d-\d\d' AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD')
  ON CONFLICT (axs_event_id) DO UPDATE SET
    tevo_event_id = CASE WHEN c.source = 'axs_export' THEN EXCLUDED.tevo_event_id
                         ELSE coalesce(EXCLUDED.tevo_event_id, c.tevo_event_id) END,
    axs_ticketed  = EXCLUDED.axs_ticketed,
    axs_venue_id  = coalesce(EXCLUDED.axs_venue_id, c.axs_venue_id),
    event_date    = EXCLUDED.event_date,
    event_name    = coalesce(c.event_name, EXCLUDED.event_name),
    venue_name    = coalesce(c.venue_name, EXCLUDED.venue_name),
    last_seen_at  = now();
  GET DIAGNOSTICS v_catalog = ROW_COUNT;

  -- export-sourced catalogue rows whose event left AXS (or was played) go
  DELETE FROM public.axs_catalog c
   WHERE c.source = 'axs_export'
     AND NOT EXISTS (SELECT 1 FROM public.axs_export_event x
                      WHERE x.axs_event_id::text = c.axs_event_id AND x.gone_at IS NULL);

  RETURN jsonb_build_object('venues_seen', v_venues, 'venues_mapped_now', v_vmatch,
                            'events_rematched', v_reset, 'events_matched_now', v_events,
                            'catalog_rows', v_catalog);
END $$;
REVOKE ALL ON FUNCTION public.axs_export_match(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_export_match(int) TO service_role;

CREATE OR REPLACE VIEW public.v_axs_export WITH (security_invoker = true) AS
SELECT x.axs_event_id, x.type, x.status, x.event_title, x.headliner, x.event_date_local,
       x.venue_name, x.venue_city, x.venue_state, x.onsale_utc, x.presale_utc,
       x.tevo_event_id, x.match_method,
       (SELECT min(m.aq_short_event_id) FROM public.aq_event_map m WHERE m.tevo_event_id = x.tevo_event_id) AS aq_short_event_id,
       d.tevo_venue_id AS tevo_venue_id_mapped, d.match_method AS venue_match_method, x.event_url,
       x.first_seen_utc, x.last_synced_at
  FROM public.axs_export_event x
  LEFT JOIN public.axs_venue_directory d ON d.axs_venue_id = x.venue_id::text
 WHERE x.gone_at IS NULL AND x.venue_country = 'US'
   AND x.event_date_local >= to_char(now(), 'YYYY-MM-DD');
REVOKE ALL ON public.v_axs_export FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_axs_export TO service_role;

-- ---------------------------------------------------------------------------
-- tagger: an event AXS lists but another ticketer sells → not_axs
-- (the body is mig 20261102260000's with one more evidence flag and rule)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.axs_primary_tag_refresh()
RETURNS jsonb LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_rows   int;
  v_gone   int;
  v_counts jsonb;
BEGIN
  DROP TABLE IF EXISTS _axs_ids, _axs_tag;

  -- every AXS id we hold for a TEvo event, best source first
  CREATE TEMP TABLE _axs_ids ON COMMIT DROP AS
  SELECT DISTINCT ON (tevo_event_id) tevo_event_id, axs_event_id, src
    FROM (
      SELECT m.tevo_event_id, m.axs_event_id, 'aq_event_map' AS src, 1 AS pri
        FROM public.aq_event_map m WHERE m.tevo_event_id IS NOT NULL AND m.axs_event_id IS NOT NULL
      UNION ALL
      SELECT a.tevo_event_id, a.axs_event_id, 'axs_events', 2
        FROM public.axs_events a
       WHERE a.tevo_event_id IS NOT NULL AND coalesce(a.is_axs_primary, true)
         AND coalesce(a.probe_status, 'axs_ok') <> 'not_axs'
      UNION ALL
      SELECT c.tevo_event_id, c.axs_event_id, 'axs_catalog:' || c.source, 3
        FROM public.axs_catalog c WHERE c.tevo_event_id IS NOT NULL AND coalesce(c.axs_ticketed, true)
      UNION ALL
      SELECT r.tevo_event_id,
             substring(coalesce(r.tm_url, '') || ' ' || coalesce(r.matches_raw::text, '') FROM 'axs\.com/events/(\d+)'),
             'td_match', 4
        FROM public.td_match_results r
       WHERE r.tevo_event_id IS NOT NULL
         AND (coalesce(r.tm_url, '') || ' ' || coalesce(r.matches_raw::text, '')) ~ 'axs\.com/events/\d+'
    ) s
   ORDER BY tevo_event_id, pri;

  CREATE TEMP TABLE _axs_tag ON COMMIT DROP AS
  WITH ev AS (
    SELECT e.id, e.name, e.venue_id, e.venue_name, e.venue_location, e.occurs_at_local
      FROM public.events e
     WHERE e.occurs_at_local ~ '^\d{4}-\d\d-\d\d' AND left(e.occurs_at_local, 10) >= current_date::text
       AND coalesce(e.state, 'shown') <> 'ignored'
       AND coalesce(e.name, '') !~* 'parking|shuttle'
       AND public.axs_is_us_location(e.venue_location)
       AND (EXISTS (SELECT 1 FROM public.axs_venue_catalog v WHERE v.tevo_venue_id = e.venue_id AND v.verdict IN ('axs', 'mixed'))
            OR EXISTS (SELECT 1 FROM _axs_ids i WHERE i.tevo_event_id = e.id)
            OR EXISTS (SELECT 1 FROM public.axs_primary_signal p WHERE p.tevo_event_id = e.id AND p.axs_share >= 0.30)
            OR EXISTS (SELECT 1 FROM public.sg_events_canonical g WHERE g.tevo_event_id = e.id
                          AND g.raw_event_jsonb->'integrated'->>'provider_name' = 'AXS'))),
  sg AS (
    SELECT DISTINCT ON (g.tevo_event_id) g.tevo_event_id, g.raw_event_jsonb->'integrated'->>'provider_name' AS seller,
           substring(g.raw_event_jsonb->'integrated'->>'provider_id' FROM '(\d+)$') AS sg_axs_id
      FROM public.sg_events_canonical g
     WHERE g.tevo_event_id IS NOT NULL AND g.raw_event_jsonb->'integrated'->>'provider_name' IS NOT NULL
     ORDER BY g.tevo_event_id, (g.raw_event_jsonb->'integrated'->>'provider_name' = 'AXS') DESC, g.updated_at DESC),
  pull AS (   -- latest AXS pull per event: primary inventory vs resale only
    SELECT DISTINCT ON (s.tevo_event_id) s.tevo_event_id,
           (coalesce(s.seats_primary, 0) > 0 OR s.ga_price_levels IS NOT NULL) AS pull_primary,
           (coalesce(s.seats_primary, 0) = 0 AND s.ga_price_levels IS NULL AND coalesce(s.seats_resale, 0) > 0) AS pull_resale_only
      FROM public.axs_event_snapshots s
     WHERE s.tevo_event_id IS NOT NULL
     ORDER BY s.tevo_event_id, s.id DESC)
  SELECT ev.*, i.axs_event_id AS known_id, i.src, sg.seller, sg.sg_axs_id,
         coalesce(pull.pull_primary, false) AS pull_primary, coalesce(pull.pull_resale_only, false) AS pull_resale_only,
         EXISTS (SELECT 1 FROM public.axs_catalog c WHERE c.tevo_event_id = ev.id AND c.axs_ticketed) AS axs_ticketed,
         EXISTS (SELECT 1 FROM public.td_match_results r WHERE r.tevo_event_id = ev.id
                    AND (coalesce(r.tm_url, '') || ' ' || coalesce(r.matches_raw::text, '')) ~ 'axs\.com/events/\d+') AS td_primary,
         EXISTS (SELECT 1 FROM public.axs_catalog c WHERE c.tevo_event_id = ev.id AND c.axs_ticketed = false)
           AND NOT EXISTS (SELECT 1 FROM public.axs_catalog c WHERE c.tevo_event_id = ev.id AND c.axs_ticketed) AS other_ticketer,
         v.verdict AS venue_verdict, v.verdict_basis,
         p.axs_share, p.gt_rows + p.evo_rows AS signal_rows,
         (SELECT min(m.aq_short_event_id) FROM public.aq_event_map m WHERE m.tevo_event_id = ev.id) AS aq_id
    FROM ev
    LEFT JOIN _axs_ids i ON i.tevo_event_id = ev.id
    LEFT JOIN sg ON sg.tevo_event_id = ev.id
    LEFT JOIN public.axs_venue_catalog v ON v.tevo_venue_id = ev.venue_id
    LEFT JOIN public.axs_primary_signal p ON p.tevo_event_id = ev.id
    LEFT JOIN pull ON pull.tevo_event_id = ev.id;

  INSERT INTO public.event_axs_primary AS t
         (tevo_event_id, status, basis, axs_event_id, event_url, aq_short_event_id, event_name, venue_id,
          venue_name, venue_location, occurs_at_local, venue_verdict, seatgeek_seller, delivery_share, updated_at)
  SELECT x.id, x.status, x.basis, x.axs_id,
         CASE WHEN x.axs_id IS NOT NULL THEN 'https://www.axs.com/events/' || x.axs_id END,
         x.aq_id, x.name, x.venue_id, x.venue_name, x.venue_location, x.occurs_at_local,
         x.venue_verdict, x.seller, x.axs_share, now()
    FROM (
      SELECT t.*,
             coalesce(t.known_id, CASE WHEN t.seller = 'AXS' THEN t.sg_axs_id END) AS axs_id,
             CASE
               WHEN t.seller = 'AXS' OR t.pull_primary OR t.axs_ticketed OR t.td_primary THEN 'confirmed'
               WHEN t.axs_share >= 0.30 AND t.signal_rows >= 50 THEN 'confirmed'
               WHEN t.pull_resale_only THEN 'axs_resale'
               WHEN t.seller IS NOT NULL OR t.other_ticketer THEN 'not_axs'
               WHEN t.venue_verdict = 'axs' THEN 'probable'
               WHEN t.known_id IS NOT NULL THEN 'axs_listed'
             END AS status,
             CASE
               WHEN t.seller = 'AXS' THEN 'seatgeek_seller:AXS'
               WHEN t.pull_primary THEN 'axs_pull:primary_inventory'
               WHEN t.axs_ticketed THEN 'axs_ticketed'
               WHEN t.td_primary THEN 'td_match:primary_link'
               WHEN t.axs_share >= 0.30 AND t.signal_rows >= 50
                 THEN format('delivery %s%% of %s rows', round(100 * t.axs_share), t.signal_rows)
               WHEN t.pull_resale_only THEN 'axs_pull:resale_only'
               WHEN t.other_ticketer AND t.seller IS NULL THEN 'axs_export:other_ticketer'
               WHEN t.seller IS NOT NULL
                 THEN 'seatgeek_seller:' || t.seller || CASE WHEN t.known_id IS NOT NULL THEN ' (AXS id is a resale page)' ELSE '' END
               WHEN t.venue_verdict = 'axs'
                 THEN 'axs_venue:' || coalesce(t.verdict_basis, 'axs') || CASE WHEN t.known_id IS NOT NULL THEN ' +axs_id:' || t.src ELSE '' END
               WHEN t.known_id IS NOT NULL THEN 'axs_id:' || t.src || ' (primary unproven)'
             END AS basis
        FROM _axs_tag t) x
   WHERE x.status IS NOT NULL
  ON CONFLICT (tevo_event_id) DO UPDATE
     SET status = EXCLUDED.status, basis = EXCLUDED.basis,
         axs_event_id = EXCLUDED.axs_event_id,
         event_url = EXCLUDED.event_url,
         aq_short_event_id = coalesce(EXCLUDED.aq_short_event_id, t.aq_short_event_id),
         event_name = EXCLUDED.event_name, venue_id = EXCLUDED.venue_id, venue_name = EXCLUDED.venue_name,
         venue_location = EXCLUDED.venue_location, occurs_at_local = EXCLUDED.occurs_at_local,
         venue_verdict = EXCLUDED.venue_verdict, seatgeek_seller = EXCLUDED.seatgeek_seller,
         delivery_share = EXCLUDED.delivery_share,
         status_changed_at = CASE WHEN t.status IS DISTINCT FROM EXCLUDED.status THEN now() ELSE t.status_changed_at END,
         updated_at = now();
  GET DIAGNOSTICS v_rows = ROW_COUNT;

  -- past events, and events that lost all evidence, leave the table
  DELETE FROM public.event_axs_primary t
   WHERE left(t.occurs_at_local, 10) < current_date::text
      OR t.updated_at < now();   -- not touched by this run (rows written above carry now())
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  SELECT jsonb_object_agg(status, n) INTO v_counts
    FROM (SELECT status, count(*) n FROM public.event_axs_primary GROUP BY 1) c;
  RETURN jsonb_build_object('tagged', v_rows, 'removed', v_gone, 'by_status', v_counts);
END $$;
REVOKE ALL ON FUNCTION public.axs_primary_tag_refresh() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_primary_tag_refresh() TO service_role;

-- ---------------------------------------------------------------------------
-- crons
-- ---------------------------------------------------------------------------
SELECT cron.schedule('axs_export_tick_1m', '0,1,3,4,6,8-59 * * * *', $c$   -- every minute except :02/:05/:07
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_export_tick_1m') THEN RETURN; END IF;
  PERFORM public.axs_export_tick();
END $body$;
$c$);

SELECT cron.schedule('axs_export_match_15m', '4,19,34,49 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_export_match_15m') THEN RETURN; END IF;
  PERFORM public.axs_export_match();
END $body$;
$c$);

-- the AXS export replaces the per-artist crawl
SELECT cron.alter_job(j.jobid, active := false)
  FROM cron.job j WHERE j.jobname = 'axs_artist_discover_hourly' AND j.active;
