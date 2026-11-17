-- ============================================================================
-- Migration 20260910280000 — poll the marketplaces for as long as the
--                            obligation is open, not once when it arrives
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_pull_all_sources() (DROP/CREATE — gains a parameter and two
--           result columns), n2s_items.sources_pulled_at (COMMENT only).
-- Pre-reqs: 20260910130000, 20260910200000
--
-- READ-ONLY upstream: every call here is a GET for listings data. No order,
-- hold, price or inventory write. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "fix the freshness gap."
--
-- ── THE BUG ───────────────────────────────────────────────────────────────
-- The selector was `sources_pulled_at IS NULL`, and the last statement in the
-- function sets that column to now(). So every order was polled EXACTLY ONCE,
-- ever, and this function was the only writer of that column — nothing reset
-- it. Meanwhile n2s_cover_candidates() only considers listings captured
-- within p_max_listing_age (1 hour). An obligation therefore had a one-hour
-- window in which it could be covered at all, after which it was permanently
-- invisible to the matcher no matter how long it stayed open.
--
-- Measured before the fix: 107 open mapped orders, every one of them with a
-- sources_pulled_at older than an hour (4.4 hours on average). Of 47 open
-- events only 18 had ANY source inside the window, so 66 of 107 orders could
-- not be covered at all — not for want of a good matcher, but for want of
-- anything to match against.
--
-- How much that was worth: re-running the matcher unchanged with a 3-hour
-- window instead of 1 took covers from 8 to 18. The inventory was there.
--
-- ── THE FIX, AND WHY IT DOES NOT BECOME A POLLING STORM ───────────────────
-- Eligibility is now `sources_pulled_at IS NULL OR sources_pulled_at <
-- now() - p_refresh_after`, so an order is revisited for as long as it stays
-- open. On its own that would hammer the upstreams: the cron runs every
-- minute, and several orders usually share one event.
--
-- Two things bound it, and BOTH are needed:
--
--   1. Per-ORDER: the p_refresh_after eligibility window above, plus the
--      existing LIMIT p_max. New arrivals still come first — the ordering is
--      `sources_pulled_at ASC NULLS FIRST`, so a never-pulled order (which is
--      inside its 15-minute CRM timer and genuinely urgent) always outranks a
--      refresh, and refreshes then go stalest-first so nothing starves.
--
--   2. Per-EVENT and per-SOURCE: before firing, each source is skipped if
--      that event ALREADY has a snapshot newer than p_refresh_after. This is
--      the guard that actually holds the line, because it is what stops two
--      orders on the same event causing two pulls, and what stops a tick
--      re-pulling an event a previous tick just refreshed.
--
--      SeatGeek already worked this way — sg_listings_pull_on_demand() takes
--      a p_freshness and skips fresh events itself, so it only needed the
--      interval threading through. TEvo and GoTickets had NO such guard, and
--      adding the re-poll without adding one to them is precisely how this
--      change would have turned into an outbound flood. They now carry the
--      same test against listings_snapshots / gotickets_listings_snapshots.
--      GoTickets keeps its existing cold_until / quarantined_until checks on
--      top; those are the vendor's backpressure and are not weakened here.
--
-- Net effect on call volume: each open event is polled at most once per
-- p_refresh_after per source, regardless of how many orders sit on it or how
-- often the cron fires. With 47 open events at 30 minutes that is ~94
-- event-polls/hour spread across three sources — bounded by the event count,
-- not by the tick rate.
--
-- 30 minutes is chosen against the matcher's 1-hour window: it leaves a full
-- window of margin, so a single missed or slow cycle still cannot push an
-- event out of matchable range.
--
-- ⚠ TICKETSDATA IS NOT FIXED HERE, AND CANNOT BE FROM SQL. Its arm is left
-- exactly as it was. n2s_td_enqueue() already re-polls on its own schedule
-- (it selects open N2S events directly and has its own 20-minute guard), so
-- it never had the once-only bug — but every one of its recent fires comes
-- back HTTP 403 `quota_exhausted`: 128 of 128 resolved `n2s_ondemand` rows in
-- td_pull_queue, with zero rows inserted, and no ticketsdata snapshot in
-- ~18 hours. Note that public.td_budget_ok() returns TRUE throughout, so our
-- internal budget accounting and the vendor's disagree; the internal counter
-- is not tracking the limit that is actually binding. That is an account /
-- quota decision for the operator, not a code change, and raising our own
-- request rate against a 403 would only burn the shared account harder.
--
-- ⚠ sources_pulled_at NOW MEANS "last considered", NOT "first pulled". A tick
-- stamps every order it selected, including ones whose event was skipped as
-- already fresh. That is the intended reading — the order was examined and
-- needed nothing — and it is what keeps the round-robin advancing instead of
-- re-selecting the same orders forever. The column comment says so.
-- ============================================================================

DROP FUNCTION IF EXISTS public.n2s_pull_all_sources(integer);

CREATE FUNCTION public.n2s_pull_all_sources(
  p_max           integer  DEFAULT 10,
  p_refresh_after interval DEFAULT interval '30 minutes'
)
RETURNS TABLE(orders integer, evo_fired integer, gt_fired integer,
              sg_queued integer, td_queued integer,
              sg_orders_stored integer, sg_prices_filled integer,
              evo_skipped_fresh integer, gt_skipped_fresh integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_ids bigint[]; v_events bigint[]; v_token text; v_req bigint;
  v_eid bigint;
  v_evo int := 0; v_gt int := 0; v_sg int := 0; v_td int := 0; v_orders int := 0;
  v_sg_stored int := 0; v_sg_fill int := 0;
  v_evo_skip int := 0; v_gt_skip int := 0;
BEGIN
  BEGIN
    SELECT d.stored, d.prices_filled INTO v_sg_stored, v_sg_fill
      FROM public.n2s_sg_drain() d;
    PERFORM public.n2s_sg_queue(10);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_all_sources: seatgeek order enrich failed: %', SQLERRM;
    v_sg_stored := 0; v_sg_fill := 0;
  END;

  -- Never-pulled first (a new order is inside its 15-minute timer), then
  -- stalest-first so the refresh rotation cannot starve an order.
  SELECT array_agg(n2s_id), array_agg(DISTINCT tevo_event_id)
    INTO v_ids, v_events
    FROM (SELECT n2s_id, tevo_event_id
            FROM public.n2s_items
           WHERE (sources_pulled_at IS NULL
                  OR sources_pulled_at < now() - p_refresh_after)
             AND tevo_event_id IS NOT NULL
             AND NOT is_terminal
             AND event_dt::date >= current_date
           ORDER BY sources_pulled_at ASC NULLS FIRST, alert_at DESC
           LIMIT p_max) x;

  IF v_events IS NULL OR cardinality(v_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0, 0, 0,
                        COALESCE(v_sg_stored, 0), COALESCE(v_sg_fill, 0), 0, 0;
    RETURN;
  END IF;
  v_orders := cardinality(v_ids);

  -- TEvo/EVO. The freshness test is the per-event bound: without it, every
  -- order sharing an event would fire its own pull, every minute.
  SELECT count(*) INTO v_evo_skip
    FROM unnest(v_events) AS e
   WHERE EXISTS (SELECT 1 FROM public.listings_snapshots s
                  WHERE s.event_id = e
                    AND s.captured_at >= now() - p_refresh_after);

  FOR v_eid IN
    SELECT e FROM unnest(v_events) AS e
     WHERE NOT EXISTS (SELECT 1 FROM public.listings_snapshots s
                        WHERE s.event_id = e
                          AND s.captured_at >= now() - p_refresh_after)
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

  -- GoTickets. Same freshness bound, layered on top of the vendor's own
  -- cold_until / quarantined_until backpressure, which is unchanged.
  v_token := public._gotickets_pro_token();
  IF v_token IS NOT NULL AND btrim(v_token) <> '' THEN
    SELECT count(*) INTO v_gt_skip
      FROM public.gotickets_event g
      LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
     WHERE g.tevo_event_id = ANY(v_events)
       AND (ps.cold_until IS NULL OR ps.cold_until < now())
       AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
       AND EXISTS (SELECT 1 FROM public.gotickets_listings_snapshots s
                    WHERE s.tevo_event_id = g.tevo_event_id
                      AND s.captured_at >= now() - p_refresh_after);

    FOR r IN
      SELECT g.gt_event_id, g.tevo_event_id
        FROM public.gotickets_event g
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
       WHERE g.tevo_event_id = ANY(v_events)
         AND (ps.cold_until IS NULL OR ps.cold_until < now())
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
         AND NOT EXISTS (SELECT 1 FROM public.gotickets_listings_snapshots s
                          WHERE s.tevo_event_id = g.tevo_event_id
                            AND s.captured_at >= now() - p_refresh_after)
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

  -- SeatGeek already skips events fresher than p_freshness internally; it only
  -- needed the same interval threaded through so all three sources agree.
  BEGIN
    SELECT queued INTO v_sg
      FROM public.sg_listings_pull_on_demand(v_events, cardinality(v_events), p_refresh_after);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_all_sources: seatgeek on-demand failed: %', SQLERRM;
    v_sg := 0;
  END;

  -- TicketsData unchanged: it re-polls on its own schedule and is currently
  -- returning 403 quota_exhausted regardless. See the header.
  SELECT events_enqueued INTO v_td FROM public.n2s_td_enqueue(cardinality(v_events));

  UPDATE public.n2s_items SET sources_pulled_at = now() WHERE n2s_id = ANY(v_ids);

  RETURN QUERY SELECT v_orders, v_evo, v_gt, COALESCE(v_sg, 0), COALESCE(v_td, 0),
                      COALESCE(v_sg_stored, 0), COALESCE(v_sg_fill, 0),
                      v_evo_skip, v_gt_skip;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_pull_all_sources(integer,interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_pull_all_sources(integer,interval) TO service_role;

COMMENT ON COLUMN public.n2s_items.sources_pulled_at IS
  'When this order was last CONSIDERED for a marketplace pull — not when it '
  'first was. A tick stamps every order it selected, including ones whose '
  'event was skipped because a fresh snapshot already existed. Drives the '
  'round-robin in n2s_pull_all_sources(); an open order is revisited every '
  'p_refresh_after for as long as it stays open. See migration 20260910280000.';
