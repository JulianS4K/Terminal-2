-- Migration 20260603210000 · level:2 · lane:A1
-- writes: REPLACE fn sweep_duplicate_listings — bound the per-event dedup to a recent
--         captured_at window (the prior fix `…200000` still timed out)
-- reads:  evo_listings_poll_state, listings_snapshots
--
-- ============================================================
-- Follow-up to `…200000`: the recent-event targeting + cross-event time-box was NOT
-- enough. Picking the most-recently-polled events (ORDER BY last_polled DESC) selects
-- the HOTTEST events — exactly the ones with the most accumulated snapshot rows — and
-- a single hot event's window-dedup (PARTITION BY tevo_ticket_group_id ORDER BY
-- captured_at over its FULL 15-day history = millions of rows) exceeds the timeout on
-- its own. A cross-event time-box can't interrupt one heavy statement.
--
-- FIX: bound the per-event dedup to a SHORT recent captured_at window (2h). Duplicates
-- form at write time (a re-poll re-inserts an unchanged listing), so only the recent
-- window has new dups to clear; older dups age out via the 15d retention (mig …190000).
-- Hourly cron × 2h window = 2× overlap → no gap. Each event's work is now bounded to
-- ~2h of its rows regardless of total history → fast + can't blow the cron 120s cap.
-- (Proper write-time fix = change-detection, KANBAN A1-OPS-17, in progress.)
--
-- Already applied to prod. Applied via MCP apply_migration 2026-06-03 (A1, operator-directed).
-- ============================================================

CREATE OR REPLACE FUNCTION public.sweep_duplicate_listings(p_max_events integer DEFAULT 100)
 RETURNS TABLE(events_swept integer, rows_deleted integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_event_id bigint; v_total_deleted int := 0; v_events_count int := 0; v_batch_deleted int;
  v_start timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sweep_duplicate_listings: caller % not authorized', current_user;
  END IF;
  FOR v_event_id IN
    SELECT event_id FROM public.evo_listings_poll_state
    WHERE last_polled_listings_at > now() - interval '6 hours'
    ORDER BY last_polled_listings_at DESC
    LIMIT p_max_events
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '60 seconds';
    WITH dups AS (
      SELECT s.ctid,
        lag(quantity) OVER w IS NOT DISTINCT FROM quantity AS q_same,
        lag(retail_price) OVER w IS NOT DISTINCT FROM retail_price AS rp_same,
        lag(wholesale_price) OVER w IS NOT DISTINCT FROM wholesale_price AS wp_same,
        lag(format) OVER w IS NOT DISTINCT FROM format AS fmt_same,
        lag(splits) OVER w IS NOT DISTINCT FROM splits AS spl_same,
        lag(type) OVER w IS NOT DISTINCT FROM type AS typ_same,
        lag(wheelchair) OVER w IS NOT DISTINCT FROM wheelchair AS wc_same,
        lag(instant_delivery) OVER w IS NOT DISTINCT FROM instant_delivery AS idn_same,
        lag(eticket) OVER w IS NOT DISTINCT FROM eticket AS et_same,
        lag(is_ancillary) OVER w IS NOT DISTINCT FROM is_ancillary AS ia_same,
        lag(is_owned) OVER w IS NOT DISTINCT FROM is_owned AS io_same,
        lag(office_id) OVER w IS NOT DISTINCT FROM office_id AS off_same,
        lag(brokerage_id) OVER w IS NOT DISTINCT FROM brokerage_id AS brk_same,
        lag(section) OVER w IS NOT DISTINCT FROM section AS sec_same,
        lag(row) OVER w IS NOT DISTINCT FROM row AS rw_same
      FROM listings_snapshots s
      WHERE event_id = v_event_id
        AND s.captured_at > now() - interval '2 hours'   -- bound per-event work to the recent window
      WINDOW w AS (PARTITION BY tevo_ticket_group_id ORDER BY captured_at)
    )
    DELETE FROM listings_snapshots WHERE ctid IN (
      SELECT ctid FROM dups
      WHERE q_same AND rp_same AND wp_same AND fmt_same AND spl_same AND typ_same AND wc_same AND idn_same AND et_same AND ia_same AND io_same AND off_same AND brk_same AND sec_same AND rw_same
    );
    GET DIAGNOSTICS v_batch_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_batch_deleted;
    v_events_count := v_events_count + 1;
  END LOOP;
  RETURN QUERY SELECT v_events_count, v_total_deleted;
END $function$;
