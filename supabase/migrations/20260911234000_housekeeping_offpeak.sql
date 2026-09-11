-- ============================================================================
-- Migration 20260911234000 — move housekeeping off peak hours
--
-- Lane:     A1 (crons)
-- Touches:  cron.job (W), cron_policy (W)
-- Pre-reqs: 20260705153000 (retention engine), cron_policy/is_peak
--
-- Peak is ET 09:00–01:59 (is_peak(), ~93% of realised sales); offpeak is
-- ET 02:00–08:59. Several jobs that are pure housekeeping — nothing user-facing
-- reads them inside a minute — have been running at full cadence straight
-- through peak on a database that is IO-starved (411 GB against 2 GB
-- shared_buffers, 82% cache hit).
--
-- Worst offender by a wide margin: pww_wiki_process(). Across pg_stat_statements
-- it is the single largest consumer of physical reads IN THE ENTIRE DATABASE —
-- 7.58 BILLION shared_blks_read over 28,440 calls (mean 38.5s), ahead of
-- gt_listings_drain and the health monitor. It is wiki enrichment, scheduled
-- '* * * * *'. Every one of those reads evicts somebody else's working set from
-- a 2 GB cache, which is a direct tax on the sub finder's latency.
--
-- Approach: gate each job on cron_should_fire() with a peak/offpeak interval in
-- cron_policy, rather than hardcoding a new schedule. The cron keeps ticking at
-- its old frequency and the POLICY decides — so cadence stays a data lever the
-- operator can retune in one UPDATE with no migration (RESOURCES_BIBLE §5).
--
-- Deliberately NOT moved (peak-critical, user-facing):
--   n2s_pipeline_tick_1min          — the sub finder, priority #1
--   latest_event_metrics_refresh_5min, evo_listings_poll_2min — D0 terminal
--   sg_sales_poll_5min, sg_priority_* — live market data
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Wiki enrichment — the database's biggest IO consumer, off peak
-- ---------------------------------------------------------------------------
INSERT INTO public.cron_policy(
  jobname, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires,
  enabled, notes)
VALUES
  ('pww_wiki_process_1min', 20, 1, NULL, true,
   'Performer/venue wiki enrichment. Largest source of physical reads in the '
   'database (7.58B shared_blks_read, mean 38.5s/call) — throttled to 20-min '
   'at peak, full 1-min cadence offpeak (20260911234000).'),
  ('pww_wiki_queue_1min', 20, 1, NULL, true,
   'Paired queue side of pww_wiki_process_1min; same peak/offpeak split so the '
   'queue does not run ahead of the drain (20260911234000).'),
  ('wa_news_process_5min', 15, 5, NULL, true,
   'News enrichment — housekeeping, off peak (20260911234000).'),
  ('wa_news_queue_10min', 30, 10, NULL, true,
   'News enrichment queue — housekeeping, off peak (20260911234000).'),
  ('athlete_wiki_queue_searches', 120, 30, NULL, true,
   'Athlete wiki backfill — housekeeping, off peak (20260911234000).'),
  ('reddit_news_sweep_30min', 120, 30, NULL, true,
   'Reddit wire sweep — housekeeping, off peak (20260911234000).')
ON CONFLICT (jobname) DO UPDATE SET
  peak_min_interval_min    = EXCLUDED.peak_min_interval_min,
  offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
  enabled                  = EXCLUDED.enabled,
  notes                    = EXCLUDED.notes,
  updated_at               = now();

-- These jobs gated only on cron_try_lock, so cron_policy had no effect on them.
-- Re-schedule with the policy gate in front of the existing lock.
SELECT cron.unschedule('pww_wiki_process_1min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pww_wiki_process_1min');
SELECT cron.schedule(
  'pww_wiki_process_1min', '* * * * *',
  $cron$ SET statement_timeout='55s';
         DO $guard$ BEGIN
           IF NOT public.cron_should_fire('pww_wiki_process_1min') THEN RETURN; END IF;
           IF NOT public.cron_try_lock('pww_wiki_process') THEN RETURN; END IF;
           PERFORM public.pww_wiki_process();
         END $guard$; $cron$);

SELECT cron.unschedule('pww_wiki_queue_1min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pww_wiki_queue_1min');
SELECT cron.schedule(
  'pww_wiki_queue_1min', '* * * * *',
  $cron$ SET statement_timeout='55s';
         DO $guard$ BEGIN
           IF NOT public.cron_should_fire('pww_wiki_queue_1min') THEN RETURN; END IF;
           PERFORM public.pww_wiki_queue(interval '1 minute');
         END $guard$; $cron$);

SELECT cron.unschedule('wa_news_process_5min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'wa_news_process_5min');
SELECT cron.schedule(
  'wa_news_process_5min', '4-59/5 * * * *',
  $cron$ SET statement_timeout='115s';
         DO $guard$ BEGIN
           IF NOT public.cron_should_fire('wa_news_process_5min') THEN RETURN; END IF;
           IF NOT public.cron_try_lock('wa_news_process') THEN RETURN; END IF;
           PERFORM public.wa_news_process();
         END $guard$; $cron$);

SELECT cron.unschedule('wa_news_queue_10min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'wa_news_queue_10min');
SELECT cron.schedule(
  'wa_news_queue_10min', '9-59/10 * * * *',
  $cron$ DO $guard$ BEGIN
           IF NOT public.cron_should_fire('wa_news_queue_10min') THEN RETURN; END IF;
           PERFORM public.wa_news_queue(3);
         END $guard$; $cron$);

SELECT cron.unschedule('athlete_wiki_queue_searches')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'athlete_wiki_queue_searches');
SELECT cron.schedule(
  'athlete_wiki_queue_searches', '*/30 * * * *',
  $cron$ DO $guard$ BEGIN
           IF NOT public.cron_should_fire('athlete_wiki_queue_searches') THEN RETURN; END IF;
           PERFORM public.queue_athlete_wiki_searches(15);
         END $guard$; $cron$);

SELECT cron.unschedule('reddit_news_sweep_30min')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'reddit_news_sweep_30min');
SELECT cron.schedule(
  'reddit_news_sweep_30min', '*/30 * * * *',
  $cron$ DO $guard$ BEGIN
           IF NOT public.cron_should_fire('reddit_news_sweep_30min') THEN RETURN; END IF;
           PERFORM public.reddit_news_sweep();
         END $guard$; $cron$);

-- ---------------------------------------------------------------------------
-- 2. refresh_movers_agg — both runs into the offpeak window, and capped
--
-- Was '20 7,19 * * *' UTC. The 19:20 run is 15:20 ET — mid-peak — and it holds
-- a slot for a very long time: mean 890s across 294 calls, and on 2026-09-11 a
-- single run sat on a connection for 38 minutes under statement_timeout=2700s
-- while every other job queued behind it on IO. Moved to 07:20 + 11:20 UTC
-- (03:20 + 07:20 ET, both offpeak) and capped at 25 minutes.
-- ---------------------------------------------------------------------------
SELECT cron.unschedule('refresh_movers_agg')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'refresh_movers_agg');
SELECT cron.schedule(
  'refresh_movers_agg', '20 7,11 * * *',
  $cron$ SET statement_timeout='1500s';
         SELECT set_config('app.movers_go', public.cron_should_fire('refresh_movers_agg')::text, false);
         SELECT public.refresh_event_movers_agg(7) WHERE current_setting('app.movers_go') = 'true'; $cron$);

-- ---------------------------------------------------------------------------
-- 3. retention_tick — small bites at peak, the real work offpeak
--
-- Retention has to clear ~30M rows/day across the two listings firehoses, but
-- it only managed 14 of its 24 hourly ticks in the last 24h: it is starved by
-- the same contention it exists to relieve, and its own deletes are heavy IO.
-- Budget now scales with the window (2 min at peak, 8 min offpeak) instead of
-- a flat 240s, so peak ticks finish and offpeak ticks do the bulk.
-- ---------------------------------------------------------------------------
SELECT cron.unschedule('retention_tick_hourly')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'retention_tick_hourly');
SELECT cron.schedule(
  'retention_tick_hourly', '44 * * * *',
  $cron$
  BEGIN;
  SET LOCAL statement_timeout='600s';
  DO $b$ BEGIN
    IF NOT public.cron_should_fire('retention_tick_hourly') THEN RETURN; END IF;
    PERFORM public.retention_tick(CASE WHEN public.is_peak() THEN 120 ELSE 480 END);
  END $b$;
  COMMIT;
  $cron$);

-- ---------------------------------------------------------------------------
-- 4. Blindspot matview — 193s average every 10 minutes is not a peak job
-- ---------------------------------------------------------------------------
UPDATE public.cron_policy
   SET peak_min_interval_min    = 30,
       offpeak_min_interval_min = 10,
       notes = coalesce(notes,'') ||
               ' [20260911234000: 193s mean refresh (max 663s) every 10 min — '
               'discovery aid, not a live surface; 30-min at peak.]',
       updated_at = now()
 WHERE jobname = 'tevo_blindspot_mv_refresh';
