-- Migration 20261102250000 · level:data-collection · lane:A1 (AXS ingest) · writes:axs_artist_discover()(cap),axs_artist_discover_drain()(retry failures),axs_performers(reset 11 artists),cron axs_artist_discover_hourly(→ :17 and :47) · reads:axs_performers,td_match_queue,net._http_response · pre:20261102240000
--
-- ============================================================================
-- AXS artist crawl: stay under TicketsData's pending-request limit, and retry what it refused.
--
-- First prod run (2026-11-02 19:4x): 30 lookups fired at once (seed + two re-runs of the finish
-- paste); 19 returned 200 (67 tour items), 11 returned 429 "Too many pending requests for this
-- account (max 10 at a time)". The drain then stamped all 30 as discovered, so the 11 would have
-- waited a week.
--   * axs_artist_discover: fires at most 8 minus the lookups already pending minus /match calls
--     fired in the last 5 minutes (shared account limit of 10); default 8 per run.
--   * axs_artist_discover_drain: only a 200 marks an artist discovered; any other status just
--     frees the slot, and the artist is picked up by the next run.
--   * cron: the crawl runs at :17 and :47 (8 each, ~16/hour, same daily ceiling as before).
--   * the 11 refused artists are made due again.
-- Rollback: re-create both functions from mig 20261102210000; reschedule axs_artist_discover_hourly
--   at '47 * * * *' with axs_artist_discover(15).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.axs_artist_discover(p_limit integer DEFAULT 8)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  r       record;
  v_req   bigint;
  v_n     int := 0;
  v_slots int;
BEGIN
  IF NOT public.td_budget_ok() THEN
    RETURN 0;
  END IF;
  -- TicketsData allows 10 pending requests per account: keep this crawl to 8 minus what is in flight
  v_slots := 8 - (SELECT count(*) FROM public.axs_performers WHERE pending_request_id IS NOT NULL)
               - (SELECT count(*) FROM public.td_match_queue
                   WHERE resolved_at IS NULL AND request_id IS NOT NULL AND fired_at > now() - interval '5 minutes');
  IF v_slots <= 0 THEN
    RETURN 0;
  END IF;
  FOR r IN
    SELECT axs_artist_id, performer
      FROM public.axs_performers
     WHERE axs_artist_id ~ '^\d+$' AND pending_request_id IS NULL
       AND (last_discovered_at IS NULL OR last_discovered_at < now() - interval '7 days')
     ORDER BY last_discovered_at NULLS FIRST, axs_artist_id
     LIMIT least(greatest(p_limit, 0), v_slots)
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

CREATE OR REPLACE FUNCTION public.axs_artist_discover_drain()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  v_resp     int := 0;
  v_items    int := 0;
  v_enrolled int := 0;
  v_artists  int := 0;
  v_failed   int := 0;
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
  -- failures (429 too many pending, timeouts, 5xx) free the slot but stay due, so they retry
  UPDATE public.axs_performers p
     SET pending_request_id = NULL, updated_at = now()
    FROM net._http_response r
   WHERE r.id = p.pending_request_id AND r.status_code IS DISTINCT FROM 200;
  GET DIAGNOSTICS v_failed = ROW_COUNT;
  WITH done AS (
    UPDATE public.axs_performers p
       SET last_discovered_at = now(), pending_request_id = NULL, updated_at = now(),
           events_seen = coalesce(jsonb_array_length(
             CASE WHEN jsonb_typeof(public.safe_jsonb(r.content)->'body'->'items') = 'array'
                  THEN public.safe_jsonb(r.content)->'body'->'items' END), 0)
      FROM net._http_response r
     WHERE r.id = p.pending_request_id AND r.status_code = 200
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

  RETURN jsonb_build_object('responses', v_resp, 'failed_retry', v_failed, 'us_items', v_items,
                            'events_enrolled', v_enrolled, 'artists_added', v_artists);
END $$;

REVOKE ALL ON FUNCTION public.axs_artist_discover(integer), public.axs_artist_discover_drain() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_artist_discover(integer), public.axs_artist_discover_drain() TO service_role;

UPDATE public.axs_performers SET last_discovered_at = NULL, updated_at = now()
 WHERE axs_artist_id IN ('103954','104936','104960','104186','104194','104353','104586','104972','104975','104993','105099')
   AND pending_request_id IS NULL
   AND last_discovered_at > '2026-11-02 19:00+00';

SELECT cron.schedule('axs_artist_discover_hourly', '17,47 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_artist_discover_hourly') THEN RETURN; END IF;
  PERFORM public.axs_artist_discover(8);
END $body$;
$c$);
