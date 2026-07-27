-- ============================================================================
-- Migration 20260701191500 — EVO poller: band-priority ordering (fix near-term starvation)
--
-- Lane:     A1
-- Touches:  public.evo_listings_poll_tick(integer) — ORDER BY only. No signature/behavior change otherwise.
-- Pre-reqs: collector_band('EVO','listings',hte) (returns required_min), evo_listings_poll_state.
--
-- WHY (operator 2026-07-01 "make EVO near-perfect: pull listings + generate metrics for D0"):
--   The tick selected due events `ORDER BY overdue_ratio DESC LIMIT p_max`, where
--   overdue_ratio = minutes_since_poll / required_min. That lets a CHRONICALLY-stale far-out
--   event outrank a TIME-CRITICAL near-term one: a 6-month-out event last polled 30 days ago
--   has overdue_ratio ≈ 30, while a ≤3-day event 25 min stale (5 min cadence) has ratio ≈ 5 —
--   so the far-out event wins the LIMIT and the ≤3d band is starved. Observed on prod: ≤3d
--   events averaging ~25 min between polls (target 5 min), and getting WORSE over time.
--
--   FIX: prioritize by BAND first, then overdue within band —
--     ORDER BY required_min ASC, overdue_ratio DESC
--   Tightest cadence (=nearest event =fastest-moving prices) is served first every tick; the
--   remaining budget flows to longer-horizon events by how overdue they are. Near-term demand
--   (≤3d+≤7d ≈ 57 events/tick) fits well under p_max=120, so the near-term bands are never
--   starved while far-out still drains with the leftover budget. No throughput increase — this
--   only redistributes the existing 120/tick, so it does not raise listings_snapshots write load.
--
-- Idempotent: CREATE OR REPLACE only. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

CREATE OR REPLACE FUNCTION public.evo_listings_poll_tick(p_max integer DEFAULT 30)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_n int := 0;
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
    )
    -- Band priority first (smaller required_min = nearer event = fastest-moving = served first),
    -- then most-overdue within the band. Fixes near-term starvation by chronically-stale far-out events.
    SELECT id FROM due ORDER BY required_min ASC NULLS LAST, overdue_ratio DESC LIMIT p_max
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
