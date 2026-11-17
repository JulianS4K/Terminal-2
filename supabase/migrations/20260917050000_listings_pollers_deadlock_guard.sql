-- Migration 20260917050000 · level:data-collection · lane:A1 · writes:listings_poll_tick(int) fn (deadlock guard), gt_listings_poll_tick(int,int) fn (deadlock guard) · reads:gt_listings_poll_state · pre:20260917040000
--
-- ============================================================================================
-- A DEADLOCK ON ONE CLOCK ROW MUST NOT ABORT A WHOLE POLLER TICK.
-- ============================================================================================
-- NOT YET APPLIED. Authored 2026-09-17 08:35Z from the check-in that found it; apply is the
-- operator's call (a poller-function change, not covered by the 2026-09-17 scope directive).
--
-- WHAT WAS SEEN. Three "deadlock detected" failures on 2026-09-17, all in the same statement:
--     05:08Z  gt_listings_poll_tick   INSERT ... gt_listings_poll_state ON CONFLICT DO UPDATE
--     07:22Z  gt_listings_poll_tick   same
--     08:00Z  listings_poll_tick      same statement, in the EVO tick's GoTickets leg
-- and the 08:00Z one landed after two launcher timeouts, so the EVO poller missed THREE
-- consecutive ticks (07:57–08:00Z, ~6 min with no EVO listings poll). A deadlock anywhere in the
-- loop rolls back the entire tick: every HTTP request already fired that tick loses its clock
-- update, and the tick's whole quota of events is re-polled next time.
--
-- WHY. Two writers upsert gt_listings_poll_state concurrently every two minutes:
--     * gt_listings_poll_tick (cron gt_listings_poll_2min) — up to 300 rows, ordered by overdue
--       ratio then staleness;
--     * listings_poll_tick (cron evo_listings_poll_2min) — its GoTickets leg upserts the same
--       rows, ordered by the EVO event's overdue ratio.
--   Different orders over the same rows is the textbook deadlock, and mig 20260917030000 made
--   it far more likely: both pollers now draw from the same ~1,379-event book instead of
--   27,917, so the row sets overlap on nearly every tick. Deadlocks on these two jobs existed
--   before the scope cut (1–5/day across the pollers and the drain since 09-12) but not at
--   three in one morning on this one statement.
--
-- THE FIX, MINIMAL. Wrap that one upsert, in both functions, in a sub-transaction that catches
-- deadlock_detected (SQLSTATE 40P01), logs a WARNING and continues. The HTTP request for the
-- row has already been sent by then; the only thing lost is one last_polled_listings_at bump,
-- which the row's next poll rewrites. The tick keeps its place in the loop, its other clock
-- updates, and its budget accounting. Nothing else in either body changes.
--
-- WHY NOT lock ordering. Ordering both loops by gt_event_id would also prevent the deadlock but
-- would replace the overdue-first priority both pollers exist to provide. Not worth it for a
-- clock row that is rewritten two minutes later anyway.
--
-- Bodies below are the mig 20260917030000 bodies (themselves the live prod bodies + the scope
-- gate) with ONLY the guarded block added. Diff against 20260917030000 to see the change.
--
-- ROLLBACK: restore both functions from mig 20260917030000.
-- ============================================================================================

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
      -- DEADLOCK GUARD (mig 20260917050000): this row is also upserted by gt_listings_poll_tick,
      -- which runs concurrently over the same in-scope book in a different order. A deadlock
      -- here used to abort the WHOLE tick (three today: 05:08Z, 07:22Z, 08:00Z; the last one
      -- cost three consecutive EVO ticks). The HTTP request above has already been sent, so
      -- losing this one clock update is harmless: the row is written again on its next poll.
      BEGIN
        INSERT INTO public.gt_listings_poll_state(gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
          VALUES (g.gt_event_id, now(), 1, current_date)
          ON CONFLICT (gt_event_id) DO UPDATE SET
            last_polled_listings_at = now(),
            listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                        THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
            budget_day = current_date;
      EXCEPTION WHEN deadlock_detected THEN
        RAISE WARNING 'listings_poll_tick: gt_listings_poll_state deadlock on gt_event_id %, clock update skipped', g.gt_event_id;
      END;
      v_gt := v_gt + 1;
    END LOOP;

    v_n := v_n + 1;
  END LOOP;

  RAISE NOTICE 'listings_poll_tick: % events sampled, % GoTickets legs', v_n, v_gt;
  RETURN v_n;
END $function$;

-- ---------------------------------------------------------------------------
-- 2. GoTickets tick — mig 20260917030000 body + the deadlock guard
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
    -- DEADLOCK GUARD (mig 20260917050000): see listings_poll_tick. Same row, other writer.
    BEGIN
      INSERT INTO public.gt_listings_poll_state(gt_event_id, last_polled_listings_at, listings_polls_today, budget_day)
        VALUES (r.gt_event_id, now(), 1, current_date)
        ON CONFLICT (gt_event_id) DO UPDATE SET
          last_polled_listings_at = now(),
          listings_polls_today = CASE WHEN gt_listings_poll_state.budget_day < current_date
                                      THEN 1 ELSE gt_listings_poll_state.listings_polls_today + 1 END,
          budget_day = current_date;
    EXCEPTION WHEN deadlock_detected THEN
      RAISE WARNING 'gt_listings_poll_tick: gt_listings_poll_state deadlock on gt_event_id %, clock update skipped', r.gt_event_id;
    END;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$function$;
