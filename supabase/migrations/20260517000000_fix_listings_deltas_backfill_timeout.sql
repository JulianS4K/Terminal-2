-- ============================================================================
-- Fix: listings_deltas_backfill_chunked statement-timeout cascade
--
-- Status before this migration (C1 #195 context):
--   - listings_deltas_backfill_overnight cron: 15 of 15 fires/24h failing
--   - All with "canceling statement due to statement timeout" on
--     listings_deltas_backfill_chunked(100)
--   - Function would have looped 100 events × ~6,800 rows/event UPDATE
--     + 100× pg_sleep(0.1) = ~10s sleep alone in a 60s budget
--   - Then the final count(DISTINCT event_id) over 6.5M-row table itself
--     timed out (post-loop wrap-up).
--
-- Pre-flight (this session):
--   - listings_snapshots: 970 events × ~6,790 rows avg unprocessed
--   - seatgeek_listings_snapshots: 587 events × 5,400 rows avg, max 276K
--   - 12 SG events >50K rows (p99 = 135K rows)
--   - Per-event read benchmark: ~28ms (BitmapIndex + Sort + WindowAgg)
--
-- Three-part fix:
--   1. SET LOCAL statement_timeout = '5min' — gives chunked work room.
--      (Only honored from server-side callers like pg_cron; MCP REST client
--       has its own ~60s ceiling, so interactive drains via MCP still
--       limited.)
--   2. Dropped pg_sleep(0.1) per iteration — wasted budget for no rate-limit
--      reason (no upstream API calls in this fn).
--   3. First-row sentinel: lag() returns NULL for the first observation in
--      each (event_id, tevo_ticket_group_id) partition. Old code skipped
--      these via WHERE ranked.pr_price IS NOT NULL, leaving them NULL
--      forever → events_remaining never drained → cron re-processed same
--      events every night. New behavior: write COALESCE(lag, current) so
--      first-row gets sentinel = current value (delta = 0). Function is
--      now actually idempotent.
--   4. Smallest-first ordering — drain tail events fast in early calls,
--      heavy outliers process individually in later calls (with pg_cron's
--      5min budget per firing).
--   5. EXISTS-based remaining check — count(DISTINCT) over 6.5M rows was
--      itself triggering the timeout AFTER the actual work succeeded.
--      Switch to binary "any work left?" sentinel (1 vs 0). Cron-side
--      `coalesce(v_remaining, 0) = 0` unschedule logic still works.
--   6. Cron command updated: p_max_events 100 → 30 for safety margin.
--
-- Acks: cron `listings_deltas_backfill_overnight` next fires 04:30-04:44 UTC
-- daily. With 30 events/call × 30 firings (5 days) = 900 events processed,
-- which covers the 970+587 remaining at session start. Top 12 heavy events
-- get processed individually toward the end (each gets ~5min of budget).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.listings_deltas_backfill_chunked(p_max_events integer DEFAULT 30)
 RETURNS TABLE(source_table text, events_processed integer, rows_updated integer, events_remaining integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; v_proc int; v_upd int; v_rows int; v_remaining int;
BEGIN
  SET LOCAL statement_timeout = '5min';

  -- listings_snapshots (TEvo) — process smallest-row events first
  v_proc := 0; v_upd := 0;
  FOR r IN
    SELECT event_id FROM (
      SELECT event_id, count(*) AS rcnt
      FROM public.listings_snapshots
      WHERE prev_retail_price IS NULL AND event_id IS NOT NULL
      GROUP BY event_id
      ORDER BY rcnt ASC
      LIMIT p_max_events
    ) ranked_events
  LOOP
    v_proc := v_proc + 1;
    WITH ranked AS (
      SELECT event_id, captured_at, tevo_ticket_group_id, retail_price, quantity,
             lag(retail_price) OVER w AS pr_price,
             lag(quantity)     OVER w AS pr_qty
      FROM public.listings_snapshots
      WHERE event_id = r.event_id
      WINDOW w AS (PARTITION BY tevo_ticket_group_id ORDER BY captured_at)
    )
    UPDATE public.listings_snapshots ls
       SET prev_retail_price = COALESCE(ranked.pr_price, ranked.retail_price),
           prev_quantity     = COALESCE(ranked.pr_qty,   ranked.quantity)
      FROM ranked
     WHERE ls.event_id = ranked.event_id
       AND ls.captured_at = ranked.captured_at
       AND ls.tevo_ticket_group_id = ranked.tevo_ticket_group_id
       AND ls.prev_retail_price IS NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_upd := v_upd + v_rows;
  END LOOP;
  v_remaining := CASE WHEN EXISTS (
    SELECT 1 FROM public.listings_snapshots
    WHERE prev_retail_price IS NULL AND event_id IS NOT NULL
  ) THEN 1 ELSE 0 END;
  RETURN QUERY SELECT 'listings_snapshots'::text, v_proc, v_upd, v_remaining;

  -- seatgeek_listings_snapshots — same smallest-first ordering
  v_proc := 0; v_upd := 0;
  FOR r IN
    SELECT sg_event_id AS event_id FROM (
      SELECT sg_event_id, count(*) AS rcnt
      FROM public.seatgeek_listings_snapshots
      WHERE prev_broadcast_price IS NULL AND sg_event_id IS NOT NULL
      GROUP BY sg_event_id
      ORDER BY rcnt ASC
      LIMIT p_max_events
    ) ranked_events
  LOOP
    v_proc := v_proc + 1;
    WITH ranked AS (
      SELECT id, broadcast_price, quantity,
             lag(broadcast_price) OVER w AS pr_price,
             lag(quantity)        OVER w AS pr_qty
      FROM public.seatgeek_listings_snapshots
      WHERE sg_event_id = r.event_id
      WINDOW w AS (PARTITION BY display_id ORDER BY captured_at)
    )
    UPDATE public.seatgeek_listings_snapshots sls
       SET prev_broadcast_price = COALESCE(ranked.pr_price, ranked.broadcast_price),
           prev_quantity        = COALESCE(ranked.pr_qty,   ranked.quantity)
      FROM ranked
     WHERE sls.id = ranked.id
       AND sls.prev_broadcast_price IS NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_upd := v_upd + v_rows;
  END LOOP;
  v_remaining := CASE WHEN EXISTS (
    SELECT 1 FROM public.seatgeek_listings_snapshots
    WHERE prev_broadcast_price IS NULL AND sg_event_id IS NOT NULL
  ) THEN 1 ELSE 0 END;
  RETURN QUERY SELECT 'seatgeek_listings_snapshots'::text, v_proc, v_upd, v_remaining;
END $function$;

-- Update cron command to call with p_max_events=30 (was 100)
DO $body$
DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'listings_deltas_backfill_overnight';
  IF v_jobid IS NOT NULL THEN
    PERFORM cron.unschedule(v_jobid);
  END IF;

  PERFORM cron.schedule(
    'listings_deltas_backfill_overnight',
    '30-44 4 * * *',
    $cron$DO $cronbody$
    DECLARE v_remaining int;
    BEGIN
      IF NOT public.cron_should_fire('listings_deltas_backfill_overnight') THEN RETURN; END IF;
      SELECT max(events_remaining) INTO v_remaining
      FROM public.listings_deltas_backfill_chunked(30);
      IF coalesce(v_remaining, 0) = 0 THEN
        PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'listings_deltas_backfill_overnight'));
      END IF;
    END $cronbody$;$cron$
  );
END $body$;
