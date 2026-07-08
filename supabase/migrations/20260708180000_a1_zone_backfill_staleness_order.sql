-- ============================================================================
-- Migration 20260708180000 — Fix zone_metrics backfill starvation
--
-- Lane:     data plane (A1)
-- Touches:  backfill_stale_zone_metrics() (re-order the work queue)
--
-- Bug: backfill_stale_zone_metrics ordered its candidate queue by
--   ORDER BY latest_ls_at DESC  -- freshest-listing events first
-- and processes only p_max_events (100) per 10-min run. Near-term events
-- re-poll listings every few minutes, so they permanently occupy the top of a
-- freshest-first queue; far-future events (polled a few times a day) never climb
-- into the window. Measured 2026-07-08: 2,663 events qualified as stale and the
-- tail (~rank >100) was frozen — e.g. event 3091424 (Yankees, Aug 29, rescheduled)
-- sat at rank 877 with zone_metrics stuck at the June 22 value while its listings
-- kept updating. The per-zone "Zone Metrics" panel reads zone_metrics, so it went
-- stale/blank for every starved event.
--
-- Fix: order by the STALENESS GAP (latest listings minus last zone_metrics),
-- biggest gap first. Never-computed events (NULL) sort first via a sentinel far
-- past. This drains the tail: once an event is recomputed its gap collapses to ~0
-- and it drops to the back, so the queue self-levels and nothing can starve. The
-- `latest_ls_at >= now() - 7 days` qualifier is unchanged (only actively-listed
-- events are serviced). No signature / cadence change — pure ORDER BY fix.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.backfill_stale_zone_metrics(p_max_events integer DEFAULT 3)
RETURNS TABLE(events_recomputed integer, zones_written integer)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_events int := 0; v_zones int := 0; v_n int;
  v_start timestamptz := clock_timestamp();
BEGIN
  FOR r IN (
    WITH latest_ls AS (
      SELECT event_id, captured_at AS latest_ls_at
      FROM latest_event_metrics
      WHERE captured_at >= now() - interval '7 days'
    ),
    latest_zm AS (
      SELECT event_id, MAX(captured_at) AS latest_zm_at
      FROM zone_metrics GROUP BY event_id
    )
    SELECT ll.event_id, ll.latest_ls_at
    FROM latest_ls ll
    LEFT JOIN latest_zm zm ON zm.event_id = ll.event_id
    WHERE zm.latest_zm_at IS NULL OR zm.latest_zm_at < ll.latest_ls_at
    -- Staleness-gap-first: how far zone_metrics trails the live listings.
    -- Never-computed (NULL) sorts first via the epoch sentinel. Drains the
    -- long tail that a freshest-listings-first order would starve.
    ORDER BY (ll.latest_ls_at - COALESCE(zm.latest_zm_at, 'epoch'::timestamptz)) DESC,
             ll.latest_ls_at DESC
    LIMIT p_max_events
  ) LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '90 seconds';
    BEGIN
      v_n := compute_event_zone_metrics(r.event_id, r.latest_ls_at);
      PERFORM compute_event_section_metrics(r.event_id, r.latest_ls_at);
      v_events := v_events + 1;
      v_zones  := v_zones + COALESCE(v_n, 0);
    EXCEPTION
      WHEN query_canceled THEN
        RAISE NOTICE 'backfill_stale_zone_metrics: event % cancelled (statement_timeout)', r.event_id;
      WHEN OTHERS THEN
        RAISE NOTICE 'backfill_stale_zone_metrics failed for event %: %', r.event_id, SQLERRM;
    END;
  END LOOP;
  events_recomputed := v_events;
  zones_written := v_zones;
  RETURN NEXT;
END
$function$;
