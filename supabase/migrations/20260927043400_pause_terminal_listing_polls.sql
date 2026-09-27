-- Migration 20260927043400 · level:secondary-sales · lane:A1 (operator-routed to D7; A1 retired) · writes:cron.job,gt_listings_inflight · reads:none · pre:20260927042100
--
-- Already applied to prod · via MCP 2026-09-27 04:34–04:41 UTC under operator
-- direction ("Since n2s is priority for these pollers keep them paused. Nobody is
-- using this historic data" → "Pause all non n2s listing polls, but retain the
-- marketplace event matchers" → "yes pause 627 too"). bot_chat #4477, #4478.
--
-- ============================================================================
-- N2S has sole priority on the marketplace listing APIs. Every terminal listing
-- poll is paused (active = false; nothing deleted, resume per job with
-- cron.alter_job(<id>, active := true)). Event matchers keep running (141, 169,
-- 227, 228, 294, 319, 320, 336, 473, 536, 548, 562, 563, 583, 586, 638, 653,
-- 654); the events catalogue is fed by 653 tevo_event_pull_tick + 294
-- evo_discover_new_events. Terminal listing snapshots and what is built on
-- them (blind-spot MVs, deal models) go stale by design.
--
-- Also 2026-09-27 ~04:00 UTC: gt_listings_inflight held 337,942 dead rows
-- (fired 2026-08-27..31, responses long expired); 629 scanned past them every
-- minute. Deleted in batches (the queue was then empty).
-- ============================================================================

DELETE FROM public.gt_listings_inflight i
 WHERE i.fired_at < '2026-09-01'
   AND NOT EXISTS (SELECT 1 FROM net._http_response h WHERE h.id = i.request_id);

SELECT cron.alter_job(jobid, active := false)
  FROM cron.job
 WHERE jobname IN ('gt_listings_poll_2min',                  -- 628
                   'gt_ingest_drain_1min',                   -- 629
                   'deal_scan_tick_5min',                    -- 630
                   'sg_listings_process_on_demand_2min',     -- 639
                   'evo_listings_poll_2min',                 -- 321
                   'collect-listings-discover-0-24h',        -- 330
                   'collect-listings-discover-1-7d',         -- 331
                   'collect-listings-discover-7-30d',        -- 332
                   'collect-listings-discover-30-60d',       -- 333
                   'collect-listings-discover-60d',          -- 334
                   'gt_deals_scan_odd_min');                 -- 627

-- rollback: SELECT cron.alter_job(<jobid>, active := true) for each job above.
