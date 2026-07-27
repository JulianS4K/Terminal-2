-- Daily midnight UTC catch-up sweep that runs all idempotent backfills.
-- Applied to prod 2026-05-09 ~02:30 UTC; this file captures it for git parity.
--
-- Why: each backfill has its own intra-day cron (auto-link 15m,
-- zone-metrics 10m, splits 30m, watchlist-coverage daily 06:00). A single
-- midnight pass guarantees that anything added during the day gets one
-- coordinated catch-up run regardless of intra-day cron timing or
-- transient timeouts. All component fns are idempotent so safe to re-run.
--
-- Cron: 'midnight-catchup-sweep' jobid 36, schedule '0 0 * * *' (00:00 UTC).
-- First fire: 2026-05-10 00:00 UTC.

CREATE OR REPLACE FUNCTION midnight_catchup_sweep()
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_xref       int;
  v_zones      record;
  v_splits     int;
  v_watch      record;
BEGIN
  -- 1. Auto-link any newly-discoverable TEvo↔ESPN event matches
  SELECT linked_count INTO v_xref FROM auto_link_event_xref();

  -- 2. Recompute zone metrics for events whose listings outpaced their zones
  SELECT * INTO v_zones FROM backfill_stale_zone_metrics(500);

  -- 3. Compute splits metrics for any events that don't have them yet
  SELECT updated_count INTO v_splits FROM backfill_event_splits_metrics(500);

  -- 4. Ensure every ESPN-mapped major-league team is in the watchlist
  SELECT * INTO v_watch FROM ensure_major_league_watchlist_coverage();

  RETURN jsonb_build_object(
    'ran_at',                  NOW(),
    'auto_link_xref',          v_xref,
    'zone_events_recomputed',  v_zones.events_recomputed,
    'zone_rows_written',       v_zones.zones_written,
    'splits_events_updated',   v_splits,
    'watchlist_perfs_added',   v_watch.performers_added,
    'watchlist_venues_added',  v_watch.venues_added
  );
END $$;

GRANT EXECUTE ON FUNCTION midnight_catchup_sweep() TO authenticated, service_role;

SELECT cron.schedule(
  'midnight-catchup-sweep',
  '0 0 * * *',
  $$ SELECT public.midnight_catchup_sweep(); $$
);
