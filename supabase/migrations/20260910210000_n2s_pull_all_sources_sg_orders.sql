-- ============================================================================
-- Migration 20260910210000 — run SeatGeek order enrichment on the 2-min tick
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_pull_all_sources() — gains an SG order-enrichment step and two
--           output counters. No cron schedule is created or altered.
-- Pre-reqs: 20260910200000
--
-- READ-ONLY upstream: the step it adds issues GETs only. RULE 2 holds.
--
-- ⚠ THE STEP RUNS BEFORE THE no-new-orders EARLY RETURN, AND THAT IS THE POINT.
-- n2s_pull_all_sources exists to pull LISTINGS for newly-arrived orders, so it
-- bails out early whenever nothing new has landed — which is almost every tick.
-- SeatGeek order enrichment is not about new arrivals: it is about order
-- records already here that are missing their economics, including ones whose
-- sources_pulled_at was set long ago. After the early return it would
-- effectively never run.
--
-- ⚠ DRAIN BEFORE QUEUE. pg_net is asynchronous with 1-3 minutes of latency, so
-- the drain in this tick collects what the PREVIOUS tick fired. Queueing first
-- would push every response one tick further away. Same even/odd reasoning as
-- the CRM poll (20260910040000), expressed inside a single function.
--
-- ⚠ ITS FAILURES MUST NOT ABORT THE LISTING PULLS — wrapped in its own
-- exception block, for the same reason the SeatGeek listings call already is.
--
-- ⚠ EVERYTHING ELSE HERE IS A BYTE-FAITHFUL COPY OF THE DEPLOYED FUNCTION.
-- The EVO leg calls collect-listings by full URL, the GoTickets leg uses
-- _gotickets_pro_token() with the X-Broker-Api-Token header, and BOTH legs
-- maintain their own daily budget counters in evo_listings_poll_state /
-- gt_listings_poll_state. A rewrite from memory got all of that wrong and
-- would have silently stopped EVO and GoTickets from pulling at all while
-- resetting their budget accounting. Do not "tidy" these legs; diff against
-- pg_get_functiondef before touching this function again.
-- ============================================================================

DROP FUNCTION IF EXISTS public.n2s_pull_all_sources(integer);

CREATE FUNCTION public.n2s_pull_all_sources(p_max integer DEFAULT 10)
RETURNS TABLE(orders integer, evo_fired integer, gt_fired integer,
              sg_queued integer, td_queued integer,
              sg_orders_stored integer, sg_prices_filled integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_ids bigint[]; v_events bigint[]; v_token text; v_req bigint;
  v_eid bigint;
  v_evo int := 0; v_gt int := 0; v_sg int := 0; v_td int := 0; v_orders int := 0;
  v_sg_stored int := 0; v_sg_fill int := 0;
BEGIN
  -- ── SeatGeek order enrichment — independent of new arrivals (see header) ──
  BEGIN
    SELECT d.stored, d.prices_filled INTO v_sg_stored, v_sg_fill
      FROM public.n2s_sg_drain() d;      -- collects the PREVIOUS tick's GETs
    PERFORM public.n2s_sg_queue(10);     -- fires this tick's
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_all_sources: seatgeek order enrich failed: %', SQLERRM;
    v_sg_stored := 0; v_sg_fill := 0;
  END;

  SELECT array_agg(n2s_id ORDER BY alert_at DESC),
         array_agg(DISTINCT tevo_event_id)
    INTO v_ids, v_events
    FROM (SELECT n2s_id, alert_at, tevo_event_id
            FROM public.n2s_items
           WHERE sources_pulled_at IS NULL
             AND tevo_event_id IS NOT NULL
             AND NOT is_terminal
             AND event_dt::date >= current_date
           ORDER BY alert_at DESC
           LIMIT p_max) x;

  IF v_events IS NULL OR cardinality(v_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0, 0, 0,
                        COALESCE(v_sg_stored, 0), COALESCE(v_sg_fill, 0);
    RETURN;
  END IF;
  v_orders := cardinality(v_ids);

  FOREACH v_eid IN ARRAY v_events LOOP
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

  v_token := public._gotickets_pro_token();
  IF v_token IS NOT NULL AND btrim(v_token) <> '' THEN
    FOR r IN
      SELECT g.gt_event_id, g.tevo_event_id
        FROM public.gotickets_event g
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
       WHERE g.tevo_event_id = ANY(v_events)
         AND (ps.cold_until IS NULL OR ps.cold_until < now())
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
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

  BEGIN
    SELECT queued INTO v_sg
      FROM public.sg_listings_pull_on_demand(v_events, cardinality(v_events), interval '30 minutes');
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_all_sources: seatgeek on-demand failed: %', SQLERRM;
    v_sg := 0;
  END;

  SELECT events_enqueued INTO v_td FROM public.n2s_td_enqueue(cardinality(v_events));

  UPDATE public.n2s_items SET sources_pulled_at = now() WHERE n2s_id = ANY(v_ids);

  RETURN QUERY SELECT v_orders, v_evo, v_gt, COALESCE(v_sg, 0), COALESCE(v_td, 0),
                      COALESCE(v_sg_stored, 0), COALESCE(v_sg_fill, 0);
END $function$;

REVOKE ALL ON FUNCTION public.n2s_pull_all_sources(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_pull_all_sources(integer) TO service_role;
