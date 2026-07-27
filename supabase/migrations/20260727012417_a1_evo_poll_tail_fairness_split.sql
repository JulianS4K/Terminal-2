-- ============================================================================
-- Migration 20260727012417 — EVO listings poller: tail-fairness split (unstarve far bands)
--
-- Lane:     A1
-- Touches:  W: public.evo_listings_poll_tick() (selection ordering only — signature,
--              SECURITY DEFINER, search_path, ACL, and the collect-listings invoke +
--              evo_listings_poll_state upsert all UNCHANGED).
--           R: public.events, public.evo_listings_poll_state, public.collector_band('EVO','listings',hte).
-- Pre-reqs: migration 20260701180000 (defines the fn + the le3d..d181p EVO ladder in collector_cadence).
--           Cron evo_listings_poll_2min (jobid 321) already calls evo_listings_poll_tick(120); NOT touched.
--
-- WHY (operator 2026-07-27): pre-season NFL polling was effectively dead — 284/346 upcoming NFL
-- events (82%) unpolled for >7 days, oldest last-poll ~27 days. Not NFL-specific: every far-out band
-- was starved workspace-wide (measured 24h coverage: d31_60 7 events, d61p 1, d181p 0, vs ~6,700 due).
-- NFL is 100% far-out in July, so it surfaced the bug first.
--
-- ROOT CAUSE: the tick selected `ORDER BY overdue_ratio DESC LIMIT p_max`, where
-- overdue_ratio = minutes_stale / required_min. A near event's ratio grows ~1/required_min per minute,
-- so an le3d (5-min) event's ratio climbs 288x faster than a d181p (24h) event's. Short-cadence bands
-- therefore permanently occupy the top of the ORDER BY and crowd the long tail below the 120/tick cut
-- line — a structural starvation, not a capacity shortfall (throughput ceiling far exceeds demand).
--
-- FIX: split each tick's budget. ~2/3 (v_near) still go by overdue_ratio DESC (keeps the 5-min le3d band
-- honored); the remaining slots go to the events with the OLDEST absolute last_polled_listings_at
-- (NULLS FIRST), which are necessarily the starved far-out events. This guarantees every event drains to
-- at least its nominal cadence regardless of near-band churn. No throughput/cost change (same p_max=120,
-- same per-event collect-listings invoke), so the DOWNSTREAM NOTE in 20260701180000 is unaffected.
--
-- Idempotent (CREATE OR REPLACE, identical signature). Re-apply is a no-op.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.evo_listings_poll_tick(p_max integer DEFAULT 30)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD;
  v_n int := 0;
  v_near int := GREATEST(1, (p_max * 2) / 3);  -- ~2/3 budget: overdue-ratio priority (near-band 5-min honoring)
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
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
    ),
    due AS (
      SELECT ev.id, ev.last_polled_listings_at, c.required_min,
             CASE WHEN ev.last_polled_listings_at IS NULL THEN 1e9
                  ELSE (EXTRACT(epoch FROM (now() - ev.last_polled_listings_at))/60.0)
                       / NULLIF(c.required_min, 0) END AS overdue_ratio
      FROM ev
      JOIN LATERAL public.collector_band('EVO','listings', ev.hte) c ON true
      WHERE ev.last_polled_listings_at IS NULL
         OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    ),
    -- ~2/3 of the budget by overdue_ratio DESC — preserves the 5-min le3d responsiveness.
    near AS (
      SELECT id FROM due ORDER BY overdue_ratio DESC LIMIT v_near
    ),
    -- remaining budget to the stalest events in wall-clock terms (NULLS FIRST = never-polled),
    -- which are the far-out bands the ratio ordering structurally starves. Excludes the near picks.
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
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;
