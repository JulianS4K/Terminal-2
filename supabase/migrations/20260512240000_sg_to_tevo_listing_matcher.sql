-- Migration 20260512240000 · level:admin · lane:Audit/Push · writes:match_listings_to_sg_tick,cron(match_listings_to_sg_30min) · reads:listings_snapshots,seatgeek_listings_snapshots,seatgeek_event_xref,listing_xref · pre:20260510120000
-- SG↔Evo listing-level matcher. Mirrors event matcher pattern (seatgeek_event_xref).
--
-- Strategy:
--   * Restricted to events already matched at event level (seatgeek_event_xref)
--   * Tier 2 match: same section + same row + same quantity + retail_price within 15% of broadcast_price
--   * Reject ambiguous candidates (>1 match on either side)
--   * Skip pairs already matched at same captured_at timestamps
--   * 24h freshness window on both sides — only matches current-ish state
--
-- Uses match_method='broker_section_row_qty' from C1's listing_xref schema
-- (PR #61). Initial seed: 5 listings matched (avg 5.8% price spread, well
-- within band — real matches, not noise).
--
-- Ceiling: event-level matches (currently 11/228 SG canonical events). As
-- canonical bot grows seatgeek_event_xref coverage, this matcher
-- auto-populates listing_xref downstream.

CREATE OR REPLACE FUNCTION public.match_listings_to_sg_tick()
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_matched int;
BEGIN
  WITH event_pairs AS (
    SELECT DISTINCT tevo_event_id FROM seatgeek_event_xref WHERE tevo_event_id IS NOT NULL
  ),
  tevo_latest AS (
    SELECT DISTINCT ON (event_id, tevo_ticket_group_id)
      event_id, tevo_ticket_group_id, section, row, quantity, retail_price, captured_at
    FROM listings_snapshots
    WHERE event_id IN (SELECT tevo_event_id FROM event_pairs)
      AND captured_at > now() - interval '24 hours'
    ORDER BY event_id, tevo_ticket_group_id, captured_at DESC
  ),
  sg_latest AS (
    SELECT DISTINCT ON (tevo_event_id, sglid)
      tevo_event_id, sglid::text AS sg_listing_id, section, row, quantity, broadcast_price, captured_at
    FROM seatgeek_listings_snapshots
    WHERE tevo_event_id IN (SELECT tevo_event_id FROM event_pairs)
      AND captured_at > now() - interval '24 hours'
    ORDER BY tevo_event_id, sglid, captured_at DESC
  ),
  candidates AS (
    SELECT
      t.tevo_ticket_group_id, s.sg_listing_id,
      t.captured_at AS captured_at_tevo, s.captured_at AS captured_at_sg,
      t.retail_price, s.broadcast_price,
      (abs(s.broadcast_price - t.retail_price) / NULLIF(t.retail_price, 0))::numeric AS price_spread
    FROM tevo_latest t
    JOIN sg_latest s ON s.tevo_event_id = t.event_id
    WHERE lower(trim(t.section)) = lower(trim(s.section))
      AND lower(trim(t.row)) IS NOT DISTINCT FROM lower(trim(s.row))
      AND t.quantity = s.quantity
      AND s.broadcast_price IS NOT NULL AND t.retail_price > 0
      AND abs(s.broadcast_price - t.retail_price) / t.retail_price < 0.15
  ),
  unique_pairs AS (
    SELECT * FROM candidates c
    WHERE NOT EXISTS (SELECT 1 FROM candidates c2
                        WHERE c2.tevo_ticket_group_id = c.tevo_ticket_group_id
                          AND c2.sg_listing_id <> c.sg_listing_id)
      AND NOT EXISTS (SELECT 1 FROM candidates c2
                        WHERE c2.sg_listing_id = c.sg_listing_id
                          AND c2.tevo_ticket_group_id <> c.tevo_ticket_group_id)
      AND NOT EXISTS (SELECT 1 FROM listing_xref lx
                        WHERE lx.tevo_ticket_group_id = c.tevo_ticket_group_id
                          AND lx.sg_listing_id = c.sg_listing_id
                          AND lx.captured_at_tevo = c.captured_at_tevo
                          AND lx.captured_at_sg = c.captured_at_sg)
  )
  INSERT INTO listing_xref
    (tevo_ticket_group_id, sg_listing_id, captured_at_tevo, captured_at_sg,
     confidence, match_method, price_spread_pct, meta)
  SELECT
    tevo_ticket_group_id, sg_listing_id, captured_at_tevo, captured_at_sg,
    0.80, 'broker_section_row_qty', price_spread,
    jsonb_build_object('tevo_price', retail_price, 'sg_price', broadcast_price,
                       'matched_at', now()::text, 'price_band', '15%')
  FROM unique_pairs;

  GET DIAGNOSTICS v_matched = ROW_COUNT;
  RETURN v_matched;
END $$;

COMMENT ON FUNCTION public.match_listings_to_sg_tick() IS
  'SG↔TEvo listing matcher (broker_section_row_qty method). Mirrors event matcher pattern.';

SELECT cron.schedule(
  'match_listings_to_sg_30min',
  '7,37 * * * *',
  $$ SELECT public.match_listings_to_sg_tick(); $$
);
