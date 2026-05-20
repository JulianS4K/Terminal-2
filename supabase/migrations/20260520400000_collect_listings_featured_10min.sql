-- 20260520400000_collect_listings_featured_10min.sql
--
-- Featured-rail pricing refresh: TEvo /v9/ticket_groups every 10 minutes
-- for the NYC storefront's Featured-eligible event pool.
--
-- ## Why
--
-- The 5 existing collect-listings windowed crons only refresh 24h+ events
-- twice per day (06:00 / 18:00 UTC). The storefront's Featured rail surfaces
-- events up to 90 days out (playoffs, holiday games, US Open, etc.), so
-- their TEvo pricing on consumer cards goes stale by ~6h average under the
-- existing schedule.
--
-- Operator directive 2026-05-19: "for events on featured, run the cron
-- every 10 mins to get newest evo pricing".
--
-- ## Approach
--
-- 1. Define a candidate pool that's a *superset* of Featured selections:
--    NYC venue + owned_tickets_count > 100 + occurs_at 24h-90d out.
--    Featured selection (5 branches: playoff/holiday/rivalry/marquee/median>$50)
--    is computed in app.py from this pool. Refreshing the whole pool
--    guarantees Featured events are always fresh, regardless of which
--    branch elevated them.
--
-- 2. 10-min cron iterates candidates ordered by `captured_at NULLS FIRST`
--    + occurs_at ASC, fires `/functions/v1/collect-listings?event_id=X`
--    per event via `_cron_invoke_edge_fn`. Single-event mode = 1 TEvo call
--    per invocation.
--
-- 3. Cap at 50 events/firing (pool currently 40 NYC + owned>100 in 24h-90d
--    so the cap is mostly bandwidth headroom). 50 × 144 firings/day = 7,200
--    extra TEvo calls/day on top of the existing hot-tier ~5-11k.
--
-- 4. Skip events with `captured_at` < 9min old: avoids re-pulling rows
--    another path just refreshed (90%-of-cadence pattern, same convention
--    as the existing crons' `min_age_seconds`).
--
-- 5. Skip 0-24h events (existing collect-listings-0-24h cron already runs
--    at 10-min cadence for that window; we'd double-pull otherwise).
--
-- ## Matview handoff
--
-- `latest_event_metrics` (matview, what storefront reads) is refreshed by
-- the existing `latest_event_metrics_refresh_5min` cron at `:2 / :12 / :22…`.
-- New cron runs at `:3 / :13 / :23…` so its TEvo writes land in
-- `event_metrics` ~10s after firing, then the next matview refresh (~9 min
-- later) makes them visible to /api/store/movers and /api/store/home.
--
-- ## Sequencing vs other crons
--
-- Minute slot map (post-2026-05-19):
--   :0  sg_broker_listings_queue_5min
--   :1  collect-listings-0-24h (existing) — HOT tier 0-24h
--   :2  latest_event_metrics_refresh_5min (matview refresh)
--   :2  sg_broker_sales_queue_5min
--   :3  collect-listings-featured-10min  ← THIS MIGRATION
--   :4  sg_priority_poll_tick_5min
--
-- 10-min schedule = 6 firings/hour at `:3, :13, :23, :33, :43, :53`.

-- ============================================================
-- Refresh function
-- ============================================================

CREATE OR REPLACE FUNCTION public.collect_listings_featured_refresh(p_max_events int DEFAULT 50)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, extensions, pg_temp
AS $func$
DECLARE
  v_url   text;
  v_count int := 0;
  v_eid   bigint;
BEGIN
  -- Round-robin oldest-captured first; skip recently-pulled (90% cadence)
  -- and 0-24h events (own cron handles those). NYC venue match mirrors
  -- the storefront's venue_patterns (see app.py _NYC_VENUE_PATTERNS).
  FOR v_eid IN
    SELECT e.id
    FROM public.events e
    JOIN public.latest_event_metrics lem ON lem.event_id = e.id
    JOIN public.event_lifecycle el       ON el.event_id  = e.id AND el.is_active = true
    WHERE (e.venue_location ILIKE '%new york%'
           OR e.venue_location ILIKE '%, NY%'
           OR e.venue_location = 'New York, NY')
      AND e.occurs_at_local::timestamptz
            BETWEEN now() + interval '24 hours' AND now() + interval '90 days'
      AND lem.owned_tickets_count > 100
      AND (lem.captured_at IS NULL OR lem.captured_at < now() - interval '9 minutes')
    ORDER BY lem.captured_at NULLS FIRST, e.occurs_at_local::timestamptz ASC
    LIMIT p_max_events
  LOOP
    v_url := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings'
             || '?event_id=' || v_eid::text;
    PERFORM public._cron_invoke_edge_fn(v_url, '{}'::jsonb);
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $func$;

COMMENT ON FUNCTION public.collect_listings_featured_refresh(int) IS
  'Refreshes TEvo /v9/ticket_groups for up to p_max_events NYC events '
  'with owned>100 in 24h-90d window. Fires per-event edge function calls '
  'via _cron_invoke_edge_fn. Returns count of events dispatched. '
  'Called by cron collect-listings-featured-10min every 10 min.';

-- ============================================================
-- Cron schedule
-- ============================================================
-- Avoid collision with existing crons:
--   :1  collect-listings-0-24h   (10-min, hot tier)
--   :2  latest_event_metrics_refresh_5min (matview refresh)
--   :3  collect-listings-featured-10min   ← THIS
SELECT cron.schedule(
  'collect-listings-featured-10min',
  '3-53/10 * * * *',
  $cron$DO $body$ BEGIN
    IF NOT public.cron_should_fire('collect-listings-featured-10min') THEN RETURN; END IF;
    PERFORM public.collect_listings_featured_refresh(50);
  END $body$;$cron$
);

-- ============================================================
-- Cron policy (pause/resume + daily cap)
-- ============================================================
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
   work_check_sql, daily_max_fires, enabled, notes, updated_at)
VALUES
  ('collect-listings-featured-10min',
   ARRAY[]::int[],
   10, 10,
   NULL,
   150,
   true,
   '10-min TEvo pricing refresh for NYC Featured-eligible events '
   '(owned>100, 24h-90d horizon). Cap 50 events/firing. Closes the '
   'staleness gap on Featured rail vs the twice-daily window crons.',
   now())
ON CONFLICT (jobname) DO UPDATE
SET notes           = EXCLUDED.notes,
    enabled         = true,
    daily_max_fires = EXCLUDED.daily_max_fires,
    updated_at      = now();

-- ============================================================
-- Post-apply verification
-- ============================================================
-- 1. Function exists:
--    SELECT proname FROM pg_proc WHERE proname = 'collect_listings_featured_refresh';
--
-- 2. Cron scheduled:
--    SELECT jobname, schedule, active FROM cron.job
--    WHERE jobname = 'collect-listings-featured-10min';
--
-- 3. Policy row:
--    SELECT jobname, peak_min_interval_min, daily_max_fires, enabled
--    FROM public.cron_policy WHERE jobname = 'collect-listings-featured-10min';
--
-- 4. One-shot smoke test (returns count of events dispatched):
--    SELECT public.collect_listings_featured_refresh(5);
--    -- Wait 30s for async edge fn responses
--    SELECT count(*) FROM public.event_metrics
--    WHERE captured_at > now() - interval '2 minutes';
--    -- Expect ~5
--
-- 5. At next :12, :22 confirm matview caught the writes:
--    SELECT count(*) FROM public.latest_event_metrics
--    WHERE captured_at > now() - interval '15 minutes';
