-- ============================================================================
-- Migration 20260910130000 — a new N2S order pulls EVERY listing source
--
-- Lane:     D0 (orders surface), reaching into A1's EVO/GT/SG/TD pull planes
-- Touches:  n2s_items (+sources_pulled_at), n2s_pull_all_sources(), one cron
-- Pre-reqs: 20260910120000
--
-- Upstream: GET only — TEvo collect-listings, GoTickets /listings, the SG
--           on-demand queue, TicketsData /fetch. RULE 2 holds.
--
-- Operator direction 2026-09-09: "for new orders pull all listing sources when
-- they arrive."
--
-- ── Why this is the fix that matters ───────────────────────────────────────
-- Measured over the 25 newest N2S orders: ZERO had a live cover, while every
-- cover in the queue belonged to an older order. The pipeline was structurally
-- worst at exactly the moment it matters most — the 15-minute N2S timer is
-- running on a brand-new order, and inventory for its event is whatever the
-- background pollers last happened to collect.
--
-- Only TicketsData was being pulled on arrival (mig 20260910070000). The other
-- three sources waited for their own cadence. This fires all four the moment
-- an order is mapped.
--
-- ── ⚠ EACH SOURCE'S OWN GUARDS ARE RESPECTED, NOT BYPASSED ────────────────
-- These are other lanes' pull planes with their own budgets and back-off
-- state. This function goes through each one's front door:
--   * EVO   — invokes the same collect-listings edge function the tick does,
--             and writes evo_listings_poll_state so the poller SEES the poll
--             and does not immediately repeat it. Skipping that write would
--             spend A1's budget invisibly and double-poll the event.
--   * GT    — same request shape and token as gt_listings_poll_tick, records
--             gt_listings_inflight so the existing drain parses the response,
--             and HONOURS cold_until / quarantined_until. An event GT has
--             quarantined stays quarantined; a hot new order is not a reason
--             to hammer a source that asked us to back off.
--   * SG    — delegates to sg_listings_pull_on_demand(), which already carries
--             its own freshness and event-count limits.
--   * TD    — delegates to n2s_td_enqueue(); the 500/day cap and the vendor
--             quota back-off still apply.
--
-- ⚠ ONCE PER ORDER, NOT ONCE PER CYCLE. `sources_pulled_at` marks an order as
-- pulled-for. Without it a 2-minute cron would re-pull every source for every
-- open order forever — four upstreams hammered on a loop, budgets drained, and
-- the pollers' own scheduling wrecked. p_max bounds a single burst too, so a
-- flood of new orders degrades into "the next tick gets the rest".
--
-- ⚠ THE ORDER IS MARKED EVEN WHEN A SOURCE DECLINES. A GT quarantine or an
-- exhausted TD quota is not a transient error to retry in two minutes — the
-- background pollers will still reach the event on their own cadence. Marking
-- only on full success would turn every declining source into an infinite
-- retry loop, which is precisely what its back-off exists to prevent.
-- ============================================================================

ALTER TABLE public.n2s_items ADD COLUMN IF NOT EXISTS sources_pulled_at timestamptz;

CREATE INDEX IF NOT EXISTS n2s_items_unpulled_idx
  ON public.n2s_items (alert_at)
  WHERE sources_pulled_at IS NULL AND tevo_event_id IS NOT NULL;

COMMENT ON COLUMN public.n2s_items.sources_pulled_at IS
  'When every listing source was pulled on this order''s arrival. NULL = not '
  'yet. Set even if a source declined (GT quarantine, TD quota) — the '
  'background pollers still reach the event, and retrying a declining source '
  'every cycle defeats its back-off.';

CREATE OR REPLACE FUNCTION public.n2s_pull_all_sources(p_max integer DEFAULT 10)
RETURNS TABLE(orders integer, evo_fired integer, gt_fired integer,
              sg_queued integer, td_queued integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  r        RECORD;
  v_ids    bigint[];
  v_events bigint[];
  v_token  text;
  v_req    bigint;
  v_evo    int := 0;
  v_gt     int := 0;
  v_sg     int := 0;
  v_td     int := 0;
  v_orders int := 0;
BEGIN
  -- Newest first: the timer is running hardest on the most recent arrival.
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
    RETURN QUERY SELECT 0, 0, 0, 0, 0; RETURN;
  END IF;
  v_orders := cardinality(v_ids);

  -- ── EVO / TEvo: same edge function the poller uses ──────────────────────
  FOREACH v_req IN ARRAY v_events LOOP
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id='
        || v_req::text, '{}'::jsonb);
    -- Record it so the poller sees the poll and does not repeat it.
    INSERT INTO public.evo_listings_poll_state(
             event_id, last_polled_listings_at, listings_polls_today, budget_day)
    VALUES (v_req, now(), 1, current_date)
    ON CONFLICT (event_id) DO UPDATE SET
      last_polled_listings_at = now(),
      listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                  THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
      budget_day = current_date;
    v_evo := v_evo + 1;
  END LOOP;

  -- ── GoTickets: same shape as gt_listings_poll_tick, honouring back-off ──
  v_token := public._gotickets_pro_token();
  IF v_token IS NOT NULL AND btrim(v_token) <> '' THEN
    FOR r IN
      SELECT g.gt_event_id, g.tevo_event_id
        FROM public.gotickets_event g
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
       WHERE g.tevo_event_id = ANY(v_events)
         -- An event GT asked us to back off from stays backed off.
         AND (ps.cold_until IS NULL OR ps.cold_until < now())
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
    LOOP
      SELECT net.http_get(
        url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
        headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept', 'application/json'),
        timeout_milliseconds := 30000) INTO v_req;
      -- inflight is what the EXISTING gt drain reads; without this the
      -- response would arrive and never be parsed.
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

  -- ── SeatGeek + TicketsData: their own on-demand paths, guards intact ────
  BEGIN
    -- It returns ONE row of counters (queued, skipped_fresh, unmapped), not a
    -- row per event — count(*) here would always be 1.
    SELECT queued INTO v_sg
      FROM public.sg_listings_pull_on_demand(v_events, cardinality(v_events), interval '30 minutes');
  EXCEPTION WHEN OTHERS THEN
    -- SG's feed has been dead for months; a failure there must not abort the
    -- other three sources or leave the orders unmarked.
    RAISE NOTICE 'n2s_pull_all_sources: seatgeek on-demand failed: %', SQLERRM;
    v_sg := 0;
  END;

  SELECT events_enqueued INTO v_td FROM public.n2s_td_enqueue(cardinality(v_events));

  UPDATE public.n2s_items SET sources_pulled_at = now() WHERE n2s_id = ANY(v_ids);

  RETURN QUERY SELECT v_orders, v_evo, v_gt, COALESCE(v_sg, 0), COALESCE(v_td, 0);
END $function$;

REVOKE ALL ON FUNCTION public.n2s_pull_all_sources(integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_pull_all_sources(integer) TO service_role;

-- Every 2 minutes, right after the mapper, so an order is mapped and then
-- immediately has all four sources pulled for its event.
SELECT cron.schedule(
  'n2s_pull_all_sources_2min', '*/2 * * * *',
  $cron$ SELECT public.n2s_pull_all_sources(); $cron$
);
