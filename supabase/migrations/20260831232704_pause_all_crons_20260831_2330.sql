-- Migration 20260831232704 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "pause_all_crons_20260831_2330" (version 20260831232704) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration 20260831233000 — pause all active pg_cron jobs (second pause)
--
-- Lane:     xref+macro
-- Touches:  cron.job (W, via cron.alter_job)
-- Pre-reqs: 20260901000500 (the mapping-fleet resume this reverses)
--
-- Operator directive 2026-08-31 23:29 UTC: "pause all crons".
--
-- Second full pause of the day. 20260831120000 paused 205; the three resume
-- migrations since brought back 69 (ingest, orders/sales, and the mapping
-- fleet resumed ~15 minutes ago). This pauses that 69.
--
-- The enumerated list below IS the restore manifest -- 175 jobs were already
-- inactive beforehand and must stay that way, so a blanket
-- `UPDATE ... WHERE active` would lose the distinction on the way back. A
-- ready RESUME block sits at the foot of this file.
--
-- Guarded on md5 of the live active set (2b384bdefd53d8dca483ad68c5be7cf4) so
-- the migration aborts rather than pausing a set that has drifted since it was
-- written.
--
-- KNOWN CONSEQUENCE, stated so it is not discovered later: this stops
-- espn-racing-daily (06:30), espn-mma-daily (06:40) and espn-team-daily (05:00)
-- from firing tomorrow morning. Those three were the only outstanding
-- end-to-end test of the site.api -> site.web.api ESPN host swap; their tables
-- are still stuck at the 2026-08-19 outage date. That verification does not
-- happen while they are paused.
-- ============================================================================

DO $mig$
DECLARE
  v_expect_md5 constant text := '2b384bdefd53d8dca483ad68c5be7cf4';
  v_live_md5   text;
  v_paused     int := 0;
  v_name       text;
  v_manifest   text[] := ARRAY[
    'aq_maps_backfill_daily','aq_reschedule_sync_from_tevo_30min',
    'aq_to_tevo_search_bridge_13h','axs_to_tevo_search_bridge_13h',
    'backfill-order-tevo-from-aq-hourly','crawl-espn-team-assets-3min',
    'cross_source_match_tick_30min','d0_refresh_sales_fact_nightly',
    'd0_refresh_sales_fact_weekly_full','espn_injuries_sweep_daily',
    'espn_scoreboard_process_5min','espn_scoreboard_queue_4h',
    'espn_tournament_process_after_queue','espn_tournament_queue_weekly',
    'espn-attendance-daily','espn-gameday-10min','espn-gamelog-10min',
    'espn-live-score-poll','espn-mma-daily','espn-news-5min','espn-racing-daily',
    'espn-roster-10min','espn-rosters-daily','espn-rosters-new-leagues-daily',
    'espn-rosters-rotate','espn-stats-daily','espn-team-daily',
    'espn-transactions-5min','event_mapping_queue_tick','evo_discover_new_events',
    'evo_listings_poll_2min','evo_orders_process_30min','evo_orders_queue_30min',
    'gotickets_match_us_6h','gt_catalog_drain_daily','gt_catalog_sync_daily',
    'gt_ingest_drain_1min','gt_listings_poll_2min','gt_map_events_hourly',
    'gt_map_events_wide_daily','match_events_to_espn_10min',
    'match_listings_to_sg_30min','match_tournaments_daily',
    'match_unmatched_orders_sweep_hourly','pg_net_reap_10min','pm_match_15min',
    'reddit_news_process_1min','reddit_news_queue_1min','reddit_news_sweep_30min',
    'resolve-aq-seatdata-link-hourly','resolve-aq-tevo-from-sources-hourly',
    'retention_tick_hourly','seatdata_poll_twice_daily',
    'sg_broker_sales_metrics_refresh_hourly','sg_lifetime_sales_daily',
    'sg_priority_sales_process_5min','sg_sales_poll_5min',
    'sg_seller_orders_queue_30min','sg_seller_orders_queue_all_daily',
    'sg_seller_process_30min','sg_to_tevo_search_bridge_30min',
    'sweep_news_images_hourly','sweep_tevo_ticket_groups_cache',
    'td_gt_tm_enroll_from_match_hourly','tevo_blindspot_discovery_daily',
    'vivid_orders_process_30min','vivid_orders_queue_30min',
    'wa_news_process_5min','wa_news_queue_10min'
  ];
BEGIN
  SELECT md5(string_agg(jobname, ',' ORDER BY jobname)) INTO v_live_md5
    FROM cron.job WHERE active;

  IF v_live_md5 IS NULL THEN
    RAISE NOTICE 'pause_all_crons: nothing active; no-op';
    RETURN;
  END IF;

  IF v_live_md5 <> v_expect_md5 THEN
    RAISE EXCEPTION
      'pause_all_crons: live active set has drifted (live md5 %, expected %). Refusing to pause an unexpected set.',
      v_live_md5, v_expect_md5;
  END IF;

  FOREACH v_name IN ARRAY v_manifest LOOP
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_name AND active) THEN
      PERFORM cron.alter_job(
        (SELECT jobid FROM cron.job WHERE jobname = v_name), active := false);
      v_paused := v_paused + 1;
    END IF;
  END LOOP;

  RAISE NOTICE 'pause_all_crons: % job(s) paused', v_paused;
END $mig$;

-- Post-condition: nothing active.
DO $chk$
DECLARE v_on int;
BEGIN
  SELECT count(*) INTO v_on FROM cron.job WHERE active;
  IF v_on <> 0 THEN
    RAISE EXCEPTION 'pause_all_crons: % job(s) still active', v_on;
  END IF;
END $chk$;

-- ============================================================================
-- RESUME BLOCK — restores exactly the 69 jobs paused above, and nothing else.
-- The 175 jobs inactive before this migration stay inactive. Note that four of
-- those are forbidden by PROJECT_BIBLE §3 ("DISABLED 2026-06-19 -- don't
-- re-enable"): td_match_fill_enqueue, td_match_drain, td_match_apply_cron,
-- auto_match_sg_canonical_v3_hourly. They are absent from this list by design.
--
-- DO $resume$
-- DECLARE v_name text; v_manifest text[] := ARRAY[ ...the same 69 names... ];
-- BEGIN
--   FOREACH v_name IN ARRAY v_manifest LOOP
--     IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = v_name AND NOT active) THEN
--       PERFORM cron.alter_job(
--         (SELECT jobid FROM cron.job WHERE jobname = v_name), active := true);
--     END IF;
--   END LOOP;
-- END $resume$;
-- ============================================================================
;
