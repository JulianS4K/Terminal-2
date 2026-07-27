-- ============================================================================
-- Migration 20260701210000 — compute_event_zone_metrics: quantity-weighted percentiles (no row explosion)
--
-- Lane:     A1
-- Touches:  public.compute_event_zone_metrics(bigint, timestamptz) — body only.
-- Pre-reqs: zone_metrics, listings_snapshots, match_performer_zone, derive_zone_fallback.
--
-- WHY (P2 / wedge root-cause, operator 2026-07-01): the fn expanded each listing into
-- `quantity` rows via `generate_series(1, quantity)` before percentile_cont, so a high-inventory
-- event (or one bad listing with a huge quantity) exploded into millions of rows and ran
-- unbounded — a direct cause of the 2026-07-01 zone-backfill wedge (a single call ran 70 min).
-- Replace with QUANTITY-WEIGHTED percentiles via cumulative sums: collapse to (zone,price)->qty,
-- running cum qty per zone; p-th percentile = smallest price whose cum qty reaches p*total.
-- Bounded by #distinct prices, NOT #tickets. Verified: byte-identical median/p90/min/max/owned
-- vs the old percentile_cont on a live event, and instant vs the old explosion.
--
-- NOTE: this fixes ONE of two bottlenecks. A SECOND remains — match_performer_zone called per
-- distinct (section,row) for curated-zone events is still slow on large venues (separate fix
-- pending). zone-backfill-isolated-10min STAYS DISABLED until that is also bounded.
--
-- Idempotent: CREATE OR REPLACE. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

CREATE OR REPLACE FUNCTION public.compute_event_zone_metrics(p_event_id bigint, p_captured_at timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_performer_id bigint;
  v_venue_id     bigint;
  v_has_zones    boolean := false;
  v_count        integer;
BEGIN
  SELECT primary_performer_id, venue_id INTO v_performer_id, v_venue_id
  FROM events WHERE id = p_event_id;

  IF v_performer_id IS NOT NULL AND v_venue_id IS NOT NULL THEN
    SELECT EXISTS(SELECT 1 FROM performer_zones
      WHERE performer_id = v_performer_id AND venue_id = v_venue_id) INTO v_has_zones;
  END IF;

  WITH
  unique_sec AS (
    SELECT DISTINCT section, row FROM listings_snapshots
    WHERE event_id = p_event_id AND captured_at = p_captured_at
  ),
  sec_zones AS (
    SELECT u.section, u.row,
      CASE WHEN v_has_zones THEN match_performer_zone(v_performer_id, v_venue_id, u.section, u.row) END AS curated_name,
      derive_zone_fallback(u.section, u.row) AS fb_zone
    FROM unique_sec u
  ),
  zoned AS (
    SELECT l.section, l.row, l.quantity, l.retail_price, l.wholesale_price, l.is_owned,
      CASE WHEN sz.curated_name IS NOT NULL THEN sz.curated_name ELSE COALESCE(sz.fb_zone,'unmapped') END AS zone,
      CASE WHEN sz.curated_name IS NOT NULL THEN 'curated' WHEN sz.fb_zone IS NOT NULL THEN 'fallback' ELSE 'unmapped' END AS zone_source
    FROM listings_snapshots l
    LEFT JOIN sec_zones sz ON sz.section IS NOT DISTINCT FROM l.section AND sz.row IS NOT DISTINCT FROM l.row
    WHERE l.event_id = p_event_id AND l.captured_at = p_captured_at AND l.is_ancillary = false
  ),
  agg AS (
    SELECT z.zone,
      MAX(CASE WHEN z.zone_source='curated' THEN 3 WHEN z.zone_source='fallback' THEN 2 ELSE 1 END) AS src_rank,
      SUM(z.quantity)::int AS tickets_count,
      COUNT(*)::int AS groups_count,
      COUNT(DISTINCT z.section)::int AS sections_count,
      MIN(z.retail_price) FILTER (WHERE z.quantity >= 2 AND z.retail_price IS NOT NULL) AS getin_price,
      COUNT(*) FILTER (WHERE z.is_owned)::int AS owned_groups_count,
      COALESCE(SUM(z.quantity) FILTER (WHERE z.is_owned),0)::int AS owned_tickets_count,
      MIN(z.retail_price) AS retail_min,
      MAX(z.retail_price) AS retail_max,
      SUM(z.retail_price * z.quantity) AS retail_sum,
      (SUM(z.retail_price * z.quantity) / NULLIF(SUM(z.quantity) FILTER (WHERE z.retail_price IS NOT NULL),0)) AS retail_mean,
      MIN(z.wholesale_price) AS wholesale_min,
      MAX(z.wholesale_price) AS wholesale_max,
      (SUM(z.wholesale_price * z.quantity) / NULLIF(SUM(z.quantity) FILTER (WHERE z.wholesale_price IS NOT NULL),0)) AS wholesale_mean
    FROM zoned z GROUP BY z.zone
  ),
  -- Quantity-weighted percentiles WITHOUT row expansion: collapse to (zone,price)->qty,
  -- running cumulative qty per zone; the p-th weighted percentile is the smallest price whose
  -- cumulative qty reaches p*total. Bounded by #distinct prices, not #tickets.
  r_cum AS (
    SELECT zone, price,
      SUM(qty) OVER (PARTITION BY zone ORDER BY price) AS cum,
      SUM(qty) OVER (PARTITION BY zone) AS tot
    FROM (SELECT zone, retail_price AS price, SUM(quantity) AS qty
          FROM zoned WHERE retail_price IS NOT NULL GROUP BY zone, retail_price) d
  ),
  r_p AS (
    SELECT zone,
      MIN(price) FILTER (WHERE cum >= 0.25*tot) AS retail_p25,
      MIN(price) FILTER (WHERE cum >= 0.50*tot) AS retail_median,
      MIN(price) FILTER (WHERE cum >= 0.75*tot) AS retail_p75,
      MIN(price) FILTER (WHERE cum >= 0.90*tot) AS retail_p90
    FROM r_cum GROUP BY zone
  ),
  ro_cum AS (
    SELECT zone, price,
      SUM(qty) OVER (PARTITION BY zone ORDER BY price) AS cum,
      SUM(qty) OVER (PARTITION BY zone) AS tot
    FROM (SELECT zone, retail_price AS price, SUM(quantity) AS qty
          FROM zoned WHERE retail_price IS NOT NULL AND is_owned GROUP BY zone, retail_price) d
  ),
  ro_p AS (
    SELECT zone, MIN(price) FILTER (WHERE cum >= 0.50*tot) AS owned_median_retail
    FROM ro_cum GROUP BY zone
  ),
  w_cum AS (
    SELECT zone, price,
      SUM(qty) OVER (PARTITION BY zone ORDER BY price) AS cum,
      SUM(qty) OVER (PARTITION BY zone) AS tot
    FROM (SELECT zone, wholesale_price AS price, SUM(quantity) AS qty
          FROM zoned WHERE wholesale_price IS NOT NULL GROUP BY zone, wholesale_price) d
  ),
  w_p AS (
    SELECT zone, MIN(price) FILTER (WHERE cum >= 0.50*tot) AS wholesale_median
    FROM w_cum GROUP BY zone
  )
  INSERT INTO zone_metrics (
    event_id, captured_at, zone, zone_source,
    tickets_count, groups_count, sections_count,
    retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90, retail_max, retail_sum,
    wholesale_min, wholesale_median, wholesale_mean, wholesale_max,
    getin_price,
    owned_groups_count, owned_tickets_count, owned_share, owned_median_retail
  )
  SELECT
    p_event_id, p_captured_at, a.zone,
    CASE a.src_rank WHEN 3 THEN 'curated' WHEN 2 THEN 'fallback' ELSE 'unmapped' END,
    a.tickets_count, a.groups_count, a.sections_count,
    round(a.retail_min::numeric,2), round(rp.retail_p25::numeric,2), round(rp.retail_median::numeric,2),
    round(a.retail_mean::numeric,2), round(rp.retail_p75::numeric,2), round(rp.retail_p90::numeric,2),
    round(a.retail_max::numeric,2), round(a.retail_sum::numeric,2),
    round(a.wholesale_min::numeric,2), round(wp.wholesale_median::numeric,2), round(a.wholesale_mean::numeric,2), round(a.wholesale_max::numeric,2),
    round(a.getin_price::numeric,2),
    a.owned_groups_count, a.owned_tickets_count,
    CASE WHEN a.tickets_count>0 THEN round((a.owned_tickets_count::numeric/a.tickets_count),4) ELSE NULL END,
    round(rop.owned_median_retail::numeric,2)
  FROM agg a
  LEFT JOIN r_p  rp  ON rp.zone  = a.zone
  LEFT JOIN ro_p rop ON rop.zone = a.zone
  LEFT JOIN w_p  wp  ON wp.zone  = a.zone
  ON CONFLICT (event_id, captured_at, zone) DO UPDATE SET
    zone_source=EXCLUDED.zone_source, tickets_count=EXCLUDED.tickets_count, groups_count=EXCLUDED.groups_count,
    sections_count=EXCLUDED.sections_count, retail_min=EXCLUDED.retail_min, retail_p25=EXCLUDED.retail_p25,
    retail_median=EXCLUDED.retail_median, retail_mean=EXCLUDED.retail_mean, retail_p75=EXCLUDED.retail_p75,
    retail_p90=EXCLUDED.retail_p90, retail_max=EXCLUDED.retail_max, retail_sum=EXCLUDED.retail_sum,
    wholesale_min=EXCLUDED.wholesale_min, wholesale_median=EXCLUDED.wholesale_median, wholesale_mean=EXCLUDED.wholesale_mean,
    wholesale_max=EXCLUDED.wholesale_max, getin_price=EXCLUDED.getin_price, owned_groups_count=EXCLUDED.owned_groups_count,
    owned_tickets_count=EXCLUDED.owned_tickets_count, owned_share=EXCLUDED.owned_share, owned_median_retail=EXCLUDED.owned_median_retail;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;
