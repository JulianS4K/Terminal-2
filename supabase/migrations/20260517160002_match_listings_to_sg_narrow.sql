-- ============================================================================
-- A1 cron-cascade fix (2026-05-17) — match_listings_to_sg narrow + index.
--
-- Implements D2's three-part fix from bot_chat 225 (D2 flag 2026-05-16 15:56 UTC,
-- A1 ack 16:08 UTC bot_chat 231 — "queued for next-session"; never shipped).
--   (a) tevo_latest window 24h → 6h (matching is point-in-time; 6h is enough
--       to find a coexisting SG listing for the same physical seat).
--   (b) Partial index on listings_snapshots covering the DISTINCT ON window.
--   (c) Replace triple `NOT EXISTS` anti-joins for uniqueness with a single
--       window-function pass (cheaper + more readable).
--
-- Pre-fix: 22 fails/24h. Each fire cross-joined 3 GB × 3 GB tables with
-- 24h windows and 3 correlated NOT EXISTS subqueries → 5-min statement_timeout.
-- ============================================================================

-- (a) Helper indexes
CREATE INDEX CONCURRENTLY IF NOT EXISTS listings_snapshots_event_tgid_captured_idx
  ON public.listings_snapshots (event_id, tevo_ticket_group_id, captured_at DESC);

CREATE INDEX CONCURRENTLY IF NOT EXISTS sg_listings_tevo_sglid_captured_idx
  ON public.seatgeek_listings_snapshots (tevo_event_id, sglid, captured_at DESC)
  WHERE tevo_event_id IS NOT NULL;

-- (b) Rewrite the matcher with narrow window + ROW_NUMBER uniqueness
CREATE OR REPLACE FUNCTION public.match_listings_to_sg_tick()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_matched int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'match_listings_to_sg_tick: caller % not authorized', current_user;
  END IF;

  WITH event_pairs AS (
    SELECT DISTINCT tevo_event_id FROM public.seatgeek_event_xref
    WHERE tevo_event_id IS NOT NULL
  ),
  tevo_latest AS (
    SELECT DISTINCT ON (event_id, tevo_ticket_group_id)
      event_id, tevo_ticket_group_id, section, row, quantity, retail_price, captured_at
    FROM public.listings_snapshots
    WHERE event_id IN (SELECT tevo_event_id FROM event_pairs)
      AND captured_at > now() - interval '6 hours'
    ORDER BY event_id, tevo_ticket_group_id, captured_at DESC
  ),
  sg_latest AS (
    SELECT DISTINCT ON (tevo_event_id, sglid)
      tevo_event_id, sglid::text AS sg_listing_id, section, row, quantity, broadcast_price, captured_at
    FROM public.seatgeek_listings_snapshots
    WHERE tevo_event_id IN (SELECT tevo_event_id FROM event_pairs)
      AND captured_at > now() - interval '6 hours'
    ORDER BY tevo_event_id, sglid, captured_at DESC
  ),
  candidates AS (
    SELECT
      t.tevo_ticket_group_id,
      s.sg_listing_id,
      t.captured_at AS captured_at_tevo,
      s.captured_at AS captured_at_sg,
      t.retail_price,
      s.broadcast_price,
      (abs(s.broadcast_price - t.retail_price) / NULLIF(t.retail_price, 0))::numeric AS price_spread,
      count(*) OVER (PARTITION BY t.tevo_ticket_group_id) AS tgid_card,
      count(*) OVER (PARTITION BY s.sg_listing_id)        AS sgid_card
    FROM tevo_latest t
    JOIN sg_latest s ON s.tevo_event_id = t.event_id
    WHERE lower(trim(t.section)) = lower(trim(s.section))
      AND lower(trim(t.row)) IS NOT DISTINCT FROM lower(trim(s.row))
      AND t.quantity = s.quantity
      AND s.broadcast_price IS NOT NULL
      AND t.retail_price > 0
      AND abs(s.broadcast_price - t.retail_price) / t.retail_price < 0.15
  )
  INSERT INTO public.listing_xref (
    tevo_ticket_group_id, sg_listing_id,
    captured_at_tevo, captured_at_sg,
    confidence, match_method, price_spread_pct, meta
  )
  SELECT
    c.tevo_ticket_group_id, c.sg_listing_id,
    c.captured_at_tevo, c.captured_at_sg,
    0.80, 'broker_section_row_qty', c.price_spread,
    jsonb_build_object(
      'tevo_price', c.retail_price,
      'sg_price', c.broadcast_price,
      'matched_at', now()::text,
      'price_band', '15%',
      'window', '6h'
    )
  FROM candidates c
  WHERE c.tgid_card = 1 AND c.sgid_card = 1
    AND NOT EXISTS (
      SELECT 1 FROM public.listing_xref lx
      WHERE lx.tevo_ticket_group_id = c.tevo_ticket_group_id
        AND lx.sg_listing_id = c.sg_listing_id
        AND lx.captured_at_tevo = c.captured_at_tevo
        AND lx.captured_at_sg = c.captured_at_sg
    );

  GET DIAGNOSTICS v_matched = ROW_COUNT;
  RETURN v_matched;
END $function$;
