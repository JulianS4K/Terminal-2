-- Migration 20260917030000 · level:data-collection · lane:A1 · writes:listings_poll_scope_policy (new table), v_listings_poll_scope_events (new view), listings_poll_scope_enabled() fn (new), listings_poll_tick(int) fn (gate), gt_listings_poll_tick(int,int) fn (gate) · reads:s4kcs_orders, n2s_items, seatgeek_orders, gotickets_purchases, events, gotickets_event · pre:20260917020000
--
-- ============================================================================================
-- FOR NOW, POLL ONLY THE EVENTS WE HAVE A POSITION IN.
-- ============================================================================================
-- Operator 2026-09-17: "For now only poll gotix and evo events that are in CRM and n2s and sg
-- sales and go tix purchases."
--
-- Measured before this change (2026-09-17 ~01:30Z):
--   future TEvo events the EVO poller may pick        108,064   (51,384 distinct polled in 24h)
--   future GoTickets events the GT poller may pick     27,917   (23,914 distinct polled in 24h)
--   future TEvo events in CRM ∪ N2S ∪ SG orders ∪ GT purchases   1,943
--     CRM (s4kcs_orders) 1,910 · N2S (n2s_items) 99 · SG orders (seatgeek_orders) 404 ·
--     GT purchases (gotickets_purchases) 48
--   GoTickets events mapped to one of those 1,943                  1,239
--
-- WHAT THIS DOES. One policy row + one view + one predicate, consulted by BOTH 2-minute pollers:
--   * public.listings_poll_scope_policy  — key='default', enabled, sources[] (which of the four
--     transaction tables define the scope), note. Flip `enabled=false` to restore the previous
--     everything-polls behaviour: a data change, no function edit, no cron edit.
--   * public.v_listings_poll_scope_events — DISTINCT tevo_event_id over the enabled sources.
--     Nothing here is materialised: the four tables are small (45.6k / 1.6k / 3.4k / 0.7k rows),
--     every tevo_event_id column is indexed, and a new CRM order / N2S item / SG order / GT
--     purchase puts its event in scope on the very next tick with no extra plumbing.
--   * listings_poll_tick (EVO, cron evo_listings_poll_2min) and gt_listings_poll_tick (GoTickets,
--     cron gt_listings_poll_2min) each gain ONE line in their candidate CTE:
--        AND (NOT public.listings_poll_scope_enabled() OR <tevo id> IN (SELECT ... scope view))
--     Everything else — cadence bands, phase offset, quarantine, cold backoff, parking exclusion,
--     the GT leg inside the EVO tick — is unchanged. The GoTickets leg inside listings_poll_tick
--     is gated by its parent EVO event, so both pollers use the same scope.
--
-- WHAT THIS DOES NOT TOUCH.
--   * collect-listings-discover-* (edge fn, 01/09/17h) — a discovery sweep of the watchlist, 6–13
--     events per run in the last three days; it is what creates `events` rows, so it stays.
--   * gt_sales_sync / gt_purchases_sync / sg purchases pollers — sales and purchases, not listings.
--   * n2s_pull_all_sources_on_arrival (mig 20260910130000) — on-arrival pulls, already in scope.
--   * the deals scanner — it scores what the pollers land; a narrower book is the operator's call.
--
-- PROD-VS-REPO DRIFT RECORDED HERE. Neither poller's live body was in the tree:
--   * public.listings_poll_tick(int) exists only in prod (the tree has evo_listings_poll_tick from
--     mig 20260601120000, which prod no longer runs); the live body carries a GoTickets leg per
--     EVO event so both samples are contemporaneous.
--   * public.gt_listings_poll_tick live signature is (p_max int DEFAULT 300, p_budget_seconds int
--     DEFAULT 75) with a loop-level wall clock and a phase offset against EVO's clock; the tree's
--     last version (mig 20260811274000) is (p_max int DEFAULT 120) with neither.
--   Both live bodies are captured below VERBATIM (pulled from pg_proc 2026-09-17) plus the one
--   gate line each, so the tree now matches prod.
--
-- ROLLBACK (data, no DDL): UPDATE public.listings_poll_scope_policy SET enabled=false WHERE key='default';
-- FULL ROLLBACK: restore both functions to the bodies below with the gate line removed.
-- ============================================================================================

-- ---------------------------------------------------------------------------
-- 1. Policy row (service-role only, like td_poll_policy)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.listings_poll_scope_policy (
  key        text PRIMARY KEY CHECK (key = 'default'),
  enabled    boolean NOT NULL DEFAULT true,
  sources    text[]  NOT NULL DEFAULT ARRAY['s4kcs_orders','n2s_items','seatgeek_orders','gotickets_purchases'],
  note       text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.listings_poll_scope_policy IS
  'Gate for the EVO + GoTickets 2-minute listings pollers. enabled=true → poll only TEvo events present in the enabled sources (v_listings_poll_scope_events). enabled=false → poll everything (pre-2026-09-17 behaviour). Operator directive 2026-09-17, mig 20260917030000.';
REVOKE ALL ON public.listings_poll_scope_policy FROM anon, authenticated;
ALTER TABLE public.listings_poll_scope_policy ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS listings_poll_scope_policy_service_only ON public.listings_poll_scope_policy;
CREATE POLICY listings_poll_scope_policy_service_only ON public.listings_poll_scope_policy
  FOR ALL TO service_role USING (true);

INSERT INTO public.listings_poll_scope_policy (key, enabled, note)
VALUES ('default', true,
        'Operator 2026-09-17: "For now only poll gotix and evo events that are in CRM and n2s and sg sales and go tix purchases." Flip enabled=false to poll everything again.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2. Scope view + predicate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_listings_poll_scope_events AS
  WITH pol AS (SELECT sources FROM public.listings_poll_scope_policy WHERE key = 'default')
  SELECT o.tevo_event_id
    FROM public.s4kcs_orders o, pol
   WHERE o.tevo_event_id IS NOT NULL AND 's4kcs_orders' = ANY(pol.sources)
  UNION
  SELECT n.tevo_event_id
    FROM public.n2s_items n, pol
   WHERE n.tevo_event_id IS NOT NULL AND 'n2s_items' = ANY(pol.sources)
  UNION
  SELECT s.tevo_event_id
    FROM public.seatgeek_orders s, pol
   WHERE s.tevo_event_id IS NOT NULL AND 'seatgeek_orders' = ANY(pol.sources)
  UNION
  SELECT p.tevo_event_id
    FROM public.gotickets_purchases p, pol
   WHERE p.tevo_event_id IS NOT NULL AND 'gotickets_purchases' = ANY(pol.sources);
COMMENT ON VIEW public.v_listings_poll_scope_events IS
  'TEvo event ids the listings pollers are allowed to poll while listings_poll_scope_policy.enabled. UNION of the enabled transaction tables (CRM orders, N2S items, SeatGeek orders, GoTickets purchases). Not materialised — a new order puts its event in scope on the next tick.';
REVOKE ALL ON public.v_listings_poll_scope_events FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.listings_poll_scope_enabled()
 RETURNS boolean
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT coalesce((SELECT enabled FROM public.listings_poll_scope_policy WHERE key = 'default'), false);
$function$;
REVOKE ALL ON FUNCTION public.listings_poll_scope_enabled() FROM public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. EVO tick — live body verbatim + the gate line
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.listings_poll_tick(p_max integer DEFAULT 120)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; g RECORD;
  v_n int := 0; v_gt int := 0; v_req bigint; v_token text;
  v_near int := GREATEST(1, (p_max * 2) / 3);
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  v_token := public._gotickets_pro_token();

  FOR r IN
    WITH ev AS (
      SELECT e.id,
             EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
        FROM public.events e
        LEFT JOIN public.evo_listings_poll_state ps ON ps.event_id = e.id
       WHERE e.occurs_at_local IS NOT NULL
         AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
         AND coalesce(e.state, 'shown') <> 'ignored'
         -- SCOPE GATE (mig 20260917030000): while the policy is enabled, only events we hold a
         -- position in (CRM / N2S / SG orders / GT purchases). Flip the policy row to widen.
         AND (NOT public.listings_poll_scope_enabled()
              OR e.id IN (SELECT tevo_event_id FROM public.v_listings_poll_scope_events))
    ),
    due AS (
      SELECT ev.id, ev.last_polled_listings_at,
             CASE WHEN ev.last_polled_listings_at IS NULL THEN 1e9
                  ELSE (EXTRACT(epoch FROM (now() - ev.last_polled_listings_at))/60.0)
                       / NULLIF(c.required_min, 0) END AS overdue_ratio
        FROM ev
        JOIN LATERAL public.collector_band('EVO','listings', ev.hte) c ON true
       WHERE ev.last_polled_listings_at IS NULL
          OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    ),
    near AS (
      SELECT id FROM due ORDER BY overdue_ratio DESC LIMIT v_near
    ),
    tail AS (
      SELECT id FROM due
       WHERE id NOT IN (SELECT id FROM near)
       ORDER BY last_polled_listings_at ASC NULLS FIRST
       LIMIT GREATEST(0, p_max - (SELECT count(*) FROM near))
    )
    SELECT id FROM near
    UNION ALL
    SELECT id FROM tail
  LOOP
    -- ---- EVO leg -------------------------------------------------------
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id=' || r.id::text,
      '{}'::jsonb);
    INSERT INTO public.evo_listings_poll_state(event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.id, now(), 1, current_date)
      ON CONFLICT (event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;

    -- ---- GoTickets leg, same iteration so both samples are contemporaneous ----
    FOR g IN
      SELECT gt.gt_event_id
        FROM public.gotickets_event gt
        LEFT JOIN public.gt_listings_poll_state gps ON gps.gt_event_id = gt.gt_event_id
       WHERE gt.tevo_event_id = r.id
         AND gt.status = 'AS_SCHEDULED'
         AND coalesce(gt.name,'')       !~* 'parking'
         AND coalesce(gt.venue_name,'')  !~* 'parking'
         AND coalesce(gt.performer,'')   !~* 'parking'
         AND (gps.quarantined_until IS NULL OR gps.quarantined_until < now())
         AND (gps.cold_until       IS NULL OR gps.cold_until       < now())
    LOOP
      SELECT net.http_get(
        url := 'https://gotickets.com/rest/pro/api/events/' || g.gt_event_id::text || '/listings',
        headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept','application/json'),
        timeout_milliseconds := 30000
      ) INTO v_req;
      INSERT INTO public.gt_listings_inflight(request_id, gt_event_id, tevo_event_id, fired_at)
        VALUES (v_req, g.gt_event_id, r.id, now());
      INSERT INTO public.gt_listings_poll_state(gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
        VALUES (g.gt_event_id, now(), 1, current_date)
        ON CONFLICT (gt_event_id) DO UPDATE SET
          last_polled_listings_at = now(),
          listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                      THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
          budget_day = current_date;
      v_gt := v_gt + 1;
    END LOOP;

    v_n := v_n + 1;
  END LOOP;

  RAISE NOTICE 'listings_poll_tick: % events sampled, % GoTickets legs', v_n, v_gt;
  RETURN v_n;
END $function$;

-- ---------------------------------------------------------------------------
-- 4. GoTickets tick — live body verbatim + the gate line
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.gt_listings_poll_tick(p_max integer DEFAULT 300, p_budget_seconds integer DEFAULT 75)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  r RECORD; v_n int := 0; v_req bigint; v_token text;
  v_daily_cap int := 1000000;
  v_near int := GREATEST(1, (p_max * 2) / 3);
  v_start timestamptz := clock_timestamp();
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  IF (SELECT coalesce(sum(listings_polls_today),0) FROM public.gt_listings_poll_state
        WHERE budget_day = current_date) >= v_daily_cap THEN
    RETURN 0;
  END IF;
  v_token := public._gotickets_pro_token();
  FOR r IN
    WITH ev AS (
      SELECT g.gt_event_id, g.tevo_event_id,
             EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now()))/3600.0 AS hte,
             ps.last_polled_listings_at,
             pe.last_polled_listings_at AS evo_last
        FROM public.gotickets_event g
        JOIN public.events e ON e.id = g.tevo_event_id
        LEFT JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
        -- EVO's clock for the SAME event, so GT can phase-offset against it.
        LEFT JOIN public.evo_listings_poll_state pe ON pe.event_id = g.tevo_event_id
       WHERE g.status = 'AS_SCHEDULED'
         AND e.occurs_at_local IS NOT NULL
         AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
         AND coalesce(e.state, 'shown') <> 'ignored'
         AND coalesce(g.name,'')       !~* 'parking'
         AND coalesce(g.venue_name,'')  !~* 'parking'
         AND coalesce(g.performer,'')   !~* 'parking'
         AND (ps.quarantined_until IS NULL OR ps.quarantined_until < now())
         AND (ps.cold_until       IS NULL OR ps.cold_until       < now())
         -- SCOPE GATE (mig 20260917030000): while the policy is enabled, only events we hold a
         -- position in (CRM / N2S / SG orders / GT purchases). Flip the policy row to widen.
         AND (NOT public.listings_poll_scope_enabled()
              OR g.tevo_event_id IN (SELECT tevo_event_id FROM public.v_listings_poll_scope_events))
    ),
    due AS (
      SELECT ev.gt_event_id, ev.tevo_event_id, ev.last_polled_listings_at,
             CASE WHEN ev.last_polled_listings_at IS NULL THEN 1e9
                  ELSE (EXTRACT(epoch FROM (now() - ev.last_polled_listings_at))/60.0)
                       / NULLIF(c.required_min, 0) END AS overdue_ratio
        FROM ev
        -- 'GT', not 'EVO': the GT collector_cadence rows are live config now.
        JOIN LATERAL public.collector_band('GT','listings', ev.hte) c ON true
       WHERE (ev.last_polled_listings_at IS NULL
              OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min))
         -- PHASE OFFSET vs EVO: 746 of 1,008 paired events were polled by both
         -- within one minute (median gap 0.0). Holding GT half a band behind
         -- EVO interleaves them. Escapes: cap the wait at 30 min, and fire
         -- anything 1.5 bands overdue regardless of phase.
         AND (ev.evo_last IS NULL
              OR ev.evo_last < now() - make_interval(
                   secs => LEAST(c.required_min * 30, 1800)::int)
              OR ev.last_polled_listings_at IS NULL
              OR ev.last_polled_listings_at < now() - make_interval(
                   mins => (c.required_min * 3) / 2))
    ),
    near AS (
      SELECT gt_event_id, tevo_event_id FROM due ORDER BY overdue_ratio DESC LIMIT v_near
    ),
    tail AS (
      SELECT gt_event_id, tevo_event_id FROM due
       WHERE gt_event_id NOT IN (SELECT gt_event_id FROM near)
       ORDER BY last_polled_listings_at ASC NULLS FIRST
       LIMIT GREATEST(0, p_max - (SELECT count(*) FROM near))
    )
    SELECT gt_event_id, tevo_event_id FROM near
    UNION ALL
    SELECT gt_event_id, tevo_event_id FROM tail
  LOOP
    -- Loop-level wall clock: a per-iteration SET LOCAL statement_timeout is a
    -- no-op on the running statement (PROJECT_BIBLE §3).
    EXIT WHEN clock_timestamp() - v_start > make_interval(secs => p_budget_seconds);

    SELECT net.http_get(
      url := 'https://gotickets.com/rest/pro/api/events/' || r.gt_event_id::text || '/listings',
      headers := jsonb_build_object('X-Broker-Api-Token', v_token, 'Accept','application/json'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.gt_listings_inflight(request_id, gt_event_id, tevo_event_id, fired_at)
      VALUES (v_req, r.gt_event_id, r.tevo_event_id, now());
    INSERT INTO public.gt_listings_poll_state(gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.gt_event_id, now(), 1, current_date)
      ON CONFLICT (gt_event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$function$;
