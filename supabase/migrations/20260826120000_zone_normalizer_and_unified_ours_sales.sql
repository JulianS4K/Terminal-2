-- Migration 20260826120000 · lane:A1/D0 (data plane — cross-source sales + zoning) → applier (apply)
--   writes: normalize_zone(bigint,text,text) [fn], v_ours_sales_zoned [view]
--   reads:  v_event_home_away, performer_zones, performer_zone_rules, section_in_range,
--           derive_zone_fallback, classify_zone_canonical, evo_order_items, evo_orders,
--           tickpick_orders, vivid_orders, order_status_xref
--   auth: operator-directed 2026-08-26 (julian@s4kent.com — "we need a zone normalizer, and look for
--         a unified sales table of all sources that are ours and if not create"). Both objects are
--         READ-ONLY (STABLE fn + view) — no data mutation, no cron. Prod apply is gated separately.
--
-- WHY. Two gaps surfaced while zone-testing the tracked deal cohort:
--
--   1. NO SINGLE ZONE ENTRY POINT. The curated->fallback->canonical zone chain exists only as
--      scattered primitives (match_performer_zone, derive_zone_fallback, classify_zone_canonical)
--      plus the listings-only views (v_listing_zone_auto, v_section_to_curated_zone). Any NEW source
--      (SeatGeek sales comps, our Vivid/TickPick/EVO fills) had to re-implement section->zone by hand,
--      and the ad-hoc regexp range-matching disagreed with the listings zoner: match_performer_zone's
--      numeric-range branch requires PURE-numeric rule bounds, so a curated rule keyed '309L'..'314L'
--      (level-suffixed) silently misses section '314' and drops to a coarse fallback. The listings
--      pipeline avoids this by matching through section_in_range() (suffix-tolerant). normalize_zone
--      makes that same robust chain callable by (event_id, section, row) so EVERY source zones
--      identically to the listings side. (Verified: 3092241 §314 -> "300 Infield" curated, matching
--      v_listing_zone_auto, where the old match_performer_zone path fell through to "300s (upper)".)
--
--   2. NO UNIFIED *OURS* SALES TABLE AT SECTION GRAIN. What existed:
--        - unified_orders (view): all 6 legs but ORDER-HEADER grain, NO section, mixes ours + market
--          comps, no is_ours flag -> cannot be zoned.
--        - v_event_sales_combined (view): has section + is_ours but only 3 legs (EVO, SG-seller,
--          SG-BROKER market) — missing Vivid + TickPick, and folds in the non-ours SG market leg.
--        - d0_sales_fact (table): source/is_owned/section/price_per_ticket but only carries evo +
--          seatdata + seatgeek_sales (market), missing our SG-seller/TickPick/Vivid, and is stale.
--      None is a clean OURS-only, section-grain, per-ticket, zoned sales table. v_ours_sales_zoned is
--      that: our realized fills across EVO + TickPick + Vivid, one row per order line, per-ticket
--      price normalized per source, canonical order status attached, and the curated zone resolved
--      through normalize_zone. This is the seller-side truth set that pairs with the SeatGeek market
--      comps (seatgeek_sales_snapshots) — both now zone through the same normalizer.
--
-- PRICE GRAIN (per-ticket, verified against source fields):
--   evo      -> evo_order_items.price          (per-ticket list)
--   tickpick -> tickpick_orders.total          (= raw.wholesale_price, per-ticket payout)
--   vivid    -> vivid_orders.total             (= XML <cost>, per-ticket payout)
--   gross_value = price_per_ticket * quantity.
--
-- KNOWN GAPS (documented, not silently dropped):
--   * SeatGeek SELLER orders (seatgeek_orders) are EXCLUDED: all 400 rows have NULL tevo_event_id and
--     NULL sale_price (unmapped + unpriced) — nothing to zone or value. Add the leg once those are
--     backfilled (one UNION ALL branch).
--   * Exos/Bridge order tables are not ticket-resale/section-grain -> out of scope.
--   * TickPick's raw order_status vocabulary ("Scheduled"/"CONFIRMED") isn't in order_status_xref, so
--     canonical_status/is_sale_succeeded come back NULL for those rows (kept, flag left NULL — honest,
--     not miscoded as unsold). Fixing the tickpick status xref is a separate data-plane follow-up.
--
-- ROLLBACK: DROP VIEW public.v_ours_sales_zoned; DROP FUNCTION public.normalize_zone(bigint,text,text);

-- 1. Single zone entry point: curated (suffix-tolerant, listings-consistent) -> fallback -> canonical.
CREATE OR REPLACE FUNCTION public.normalize_zone(p_event_id bigint, p_section text, p_row text DEFAULT NULL)
 RETURNS TABLE(zone_name text, zone_source text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
  v_perf   bigint;
  v_venue  bigint;
  v_zone   text;
BEGIN
  IF p_section IS NULL OR btrim(p_section) = '' THEN
    RETURN QUERY SELECT 'Special'::text, 'none'::text;
    RETURN;
  END IF;

  SELECT ha.home_performer_id, ha.venue_id
    INTO v_perf, v_venue
  FROM public.v_event_home_away ha
  WHERE ha.tevo_event_id = p_event_id
  LIMIT 1;

  -- Tier 1: curated performer/venue zone, matched through the suffix-tolerant section_in_range
  -- primitive the listings zoner (v_listing_zone_auto) uses -> the two sides agree by construction.
  IF v_perf IS NOT NULL AND v_venue IS NOT NULL THEN
    SELECT pz.name
      INTO v_zone
    FROM public.performer_zones pz
    JOIN public.performer_zone_rules pzr ON pzr.zone_id = pz.id
    WHERE pz.performer_id = v_perf
      AND pz.venue_id = v_venue
      AND public.section_in_range(p_section, pzr.section_from, pzr.section_to)
      AND (pzr.row_from IS NULL OR pzr.row_to IS NULL
           OR public.section_in_range(p_row, pzr.row_from, pzr.row_to))
    ORDER BY pz.display_order ASC NULLS LAST, pz.id ASC
    LIMIT 1;
    IF v_zone IS NOT NULL THEN
      RETURN QUERY SELECT v_zone, 'curated'::text;
      RETURN;
    END IF;
  END IF;

  -- Tier 2: global fallback rules (zone_rules keyword/regex) + digit-tier bucket.
  v_zone := public.derive_zone_fallback(p_section, p_row);
  IF v_zone IS NOT NULL THEN
    RETURN QUERY SELECT v_zone, 'fallback'::text;
    RETURN;
  END IF;

  -- Tier 3: coarse canonical bucket (never NULL).
  RETURN QUERY SELECT public.classify_zone_canonical(p_section), 'canonical'::text;
END;
$fn$;

COMMENT ON FUNCTION public.normalize_zone(bigint,text,text) IS
  'Canonical section->zone entry point for ANY source. Resolves the event home performer+venue (v_event_home_away) then returns (zone_name, zone_source) via curated (section_in_range over performer_zone_rules, matching v_listing_zone_auto) -> derive_zone_fallback -> classify_zone_canonical. A1/D0 mig 20260826120000.';

REVOKE ALL ON FUNCTION public.normalize_zone(bigint,text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.normalize_zone(bigint,text,text) TO anon, authenticated, service_role;

-- 2. Unified OURS sales at section grain, per-ticket, zoned. EVO + TickPick + Vivid (see gaps above).
-- Zoning here mirrors normalize_zone's chain but resolves home performer+venue ONCE per row via a
-- join (the v_listing_zone_auto pattern) rather than a per-row function call, so a full-view scan of
-- the ~9k ours-rows stays fast (a per-row normalize_zone lateral re-evaluates v_event_home_away for
-- every row). Results are identical to normalize_zone by construction — same section_in_range curated
-- match -> derive_zone_fallback -> classify_zone_canonical. Single-row / ad-hoc callers use the
-- normalize_zone() function; bulk consumers read this view.
CREATE OR REPLACE VIEW public.v_ours_sales_zoned AS
WITH legs AS (
  SELECT 'evo'::text AS source,
         oi.evo_order_id::text AS source_order_id,
         oi.event_id AS tevo_event_id,
         oi.event_name,
         oi.occurs_at AS event_date,
         oi.ticket_group_section AS section,
         oi.ticket_group_row AS row_label,
         oi.quantity AS quantity,
         oi.price AS price_per_ticket,
         o.state AS source_status,
         o.evo_created_at AS sold_at
  FROM public.evo_order_items oi
  JOIN public.evo_orders o ON o.evo_order_id = oi.evo_order_id
  WHERE oi.event_id IS NOT NULL
  UNION ALL
  SELECT 'tickpick', o.tp_order_id, o.tevo_event_id, o.event_name,
         o.event_date::timestamp without time zone, o.section, o.row, o.quantity, o.total,
         o.status, COALESCE(o.ordered_at, o.pulled_at)
  FROM public.tickpick_orders o
  WHERE o.tevo_event_id IS NOT NULL
  UNION ALL
  SELECT 'vivid', o.vivid_order_id, o.tevo_event_id, o.event_name,
         o.event_date::timestamp without time zone, o.section, o.row, o.quantity, o.total,
         o.status, COALESCE(o.ordered_at, o.pulled_at)
  FROM public.vivid_orders o
  WHERE o.tevo_event_id IS NOT NULL
),
resolved AS (
  SELECT l.*, ha.home_performer_id AS perf_id, ha.venue_id AS venue_id
  FROM legs l
  LEFT JOIN public.v_event_home_away ha ON ha.tevo_event_id = l.tevo_event_id
)
SELECT r.source,
       r.source_order_id,
       true AS is_ours,
       r.tevo_event_id,
       r.event_name,
       r.event_date,
       r.section,
       r.row_label,
       r.quantity,
       round(r.price_per_ticket, 2) AS price_per_ticket,
       round(r.price_per_ticket * COALESCE(NULLIF(r.quantity, 0), 1)::numeric, 2) AS gross_value,
       r.source_status,
       x.canonical_status,
       x.is_terminal,
       x.is_sale_succeeded,
       r.sold_at,
       COALESCE(cz.zone_name,
                public.derive_zone_fallback(r.section, r.row_label),
                public.classify_zone_canonical(r.section)) AS zone_name,
       CASE WHEN cz.zone_name IS NOT NULL THEN 'curated'
            WHEN public.derive_zone_fallback(r.section, r.row_label) IS NOT NULL THEN 'fallback'
            ELSE 'canonical' END AS zone_source
FROM resolved r
LEFT JOIN public.order_status_xref x
  ON x.source = r.source AND x.source_status = r.source_status
LEFT JOIN LATERAL (
  SELECT pz.name AS zone_name
  FROM public.performer_zones pz
  JOIN public.performer_zone_rules pzr ON pzr.zone_id = pz.id
  WHERE pz.performer_id = r.perf_id
    AND pz.venue_id = r.venue_id
    AND public.section_in_range(r.section, pzr.section_from, pzr.section_to)
    AND (pzr.row_from IS NULL OR pzr.row_to IS NULL
         OR public.section_in_range(r.row_label, pzr.row_from, pzr.row_to))
  ORDER BY pz.display_order ASC NULLS LAST, pz.id ASC
  LIMIT 1
) cz ON true
WHERE COALESCE(x.canonical_status, '') NOT IN ('cancelled', 'rejected');

COMMENT ON VIEW public.v_ours_sales_zoned IS
  'Unified OUR realized fills (EVO + TickPick + Vivid), one row per order line at section grain, per-ticket price normalized per source, canonical order status attached, curated zone via normalize_zone. Cancelled/rejected excluded. Seller-side truth set paired with the SeatGeek market comps (seatgeek_sales_snapshots). SG-seller/Exos excluded (see mig header). A1/D0 mig 20260826120000.';

GRANT SELECT ON public.v_ours_sales_zoned TO anon, authenticated, service_role;
