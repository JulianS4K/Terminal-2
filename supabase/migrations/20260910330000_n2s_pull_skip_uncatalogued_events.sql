-- ============================================================================
-- Migration 20260910330000 — one uncatalogued event must not stop every pull
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_pull_events() (DROP/CREATE — return type gains one column).
-- Pre-reqs: 20260910290000
--
-- READ-ONLY upstream: no new API call; this REMOVES calls. RULE 2 untouched.
--
-- ── THE FAILURE, AND HOW IT WAS FOUND ─────────────────────────────────────
-- public.evo_listings_poll_state.event_id carries a FOREIGN KEY to events.id.
-- The TEvo arm of n2s_pull_events() writes that table on every poll, so an
-- event that is NOT in our events catalogue raises 23503 — and because the
-- TEvo loop is not wrapped, the exception propagates out of
-- n2s_pull_all_sources() and aborts the whole tick. The cron command is
-- "n2s_map_events(); n2s_pull_all_sources();" in one transaction, so MAPPING
-- ROLLS BACK TOO: a single uncatalogued event stops mapping and polling for
-- every open order, every minute, until someone notices.
--
-- Found by mapping an order by hand to a TEvo event that exists in TEvo but
-- had never been ingested into events (a Riverbend show absent from our
-- catalogue). Cron 598 failed on the very next tick with exactly this error.
--
-- ⚠ THIS IS NOT ONLY A MANUAL-MAPPING HAZARD. Any path that can set
-- n2s_items.tevo_event_id to an id we have not ingested reaches the same
-- state — the AQ bridge resolving against a live TEvo search, a CRM order
-- carrying a tevo_event_id, a backfill. The blast radius is the entire N2S
-- pipeline, and the symptom is a cron failure rather than anything visible on
-- the panel, so it would be found late.
--
-- ── THE FIX ───────────────────────────────────────────────────────────────
-- The TEvo arm now polls only events present in public.events, and reports
-- the rest as evo_skipped_unknown rather than raising. GoTickets and SeatGeek
-- are unaffected: their poll-state tables key on their own ids and carry no FK
-- to events, so they can still be polled for such an event.
--
-- Skipping is the correct degradation and not a silent swallow: the count is
-- returned, so a persistent non-zero says "we are holding obligations against
-- an event we never ingested" — which is a catalogue-ingest problem to fix at
-- its source, not something this function should paper over by inserting a
-- half-built events row to satisfy a constraint.
-- ============================================================================

DROP FUNCTION IF EXISTS public.n2s_pull_events(bigint[],interval);

CREATE FUNCTION public.n2s_pull_events(
  p_events        bigint[],
  p_refresh_after interval DEFAULT interval '5 minutes'
)
RETURNS TABLE(evo_fired integer, gt_fired integer, sg_queued integer,
              td_queued integer, evo_skipped_fresh integer,
              gt_skipped_fresh integer, evo_skipped_unknown integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_token text; v_req bigint; v_eid bigint;
  v_sg_events bigint[];
  v_evo int := 0; v_gt int := 0; v_sg int := 0; v_td int := 0;
  v_evo_skip int := 0; v_gt_skip int := 0; v_evo_unknown int := 0;
BEGIN
  IF p_events IS NULL OR cardinality(p_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0, 0, 0, 0, 0; RETURN;
  END IF;

  -- Events we hold obligations against but have never ingested. Counted, not
  -- polled: evo_listings_poll_state.event_id REFERENCES events(id), so writing
  -- poll state for one raises 23503 and takes the whole tick down with it.
  SELECT count(*) INTO v_evo_unknown
    FROM unnest(p_events) AS e
   WHERE NOT EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e);

  SELECT count(*) INTO v_evo_skip
    FROM unnest(p_events) AS e
   WHERE EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e)
     AND (EXISTS (SELECT 1 FROM public.listings_snapshots s
                   WHERE s.event_id = e AND s.captured_at >= now() - p_refresh_after)
          OR EXISTS (SELECT 1 FROM public.evo_listings_poll_state ps
                      WHERE ps.event_id = e
                        AND ps.last_polled_listings_at >= now() - p_refresh_after));

  FOR v_eid IN
    SELECT e FROM unnest(p_events) AS e
     WHERE EXISTS (SELECT 1 FROM public.events ev WHERE ev.id = e)
       AND NOT EXISTS (SELECT 1 FROM public.listings_snapshots s
                        WHERE s.event_id = e AND s.captured_at >= now() - p_refresh_after)
       AND NOT EXISTS (SELECT 1 FROM public.evo_listings_poll_state ps
                        WHERE ps.event_id = e
                          AND ps.last_polled_listings_at >= now() - p_refresh_after)
  LOOP
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id='
        || v_eid::text, '{}'::jsonb);
    INSERT INTO public.evo_listings_poll_state(
             event_id, last_polled_listings_at, listings_polls_today, budget_day)
    VALUES (v_eid, now(), 1, current_date)
    ON CONFLICT (event_id) DO UPDATE SET
      last_polled_listings_at = now(),
      listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                  THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
      budget_day = current_date;
    v_evo := v_evo + 1;
  END LOOP;

  -- GoTickets keys poll state on gt_event_id and carries no FK to events, so
  -- an uncatalogued event is still pollable here.
  v_token := public._gotickets_pro_token();
  IF v_token IS NOT NULL AND btrim(v_token) <> '' THEN
    SELECT count(*) INTO v_gt_skip
      FROM public.gotickets_event g
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
     WHERE g.tevo_event_id = ANY(p_events)
       AND (ps.cold_until IS NULL OR ps.cold_until < now())
       AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
       AND (EXISTS (SELECT 1 FROM public.gotickets_listings_snapshots s
                     WHERE s.tevo_event_id = g.tevo_event_id
                       AND s.captured_at >= now() - p_refresh_after)
            OR ps.last_polled_listings_at >= now() - p_refresh_after);

    FOR r IN
      SELECT g.gt_event_id, g.tevo_event_id
        FROM public.gotickets_event g
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
       WHERE g.tevo_event_id = ANY(p_events)
         AND (ps.cold_until IS NULL OR ps.cold_until < now())
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
         AND NOT EXISTS (SELECT 1 FROM public.gotickets_listings_snapshots s
                          WHERE s.tevo_event_id = g.tevo_event_id
                            AND s.captured_at >= now() - p_refresh_after)
         AND (ps.last_polled_listings_at IS NULL
              OR ps.last_polled_listings_at < now() - p_refresh_after)
    LOOP
      SELECT net.http_get(
        url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
        headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept', 'application/json'),
        timeout_milliseconds := 30000) INTO v_req;
      INSERT INTO public.gt_listings_inflight(request_id, gt_event_id, tevo_event_id, fired_at)
      VALUES (v_req, r.gt_event_id, r.tevo_event_id, now());
      INSERT INTO public.gt_listings_poll_state(
               gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.gt_event_id, now(), 1, current_date)
      ON CONFLICT (gt_event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
      v_gt := v_gt + 1;
    END LOOP;
  END IF;

  v_sg_events := ARRAY(
    SELECT e FROM unnest(p_events) AS e
     WHERE NOT EXISTS (
       SELECT 1 FROM public.sg_broker_pending b
        WHERE b.scope = 'listings'
          AND b.fired_at >= now() - p_refresh_after
          AND b.sg_event_id IN (
                SELECT c.sg_event_id FROM public.sg_events_canonical c
                 WHERE c.tevo_event_id = e
                 UNION
                SELECT a.sg_event_id FROM public.aq_event_map a
                 WHERE a.tevo_event_id = e AND a.sg_event_id IS NOT NULL)));

  BEGIN
    SELECT queued INTO v_sg
      FROM public.sg_listings_pull_on_demand(v_sg_events, cardinality(v_sg_events), p_refresh_after);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_events: seatgeek on-demand failed: %', SQLERRM;
    v_sg := 0;
  END;

  BEGIN
    SELECT events_enqueued INTO v_td FROM public.n2s_td_enqueue(cardinality(p_events));
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_events: ticketsdata enqueue failed: %', SQLERRM;
    v_td := 0;
  END;

  RETURN QUERY SELECT v_evo, v_gt, COALESCE(v_sg,0), COALESCE(v_td,0),
                      v_evo_skip, v_gt_skip, v_evo_unknown;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_pull_events(bigint[],interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_pull_events(bigint[],interval) TO service_role;
