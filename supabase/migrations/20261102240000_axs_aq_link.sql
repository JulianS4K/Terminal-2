-- Migration 20261102240000 · level:data-collection · lane:A1 (AXS ingest + AQ hub) · writes:aq_event_map(axs_event_id fill-only),td_match_queue(purpose axs_resolve),axs_match_enqueue()(new),axs_aq_link_tick()(new),axs_resolve_event()(+td_match step),cron axs_aq_link_hourly(new),cron axs_match_hourly(new) · reads:axs_catalog,axs_events,td_match_results,sg_events_canonical,ticketsdata_event_xref,v_axs_venues,events · pre:20261102230000
--
-- ============================================================================
-- Keep aq_event_map.axs_event_id filled for NEW AQ events (operator 2026-11-02: "how does it get
-- new AQ event ids? … use the TicketsData matcher API").
--
-- Until now an AQ row only got an AXS id when an AXS event was pulled and matched (pull crons off
-- since 09-01), plus a one-off June backfill. Nothing filled new AQ events.
--
-- THE MATCHER: TicketsData /match takes any marketplace event URL and returns the same event on
-- the others. Its ticketmaster_us / _ca / _uk slot carries the event's PRIMARY ticketing link —
-- for an AXS-sold event that is an axs.com/events/<id> URL (stored results, 2026-11-02: Olivia
-- Rodrigo @ T-Mobile Arena → axs.com/events/1418825, Hayley Williams @ Forest Hills Stadium → 1416004).
-- td_match_drain already lands it in td_match_results.tm_url. Cost: 12 credits + 1 report per
-- call, so it is the last resort, after the free sources and the 1-credit artist crawl.
--
-- axs_aq_link_tick() (hourly :21)
--   0  td_match_drain(50)       land any /match responses (its own cron 405 is off)
--   A  AXS → AQ                 every AXS id we know (catalogue, pull list, /match results) whose
--                               TEvo event has an AQ row with no axs_event_id → fill it
--   B  AQ → AXS                 upcoming AQ events at AXS venues (v_axs_venues) still without an id
--                               → axs_resolve_event(); a hit is written to aq_event_map; a miss on
--                               a known AXS artist re-queues the crawl (≤ once a day per artist)
-- axs_match_enqueue(n) (hourly :23, 2 per hour) — for events B could not resolve whose performer was
--   not crawled in the last 7 days (the crawl answers those for 1 credit), fire /match with the
--   event's SeatGeek URL, else any active TicketsData xref URL. One try per event per 30 days.
--   Gated by td_budget_ok() and td_reports_budget_ok() (600 reports / month).
-- aq_event_map is only FILLED (axs_event_id IS NULL), never overwritten, and an AXS id is never
-- given to a second AQ row.
-- Rollback: SELECT cron.unschedule(j) FROM unnest(ARRAY['axs_aq_link_hourly','axs_match_hourly']) j;
--   DROP FUNCTION axs_aq_link_tick(integer), axs_match_enqueue(integer); restore td_match_queue
--   purpose check to ('fill','adjudicate'); re-create axs_resolve_event from mig 20261102230000.
-- ============================================================================

DO $c$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname FROM pg_constraint
            WHERE conrelid = 'public.td_match_queue'::regclass AND contype = 'c'
              AND pg_get_constraintdef(oid) ~ 'purpose'
  LOOP
    EXECUTE format('ALTER TABLE public.td_match_queue DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $c$;
ALTER TABLE public.td_match_queue ADD CONSTRAINT td_match_queue_purpose_check
  CHECK (purpose IN ('fill', 'adjudicate', 'axs_resolve'));

-- resolver: TicketsData /match results are a source too (step 5b, after SeatGeek)
DO $patch$
DECLARE
  v_def text := pg_get_functiondef('public.axs_resolve_event(bigint)'::regprocedure);
  v_old text := $o$  -- no id: is the venue AXS at all?$o$;
  v_new text := $n$  -- 5b. TicketsData /match: primary link in the ticketmaster slot is axs.com for AXS events
  SELECT substring(coalesce(r.tm_url, '') || ' ' || coalesce(r.matches_raw::text, '') FROM 'axs\.com/events/(\d+)') INTO v_id
    FROM public.td_match_results r
   WHERE r.tevo_event_id = p_tevo_event_id
     AND (coalesce(r.tm_url, '') || ' ' || coalesce(r.matches_raw::text, '')) ~ 'axs\.com/events/\d+'
   ORDER BY r.created_at DESC LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, 'https://www.axs.com/events/' || v_id, 'td_match'::text, NULL::text; RETURN;
  END IF;

  -- no id: is the venue AXS at all?$n$;
BEGIN
  IF position('td_match_results' IN v_def) > 0 THEN
    RETURN;
  END IF;
  IF position(v_old IN v_def) = 0 THEN
    RAISE EXCEPTION 'axs_resolve_event: anchor line not found';
  END IF;
  EXECUTE replace(v_def, v_old, v_new);
END $patch$;

CREATE OR REPLACE FUNCTION public.axs_aq_link_tick(p_limit integer DEFAULT 300)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  r          record;
  x          record;
  v_drained  int := 0;
  v_known    int := 0;
  v_found    int := 0;
  v_queued   int := 0;
  v_missing  int := 0;
BEGIN
  -- 0. land /match responses
  v_drained := coalesce(public.td_match_drain(50), 0);

  -- A. AXS ids we already know → AQ rows of the same TEvo event
  WITH known AS (
    SELECT tevo_event_id, axs_event_id FROM public.axs_catalog WHERE tevo_event_id IS NOT NULL
    UNION
    SELECT tevo_event_id, axs_event_id FROM public.axs_events WHERE tevo_event_id IS NOT NULL
    UNION
    SELECT tevo_event_id, substring(coalesce(tm_url, '') || ' ' || coalesce(matches_raw::text, '') FROM 'axs\.com/events/(\d+)')
      FROM public.td_match_results
     WHERE tevo_event_id IS NOT NULL
       AND (coalesce(tm_url, '') || ' ' || coalesce(matches_raw::text, '')) ~ 'axs\.com/events/\d+'),
  pick AS (
    SELECT DISTINCT ON (tevo_event_id) tevo_event_id, axs_event_id FROM known
     WHERE axs_event_id IS NOT NULL ORDER BY tevo_event_id, axs_event_id),
  upd AS (
    UPDATE public.aq_event_map m SET axs_event_id = p.axs_event_id
      FROM pick p
     WHERE m.tevo_event_id = p.tevo_event_id AND m.axs_event_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.axs_event_id = p.axs_event_id)
    RETURNING 1)
  SELECT count(*) INTO v_known FROM upd;

  -- B. upcoming AQ events at AXS venues still without an id → resolver
  FOR r IN
    SELECT m.aq_short_event_id, m.tevo_event_id
      FROM public.aq_event_map m
      JOIN public.events e ON e.id = m.tevo_event_id
     WHERE m.axs_event_id IS NULL
       AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\d' AND left(e.occurs_at_local, 10) >= current_date::text
       AND EXISTS (SELECT 1 FROM public.v_axs_venues v WHERE v.tevo_venue_id = e.venue_id)
     ORDER BY e.occurs_at_local
     LIMIT greatest(p_limit, 0)
  LOOP
    SELECT * INTO x FROM public.axs_resolve_event(r.tevo_event_id) LIMIT 1;
    IF x.axs_event_id IS NOT NULL THEN
      UPDATE public.aq_event_map m SET axs_event_id = x.axs_event_id
       WHERE m.aq_short_event_id = r.aq_short_event_id AND m.axs_event_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.axs_event_id = x.axs_event_id);
      IF FOUND THEN v_found := v_found + 1; END IF;
    ELSIF x.method = 'queued_artist_crawl' THEN
      v_queued := v_queued + 1;
    ELSE
      v_missing := v_missing + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('match_drained', v_drained, 'filled_from_known', v_known,
                            'filled_by_resolver', v_found, 'artist_crawl_queued', v_queued,
                            'unresolved', v_missing);
END $$;

CREATE OR REPLACE FUNCTION public.axs_match_enqueue(p_limit integer DEFAULT 2)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp AS $$
DECLARE
  r     record;
  v_req bigint;
  v_n   int := 0;
BEGIN
  IF NOT public.td_budget_ok() OR NOT public.td_reports_budget_ok() THEN
    RETURN 0;
  END IF;
  FOR r IN
    SELECT m.aq_short_event_id, m.tevo_event_id,
           coalesce(sg.sg_url, xr.event_url) AS seed_url,
           CASE WHEN sg.sg_url IS NOT NULL THEN 'SG' ELSE xr.platform END AS seed_platform
      FROM public.aq_event_map m
      JOIN public.events e ON e.id = m.tevo_event_id
      LEFT JOIN LATERAL (SELECT g.sg_url FROM public.sg_events_canonical g
                          WHERE g.sg_url IS NOT NULL
                            AND (g.sg_event_id = m.sg_event_id OR g.tevo_event_id = m.tevo_event_id)
                          LIMIT 1) sg ON true
      LEFT JOIN LATERAL (SELECT x.event_url, x.platform FROM public.ticketsdata_event_xref x
                          WHERE x.aq_short_event_id = m.aq_short_event_id AND x.active AND x.event_url IS NOT NULL
                          ORDER BY x.platform LIMIT 1) xr ON true
     WHERE m.axs_event_id IS NULL
       AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\d' AND left(e.occurs_at_local, 10) >= current_date::text
       AND EXISTS (SELECT 1 FROM public.v_axs_venues v WHERE v.tevo_venue_id = e.venue_id)
       AND coalesce(sg.sg_url, xr.event_url) IS NOT NULL
       -- the 1-credit artist crawl covers performers it checked this week
       AND NOT EXISTS (SELECT 1 FROM public.axs_performers p
                        WHERE public.axs_slugify(p.performer) = public.axs_slugify(e.primary_performer_name)
                          AND p.last_discovered_at > now() - interval '7 days')
       AND NOT EXISTS (SELECT 1 FROM public.td_match_queue q
                        WHERE q.tevo_event_id = m.tevo_event_id
                          AND (q.resolved_at IS NULL OR q.fired_at > now() - interval '30 days'))
     ORDER BY e.occurs_at_local
     LIMIT greatest(p_limit, 0)
  LOOP
    SELECT net.http_get(
      url := 'https://ticketsdata.com/match',
      params := jsonb_build_object('event_url', r.seed_url,
                                   'username', public.get_app_secret('TICKETSDATA_USERNAME'),
                                   'password', public.get_app_secret('TICKETSDATA_PASSWORD')),
      headers := '{}'::jsonb, timeout_milliseconds := 45000) INTO v_req;
    INSERT INTO public.td_match_queue (tevo_event_id, aq_short_event_id, seed_platform, seed_event_url, purpose, request_id, fired_at)
    VALUES (r.tevo_event_id, r.aq_short_event_id, r.seed_platform, r.seed_url, 'axs_resolve', v_req, now());
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION public.axs_aq_link_tick(integer), public.axs_match_enqueue(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.axs_aq_link_tick(integer), public.axs_match_enqueue(integer) TO service_role;

SELECT cron.schedule('axs_aq_link_hourly', '21 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_aq_link_hourly') THEN RETURN; END IF;
  PERFORM public.axs_aq_link_tick();
END $body$;
$c$);

SELECT cron.schedule('axs_match_hourly', '23 * * * *', $c$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('axs_match_hourly') THEN RETURN; END IF;
  PERFORM public.axs_match_enqueue(2);
END $body$;
$c$);
