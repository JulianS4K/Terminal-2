-- ============================================================
-- P0 fixes for the collector cutover (post-cutover sweep, 2026-05-31).
-- A1. Three regressions found by the FE/health sweep:
--   1. New-event DISCOVERY stopped — the retired windowed collect-listings crons did
--      watchlist-driven TEvo /v9/events discovery; the per-event poller only refreshes
--      KNOWN events. Re-add a low-frequency windowed discovery sweep (decoupled from the
--      per-event refresh; high min_age so it won't double-pull poller-fresh events).
--   2. SG SALES went dark — the cutover retired the sales QUEUE (sg_broker_sales_queue_5min)
--      but the sales POLLER cron (sg_sales_poll_5min) was gated 'disabled' in cron_policy
--      (it had relied on the queue). Re-enable it + cap its p_max to the proven-safe 8.
--   3. RLS off on the 2 new control tables — they granted DML to `authenticated`; enable RLS
--      + revoke (service_role bypasses RLS, so cron/edge are unaffected).
-- ============================================================

-- ---- (3) Harden the new control tables (match the 96% house RLS convention) ----
ALTER TABLE public.collector_cadence       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.evo_listings_poll_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.collector_cadence       FROM authenticated, anon;
REVOKE ALL ON public.evo_listings_poll_state FROM authenticated, anon;

-- ---- (2) Restore SG sales polling via the retuned band poller (was dark) ----
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES ('sg_sales_poll_5min', ARRAY[12,13,14,15,16,17,18,19,20,21,22,23], 5, 5, 400, true, 'band-driven SG sales poller (re-enabled post-cutover; old sales queue retired)')
ON CONFLICT (jobname) DO UPDATE SET enabled = true, updated_at = now();

SELECT cron.schedule('sg_sales_poll_5min','*/5 * * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_sales_poll_5min') THEN RETURN; END IF; PERFORM public.sg_sales_poll_tick(8); END $b$;$cron$);

-- ---- (1) Re-add new-event discovery (windowed collect-listings, low freq, high min_age) ----
-- Discovery (upsert net-new TEvo events for watchlisted performers/venues) is separate from
-- per-event refresh. min_age_seconds=3600 → it discovers + only pulls events the per-event
-- poller hasn't kept fresh, so no meaningful double-pull. 3x/day per band is ample for discovery.
SELECT cron.schedule('collect-listings-discover-0-24h','7 1,9,17 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('collect-listings-discover-0-24h') THEN RETURN; END IF; PERFORM public._cron_invoke_edge_fn('https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=0-24h&min_age_seconds=3600','{}'::jsonb); END $b$;$cron$);
SELECT cron.schedule('collect-listings-discover-1-7d','12 1,9,17 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('collect-listings-discover-1-7d') THEN RETURN; END IF; PERFORM public._cron_invoke_edge_fn('https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=1-7d&min_age_seconds=3600','{}'::jsonb); END $b$;$cron$);
SELECT cron.schedule('collect-listings-discover-7-30d','17 1,9,17 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('collect-listings-discover-7-30d') THEN RETURN; END IF; PERFORM public._cron_invoke_edge_fn('https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=7-30d&min_age_seconds=3600','{}'::jsonb); END $b$;$cron$);
SELECT cron.schedule('collect-listings-discover-30-60d','22 1,9,17 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('collect-listings-discover-30-60d') THEN RETURN; END IF; PERFORM public._cron_invoke_edge_fn('https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=30-60d&min_age_seconds=3600','{}'::jsonb); END $b$;$cron$);
SELECT cron.schedule('collect-listings-discover-60d','27 1,9,17 * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('collect-listings-discover-60d') THEN RETURN; END IF; PERFORM public._cron_invoke_edge_fn('https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?window=60d%2B&min_age_seconds=3600','{}'::jsonb); END $b$;$cron$);
