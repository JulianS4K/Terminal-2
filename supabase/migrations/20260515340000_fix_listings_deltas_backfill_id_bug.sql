-- Migration 20260515340000 · admin · Audit/Push · fix listings_deltas_backfill_chunked id-column bug · pre:20260515330000
--
-- 20260515270100 shipped listings_deltas_backfill_chunked referencing an `id` column on
-- listings_snapshots, but that table's PK is composite (event_id, captured_at, tevo_ticket_group_id).
-- The function failed every run with `ERROR: column "id" does not exist` (15/15 last night).
-- seatgeek_listings_snapshots DOES have an `id` PK so its branch was unaffected — fix listings only.

CREATE OR REPLACE FUNCTION public.listings_deltas_backfill_chunked(p_max_events int DEFAULT 50)
RETURNS TABLE(source_table text, events_processed int, rows_updated int, events_remaining int)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE r RECORD; v_proc int; v_upd int; v_rows int; v_remaining int;
BEGIN
  v_proc := 0; v_upd := 0;
  FOR r IN
    SELECT DISTINCT event_id FROM public.listings_snapshots
    WHERE prev_retail_price IS NULL AND event_id IS NOT NULL LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    WITH ranked AS (
      SELECT event_id, captured_at, tevo_ticket_group_id,
             lag(retail_price) OVER w AS pr_price,
             lag(quantity)     OVER w AS pr_qty
      FROM public.listings_snapshots
      WHERE event_id = r.event_id
      WINDOW w AS (PARTITION BY tevo_ticket_group_id ORDER BY captured_at)
    )
    UPDATE public.listings_snapshots ls
       SET prev_retail_price = ranked.pr_price,
           prev_quantity     = ranked.pr_qty
      FROM ranked
     WHERE ls.event_id              = ranked.event_id
       AND ls.captured_at           = ranked.captured_at
       AND ls.tevo_ticket_group_id  = ranked.tevo_ticket_group_id
       AND ranked.pr_price IS NOT NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_upd := v_upd + v_rows;
    PERFORM pg_sleep(0.1);
  END LOOP;
  SELECT count(DISTINCT event_id) INTO v_remaining FROM public.listings_snapshots
    WHERE prev_retail_price IS NULL AND event_id IS NOT NULL;
  RETURN QUERY SELECT 'listings_snapshots'::text, v_proc, v_upd, v_remaining;

  v_proc := 0; v_upd := 0;
  FOR r IN
    SELECT DISTINCT sg_event_id FROM public.seatgeek_listings_snapshots
    WHERE prev_broadcast_price IS NULL AND sg_event_id IS NOT NULL LIMIT p_max_events
  LOOP
    v_proc := v_proc + 1;
    WITH ranked AS (
      SELECT id, lag(broadcast_price) OVER w AS pr_price, lag(quantity) OVER w AS pr_qty
      FROM public.seatgeek_listings_snapshots
      WHERE sg_event_id = r.sg_event_id
      WINDOW w AS (PARTITION BY display_id ORDER BY captured_at)
    )
    UPDATE public.seatgeek_listings_snapshots sls
       SET prev_broadcast_price = ranked.pr_price,
           prev_quantity        = ranked.pr_qty
      FROM ranked
     WHERE sls.id = ranked.id
       AND ranked.pr_price IS NOT NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_upd := v_upd + v_rows;
    PERFORM pg_sleep(0.1);
  END LOOP;
  SELECT count(DISTINCT sg_event_id) INTO v_remaining FROM public.seatgeek_listings_snapshots
    WHERE prev_broadcast_price IS NULL AND sg_event_id IS NOT NULL;
  RETURN QUERY SELECT 'seatgeek_listings_snapshots'::text, v_proc, v_upd, v_remaining;
END $func$;
