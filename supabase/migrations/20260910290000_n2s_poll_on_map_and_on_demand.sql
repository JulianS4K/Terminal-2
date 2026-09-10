-- ============================================================================
-- Migration 20260910290000 — poll at mapping (demand-driven), sweep only what
--                            still has no answer
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_pull_events() (NEW), n2s_pull_on_demand() (DROPPED — see below),
--           n2s_pull_all_sources() (DROP/CREATE — gains three parameters),
--           cron jobs n2s_map_events_5min (command) and
--           n2s_pull_all_sources_2min (deactivated).
-- Pre-reqs: 20260910280000
--
-- READ-ONLY upstream: every call is a GET for listings data. No order, hold,
-- price or inventory write. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "poll as the order comes in and is mapped and
-- then give result, poll on demand and skip snapshots unless under 5 mins" —
-- with the follow-ups confirming a slow safety net should remain, and that the
-- 5-minute rule is the POLL guard, not the matcher window.
--
-- ── WHAT CHANGES ──────────────────────────────────────────────────────────
-- 20260910280000 fixed orders never being re-polled by sweeping every open
-- order every 30 minutes. That works, but it spends upstream budget on orders
-- that already have an answer, and it still makes a newly mapped order wait
-- for its turn in a rotation. Polling is now driven by two things instead:
--
--   1. AT MAPPING. The pull runs in the same cron tick as n2s_map_events(),
--      immediately after it. An order that maps at 12:03 is polled at 12:03,
--      not whenever the rotation reaches it. Never-pulled orders also sort
--      first AND draw on a separate budget (p_new_max), so a backlog of stale
--      sweep candidates can neither outrank them nor use up their slots.
--      "On demand" means demand-driven, not operator-driven: the demand is a
--      newly mapped order needing data. There is deliberately NO manual pull
--      button and no route behind one — an earlier draft of this migration had
--      both, and they were the wrong reading of the ask.
--   2. A SWEEP, now narrowed to orders that STILL HAVE NO COVER and have not
--      been looked at for p_sweep_after (20 min). A covered order already has
--      its answer; re-polling it buys a marginally better price at the cost of
--      budget. Measured
--      at the time of writing this cuts the swept set from 107 orders / 47
--      events to 63 / 29, and it shrinks further as covers land.
--
-- The safety net is deliberately kept rather than relying on arrivals alone: an
-- order that maps once and then sits for hours would otherwise age out of the
-- matcher's window and its cover would silently vanish — the same shape as the
-- once-only bug 20260910280000 just fixed.
--
-- ── THE 5-MINUTE RULE IS THE RATE LIMIT, AND IT LIVES IN ONE PLACE ────────
-- p_refresh_after drops 30 min -> 5 min: a source is skipped for an event only
-- if that event already has a snapshot under 5 minutes old. Because polling is
-- now triggered rather than rotated, a tighter guard does NOT mean more calls —
-- it means a triggered poll returns genuinely current prices instead of
-- something up to half an hour stale.
--
-- ⚠ THIS GUARD IS THE ONLY THING BOUNDING OUTBOUND VOLUME NOW, so both callers
-- share one body — n2s_pull_events(). Extracting it is not tidiness: with a
-- per-source guard copied into each caller, one path would eventually be
-- written without it, and that path would be an unthrottled loop over every
-- open event on a one-minute cron. The map-time path is the one to watch,
-- because it is driven by arrivals rather than by a rotation and so has no
-- natural ceiling of its own.
--
-- ⚠ THE MATCHER WINDOW IS NOT TOUCHED. n2s_cover_candidates() keeps its
-- 1-hour p_max_listing_age. Tying it to the 5-minute poll guard would empty
-- the panel between polls — a cover computed 6 minutes ago would stop being
-- displayed even though nothing about it had changed.
--
-- ⚠ TICKETSDATA REMAINS BLOCKED UPSTREAM. Unchanged here and still returning
-- HTTP 403 quota_exhausted on every fire. Its enqueue is now wrapped in its
-- own exception block so a vendor-side failure cannot abort the other three
-- sources' pulls, which is a real risk once every entry point shares this
-- body. See 20260910280000's header for the quota finding.
-- ============================================================================

-- The shared poller. Both callers — the map-time chain and the safety-net
-- sweep — go through this one body, so
-- the per-event freshness guard cannot be honoured by one path and skipped by
-- another. That guard is the whole rate limit: an event is polled at most once
-- per p_refresh_after per source no matter how many callers ask.
CREATE OR REPLACE FUNCTION public.n2s_pull_events(
  p_events        bigint[],
  p_refresh_after interval DEFAULT interval '5 minutes'
)
RETURNS TABLE(evo_fired integer, gt_fired integer, sg_queued integer,
              td_queued integer, evo_skipped_fresh integer, gt_skipped_fresh integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_token text; v_req bigint; v_eid bigint;
  v_sg_events bigint[];
  v_evo int := 0; v_gt int := 0; v_sg int := 0; v_td int := 0;
  v_evo_skip int := 0; v_gt_skip int := 0;
BEGIN
  IF p_events IS NULL OR cardinality(p_events) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0, 0, 0, 0; RETURN;
  END IF;

  -- ⚠ A SNAPSHOT-ONLY GUARD DOES NOT HOLD FOR ASYNC SOURCES. GoTickets and
  -- SeatGeek fire through net.http_get and the response lands 1-3 minutes
  -- later, so between firing and landing there is no fresh snapshot to see and
  -- a second caller re-fires the same event. Measured before this was added:
  -- calling n2s_pull_on_demand() twice back to back re-fired 30 of 47 GoTickets
  -- events and re-queued 33 SeatGeek ones. Every source is therefore guarded on
  -- (fresh snapshot) OR (request already in flight), using the fire timestamp
  -- each source already records. TEvo goes through the edge function and lands
  -- fast enough to have mostly self-guarded, but it gets the same treatment so
  -- the three arms cannot drift apart.
  SELECT count(*) INTO v_evo_skip
    FROM unnest(p_events) AS e
   WHERE EXISTS (SELECT 1 FROM public.listings_snapshots s
                  WHERE s.event_id = e AND s.captured_at >= now() - p_refresh_after)
      OR EXISTS (SELECT 1 FROM public.evo_listings_poll_state ps
                  WHERE ps.event_id = e
                    AND ps.last_polled_listings_at >= now() - p_refresh_after);

  FOR v_eid IN
    SELECT e FROM unnest(p_events) AS e
     WHERE NOT EXISTS (SELECT 1 FROM public.listings_snapshots s
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

  -- sg_listings_pull_on_demand() guards on snapshot freshness only, so the
  -- in-flight events are filtered out here before it is asked.
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

  RETURN QUERY SELECT v_evo, v_gt, COALESCE(v_sg,0), COALESCE(v_td,0), v_evo_skip, v_gt_skip;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_pull_events(bigint[],interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_pull_events(bigint[],interval) TO service_role;

-- 20260910290000 first shipped an operator-facing n2s_pull_on_demand() wrapper
-- and a button behind it. That was a misreading of "poll on demand": the demand
-- is a newly mapped order needing data, not a human pressing something. The
-- wrapper is dropped rather than left unused — an unreferenced SECURITY DEFINER
-- function that fires outbound requests is exactly the surface that gets called
-- by something later without the reasoning that bounded it.
DROP FUNCTION IF EXISTS public.n2s_pull_on_demand(bigint[],interval);

-- The safety net. Runs in the same tick as n2s_map_events(), immediately after
-- it, so an order that has just been mapped is polled without waiting for a
-- rotation — that is the "poll as it comes in and is mapped" path, and it is
-- why never-pulled orders sort first and carry their own budget.
--
-- Beyond that it only sweeps orders that STILL HAVE NO COVER. A covered order
-- already has its answer, and re-polling it buys a marginally better price at
-- the cost of upstream budget. This is what keeps background volume down while
-- guaranteeing a long-open obligation cannot silently go dark.
DROP FUNCTION IF EXISTS public.n2s_pull_all_sources(integer,interval);
DROP FUNCTION IF EXISTS public.n2s_pull_all_sources(integer,interval,interval,boolean);

CREATE FUNCTION public.n2s_pull_all_sources(
  p_max           integer  DEFAULT 10,
  p_refresh_after interval DEFAULT interval '5 minutes',
  p_sweep_after   interval DEFAULT interval '20 minutes',
  p_uncovered_only boolean DEFAULT true,
  p_new_max       integer  DEFAULT 200
)
RETURNS TABLE(orders integer, new_orders integer, evo_fired integer, gt_fired integer,
              sg_queued integer, td_queued integer,
              sg_orders_stored integer, sg_prices_filled integer,
              evo_skipped_fresh integer, gt_skipped_fresh integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_ids bigint[]; v_events bigint[]; p RECORD; v_new int := 0;
  v_sg_stored int := 0; v_sg_fill int := 0;
BEGIN
  BEGIN
    SELECT d.stored, d.prices_filled INTO v_sg_stored, v_sg_fill
      FROM public.n2s_sg_drain() d;
    PERFORM public.n2s_sg_queue(10);
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'n2s_pull_all_sources: seatgeek order enrich failed: %', SQLERRM;
    v_sg_stored := 0; v_sg_fill := 0;
  END;

  -- ⚠ THE TWO POPULATIONS GET SEPARATE BUDGETS ON PURPOSE. Sharing one LIMIT
  -- means a backlog of stale sweep candidates can crowd out the orders that
  -- were mapped seconds ago — and those are the whole point of running this
  -- immediately after n2s_map_events(). Sorting never-pulled first fixes the
  -- ordering but not the cap: 11 orders mapped in one tick against LIMIT 10
  -- still leaves one waiting a full cycle for data it should have had at once.
  -- So newly mapped orders are taken in full (up to p_new_max, sized for a
  -- CRM burst rather than a steady trickle) and the sweep gets its own p_max
  -- on top.
  WITH newly AS (
    SELECT i.n2s_id, i.tevo_event_id
      FROM public.n2s_items i
     WHERE i.tevo_event_id IS NOT NULL
       AND NOT i.is_terminal
       AND i.event_dt::date >= current_date
       AND i.sources_pulled_at IS NULL
     ORDER BY i.alert_at DESC
     LIMIT p_new_max
  ),
  sweep AS (
    SELECT i.n2s_id, i.tevo_event_id
      FROM public.n2s_items i
     WHERE i.tevo_event_id IS NOT NULL
       AND NOT i.is_terminal
       AND i.event_dt::date >= current_date
       AND i.sources_pulled_at < now() - p_sweep_after
       AND (NOT p_uncovered_only
            OR NOT EXISTS (SELECT 1 FROM public.n2s_cover_queue q
                            WHERE q.n2s_id = i.n2s_id))
     ORDER BY i.sources_pulled_at ASC
     LIMIT p_max
  )
  SELECT array_agg(x.n2s_id), array_agg(DISTINCT x.tevo_event_id),
         count(*) FILTER (WHERE x.is_new)
    INTO v_ids, v_events, v_new
    FROM (SELECT n2s_id, tevo_event_id, true  AS is_new FROM newly
          UNION ALL
          SELECT n2s_id, tevo_event_id, false            FROM sweep) x;

  IF v_events IS NULL OR cardinality(v_events) = 0 THEN
    RETURN QUERY SELECT 0,0,0,0,0,0,
                        COALESCE(v_sg_stored,0), COALESCE(v_sg_fill,0), 0, 0;
    RETURN;
  END IF;

  SELECT * INTO p FROM public.n2s_pull_events(v_events, p_refresh_after);

  UPDATE public.n2s_items SET sources_pulled_at = now() WHERE n2s_id = ANY(v_ids);

  RETURN QUERY SELECT cardinality(v_ids), COALESCE(v_new,0), p.evo_fired, p.gt_fired,
                      p.sg_queued, p.td_queued,
                      COALESCE(v_sg_stored,0), COALESCE(v_sg_fill,0),
                      p.evo_skipped_fresh, p.gt_skipped_fresh;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_pull_all_sources(integer,interval,interval,boolean,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_pull_all_sources(integer,interval,interval,boolean,integer) TO service_role;

-- Chain the pull onto mapping so "as the order comes in and is mapped" is
-- literally true: one tick maps, then polls, in that order. Previously mapping
-- and pulling were separate every-minute jobs with no ordering between them, so
-- a freshly mapped order waited for the next pull tick.
--
-- Looked up by name rather than hardcoded id: cron ids are environment state,
-- not schema, and this migration must be re-appliable anywhere.
DO $do$
DECLARE v_map bigint; v_pull bigint;
BEGIN
  SELECT jobid INTO v_map  FROM cron.job WHERE jobname = 'n2s_map_events_5min';
  SELECT jobid INTO v_pull FROM cron.job WHERE jobname = 'n2s_pull_all_sources_2min';

  IF v_map IS NOT NULL THEN
    PERFORM cron.alter_job(
      v_map,
      command := $cmd$ SELECT public.n2s_map_events(true); SELECT public.n2s_pull_all_sources(); $cmd$);
  END IF;

  -- The standalone pull job is now redundant: its body runs inside the mapping
  -- job above. Deactivated rather than unscheduled so the history and the id
  -- survive, and so re-enabling is one call if the chain is ever unpicked.
  -- (pg_cron cannot rename a job in place, which is why the surviving job is
  -- still called *_5min while running every minute and doing both steps.)
  IF v_pull IS NOT NULL THEN
    PERFORM cron.alter_job(v_pull, active := false);
  END IF;
END $do$;
