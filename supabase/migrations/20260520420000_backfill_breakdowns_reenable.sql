-- 20260520420000_backfill_breakdowns_reenable.sql
--
-- Re-enable + extend the isolated breakdowns backfill so heavy events that
-- soft-fail compute_event_breakdowns on the hot path get their zone AND
-- section metrics recomputed out-of-band.
--
-- ## Context
--
-- Migration 20260520410000 made compute_event_breakdowns non-fatal: a heavy
-- event (e.g. Yankees games, 1300+ listings) now soft-fails its zone/section
-- step inside the 6s cap instead of 502-ing the collect-listings pull. That
-- fixes the false 502 but leaves those events' breakdowns stale on the hot
-- path (observed: event 3091452 zone_metrics stale since May 12).
--
-- backfill_stale_zone_metrics + its cron zone-backfill-isolated-10min are the
-- designed catch-up path (runs under cron with no 8s authenticator ceiling,
-- 90s per-event budget — enough for heavy events to complete). But the cron
-- was DISABLED and the function only recomputed zones, not sections.
--
-- ## Changes
--
-- 1. Detection query: replace the 7-day scan over listings_snapshots (8M
--    rows — a contention risk, the reason this cron was likely parked) with
--    a cheap read of the latest_event_metrics matview (~1k rows, already
--    maintained, captured_at points at a real snapshot). Same staleness
--    semantics: events whose newest zone_metrics is older than their newest
--    snapshot (or never computed).
--
-- 2. Recompute BOTH zone + section per event (was zones only), so the
--    catch-up matches what the inline RPC would have written.
--
-- 3. Exception handler now traps query_canceled EXPLICITLY (the 90s cap
--    raises 57014, which a bare WHEN OTHERS does NOT catch — same landmine
--    that broke the first cut of the non-fatal fix). Without this a single
--    >90s event would abort the whole backfill loop.
--
-- 4. Re-enable the zone-backfill-isolated-10min cron (active = true).
--
-- Return signature unchanged (events_recomputed, zones_written) so this is a
-- CREATE OR REPLACE — section recompute is a side effect, not a new column.

CREATE OR REPLACE FUNCTION public.backfill_stale_zone_metrics(p_max_events integer DEFAULT 3)
RETURNS TABLE(events_recomputed integer, zones_written integer)
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_events int := 0; v_zones int := 0; v_n int;
BEGIN
  FOR r IN (
    -- Cheap detection via the matview instead of an 8M-row listings scan.
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
    ORDER BY ll.latest_ls_at DESC
    LIMIT p_max_events
  ) LOOP
    BEGIN
      -- 90s per-event cap so one hot event can't blow the cron budget.
      -- Runs under cron (no 8s authenticator ceiling), so heavy events
      -- that soft-fail the inline 6s RPC can complete here.
      SET LOCAL statement_timeout = '90s';
      v_n := compute_event_zone_metrics(r.event_id, r.latest_ls_at);
      PERFORM compute_event_section_metrics(r.event_id, r.latest_ls_at);
      v_events := v_events + 1;
      v_zones  := v_zones + COALESCE(v_n, 0);
    EXCEPTION
      WHEN query_canceled THEN
        RAISE NOTICE 'backfill_stale_zone_metrics: event % hit 90s cap', r.event_id;
      WHEN OTHERS THEN
        RAISE NOTICE 'backfill_stale_zone_metrics failed for event %: %', r.event_id, SQLERRM;
    END;
  END LOOP;
  events_recomputed := v_events;
  zones_written := v_zones;
  RETURN NEXT;
END
$function$;

COMMENT ON FUNCTION public.backfill_stale_zone_metrics(integer) IS
  'Out-of-band catch-up for events whose zone_metrics is stale vs their '
  'latest snapshot (detected via latest_event_metrics matview). Recomputes '
  'BOTH zone + section metrics under a 90s per-event cap. Complements the '
  'non-fatal compute_event_breakdowns: heavy events soft-fail the inline 6s '
  'RPC, this finishes them under the longer budget. Driven by cron '
  'zone-backfill-isolated-10min.';

-- Re-enable the catch-up cron (was active=false).
SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname = 'zone-backfill-isolated-10min'),
  active := true
);

-- ============================================================
-- Post-apply verification
-- ============================================================
-- 1. Cron active:
--    SELECT jobname, schedule, active FROM cron.job
--    WHERE jobname = 'zone-backfill-isolated-10min';   -- active = true
--
-- 2. Manual one-shot (recomputes up to 5 stale events incl. heavy ones):
--    SELECT * FROM public.backfill_stale_zone_metrics(5);
--
-- 3. Heavy event catches up — zone_metrics for 3091452 goes fresh:
--    SELECT max(captured_at) FROM zone_metrics WHERE event_id = 3091452;
--
-- 4. After a few cron firings, stale backlog shrinks:
--    WITH lz AS (SELECT event_id, max(captured_at) z FROM zone_metrics GROUP BY 1)
--    SELECT count(*) FROM latest_event_metrics lem
--    LEFT JOIN lz ON lz.event_id = lem.event_id
--    WHERE lz.z IS NULL OR lz.z < lem.captured_at;
