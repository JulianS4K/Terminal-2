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
-- Fix, two parts:
--  1. Order by the STALENESS GAP (latest listings minus last zone_metrics),
--     biggest gap first, so the queue self-levels: a recomputed event's gap
--     collapses to ~0 and drops to the back. Never-computed events sort first
--     via an epoch sentinel.
--  2. Skip events with NO zoneable (non-ancillary) inventory at their latest
--     snapshot. compute_event_zone_metrics writes 0 zones for them, so they
--     stay never-computed forever and — with the epoch sentinel — would
--     permanently dominate the queue. In practice these are seatless events
--     (Broadway/venue tours, "experiences", conferences, ancillary-only rows)
--     that are still actively re-polled, so their fresh listings kept them
--     pinned to the top writing nothing every run, starving real stale events.
--     They have no zones to show, so excluding them is correct.
--
-- The `latest_ls_at >= now() - 7 days` qualifier and the 10-min cadence /
-- signature are unchanged.
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
    WHERE (zm.latest_zm_at IS NULL OR zm.latest_zm_at < ll.latest_ls_at)
      -- Only events that actually have zoneable inventory at their latest
      -- snapshot. Seatless events (tours/experiences/conferences, ancillary-
      -- only) compute to 0 zones and would otherwise stay never-computed and
      -- pin the top of the queue forever, starving real stale events.
      AND EXISTS (
        SELECT 1 FROM listings_snapshots l
        WHERE l.event_id = ll.event_id
          AND l.captured_at = ll.latest_ls_at
          AND l.is_ancillary = false
      )
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
