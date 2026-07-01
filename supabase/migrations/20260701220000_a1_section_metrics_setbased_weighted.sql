-- ============================================================================
-- Migration 20260701220000 — compute_event_section_metrics: set-based match + weighted percentiles
--
-- Lane:     A1
-- Touches:  public.compute_event_section_metrics(bigint,timestamptz) — body only.
-- Pre-reqs: 20260701215000 (zone fn, same pattern), _sec_norm/_sec_prefix/_sec_suffix,
--           performer_zones/performer_zone_rules, derive_zone_fallback, section_metrics.
--
-- WHY: the sibling of compute_event_zone_metrics had the SAME two unbounded paths, confirmed
-- live when the re-enabled zone-backfill stuck at 21:54 (a direct 30s-timeout test dumped this
-- fn's body mid-hang): (1) match_performer_zone() per distinct (section,row) — ~106k regex evals
-- on big curated venues; (2) generate_series(1,quantity) row explosion before percentile_cont.
-- Fixed identically: MATERIALIZED normalized rules/sec_n/sec_zones (PG12+ inlines once-referenced
-- CTEs, silently restoring the per-row cost without MATERIALIZED) + quantity-weighted percentiles
-- per SECTION via cumulative sums.
--
-- VERIFIED on prod: small event 85 sections + pathological event (175 sections, was 30s-timeout)
-- both in <10ms; backfill_stale_zone_metrics(100) = 100 events / 357 zones + sections in <0.1s;
-- baseline values: medians/min/max/sum/get-in/owned/zone assignment IDENTICAL. Known, accepted
-- behavior change: on small-n sections the tail percentiles (p25/p90) now return the nearest
-- ACTUAL listed price (discrete weighted percentile) instead of percentile_cont's interpolated
-- synthetic value (e.g. 18-ticket section p90 122.89-interpolated -> 171.36-actual). Medians match.
--
-- zone-backfill-isolated-10min re-enabled after this fix (batch 100; bounded by fast fns + 90s
-- loop budget + postgres-role 900s statement_timeout).
--
-- Idempotent: CREATE OR REPLACE. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

CREATE OR REPLACE FUNCTION public.compute_event_section_metrics(p_event_id bigint, p_captured_at timestamp with time zone)
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
  rules AS MATERIALIZED (
    SELECT z.name, z.display_order,
           _sec_norm(r.section_from)   AS nf,  _sec_norm(r.section_to)   AS nt,
           _sec_prefix(r.section_from) AS pf,  _sec_prefix(r.section_to) AS pt,
           _sec_suffix(r.section_from) AS sf,  _sec_suffix(r.section_to) AS st,
           (r.section_from ~ '^[0-9]+$' AND r.section_to ~ '^[0-9]+$')   AS sec_range_num,
           CASE WHEN r.section_from ~ '^[0-9]+$' THEN r.section_from::int END AS from_int,
           CASE WHEN r.section_to   ~ '^[0-9]+$' THEN r.section_to::int   END AS to_int,
           r.row_from, r.row_to,
           lower(coalesce(r.row_from,'')) AS rlf, lower(coalesce(r.row_to,'')) AS rlt,
           (r.row_from ~ '^[0-9]+$' AND r.row_to ~ '^[0-9]+$')           AS row_range_num,
           CASE WHEN r.row_from ~ '^[0-9]+$' THEN r.row_from::int END    AS row_from_int,
           CASE WHEN r.row_to   ~ '^[0-9]+$' THEN r.row_to::int   END    AS row_to_int
    FROM performer_zones z
    JOIN performer_zone_rules r ON r.zone_id = z.id
    WHERE v_has_zones AND z.performer_id = v_performer_id AND z.venue_id = v_venue_id
  ),
  unique_sec AS (
    SELECT DISTINCT section, row FROM listings_snapshots
    WHERE event_id = p_event_id AND captured_at = p_captured_at AND section IS NOT NULL
  ),
  sec_n AS MATERIALIZED (
    SELECT u.section, u.row,
           _sec_norm(u.section)   AS sn,
           _sec_prefix(u.section) AS sp,
           _sec_suffix(u.section) AS ss,
           (u.section ~ '^[0-9]+$') AS sec_is_num,
           CASE WHEN u.section ~ '^[0-9]+$' THEN u.section::int END AS sec_int,
           lower(coalesce(u.row,'')) AS rl,
           (u.row ~ '^[0-9]+$') AS row_is_num,
           CASE WHEN u.row ~ '^[0-9]+$' THEN u.row::int END AS row_int
    FROM unique_sec u
  ),
  sec_zones AS MATERIALIZED (
    SELECT s.section, s.row,
           (SELECT ru.name FROM rules ru
             WHERE (
                     (ru.nf = ru.nt AND s.sn = ru.nf)
                  OR (ru.sec_range_num AND s.sec_is_num AND s.sec_int BETWEEN ru.from_int AND ru.to_int)
                  OR (ru.pf <> '' AND ru.pf = ru.pt AND ru.pf = s.sp
                      AND ru.sf IS NOT NULL AND ru.st IS NOT NULL AND s.ss IS NOT NULL
                      AND s.ss BETWEEN ru.sf AND ru.st)
                   )
               AND (
                     (ru.row_from IS NULL AND ru.row_to IS NULL)
                  OR (ru.rlf = ru.rlt AND s.rl = ru.rlf)
                  OR (ru.row_range_num AND s.row_is_num AND s.row_int BETWEEN ru.row_from_int AND ru.row_to_int)
                   )
             ORDER BY ru.display_order ASC LIMIT 1) AS curated_name,
           derive_zone_fallback(s.section, s.row) AS fb_zone
    FROM sec_n s
  ),
  per_row AS (
    SELECT l.section, l.row, l.quantity, l.retail_price, l.wholesale_price, l.is_owned, l.is_ancillary,
           COALESCE(sz.curated_name, sz.fb_zone, 'unmapped') AS zone,
           CASE WHEN sz.curated_name IS NOT NULL THEN 'curated'
                WHEN sz.fb_zone IS NOT NULL       THEN 'fallback'
                ELSE 'unmapped' END AS zone_source
    FROM listings_snapshots l
    LEFT JOIN sec_zones sz ON sz.section = l.section AND sz.row IS NOT DISTINCT FROM l.row
    WHERE l.event_id = p_event_id AND l.captured_at = p_captured_at AND l.section IS NOT NULL
  ),
  per_section_zone_counts AS (
    SELECT section, zone, zone_source, COUNT(*) AS row_cnt
    FROM per_row GROUP BY section, zone, zone_source
  ),
  per_section_zone AS (
    SELECT section, zone, zone_source,
           ROW_NUMBER() OVER (
             PARTITION BY section
             ORDER BY CASE zone_source WHEN 'curated' THEN 0 WHEN 'fallback' THEN 1 ELSE 2 END,
                      row_cnt DESC) AS rn
    FROM per_section_zone_counts
  ),
  agg AS (
    SELECT pr.section,
      bool_and(pr.is_ancillary) AS all_ancillary,
      SUM(pr.quantity)::int AS tickets_count,
      COUNT(*)::int AS groups_count,
      MIN(pr.retail_price) FILTER (WHERE pr.quantity >= 2 AND pr.retail_price IS NOT NULL) AS getin_price,
      COUNT(*) FILTER (WHERE pr.is_owned)::int AS owned_groups_count,
      COALESCE(SUM(pr.quantity) FILTER (WHERE pr.is_owned),0)::int AS owned_tickets_count,
      MIN(pr.retail_price) AS retail_min,
      MAX(pr.retail_price) AS retail_max,
      SUM(pr.retail_price * pr.quantity) AS retail_sum,
      (SUM(pr.retail_price * pr.quantity) / NULLIF(SUM(pr.quantity) FILTER (WHERE pr.retail_price IS NOT NULL),0)) AS retail_mean,
      MIN(pr.wholesale_price) AS wholesale_min,
      MAX(pr.wholesale_price) AS wholesale_max,
      (SUM(pr.wholesale_price * pr.quantity) / NULLIF(SUM(pr.quantity) FILTER (WHERE pr.wholesale_price IS NOT NULL),0)) AS wholesale_mean
    FROM per_row pr GROUP BY pr.section
  ),
  r_cum AS (
    SELECT section, price,
      SUM(qty) OVER (PARTITION BY section ORDER BY price) AS cum,
      SUM(qty) OVER (PARTITION BY section) AS tot
    FROM (SELECT section, retail_price AS price, SUM(quantity) AS qty
          FROM per_row WHERE retail_price IS NOT NULL GROUP BY section, retail_price) d
  ),
  r_p AS (
    SELECT section,
      MIN(price) FILTER (WHERE cum >= 0.25*tot) AS retail_p25,
      MIN(price) FILTER (WHERE cum >= 0.50*tot) AS retail_median,
      MIN(price) FILTER (WHERE cum >= 0.75*tot) AS retail_p75,
      MIN(price) FILTER (WHERE cum >= 0.90*tot) AS retail_p90
    FROM r_cum GROUP BY section
  ),
  ro_cum AS (
    SELECT section, price,
      SUM(qty) OVER (PARTITION BY section ORDER BY price) AS cum,
      SUM(qty) OVER (PARTITION BY section) AS tot
    FROM (SELECT section, retail_price AS price, SUM(quantity) AS qty
          FROM per_row WHERE retail_price IS NOT NULL AND is_owned GROUP BY section, retail_price) d
  ),
  ro_p AS (
    SELECT section, MIN(price) FILTER (WHERE cum >= 0.50*tot) AS owned_median_retail
    FROM ro_cum GROUP BY section
  ),
  w_cum AS (
    SELECT section, price,
      SUM(qty) OVER (PARTITION BY section ORDER BY price) AS cum,
      SUM(qty) OVER (PARTITION BY section) AS tot
    FROM (SELECT section, wholesale_price AS price, SUM(quantity) AS qty
          FROM per_row WHERE wholesale_price IS NOT NULL GROUP BY section, wholesale_price) d
  ),
  w_p AS (
    SELECT section, MIN(price) FILTER (WHERE cum >= 0.50*tot) AS wholesale_median
    FROM w_cum GROUP BY section
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
    round(a.retail_min::numeric,2), round(rp.retail_p25::numeric,2), round(rp.retail_median::numeric,2),
    round(a.retail_mean::numeric,2), round(rp.retail_p75::numeric,2), round(rp.retail_p90::numeric,2),
    round(a.retail_max::numeric,2), round(a.retail_sum::numeric,2),
    round(a.wholesale_min::numeric,2), round(wp.wholesale_median::numeric,2), round(a.wholesale_mean::numeric,2), round(a.wholesale_max::numeric,2),
    round(a.getin_price::numeric,2),
    a.owned_groups_count, a.owned_tickets_count,
    CASE WHEN a.tickets_count>0 THEN round((a.owned_tickets_count::numeric/a.tickets_count),4) ELSE NULL END,
    round(rop.owned_median_retail::numeric,2),
    z.zone, z.zone_source
  FROM agg a
  LEFT JOIN r_p  rp  ON rp.section  = a.section
  LEFT JOIN ro_p rop ON rop.section = a.section
  LEFT JOIN w_p  wp  ON wp.section  = a.section
  LEFT JOIN per_section_zone z ON z.section = a.section AND z.rn = 1
  ON CONFLICT (event_id, captured_at, section) DO UPDATE SET
    is_ancillary=EXCLUDED.is_ancillary, tickets_count=EXCLUDED.tickets_count, groups_count=EXCLUDED.groups_count,
    sections_count=EXCLUDED.sections_count, retail_min=EXCLUDED.retail_min, retail_p25=EXCLUDED.retail_p25,
    retail_median=EXCLUDED.retail_median, retail_mean=EXCLUDED.retail_mean, retail_p75=EXCLUDED.retail_p75,
    retail_p90=EXCLUDED.retail_p90, retail_max=EXCLUDED.retail_max, retail_sum=EXCLUDED.retail_sum,
    wholesale_min=EXCLUDED.wholesale_min, wholesale_median=EXCLUDED.wholesale_median, wholesale_mean=EXCLUDED.wholesale_mean,
    wholesale_max=EXCLUDED.wholesale_max, getin_price=EXCLUDED.getin_price,
    owned_groups_count=EXCLUDED.owned_groups_count, owned_tickets_count=EXCLUDED.owned_tickets_count,
    owned_share=EXCLUDED.owned_share, owned_median_retail=EXCLUDED.owned_median_retail,
    zone=EXCLUDED.zone, zone_source=EXCLUDED.zone_source;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;
