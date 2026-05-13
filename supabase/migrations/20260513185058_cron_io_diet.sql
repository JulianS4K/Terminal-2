-- Migration 20260513180000 · level:admin · lane:A1 · writes:cron(alter_job ×69 schedule/active) · reads:cron.job · pre:20260513002000
-- P0 IO-budget incident response 2026-05-13 — restore data flow with leaner cron matrix.
--
-- Incident timeline:
--   17:34 UTC  jobid 98 (zone-backfill-isolated-10min) begins failing with
--              job-startup-timeout; backfill_stale_zone_metrics(3) was
--              reading ~1.5 GB / run via a `MAX(captured_at) GROUP BY event_id`
--              over 2.74M rows / 2.45 GB of listings_snapshots every 10 min.
--   17:44 UTC  Statement timeout in PL/pgSQL after 132 s.
--   17:54 UTC  Statement timeout in PL/pgSQL after 203 s.
--   18:04:21Z  Postgres SERVER RESTART — disk-IO budget exhausted.
--   18:07 UTC  Cloudflare 522 surfaces on d2_dashboard (PR #85) sign-in,
--              caused by slow auth.users / auth.sessions reads against
--              throttled disk.
--   18:25 UTC  A1 paused all 70 active cron jobs (bot_chat row 88).
--
-- This migration re-enables 69 of those 70 with a leaner cadence matrix.
-- Goal: maintain broker data flow (TEvo + SG order/listings pulls) while
-- cutting derived-data / enrichment / observability cadence by ~80%.
-- Net expected IO recovery: ~12 GB/hr disk read, comfortably inside the
-- free-tier baseline.
--
-- Decisions captured here (operator-approved):
--   * job 91 (dashboard_writes_24h_refresh) → */15
--   * job 36 (midnight-catchup-sweep)       → 0 8 * * *  (3am EST canonical;
--                                              equivalent to 4am EDT during DST)
--   * jobs 53–57 (sg_listings_*) and 108–112 (collect-listings-*) BOTH stay
--     active — audit confirmed they are NOT duplicates: sg_listings_* pulls
--     SeatGeek → seatgeek_listings_snapshots; collect-listings pulls TEvo
--     → listings_snapshots/event_metrics/event_breakdowns.
--   * jobid 98 stays PAUSED until A1 lands the index migration on
--     listings_snapshots(event_id, captured_at DESC) so that the driver CTE
--     in backfill_stale_zone_metrics can use an index-only scan instead of
--     a sequential 2.4 GB read.
--
-- Reversal: per-job `SELECT cron.alter_job(<id>, schedule := '<original>', active := true);`
-- The original schedules are listed inline next to every alter_job call below.

BEGIN;

-- ============================================================
-- TIER 1 — broker data pipeline, current cadence, RE-ENABLE.
-- ============================================================
-- TEvo orders (D2 fan-out source)
SELECT cron.alter_job(61, schedule := '*/30 * * * *',  active := true);   -- evo_orders_queue_30min (unchanged)
SELECT cron.alter_job(62, schedule := '5-59/30 * * * *', active := true); -- evo_orders_process_30min (unchanged)
-- SG seller orders + listings
SELECT cron.alter_job(63, schedule := '*/30 * * * *',  active := true);   -- sg_seller_orders_queue_30min (unchanged)
SELECT cron.alter_job(64, schedule := '2-59/30 * * * *', active := true); -- sg_seller_listings_queue_30min (unchanged)
SELECT cron.alter_job(65, schedule := '5-59/30 * * * *', active := true); -- sg_seller_process_30min (unchanged)
-- SG listings (in-DB / pg_net) — 0-24h kept hot; 1-7d / 7-30d throttled in Tier 2 below.
SELECT cron.alter_job(53, schedule := '*/20 * * * *',  active := true);   -- sg_listings_0-24h (unchanged)
SELECT cron.alter_job(56, schedule := '15 */12 * * *', active := true);   -- sg_listings_30-60d (unchanged)
SELECT cron.alter_job(57, schedule := '20 2 * * *',    active := true);   -- sg_listings_60d+ (unchanged)
SELECT cron.alter_job(58, schedule := '2-59/5 * * * *', active := true);  -- sg_listings_process_5min (unchanged)
-- TEvo listings (edge fn) — 0-24h kept hot; 1-7d / 7-30d throttled in Tier 2 below.
SELECT cron.alter_job(108, schedule := '*/20 * * * *',  active := true);  -- collect-listings-0-24h (unchanged)
SELECT cron.alter_job(111, schedule := '15 */12 * * *', active := true);  -- collect-listings-30-60d (unchanged)
SELECT cron.alter_job(112, schedule := '20 2 * * *',    active := true);  -- collect-listings-60d+ (unchanged)
-- pg_net hygiene
SELECT cron.alter_job(114, schedule := '17 * * * *', active := true);     -- sweep_expired_pg_net_pending_hourly (unchanged)

-- ============================================================
-- TIER 2 — stretched cadences. Data still flows, less often.
-- ============================================================
SELECT cron.alter_job( 54, schedule := '5 */2 * * *',   active := true);  -- sg_listings_1-7d   (was hourly)
SELECT cron.alter_job( 55, schedule := '10 */8 * * *',  active := true);  -- sg_listings_7-30d  (was every 4h)
SELECT cron.alter_job(109, schedule := '5 */2 * * *',   active := true);  -- collect-listings-1-7d   (was hourly)
SELECT cron.alter_job(110, schedule := '10 */8 * * *',  active := true);  -- collect-listings-7-30d  (was every 4h)
SELECT cron.alter_job( 71, schedule := '0 * * * *',     active := true);  -- orphan_event_backfill_queue   (was */15)
SELECT cron.alter_job( 72, schedule := '5 * * * *',     active := true);  -- orphan_event_backfill_process (was 2-59/15)
SELECT cron.alter_job( 74, schedule := '*/30 * * * *',  active := true);  -- compute_alerts_tick    (was 5-59/15)
SELECT cron.alter_job( 92, schedule := '0 * * * *',     active := true);  -- auto_ack_stale_alerts  (was 8-59/30)
SELECT cron.alter_job(120, schedule := '7 * * * *',     active := true);  -- match_listings_to_sg   (was 7,37 hourly→every 30m, now hourly)
SELECT cron.alter_job( 68, schedule := '40 * * * *',    active := true);  -- cross_source_match_tick (was */30)
SELECT cron.alter_job(101, schedule := '*/30 * * * *',  active := true);  -- match_events_to_espn   (was */10)

-- ============================================================
-- TIER 3 — sharp throttle on derived/enrichment/observability.
-- ============================================================
SELECT cron.alter_job( 91, schedule := '*/15 * * * *',  active := true);  -- dashboard_writes_24h_refresh (was every minute — top IO offender after job 98)
SELECT cron.alter_job( 38, schedule := '*/10 * * * *',  active := true);  -- master-cascade  (was */2)
SELECT cron.alter_job(124, schedule := '*/30 * * * *',  active := true);  -- latest_event_metrics_refresh (was */5)
SELECT cron.alter_job( 43, schedule := '*/30 * * * *',  active := true);  -- performer_wiki_queue_searches (was */5)
SELECT cron.alter_job( 44, schedule := '*/30 * * * *',  active := true);  -- performer_wiki_process_searches (was 1-59/5)
SELECT cron.alter_job( 45, schedule := '*/30 * * * *',  active := true);  -- performer_wiki_process_summaries (was 2-59/5)
SELECT cron.alter_job( 46, schedule := '*/30 * * * *',  active := true);  -- venue_geocode_queue (was */5)
SELECT cron.alter_job( 47, schedule := '*/30 * * * *',  active := true);  -- venue_geocode_process (was 1-59/5)
SELECT cron.alter_job( 48, schedule := '0 */2 * * *',   active := true);  -- weather_forecast_queue (was */30)
SELECT cron.alter_job( 49, schedule := '5 */2 * * *',   active := true);  -- weather_forecast_process (was 5-59/30)
SELECT cron.alter_job( 93, schedule := '0 */2 * * *',   active := true);  -- nws_alerts_queue (was */30)
SELECT cron.alter_job( 94, schedule := '5 */2 * * *',   active := true);  -- nws_alerts_process_aligned (was 5,20 hourly)
SELECT cron.alter_job( 99, schedule := '0 */6 * * *',   active := true);  -- espn_scoreboard_queue (was every 4h)
SELECT cron.alter_job(100, schedule := '*/30 * * * *',  active := true);  -- espn_scoreboard_process (was */5)
SELECT cron.alter_job(104, schedule := '*/30 * * * *',  active := true);  -- fred_process (was 5-59/5)
SELECT cron.alter_job(105, schedule := '*/30 * * * *',  active := true);  -- backfill-event-configurations (was */5)
SELECT cron.alter_job(106, schedule := '*/30 * * * *',  active := true);  -- crawl-venues-and-performers (was */3)
SELECT cron.alter_job(107, schedule := '*/30 * * * *',  active := true);  -- crawl-espn-team-assets (was */3)
SELECT cron.alter_job( 20, schedule := '0 */4 * * *',   active := true);  -- sweep_tevo_ticket_groups_cache (was hourly)
SELECT cron.alter_job( 21, schedule := '0 */6 * * *',   active := true);  -- refresh-chat-corpus (was hourly)
SELECT cron.alter_job( 29, schedule := '0 */6 * * *',   active := true);  -- refresh-chat-term-freq-split (was hourly)
SELECT cron.alter_job( 70, schedule := '0 */6 * * *',   active := true);  -- event_competitors_refresh (was hourly)
SELECT cron.alter_job(117, schedule := '0 */6 * * *',   active := true);  -- sweep_duplicate_listings (was hourly)
SELECT cron.alter_job(118, schedule := '0 */6 * * *',   active := true);  -- sweep_terminal_event_listings (was hourly)

-- ============================================================
-- TIER 4 — job 98 stays paused; job 36 reschedules to 3am EST.
-- ============================================================
SELECT cron.alter_job( 36, schedule := '0 8 * * *',     active := true);  -- midnight-catchup-sweep → 3am EST (was 0 0 * * *, midnight UTC)
-- Job 98 zone-backfill-isolated-10min INTENTIONALLY LEFT PAUSED.
-- Re-enable in a separate migration AFTER landing an index on
-- listings_snapshots(event_id, captured_at DESC) so the driver CTE in
-- backfill_stale_zone_metrics can use an index-only scan. Failure mode if
-- prematurely re-enabled: another Postgres restart (see 18:04:21Z above).
-- SELECT cron.alter_job(98, schedule := '4-59/10 * * * *', active := true);

-- ============================================================
-- TIER 5 — dailies and weeklies, re-enable at original cadence.
-- ============================================================
SELECT cron.alter_job(  6, schedule := '0 3 * * *',     active := true);  -- sweep-old-listings
SELECT cron.alter_job( 18, schedule := '10 4 * * *',    active := true);  -- sweep-bot-messages
SELECT cron.alter_job( 27, schedule := '0 4 * * *',     active := true);  -- run-daily-chat-audit
SELECT cron.alter_job( 34, schedule := '0 6 * * *',     active := true);  -- ensure-watchlist-coverage-daily
SELECT cron.alter_job( 50, schedule := '0 6 * * 0',     active := true);  -- weather_climatology_weekly
SELECT cron.alter_job( 69, schedule := '30 3 * * *',    active := true);  -- wiki_pending_sweep_daily
SELECT cron.alter_job( 73, schedule := '35 3 * * *',    active := true);  -- orphan_backfill_sweep_daily
SELECT cron.alter_job( 80, schedule := '10 4 * * 0',    active := true);  -- tournament_search_pending_sweep_weekly
SELECT cron.alter_job( 81, schedule := '0 4 * * 0',     active := true);  -- tournament_pull_queue_weekly
SELECT cron.alter_job( 82, schedule := '5 4 * * 0',     active := true);  -- tournament_pull_process_weekly
SELECT cron.alter_job( 83, schedule := '15 4 * * 0',    active := true);  -- venue_pull_queue_weekly
SELECT cron.alter_job( 84, schedule := '15 4 * * *',    active := true);  -- nws_points_queue_daily
SELECT cron.alter_job( 88, schedule := '0 4 * * 0',     active := true);  -- espn_tournament_queue_weekly
SELECT cron.alter_job( 90, schedule := '30 4 * * *',    active := true);  -- match_tournaments_daily
SELECT cron.alter_job( 95, schedule := '25 4 * * *',    active := true);  -- nws_points_process_after_queue
SELECT cron.alter_job( 96, schedule := '5,15,30 4 * * 0', active := true);-- espn_tournament_process_after_queue
SELECT cron.alter_job( 97, schedule := '20 4 * * 0',    active := true);  -- venue_pull_process_weekly
SELECT cron.alter_job(102, schedule := '0 5 * * *',     active := true);  -- sweep_inactive_event_states_daily
SELECT cron.alter_job(103, schedule := '30 15 * * *',   active := true);  -- fred_queue_daily
SELECT cron.alter_job(113, schedule := '0 5 * * *',     active := true);  -- espn-team-daily

COMMIT;

-- Post-apply verification (run as service_role):
--   SELECT COUNT(*) FILTER (WHERE active) AS active, COUNT(*) FILTER (WHERE NOT active) AS paused FROM cron.job;
--   → expected: 69 active / 1 paused (only jobid 98 stays paused).
--
-- Followup work (separate migration, owner A1):
--   * Index migration on public.listings_snapshots(event_id, captured_at DESC)
--     to make backfill_stale_zone_metrics(p_max_events) drive off an
--     index-only scan instead of a full table scan. Re-enable job 98 after.
--   * Investigate whether jobs 53–57 (SG via pg_net) and 108–112
--     (TEvo via collect-listings edge fn) actually need the same 5-window
--     parallel cadence, or whether one of them can drop the long-tail
--     windows. Audit confirms they're not duplicates but the 60d+ window
--     in particular pulls very-rarely-changing data.
