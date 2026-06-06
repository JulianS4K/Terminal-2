-- Migration 20260606130000 · level:2 · lane:D0 (operator-directed)
-- writes: CREATE fn sg_market_chart_reveal_pull(int); cron_policy row +
--         cron.schedule('sg_market_chart_reveal_pull_daily') @ 10:30 UTC.
-- reads:  seatgeek_event_metrics (sales), sg_event_priority_state (owned/horizon/map),
--         evo_listings_poll_state (enrollment), event_metrics (freshness guard).
--
-- ============================================================
-- DURABLE FIX for the Top-50 chart's exposure blind spot.
--
-- The "TOP 50 — SG SELLING, WE'RE NOT IN" chart (mig 20260606120000) filters on
-- sg_event_priority_state.owned_count_last_7d = 0. That owned-count is only
-- accurate for events we actually PULL on EVO/TEvo (collect-listings →
-- listings_snapshots → event_metrics → classifier). An event that is mapped to a
-- TEvo event but NOT enrolled in evo_listings_poll_state shows owned = 0 even when
-- we hold inventory — a FALSE POSITIVE on the chart.
--
-- One-off audit 2026-06-06 (operator-directed): of 1,000 charting events, 133 were
-- mapped-but-uncollected; reveal-pulling them surfaced 100 events we actually hold
-- (7,189 owned tickets, incl. the F1 USGP weekend at COTA) that were wrongly shown
-- as "we're not in". This migration makes that reveal-pull self-correcting.
--
-- MECHANISM: a daily cron (10:30 UTC, ~35 min BEFORE the 11:05 chart rebuild) fires
-- collect-listings for every chart-eligible candidate (non-owned, future, >= 2 days
-- of SG sales in the trailing 7d) that is mapped to TEvo but not enrolled in the EVO
-- poller and has no fresh (<20h) event_metrics row. By the time the chart rebuilds:
--   reveal-pull (10:30) -> event_metrics owned written (secs)
--   -> sg_classify_events (5-min cron) sets owned_count_last_7d (<= 10:40)
--   -> rebuild_sg_market_chart (11:05) excludes the now-owned events.
-- Events we genuinely hold auto-enrol via the poller's owned-branch and stop being
-- re-pulled here; confirmed-unowned candidates get a once-daily refresh (the 20h
-- guard) so newly-acquired inventory is caught within a day. TEvo is our sole TEvo
-- consumer (effectively unlimited), so the pull volume is safe.
--
-- PENDING OPERATOR APPLY: prod apply is gated (CLAUDE.md §1).
-- ROLLBACK: cron.unschedule('sg_market_chart_reveal_pull_daily');
-- DROP FUNCTION sg_market_chart_reveal_pull(int); DELETE the cron_policy row.
-- ============================================================

CREATE OR REPLACE FUNCTION public.sg_market_chart_reveal_pull(p_max integer DEFAULT 400)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE r record; v_n int := 0;
BEGIN
  FOR r IN
    WITH daily AS (
      SELECT DISTINCT ON (sg_event_id, (captured_at AT TIME ZONE 'UTC')::date)
        sg_event_id, (captured_at AT TIME ZONE 'UTC')::date AS d
      FROM public.seatgeek_event_metrics
      WHERE captured_at > now() - interval '7 days'
        AND coalesce(sold_quantity, 0) > 0
      ORDER BY sg_event_id, (captured_at AT TIME ZONE 'UTC')::date, captured_at DESC
    ),
    cand AS (
      SELECT sg_event_id FROM daily GROUP BY sg_event_id HAVING count(*) >= 2
    )
    SELECT DISTINCT p.tevo_event_id
    FROM cand c
    JOIN public.sg_event_priority_state p ON p.sg_event_id = c.sg_event_id
    WHERE coalesce(p.owned_count_last_7d, 0) = 0           -- chart-eligible (looks non-owned)
      AND p.sg_datetime_utc > now()                        -- future
      AND p.tevo_event_id IS NOT NULL                      -- mapped to TEvo
      AND NOT EXISTS (SELECT 1 FROM public.evo_listings_poll_state ps
                      WHERE ps.event_id = p.tevo_event_id) -- not already collected by the EVO poller
      AND NOT EXISTS (SELECT 1 FROM public.event_metrics em
                      WHERE em.event_id = p.tevo_event_id
                        AND em.captured_at > now() - interval '20 hours') -- once-daily refresh guard
    LIMIT p_max
  LOOP
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id=' || r.tevo_event_id::text,
      '{}'::jsonb);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $func$;

REVOKE ALL ON FUNCTION public.sg_market_chart_reveal_pull(integer) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_market_chart_reveal_pull(integer) TO service_role;

COMMENT ON FUNCTION public.sg_market_chart_reveal_pull(integer) IS
  'Daily pre-step for the Top-50 chart: fires collect-listings for chart-eligible '
  '(non-owned, future, >=2d SG sales/7d) events that are mapped to TEvo but not yet '
  'collected on EVO, so true ownership surfaces before the 11:05 UTC chart rebuild. '
  'Eliminates false-positive "we are not in" rows. Cron @ 10:30 UTC.';

-- Daily cron, 35 min before the chart rebuild (gated)
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sg_market_chart_reveal_pull_daily',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   720, 720, 2, true,
   'Reveal-pull EVO listings for mapped-but-uncollected Top-50 chart candidates @ 10:30 UTC (35m before sg_market_chart_rebuild_daily). Makes the chart''s owned-filter self-correcting.')
ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et = EXCLUDED.peak_hours_et,
      peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = true,
      notes = EXCLUDED.notes,
      updated_at = now();

SELECT cron.schedule('sg_market_chart_reveal_pull_daily', '30 10 * * *', $cron$
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_market_chart_reveal_pull_daily') THEN RETURN; END IF;
    SET LOCAL statement_timeout = '120s';
    PERFORM public.sg_market_chart_reveal_pull(400);
  END $body$;
$cron$);
