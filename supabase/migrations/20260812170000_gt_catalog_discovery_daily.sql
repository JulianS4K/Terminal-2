-- Migration 20260812170000 · lane:A1 (data plane — GoTickets ingest) → applier (apply)
--   writes (cron): retire gt_catalog_sync_hourly + gt_catalog_drain_hourly;
--                  add gt_catalog_sync_daily (08:15, 26h lookback) + gt_catalog_drain_daily (08:45)
--   auth: operator directive 2026-08-12 (julian@s4kent.com — "poll GoTickets for new events once
--         a day and add and match those to EVO")
--
-- WHY. GoTickets NEW-EVENT DISCOVERY was running hourly (gt_catalog_sync_hourly @ :15 with a 2h
-- overlap window) — the ~17k-event catalog sweep. New events (games, tours) are scheduled far
-- ahead and don't need hourly discovery, so this drops discovery to ONCE DAILY. Price polling of
-- already-mapped events (gt_listings_poll_2min / the external collector) and the incremental
-- mapping pass (gt_map_events_hourly) are unchanged.
--
-- Moving to daily requires WIDENING the sync lookback: an hourly run used a 2h overlap; a daily
-- run must cover ~24h + overlap, so it polls with interval '26 hours' — otherwise a daily run
-- would only see the last 2h of catalog changes and miss the day. The async sync→drain gap is
-- widened to 30 min (a full-day delta returns more responses than the hourly delta did).
--
-- The daily chain (discover → add → match to EVO):
--   08:15  gt_catalog_sync_daily   — fire async 26h catalog delta (DISCOVER new/changed events)
--   08:45  gt_catalog_drain_daily  — upsert the returned events into gotickets_event (ADD)
--   08:50  gt_map_events_wide_daily — gt_map_events(3650) + match_gotickets_us_events(...) (MATCH
--          each new US GoTickets event to its tevo/EVO event; the collector then price-polls it).
--   (gt_map_events_wide_daily already exists at 08:50 and is unchanged — it runs after the drain.)
--
-- ROLLBACK: cron.unschedule('gt_catalog_sync_daily'); cron.unschedule('gt_catalog_drain_daily');
--   cron.schedule('gt_catalog_sync_hourly','15 * * * *',$$SELECT public.gt_catalog_sync();$$);
--   cron.schedule('gt_catalog_drain_hourly','20 * * * *',$$SELECT public.gt_catalog_drain();$$);

-- Retire the hourly discovery.
SELECT cron.unschedule('gt_catalog_sync_hourly');
SELECT cron.unschedule('gt_catalog_drain_hourly');

-- Once-daily discovery with a full-day lookback, drained 30 min later (before the 08:50 map+match).
SELECT cron.schedule('gt_catalog_sync_daily',  '15 8 * * *', $c$SELECT public.gt_catalog_sync(interval '26 hours');$c$);
SELECT cron.schedule('gt_catalog_drain_daily', '45 8 * * *', $c$SELECT public.gt_catalog_drain();$c$);