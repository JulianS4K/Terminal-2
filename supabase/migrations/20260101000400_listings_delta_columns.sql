-- Migration 20260515270100 · level:admin · lane:Audit/Push · writes:listings_snapshots/seatgeek_listings_snapshots prev_* cols + chunked backfill fn + overnight cron · pre:20260515270000
-- Pattern A change-tracking deltas: store prev_price + prev_qty so analytics
-- can answer "what changed" without self-join over 8.16M rows.
-- delta is computed at query time as (current - prev). Avoids GENERATED STORED
-- which would force a table rewrite (ran out of disk on first attempt).
--
-- Overnight backfill: 04:30-04:44 UTC = 12:30-12:44am ET, after listings_aq_backfill window.
-- Chunked: 100 events per minute with pg_sleep(0.1) yields between events.
--
-- ## Already applied to prod  Applied via MCP 2026-05-14.

ALTER TABLE public.listings_snapshots
  ADD COLUMN IF NOT EXISTS prev_retail_price numeric,
  ADD COLUMN IF NOT EXISTS prev_quantity int;

ALTER TABLE public.seatgeek_listings_snapshots
  ADD COLUMN IF NOT EXISTS prev_broadcast_price numeric,
  ADD COLUMN IF NOT EXISTS prev_quantity int;

CREATE INDEX IF NOT EXISTS listings_snapshots_price_change_idx
  ON public.listings_snapshots (event_id, captured_at)
  WHERE prev_retail_price IS NOT NULL AND retail_price <> prev_retail_price;

CREATE INDEX IF NOT EXISTS sg_listings_price_change_idx
  ON public.seatgeek_listings_snapshots (sg_event_id, captured_at)
  WHERE prev_broadcast_price IS NOT NULL AND broadcast_price <> prev_broadcast_price;

CREATE OR REPLACE FUNCTION public.listings_deltas_backfill_chunked(p_max_events int DEFAULT 100)
RETURNS TABLE (source_table text, events_processed int, rows_updated int, events_remaining int)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions, pg_temp
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
      SELECT id, lag(retail_price) OVER w AS pr_price, lag(quantity) OVER w AS pr_qty
      FROM public.listings_snapshots
      WHERE event_id = r.event_id
      WINDOW w AS (PARTITION BY tevo_ticket_group_id ORDER BY captured_at)
    )
    UPDATE public.listings_snapshots ls SET prev_retail_price = ranked.pr_price, prev_quantity = ranked.pr_qty
    FROM ranked WHERE ls.id = ranked.id AND ranked.pr_price IS NOT NULL;
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
    UPDATE public.seatgeek_listings_snapshots sls SET prev_broadcast_price = ranked.pr_price, prev_quantity = ranked.pr_qty
    FROM ranked WHERE sls.id = ranked.id AND ranked.pr_price IS NOT NULL;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_upd := v_upd + v_rows;
    PERFORM pg_sleep(0.1);
  END LOOP;
  SELECT count(DISTINCT sg_event_id) INTO v_remaining FROM public.seatgeek_listings_snapshots
    WHERE prev_broadcast_price IS NULL AND sg_event_id IS NOT NULL;
  RETURN QUERY SELECT 'seatgeek_listings_snapshots'::text, v_proc, v_upd, v_remaining;
END $func$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='listings_deltas_backfill_overnight') THEN
    PERFORM cron.schedule(
      'listings_deltas_backfill_overnight',
      '30-44 4 * * *',
      $cron$
        DO $body$
        DECLARE v_remaining int;
        BEGIN
          SELECT max(events_remaining) INTO v_remaining
          FROM public.listings_deltas_backfill_chunked(100);
          IF coalesce(v_remaining, 0) = 0 THEN
            PERFORM cron.unschedule('listings_deltas_backfill_overnight');
          END IF;
        END $body$;
      $cron$
    );
  END IF;
END $$;
