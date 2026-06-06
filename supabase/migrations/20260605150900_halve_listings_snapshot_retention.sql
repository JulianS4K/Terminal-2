-- Migration 20260603190000 · level:2 · lane:A1
-- writes: REPLACE fn sweep_old_listings (default p_days 30 -> 15),
--         RESCHEDULE cron sweep-old-listings to pass 15 explicitly
-- reads:  (none new)
--
-- ============================================================
-- Halve the RAW listings-snapshot retention; keep generated metrics normal.
-- Operator directive 2026-06-03: "cut the listings data retention by half,
-- per pull data, but the metrics we generate should retain normal retention
-- rates for now."
--
-- listings_snapshots (the EVO per-pull firehose) is 18 GB / ~50.5M rows at a
-- flat 30-day cutoff. This cuts the raw per-pull retention to 15 days. The
-- aggregated metrics we generate are UNCHANGED:
--   - event_metrics stays at 120 days (this function's own metrics delete).
--   - event_listing_snapshot_daily / latest_event_metrics / *_zone/_section
--     rollups are not touched by this sweep at all.
-- So the analytical history (medians, price series, charts) is fully preserved;
-- only the bulky raw per-listing snapshots age out twice as fast.
--
-- Applies to ALL events (owned + non-owned) — metric preservation is the safety
-- net, so owned raw history >15d is recoverable in aggregate via event_metrics.
--
-- Function body is otherwise IDENTICAL to the prior version (80s-bounded,
-- 50k-row batched delete via the captured_at index; metrics delete unchanged).
-- Signature is unchanged (only the DEFAULT moves 30->15), so CREATE OR REPLACE
-- is sufficient — no overload/DROP needed.
--
-- DRAIN NOTE: the daily 80s-bounded sweep will work down the ~15-30d backlog
-- (~half the table) over ~1-3 weeks and then hold steady; disk is reclaimed by
-- autovacuum as pages free up. A faster one-time drain can be scheduled
-- separately if desired (not done here — avoids a large unbounded delete).
--
-- Already applied to prod. Applied via MCP apply_migration 2026-06-03 (A1, operator-directed).
-- ============================================================

CREATE OR REPLACE FUNCTION public.sweep_old_listings(p_days integer DEFAULT 15)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_start timestamptz := clock_timestamp(); v_ls_count int := 0; v_em_count int; v_batch int;
  v_cutoff timestamptz := now() - make_interval(days => p_days);
BEGIN
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '80 seconds';
    WITH to_delete AS (
      SELECT id FROM public.listings_snapshots WHERE captured_at < v_cutoff ORDER BY captured_at LIMIT 50000
    )
    DELETE FROM public.listings_snapshots WHERE id IN (SELECT id FROM to_delete);
    GET DIAGNOSTICS v_batch = ROW_COUNT;
    v_ls_count := v_ls_count + v_batch;
    EXIT WHEN v_batch = 0;
  END LOOP;
  -- metrics we generate keep their NORMAL retention (unchanged): 120 days
  DELETE FROM public.event_metrics WHERE captured_at < now() - interval '120 days';
  GET DIAGNOSTICS v_em_count = ROW_COUNT;
  RETURN v_ls_count + v_em_count;
END $function$;

-- Make the cron self-documenting: pass 15 explicitly (same 03:00 daily schedule)
SELECT cron.schedule('sweep-old-listings', '0 3 * * *', 'select public.sweep_old_listings(15);');
