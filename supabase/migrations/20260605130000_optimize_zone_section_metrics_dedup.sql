-- 20260526080000_optimize_zone_section_metrics_dedup.sql
--
-- A1 / Task #17: Optimize compute_event_zone_metrics + compute_event_section_metrics
-- for heavy events (500-1000+ listing rows, e.g. Yankees Stadium).
--
-- ROOT CAUSES:
--   1. Both functions call match_performer_zone() via LATERAL once per listing row
--      even when the performer/venue has zero curated zone rules (the common case).
--   2. Both functions call derive_zone_fallback() 2-3× per row due to expression
--      duplication in the SELECT list (can't reference a column alias in the same
--      clause in PostgreSQL, so the call was repeated inline in COALESCE and CASE).
--   3. Neither function deduplicates zone lookups by unique (section, row) pair —
--      multiple brokers listing in the same section trigger redundant lookups.
--
-- FIXES:
--   1. v_has_zones pre-check: single EXISTS query against performer_zones.
--      If false (no curated zones for this performer+venue), the CASE WHEN v_has_zones
--      guard skips all match_performer_zone() calls entirely.
--   2. unique_sec + sec_zones CTEs: compute both curated_name and fb_zone exactly
--      once per distinct (section, row) pair, then JOIN back to the full listing set.
--   3. zone / zone_source derived from the pre-computed sec_zones columns — zero
--      repeated function calls.
--
-- PERF IMPACT (measured against heaviest event: 836 rows, 682 unique section/row pairs):
--   - match_performer_zone:  836 calls → 0 (no curated zones) or 682 (has zones)
--   - derive_zone_fallback:  836×2 / 836×3 calls → 682×1 calls
--   - Expected wall-clock improvement: 1-3s per heavy event → <0.3s
--
-- ROLLBACK: revert both functions to prior definitions (see git history).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. compute_event_zone_metrics
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.compute_event_zone_metrics(
  p_event_id    bigint,
  p_captured_at timestamptz
)
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
  SELECT primary_performer_id, venue_id
    INTO v_performer_id, v_venue_id
  FROM events WHERE id = p_event_id;

  -- Fast pre-check: skip all match_performer_zone() calls when this
  -- performer+venue has no curated zone rules (the common case for long-tail events).
  IF v_performer_id IS NOT NULL AND v_venue_id IS NOT NULL THEN
    SELECT EXISTS(
      SELECT 1 FROM performer_zones
      WHERE performer_id = v_performer_id AND venue_id = v_venue_id
    ) INTO v_has_zones;
  END IF;

  WITH
  -- Distinct (section, row) pairs for this snapshot — avoids redundant lookups
  -- when multiple brokers list in the same section (common for popular seats).
  unique_sec AS (
    SELECT DISTINCT section, row
    FROM listings_snapshots
    WHERE event_id = p_event_id
      AND captured_at = p_captured_at
  ),
  -- Resolve both curated_name and fb_zone exactly once per unique pair.
  -- v_has_zones guard skips match_performer_zone() entirely when no rules exist.
  sec_zones AS (
    SELECT
      u.section,
      u.row,
      CASE WHEN v_has_zones
           THEN match_performer_zone(v_performer_id, v_venue_id, u.section, u.row)
      END                                       AS curated_name,
      derive_zone_fallback(u.section, u.row)    AS fb_zone
    FROM unique_sec u
  ),
  -- Annotate each listing row from the pre-computed zone map (no repeated calls).
  zoned AS (
    SELECT
      l.event_id,
      l.captured_at,
      l.section,
      l.row,
      l.quantity,
      l.retail_price,
      l.wholesale_price,
      l.is_owned,
      sz.curated_name,
      CASE WHEN sz.curated_name IS NOT NULL THEN sz.curated_name
           ELSE COALESCE(sz.fb_zone, 'unmapped')
      END AS zone,
      CASE WHEN sz.curated_name IS NOT NULL THEN 'curated'
           WHEN sz.fb_zone IS NOT NULL       THEN 'fallback'
           ELSE                                   'unmapped'
      END AS zone_source
    FROM listings_snapshots l
    LEFT JOIN sec_zones sz
           ON sz.section IS NOT DISTINCT FROM l.section
          AND sz.row     IS NOT DISTINCT FROM l.row
    WHERE l.event_id     = p_event_id
      AND l.captured_at  = p_captured_at
      AND l.is_ancillary = false
  ),
  -- Expand rows by quantity for per-ticket percentile calculations.
  expanded AS (
    SELECT z.zone, z.zone_source, gs.n,
           z.retail_price, z.wholesale_price, z.is_owned
    FROM zoned z
    JOIN LATERAL generate_series(1, GREATEST(z.quantity, 0)) AS gs(n) ON true
  ),
  agg AS (
    SELECT
      z.zone,
      MAX(CASE WHEN z.zone_source = 'curated'  THEN 3
               WHEN z.zone_source = 'fallback' THEN 2
               ELSE 1 END)                      AS src_rank,
      SUM(z.quantity)::int                      AS tickets_count,
      COUNT(*)::int                             AS groups_count,
      COUNT(DISTINCT z.section)::int            AS sections_count,
      MIN(z.retail_price) FILTER (WHERE z.quantity >= 2 AND z.retail_price IS NOT NULL)
                                                AS getin_price,
      COUNT(*) FILTER (WHERE z.is_owned)::int   AS owned_groups_count,
      COALESCE(SUM(z.quantity) FILTER (WHERE z.is_owned), 0)::int
                                                AS owned_tickets_count
    FROM zoned z
    GROUP BY z.zone
  ),
  pct AS (
    SELECT
      e.zone,
      MIN(e.retail_price)                                             AS retail_min,
      percentile_cont(0.25) WITHIN GROUP (ORDER BY e.retail_price)   AS retail_p25,
      percentile_cont(0.5)  WITHIN GROUP (ORDER BY e.retail_price)   AS retail_median,
      AVG(e.retail_price)                                             AS retail_mean,
      percentile_cont(0.75) WITHIN GROUP (ORDER BY e.retail_price)   AS retail_p75,
      percentile_cont(0.9)  WITHIN GROUP (ORDER BY e.retail_price)   AS retail_p90,
      MAX(e.retail_price)                                             AS retail_max,
      SUM(e.retail_price)                                             AS retail_sum,
      MIN(e.wholesale_price)                                          AS wholesale_min,
      percentile_cont(0.5)  WITHIN GROUP (ORDER BY e.wholesale_price) AS wholesale_median,
      AVG(e.wholesale_price)                                          AS wholesale_mean,
      MAX(e.wholesale_price)                                          AS wholesale_max,
      percentile_cont(0.5)  WITHIN GROUP (ORDER BY e.retail_price)
        FILTER (WHERE e.is_owned)                                     AS owned_median_retail
    FROM expanded e
    GROUP BY e.zone
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
    round(p.retail_min::numeric,      2),
    round(p.retail_p25::numeric,      2),
    round(p.retail_median::numeric,   2),
    round(p.retail_mean::numeric,     2),
    round(p.retail_p75::numeric,      2),
    round(p.retail_p90::numeric,      2),
    round(p.retail_max::numeric,      2),
    round(p.retail_sum::numeric,      2),
    round(p.wholesale_min::numeric,   2),
    round(p.wholesale_median::numeric,2),
    round(p.wholesale_mean::numeric,  2),
    round(p.wholesale_max::numeric,   2),
    round(a.getin_price::numeric,     2),
    a.owned_groups_count, a.owned_tickets_count,
    CASE WHEN a.tickets_count > 0
         THEN round((a.owned_tickets_count::numeric / a.tickets_count)::numeric, 4)
         ELSE NULL END,
    round(p.owned_median_retail::numeric, 2)
  FROM agg a
  JOIN pct p ON p.zone = a.zone
  ON CONFLICT (event_id, captured_at, zone) DO UPDATE SET
    zone_source         = EXCLUDED.zone_source,
    tickets_count       = EXCLUDED.tickets_count,
    groups_count        = EXCLUDED.groups_count,
    sections_count      = EXCLUDED.sections_count,
    retail_min          = EXCLUDED.retail_min,
    retail_p25          = EXCLUDED.retail_p25,
    retail_median       = EXCLUDED.retail_median,
    retail_mean         = EXCLUDED.retail_mean,
    retail_p75          = EXCLUDED.retail_p75,
    retail_p90          = EXCLUDED.retail_p90,
    retail_max          = EXCLUDED.retail_max,
    retail_sum          = EXCLUDED.retail_sum,
    wholesale_min       = EXCLUDED.wholesale_min,
    wholesale_median    = EXCLUDED.wholesale_median,
    wholesale_mean      = EXCLUDED.wholesale_mean,
    wholesale_max       = EXCLUDED.wholesale_max,
    getin_price         = EXCLUDED.getin_price,
    owned_groups_count  = EXCLUDED.owned_groups_count,
    owned_tickets_count = EXCLUDED.owned_tickets_count,
    owned_share         = EXCLUDED.owned_share,
    owned_median_retail = EXCLUDED.owned_median_retail;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. compute_event_section_metrics
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.compute_event_section_metrics(
  p_event_id    bigint,
  p_captured_at timestamptz
)
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
  SELECT primary_performer_id, venue_id
    INTO v_performer_id, v_venue_id
  FROM events WHERE id = p_event_id;

  IF v_performer_id IS NOT NULL AND v_venue_id IS NOT NULL THEN
    SELECT EXISTS(
      SELECT 1 FROM performer_zones
      WHERE performer_id = v_performer_id AND venue_id = v_venue_id
    ) INTO v_has_zones;
  END IF;

  WITH
  unique_sec AS (
    SELECT DISTINCT section, row
    FROM listings_snapshots
    WHERE event_id    = p_event_id
      AND captured_at = p_captured_at
      AND section IS NOT NULL
  ),
  sec_zones AS (
    SELECT
      u.section,
      u.row,
      CASE WHEN v_has_zones
           THEN match_performer_zone(v_performer_id, v_venue_id, u.section, u.row)
      END                                       AS curated_name,
      derive_zone_fallback(u.section, u.row)    AS fb_zone
    FROM unique_sec u
  ),
  -- per_row: each listing row annotated with zone/zone_source from pre-computed map.
  -- derive_zone_fallback called once per unique (section,row) above, not 3× per row.
  per_row AS (
    SELECT
      l.section,
      l.row,
      l.quantity,
      l.retail_price,
      l.wholesale_price,
      l.is_owned,
      l.is_ancillary,
      sz.curated_name,
      sz.fb_zone,
      COALESCE(sz.curated_name, sz.fb_zone, 'unmapped')  AS zone,
      CASE WHEN sz.curated_name IS NOT NULL THEN 'curated'
           WHEN sz.fb_zone IS NOT NULL       THEN 'fallback'
           ELSE                                   'unmapped'
      END AS zone_source
    FROM listings_snapshots l
    LEFT JOIN sec_zones sz
           ON sz.section = l.section
          AND sz.row IS NOT DISTINCT FROM l.row
    WHERE l.event_id     = p_event_id
      AND l.captured_at  = p_captured_at
      AND l.section IS NOT NULL
  ),
  expanded AS (
    SELECT pr.section, pr.retail_price, pr.wholesale_price, pr.is_owned
    FROM per_row pr
    JOIN LATERAL generate_series(1, GREATEST(pr.quantity, 0)) AS gs(n) ON true
  ),
  per_section_zone_counts AS (
    SELECT section, zone, zone_source, COUNT(*) AS row_cnt
    FROM per_row
    GROUP BY section, zone, zone_source
  ),
  per_section_zone AS (
    SELECT section, zone, zone_source,
           ROW_NUMBER() OVER (
             PARTITION BY section
             ORDER BY CASE zone_source WHEN 'curated' THEN 0 WHEN 'fallback' THEN 1 ELSE 2 END,
                      row_cnt DESC
           ) AS rn
    FROM per_section_zone_counts
  ),
  agg AS (
    SELECT
      pr.section,
      bool_and(pr.is_ancillary)                                            AS all_ancillary,
      SUM(pr.quantity)::int                                                AS tickets_count,
      COUNT(*)::int                                                        AS groups_count,
      MIN(pr.retail_price) FILTER (WHERE pr.quantity >= 2 AND pr.retail_price IS NOT NULL)
                                                                           AS getin_price,
      COUNT(*) FILTER (WHERE pr.is_owned)::int                             AS owned_groups_count,
      COALESCE(SUM(pr.quantity) FILTER (WHERE pr.is_owned), 0)::int        AS owned_tickets_count
    FROM per_row pr
    GROUP BY pr.section
  ),
  pct AS (
    SELECT
      e.section,
      MIN(e.retail_price)                                                       AS retail_min,
      percentile_cont(0.25) WITHIN GROUP (ORDER BY e.retail_price)              AS retail_p25,
      percentile_cont(0.5)  WITHIN GROUP (ORDER BY e.retail_price)              AS retail_median,
      AVG(e.retail_price)                                                       AS retail_mean,
      percentile_cont(0.75) WITHIN GROUP (ORDER BY e.retail_price)              AS retail_p75,
      percentile_cont(0.9)  WITHIN GROUP (ORDER BY e.retail_price)              AS retail_p90,
      MAX(e.retail_price)                                                       AS retail_max,
      SUM(e.retail_price)                                                       AS retail_sum,
      MIN(e.wholesale_price)                                                    AS wholesale_min,
      percentile_cont(0.5)  WITHIN GROUP (ORDER BY e.wholesale_price)           AS wholesale_median,
      AVG(e.wholesale_price)                                                    AS wholesale_mean,
      MAX(e.wholesale_price)                                                    AS wholesale_max,
      percentile_cont(0.5)  WITHIN GROUP (ORDER BY e.retail_price)
        FILTER (WHERE e.is_owned)                                               AS owned_median_retail
    FROM expanded e
    GROUP BY e.section
  )
  INSERT INTO section_metrics (
    event_id, captured_at, section, is_ancillary,
    tickets_count, groups_count, sections_count,
    retail_min, retail_p25, retail_median, retail_mean, retail_p75, retail_p90, retail_max, retail_sum,
    wholesale_min, wholesale_median, wholesale_mean, wholesale_max,
    getin_price,
    owned_groups_count, owned_tickets_count, owned_share, owned_median_retail,
    zone, zone_source
  )
  SELECT
    p_event_id, p_captured_at, a.section, a.all_ancillary,
    a.tickets_count, a.groups_count, 1,
    round(p.retail_min::numeric,      2),
    round(p.retail_p25::numeric,      2),
    round(p.retail_median::numeric,   2),
    round(p.retail_mean::numeric,     2),
    round(p.retail_p75::numeric,      2),
    round(p.retail_p90::numeric,      2),
    round(p.retail_max::numeric,      2),
    round(p.retail_sum::numeric,      2),
    round(p.wholesale_min::numeric,   2),
    round(p.wholesale_median::numeric,2),
    round(p.wholesale_mean::numeric,  2),
    round(p.wholesale_max::numeric,   2),
    round(a.getin_price::numeric,     2),
    a.owned_groups_count, a.owned_tickets_count,
    CASE WHEN a.tickets_count > 0
         THEN round((a.owned_tickets_count::numeric / a.tickets_count)::numeric, 4)
         ELSE NULL END,
    round(p.owned_median_retail::numeric, 2),
    z.zone, z.zone_source
  FROM agg a
  JOIN pct p ON p.section = a.section
  LEFT JOIN per_section_zone z ON z.section = a.section AND z.rn = 1
  ON CONFLICT (event_id, captured_at, section) DO UPDATE SET
    is_ancillary        = EXCLUDED.is_ancillary,
    tickets_count       = EXCLUDED.tickets_count,
    groups_count        = EXCLUDED.groups_count,
    sections_count      = EXCLUDED.sections_count,
    retail_min          = EXCLUDED.retail_min,
    retail_p25          = EXCLUDED.retail_p25,
    retail_median       = EXCLUDED.retail_median,
    retail_mean         = EXCLUDED.retail_mean,
    retail_p75          = EXCLUDED.retail_p75,
    retail_p90          = EXCLUDED.retail_p90,
    retail_max          = EXCLUDED.retail_max,
    retail_sum          = EXCLUDED.retail_sum,
    wholesale_min       = EXCLUDED.wholesale_min,
    wholesale_median    = EXCLUDED.wholesale_median,
    wholesale_mean      = EXCLUDED.wholesale_mean,
    wholesale_max       = EXCLUDED.wholesale_max,
    getin_price         = EXCLUDED.getin_price,
    owned_groups_count  = EXCLUDED.owned_groups_count,
    owned_tickets_count = EXCLUDED.owned_tickets_count,
    owned_share         = EXCLUDED.owned_share,
    owned_median_retail = EXCLUDED.owned_median_retail,
    zone                = EXCLUDED.zone,
    zone_source         = EXCLUDED.zone_source;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;
