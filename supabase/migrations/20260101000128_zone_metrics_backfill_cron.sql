-- Auto-recompute zone_metrics for events whose listings_snapshots are newer
-- than their latest zone_metrics row. Closes the gap when collect-listings
-- writes event_metrics on a tick but skips zone_metrics for some events.
-- Applied to prod 2026-05-09 ~00:00 UTC; this file captures it for git parity.
--
-- Wrapper around the existing compute_event_zone_metrics(event_id, captured_at)
-- which already does curated → derive_zone_fallback → 'unmapped' resolution
-- and full percentile aggregation. We just batch it with a stale-detection
-- query and per-event try/except so one slow event doesn't block the rest.
--
-- Cron 'backfill-zone-metrics-10min' fires at :04/:14/:24/:34/:44/:54 every
-- hour, 4 minutes after each :00 collect-listings tick. Batch capped at 50
-- events per tick — Supabase statement timeout for compute_event_zone_metrics
-- on a large NBA playoff event ran ~10s in testing; 50/tick fits comfortably.

CREATE OR REPLACE FUNCTION backfill_stale_zone_metrics(p_max_events int DEFAULT 50)
RETURNS TABLE(events_recomputed int, zones_written int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_events int := 0; v_zones int := 0; v_n int;
BEGIN
  FOR r IN (
    WITH latest_ls AS (
      SELECT event_id, MAX(captured_at) AS latest_ls_at
      FROM listings_snapshots
      WHERE captured_at >= NOW() - INTERVAL '7 days'
      GROUP BY event_id
    ),
    latest_zm AS (
      SELECT event_id, MAX(captured_at) AS latest_zm_at FROM zone_metrics GROUP BY event_id
    )
    SELECT ll.event_id, ll.latest_ls_at
    FROM latest_ls ll
    LEFT JOIN latest_zm zm ON zm.event_id = ll.event_id
    WHERE zm.latest_zm_at IS NULL OR zm.latest_zm_at < ll.latest_ls_at
    ORDER BY ll.latest_ls_at DESC
    LIMIT p_max_events
  ) LOOP
    BEGIN
      v_n := compute_event_zone_metrics(r.event_id, r.latest_ls_at);
      v_events := v_events + 1;
      v_zones  := v_zones + COALESCE(v_n, 0);
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'compute_event_zone_metrics failed for event %: %', r.event_id, SQLERRM;
    END;
  END LOOP;
  events_recomputed := v_events; zones_written := v_zones;
  RETURN NEXT;
END $$;

GRANT EXECUTE ON FUNCTION backfill_stale_zone_metrics(int) TO authenticated, service_role;

SELECT cron.schedule(
  'backfill-zone-metrics-10min',
  '4-59/10 * * * *',
  $$ SELECT public.backfill_stale_zone_metrics(50); $$
);
