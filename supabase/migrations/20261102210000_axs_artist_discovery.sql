-- Migration 20261102210000 · level:data-collection · lane:A1 (AXS ingest) · writes:axs_performers(+cols, INSERT on drain),axs_venue_directory(new),axs_catalog(+cols, source axs_artist),axs_venue_catalog(+col, INSERT/UPDATE on drain),axs_events(INSERT on drain),axs_artist_discover()(new),axs_artist_discover_drain()(new),axs_venue_catalog_refresh()(verdict patch),cron axs_artist_discover_hourly(new),cron axs_artist_discover_drain_hourly(new) · reads:axs_event_snapshots,events,net._http_response · pre:20261102200000
--
-- ============================================================================
-- AXS-native discovery: crawl AXS artist pages (operator 2026-11-02: "poll AXS instead of SeatGeek").
--
-- TicketsData's REST /events accepts platform=axs with an AXS ARTIST page (mig 20260610130000;
-- re-verified 2026-11-02: Rod Stewart → 21 events). Each item carries event_id / event_url,
-- venue_id / venue_name / city / state / country, and two flags:
--   axs_ticketed    AXS is the PRIMARY seller of this event   (Red Rocks, The O2 … true)
--   axs_marketplace listed on AXS for resale only               (Mohegan Sun, Enmarket … false)
-- An AXS VENUE page returns 0 items (tested 2026-11-02), so venues are reached through artists.
-- The MCP find_events tool does not offer axs; the REST API (credentials in vault) does, and is
-- not subject to the MCP 1,000-calls/day cap.
--
-- LOOP
--   axs_performers          the crawl list (AXS artist id + name). Topped up on every drain from
--                           the performers of every AXS event snapshot, so each pulled event can
--                           add artists, and their tours add events.
--   axs_artist_discover()   hourly: up to 15 artists not checked in 7 days → /events (1 credit each),
--                           gated by td_budget_ok().
--   axs_artist_discover_drain()  hourly, 10 minutes later, for each landed response (US only):
--     - axs_venue_directory: AXS venue id → name / city / state, events seen, AXS-sold events seen,
--       mapped to a TEvo venue (same normalised name + city);
--     - axs_catalog: every AXS-sold event (source 'axs_artist', axs_ticketed, axs_venue_id);
--     - axs_venue_catalog: mapped venues gain axs_venue_id / page and axs_ticketed_events, and a
--       venue with any AXS-sold event scores 'axs' (verdict patch below, basis 'axs_artist_tours');
--     - axs_events: upcoming AXS-sold events are added to the pull list
--       (source_sheets 'axs_artist_discovery'); the AXS pull crons stay off until resumed.
-- Cost ceiling: 15 credits/hour = 360/day. Read-only GETs; nothing is bought or held.
-- Rollback: SELECT cron.unschedule(j) FROM unnest(ARRAY['axs_artist_discover_hourly',
--   'axs_artist_discover_drain_hourly']) j; DROP FUNCTION axs_artist_discover(integer),
--   axs_artist_discover_drain(); DROP TABLE axs_venue_directory; then re-create
--   axs_venue_catalog_refresh from mig 20261102190000 + 20261102200000.
-- ============================================================================

ALTER TABLE public.axs_performers
  ADD COLUMN IF NOT EXISTS last_discovered_at timestamptz,
  ADD COLUMN IF NOT EXISTS pending_request_id bigint,
  ADD COLUMN IF NOT EXISTS events_seen        integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS source             text;

ALTER TABLE public.axs_catalog
  ADD COLUMN IF NOT EXISTS axs_ticketed boolean,
  ADD COLUMN IF NOT EXISTS axs_venue_id text;
ALTER TABLE public.axs_catalog DROP CONSTRAINT IF EXISTS axs_catalog_source_check;
ALTER TABLE public.axs_catalog ADD CONSTRAINT axs_catalog_source_check
  CHECK (source IN ('seatgeek_integrated', 'axs_events', 'sitemap', 'axs_artist'));

ALTER TABLE public.axs_venue_catalog
  ADD COLUMN IF NOT EXISTS axs_ticketed_events integer NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.axs_venue_directory (
  axs_venue_id       text        PRIMARY KEY,
  venue_name         text,
  city               text,
  state              text,
  country            text,
  tevo_venue_id      bigint,
  events_seen        integer     NOT NULL DEFAULT 0,
  axs_ticketed_seen  integer     NOT NULL DEFAULT 0,
  first_seen_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS axs_venue_directory_tevo_idx ON public.axs_venue_directory (tevo_venue_id) WHERE tevo_venue_id IS NOT NULL;
COMMENT ON TABLE public.axs_venue_directory IS
  'AXS venues seen in AXS artist tours (TicketsData /events platform=axs), keyed on AXS''s own venue id: how many events, how many AXS-sold (axs_ticketed), and the matching TEvo venue. US only (mig 20261102210000).';
ALTER TABLE public.axs_venue_directory ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.axs_venue_directory FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.axs_venue_directory TO service_role;

CREATE OR REPLACE FUNCTION public.axs_artist_discover(p_limit integer DEFAULT 15)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  r     record;
  v_req bigint;
  v_n   int := 0;
BEGIN
  IF NOT public.td_budget_ok() THEN
    RETURN 0;
  END IF;
  FOR r IN
    SELECT axs_artist_id, performer
      FROM public.axs_performers
     WHERE axs_artist_id ~ '^\d+$' AND pending_request_id IS NULL
       AND (last_discovered_at IS NULL OR last_discovered_at < now() - interval '7 days')
     ORDER BY last_discovered_at NULLS FIRST, axs_artist_id
     LIMIT greatest(p_limit, 0)
  LOOP
    SELECT net.http_get(
      url := 'https://ticketsdata.com/events',
      params := jsonb_build_object(
        'platform', 'axs',
        'performer_url', 'https://www.axs.com/artists/' || r.axs_artist_id || '/'
                         || coalesce(public.axs_slugify(r.performer), 'artist') || '-tickets',
        'username', public.get_app_secret(p_name => 'TICKETSDATA_USERNAME'),
        'password', public.get_app_secret(p_name => 'TICKETSDATA_PASSWORD')),
      timeout_milliseconds := 60000) INTO v_req;
    UPDATE public.axs_performers SET pending_request_id = v_req, updated_at = now()
     WHERE axs_artist_id = r.axs_artist_id;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.axs_artist_discover(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_artist_discover(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.axs_artist_discover_drain()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_resp     int := 0;
  v_items    int := 0;
  v_enrolled int := 0;
  v_artists  int := 0;
BEGIN
  -- 0. top up the crawl list from every AXS event snapshot's performers
  INSERT INTO public.axs_performers (axs_artist_id, performer, source, updated_at)
  SELECT DISTINCT ON (p->>'id') p->>'id', p->>'name', 'axs_snapshot', now()
    FROM public.axs_event_snapshots s,
         jsonb_array_elements(CASE WHEN jsonb_typeof(s.raw->'event'->'performers') = 'array'
                                   THEN s.raw->'event'->'performers' ELSE '[]'::jsonb END) p
   WHERE (p->>'id') ~ '^\d+$' AND p->>'name' IS NOT NULL
     AND s.captured_at > now() - interval '30 days'
  ON CONFLICT (axs_artist_id) DO NOTHING;
  GET DIAGNOSTICS v_artists = ROW_COUNT;

  -- 1. landed responses → one row per US event
  DROP TABLE IF EXISTS _axs_items;
  CREATE TEMP TABLE _axs_items ON COMMIT DROP AS
  SELECT p.axs_artist_id,
         it->>'event_id' AS event_id, it->>'event_url' AS event_url, it->>'event_title' AS title,
         nullif(left(it->>'event_date_local', 10), '')::date AS event_date,
         it->>'venue_id' AS venue_id, it->>'venue_name' AS venue_name, it->>'venue_city' AS city,
         upper(it->>'venue_state') AS state, upper(coalesce(it->>'venue_country', '')) AS country,
         coalesce((it->>'axs_ticketed')::boolean, false) AS ticketed
    FROM public.axs_performers p
    JOIN net._http_response r ON r.id = p.pending_request_id AND r.status_code = 200
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE WHEN jsonb_typeof(public.safe_jsonb(r.content)->'body'->'items') = 'array'
           THEN public.safe_jsonb(r.content)->'body'->'items' ELSE '[]'::jsonb END) it
   WHERE (it->>'event_id') ~ '^\d+$'
     AND upper(coalesce(it->>'venue_country', '')) IN ('US', 'USA', 'UNITED STATES')
     AND coalesce(it->>'event_title', '') !~* 'parking';
  GET DIAGNOSTICS v_items = ROW_COUNT;

  -- 2. AXS venue directory, mapped to TEvo venues by normalised name + city
  INSERT INTO public.axs_venue_directory AS d (axs_venue_id, venue_name, city, state, country, events_seen, axs_ticketed_seen)
  SELECT venue_id, max(venue_name), max(city), max(state), 'US', count(DISTINCT event_id), count(DISTINCT event_id) FILTER (WHERE ticketed)
    FROM _axs_items WHERE venue_id IS NOT NULL GROUP BY venue_id
  ON CONFLICT (axs_venue_id) DO UPDATE
     SET venue_name = EXCLUDED.venue_name, city = EXCLUDED.city, state = EXCLUDED.state,
         events_seen = greatest(d.events_seen, EXCLUDED.events_seen),
         axs_ticketed_seen = greatest(d.axs_ticketed_seen, EXCLUDED.axs_ticketed_seen),
         last_seen_at = now();
  UPDATE public.axs_venue_directory d
     SET tevo_venue_id = m.venue_id
    FROM (SELECT DISTINCT ON (d2.axs_venue_id) d2.axs_venue_id, e.venue_id
            FROM public.axs_venue_directory d2
            JOIN public.events e
              ON regexp_replace(regexp_replace(lower(e.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g')
               = regexp_replace(regexp_replace(lower(d2.venue_name), '^the ', ''), '[^a-z0-9]+', '', 'g')
             AND lower(btrim(reverse(split_part(reverse(e.venue_location), ',', 2)))) = lower(btrim(d2.city))
           WHERE d2.tevo_venue_id IS NULL
           ORDER BY d2.axs_venue_id, e.occurs_at_local DESC) m
   WHERE m.axs_venue_id = d.axs_venue_id;

  -- 3. AXS-sold events into the catalogue (with their AXS venue)
  INSERT INTO public.axs_catalog AS c (axs_event_id, event_url, source, event_name, venue_name, event_date, axs_ticketed, axs_venue_id)
  SELECT DISTINCT ON (event_id) event_id, coalesce(event_url, 'https://www.axs.com/events/' || event_id), 'axs_artist',
         title, venue_name, event_date, true, venue_id
    FROM _axs_items WHERE ticketed
   ORDER BY event_id
  ON CONFLICT (axs_event_id) DO UPDATE
     SET axs_ticketed = true, axs_venue_id = coalesce(c.axs_venue_id, EXCLUDED.axs_venue_id),
         event_date = coalesce(c.event_date, EXCLUDED.event_date), last_seen_at = now();

  -- 4. mapped US venues into the venue catalogue, with AXS's venue id and AXS-sold event count
  INSERT INTO public.axs_venue_catalog AS v (tevo_venue_id, venue_name, venue_location, axs_venue_id, axs_page, axs_ticketed_events)
  SELECT DISTINCT ON (d.tevo_venue_id) d.tevo_venue_id, e.venue_name, e.venue_location, d.axs_venue_id,
         'https://www.axs.com/venues/' || d.axs_venue_id, d.axs_ticketed_seen
    FROM public.axs_venue_directory d
    JOIN public.events e ON e.venue_id = d.tevo_venue_id
   WHERE public.axs_is_us_location(e.venue_location)
   ORDER BY d.tevo_venue_id, d.axs_ticketed_seen DESC, e.occurs_at_local DESC
  ON CONFLICT (tevo_venue_id) DO UPDATE
     SET axs_venue_id = coalesce(v.axs_venue_id, EXCLUDED.axs_venue_id),
         axs_page = coalesce(v.axs_page, EXCLUDED.axs_page),
         axs_ticketed_events = greatest(v.axs_ticketed_events, EXCLUDED.axs_ticketed_events);

  -- 5. upcoming AXS-sold events onto the pull list
  WITH ins AS (
    INSERT INTO public.axs_events (axs_event_id, event_url, source_sheets, active, is_axs_primary)
    SELECT DISTINCT ON (event_id) event_id, coalesce(event_url, 'https://www.axs.com/events/' || event_id),
           'axs_artist_discovery', true, true
      FROM _axs_items WHERE ticketed AND event_date >= current_date
     ORDER BY event_id
    ON CONFLICT (axs_event_id) DO NOTHING
    RETURNING 1)
  SELECT count(*) INTO v_enrolled FROM ins;

  -- 6. close out the landed requests (charge 1 credit each, as the SeatGeek drain does)
  WITH done AS (
    UPDATE public.axs_performers p
       SET last_discovered_at = now(), pending_request_id = NULL, updated_at = now(),
           events_seen = coalesce(jsonb_array_length(
             CASE WHEN jsonb_typeof(public.safe_jsonb(r.content)->'body'->'items') = 'array'
                  THEN public.safe_jsonb(r.content)->'body'->'items' END), 0)
      FROM net._http_response r
     WHERE r.id = p.pending_request_id
    RETURNING r.status_code, (public.safe_jsonb(r.content)->>'quota_remaining')::int AS quota)
  SELECT count(*) INTO v_resp FROM done;
  IF v_resp > 0 THEN
    PERFORM public.td_charge_credit(v_resp, NULL, 'AXS', '/events', 200,
              (SELECT (public.safe_jsonb(r.content)->>'quota_remaining')::int
                 FROM net._http_response r ORDER BY r.id DESC LIMIT 1));
  END IF;
  -- requests that never landed (pg_net drops responses after ~6 h): free the slot
  UPDATE public.axs_performers p SET pending_request_id = NULL
   WHERE p.pending_request_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM net._http_response r WHERE r.id = p.pending_request_id)
     AND NOT EXISTS (SELECT 1 FROM net.http_request_queue q WHERE q.id = p.pending_request_id);

  RETURN jsonb_build_object('responses', v_resp, 'us_items', v_items, 'events_enrolled', v_enrolled,
                            'artists_added', v_artists);
END $$;
REVOKE ALL ON FUNCTION public.axs_artist_discover_drain() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_artist_discover_drain() TO service_role;

-- venue verdict: any AXS-sold event seen in an AXS artist tour makes the venue 'axs'
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.axs_venue_catalog_refresh(interval)'::regprocedure);
BEGIN
  IF position('axs_artist_tours' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position($o$                WHEN c.axs_ticketed THEN 'axs'
$o$ IN v_def) = 0 OR position($o$                WHEN c.axs_ticketed THEN 'axs_venue_record'$o$ IN v_def) = 0 THEN
    RAISE EXCEPTION 'axs_venue_catalog_refresh: verdict lines not found';
  END IF;
  v_def := replace(v_def, $o$                WHEN c.axs_ticketed THEN 'axs'
$o$, $n$                WHEN c.axs_ticketed THEN 'axs'
                WHEN c.axs_ticketed_events > 0 THEN 'axs'
$n$);
  v_def := replace(v_def, $o$                WHEN c.axs_ticketed THEN 'axs_venue_record'$o$,
                   $n$                WHEN c.axs_ticketed THEN 'axs_venue_record'
                WHEN c.axs_ticketed_events > 0 THEN format('axs_artist_tours: %s AXS-sold events', c.axs_ticketed_events)$n$);
  EXECUTE v_def;
END $patch$;

SELECT cron.schedule('axs_artist_discover_hourly', '47 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_artist_discover_hourly') THEN RETURN; END IF;
  PERFORM public.axs_artist_discover(15);
END $body$;
$c$);

SELECT cron.schedule('axs_artist_discover_drain_hourly', '57 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_artist_discover_drain_hourly') THEN RETURN; END IF;
  PERFORM public.axs_artist_discover_drain();
END $body$;
$c$);
