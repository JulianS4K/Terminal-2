-- ============================================================================
-- Migration 20260510080000 — Cron cascade alignment
--
-- Audit found 3 misaligned process schedules + 1 broken cascade. After
-- this migration every queue→process pair fires in the right order with
-- buffer for HTTP responses.
--
-- 1. nws_alerts_process: was every 5min, but queue is now every 30min.
--    Five of every six runs were no-ops. Realign to fire at queue+5 and
--    queue+20 (catches both fast and slow pg_net responses).
--
-- 2. nws_points_process: was every 5min, but queue is daily. ~287 no-op
--    runs/day. Single-shot at queue+10min.
--
-- 3. espn_tournament_process: was every 5min, but queue is weekly. ~2,000
--    no-op runs/week. Single-shot at queue+5/+15/+30min.
--
-- 4. venue_pull_queue_weekly fires Sun 04:15 and writes to the SHARED
--    `tournament_category_pending` table (using negative category_id as
--    a sentinel). The only existing process tick was tournament_pull_
--    process_weekly at Sun 04:05 — BEFORE the venue queue. Pending rows
--    sat unresolved for a week. Add a second process pass at Sun 04:20.
-- ============================================================================

-- (1) NWS alerts: 30min queue → process at +5 and +20
SELECT cron.unschedule('nws_alerts_process_5min');
SELECT cron.schedule(
  'nws_alerts_process_aligned',
  '5,20 * * * *',
  $$ SELECT public.nws_alerts_process(); $$
);

-- (2) NWS points: daily 04:15 queue → process at 04:25
SELECT cron.unschedule('nws_points_process_5min');
SELECT cron.schedule(
  'nws_points_process_after_queue',
  '25 4 * * *',
  $$ SELECT public.nws_points_process(); $$
);

-- (3) ESPN tournaments: weekly Sun 04:00 queue → process Sun 04:05/04:15/04:30
SELECT cron.unschedule('espn_tournament_process_5min');
SELECT cron.schedule(
  'espn_tournament_process_after_queue',
  '5,15,30 4 * * 0',
  $$ SELECT public.espn_tournament_process(); $$
);

-- (4) Venue pull cascade gap: Sun 04:15 queue → second process pass at 04:20
--     (uses tournament_pull_process — same pending table, negative category_id)
SELECT cron.schedule(
  'venue_pull_process_weekly',
  '20 4 * * 0',
  $$ SELECT public.tournament_pull_process(); $$
);

-- ============================================================================
-- All cron queue→process pairs after this migration
-- ============================================================================
--   queue                              | cadence       | process                              | cadence
--   -----------------------------------|---------------|--------------------------------------|----------------
--   evo_orders_queue_30min             | */30          | evo_orders_process_30min             | 5-59/30
--   reddit_queue_30min                 | */30          | reddit_process_30min                 | 5-59/30
--   weather_forecast_queue_30min       | */30          | weather_forecast_process_30min       | 5-59/30
--   sg_seller_orders_queue_30min       | */30          | sg_seller_process_30min              | 5-59/30
--   sg_seller_listings_queue_30min     | 2-59/30       | (same process function as orders)
--   performer_wiki_queue_searches_5min | */5           | performer_wiki_process_searches_5min | 1-59/5
--                                       |               | performer_wiki_process_summaries_5min| 2-59/5
--   venue_geocode_queue_5min           | */5           | venue_geocode_process_5min           | 1-59/5
--   orphan_event_backfill_queue_15min  | */15          | orphan_event_backfill_process_15min  | 2-59/15
--   nws_alerts_queue_30min             | */30          | nws_alerts_process_aligned           | 5,20 * * * *
--   nws_points_queue_daily             | 15 4 * * *    | nws_points_process_after_queue       | 25 4 * * *
--   espn_tournament_queue_weekly       | 0 4 * * 0     | espn_tournament_process_after_queue  | 5,15,30 4 * * 0
--   tournament_pull_queue_weekly       | 0 4 * * 0     | tournament_pull_process_weekly       | 5 4 * * 0
--   venue_pull_queue_weekly            | 15 4 * * 0    | venue_pull_process_weekly            | 20 4 * * 0
-- ============================================================================
