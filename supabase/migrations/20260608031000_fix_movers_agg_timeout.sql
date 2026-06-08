-- ============================================================
-- Fix movers index frozen since 06-02: refresh_movers_agg all-or-nothing timeout.
-- A1 2026-06-08. ## Applied via MCP after review.
--
-- BUG: the cron ran all 5 windows (7/15/30/180/365) in ONE DO-block transaction under the
-- default (short) statement_timeout. The long windows (180/365) re-percentile 1.7M–3.25M raw
-- ticketsdata rows in the td_daily CTE and exceed it → the whole block aborts → NO window
-- refreshes → event_movers_agg froze at 06-02 → compute_event_movers_index's 18h-staleness
-- guard returns 0 for every (source,window) → the index has been stale 6 days.
-- (Verified: window 7 alone completes in <30s; 15+30 together already exceed the cron budget.)
--
-- FIX: isolate each window in its own sub-transaction (savepoint via EXCEPTION) so a slow
-- long-window can't roll back the fast short-windows, and give each window an 8-minute budget.
-- The FE-critical short windows (7/15/30d) now always refresh; 180/365d get 8 min each,
-- isolated. (Follow-up tracked: source long-window TD trends from event_listing_snapshot_daily
-- — pre-aggregated medians, ~100× fewer rows — instead of re-percentiling raw snapshots.)
-- ============================================================

SELECT cron.schedule('refresh_movers_agg', '20 7,19 * * *', $cron$
  DO $g$
  DECLARE w int;
  BEGIN
    IF NOT public.cron_should_fire('refresh_movers_agg') THEN RETURN; END IF;
    FOREACH w IN ARRAY ARRAY[7,15,30,180,365] LOOP
      BEGIN
        PERFORM set_config('statement_timeout','480000', true);  -- 8 min, this sub-txn only
        PERFORM public.refresh_event_movers_agg(w);
      EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'refresh_event_movers_agg(%) skipped: %', w, SQLERRM;
      END;
    END LOOP;
  END $g$;
$cron$);
