-- Migration 20260512230000 · level:admin · lane:Audit/Push · writes:sweep_terminal_event_listings,cron(sweep_terminal_event_listings_hourly) · reads:listings_snapshots,event_lifecycle · pre:20260512220000
-- For events in terminal states (ghost_eliminated, cancelled), keep only the
-- last 5 distinct captured_at pulls. These events have no further price
-- movement to track; aggregate metrics (event_metrics/zone_metrics/section_metrics)
-- from when they were live are preserved indefinitely.
--
-- Initial backfill (90 events): 134K rows deleted.
-- Hourly cron at :20 (offset from dedup sweep at :15 to avoid contention).
--
-- Open question for operator: 'completed' events have 4.3M listing rows.
-- Including them in this sweep would recover another ~4.2M rows but would
-- lose per-listing detail for completed events. Held until explicit OK.

CREATE OR REPLACE FUNCTION public.sweep_terminal_event_listings(p_max_events int DEFAULT 50)
RETURNS TABLE(events_swept int, rows_deleted int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_event_id bigint;
  v_total_deleted int := 0;
  v_events_count int := 0;
  v_batch_deleted int;
BEGIN
  FOR v_event_id IN
    SELECT DISTINCT el.event_id
    FROM event_lifecycle el
    WHERE el.status IN ('ghost_eliminated', 'cancelled')
      AND EXISTS (SELECT 1 FROM listings_snapshots ls WHERE ls.event_id = el.event_id)
    ORDER BY el.event_id
    LIMIT p_max_events
  LOOP
    WITH ranked AS (
      SELECT captured_at,
        dense_rank() OVER (ORDER BY captured_at DESC) AS rk
      FROM (SELECT DISTINCT captured_at FROM listings_snapshots WHERE event_id = v_event_id) c
    ),
    keep_set AS (SELECT captured_at FROM ranked WHERE rk <= 5)
    DELETE FROM listings_snapshots
    WHERE event_id = v_event_id
      AND captured_at NOT IN (SELECT captured_at FROM keep_set);
    GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_batch_deleted;
    v_events_count := v_events_count + 1;
  END LOOP;
  RETURN QUERY SELECT v_events_count, v_total_deleted;
END $$;

COMMENT ON FUNCTION public.sweep_terminal_event_listings(int) IS
  'For ghost_eliminated + cancelled events, keep only the last 5 distinct captured_at pulls. Aggregates preserved. Hourly cron.';

SELECT cron.schedule(
  'sweep_terminal_event_listings_hourly',
  '20 * * * *',
  $$ SELECT public.sweep_terminal_event_listings(50); $$
);
