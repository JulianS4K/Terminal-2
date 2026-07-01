-- ============================================================================
-- Migration 20260701215000 — zone metrics: set-based curated match (MATERIALIZED) + re-enable backfill cron
--
-- Lane:     A1
-- Touches:  public.compute_event_zone_metrics(bigint,timestamptz) (body); cron 'zone-backfill-isolated-10min'.
-- Pre-reqs: 20260701210000 (weighted percentiles), 20260701213000 (postgres-role 900s cap),
--           _sec_norm/_sec_prefix/_sec_suffix, performer_zones/performer_zone_rules, derive_zone_fallback.
--
-- WHY (P2 completion — the residual zone-compute bottleneck after the generate_series fix):
--   match_performer_zone() re-normalized ALL zone rules per distinct (section,row) call:
--   714 section/rows x 149 rules ~ 106k regex-heavy evaluations on a big curated venue (event
--   3091720) -> the call ran 30-60s+ and was the residual slow path behind the 2026-07-01
--   zone-backfill wedge. Rewritten set-based: rules + sections normalized ONCE each, matched via
--   a correlated lookup over precomputed columns.
--
--   CRITICAL GOTCHA: the first set-based cut was STILL slow because PG12+ INLINES a CTE
--   referenced once — `rules` was re-evaluated per section row and `sec_zones` per listing row,
--   silently restoring the old cost. `AS MATERIALIZED` on rules/sec_n/sec_zones forces one-time
--   evaluation. (Applied to prod in two MCP steps: a1_zone_metrics_setbased_curated_match +
--   a1_zone_metrics_materialized_ctes; this file is the canonical final state.)
--
--   VERIFIED on prod: match semantics 30/30 identical to match_performer_zone on live curated
--   data; small-event values byte-identical to the original percentile_cont output; the
--   pathological event (6,234 tickets, 714x149) computes 11 zones in <10ms (was: 70-min hang);
--   backfill_stale_zone_metrics(20) = 20 events / 60 zones in <0.1s.
--
--   Cron re-enabled at batch 100 (was disabled after the wedge): now bounded by (1) the fast fn,
--   (2) the 90s loop wall-clock budget in backfill_stale_zone_metrics, (3) the postgres-role
--   statement_timeout=900s (mig 20260701213000). No SET-prefix in the command — it's a no-op
--   under pg_cron (PROJECT_BIBLE §3).
--
-- Idempotent: CREATE OR REPLACE + cron.alter_job by name. Re-apply is a no-op.
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
  -- Curated zone rules, normalized ONCE (was: match_performer_zone() re-normalized every rule
  -- for every distinct (section,row) -> 714x149 ~ 106k regex evals on big venues = the slow path).
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
    WHERE event_id = p_event_id AND captured_at = p_captured_at
  ),
  -- Each distinct (section,row) normalized ONCE.
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
  -- Same match semantics as match_performer_zone(): exact-norm | pure-numeric-range |
  -- shared-prefix+numeric-suffix-range, AND'd with the row clause; first by display_order.
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

-- Re-enable the zone/section metrics backfill cron (batch 100; role-level 900s cap is the bound).
DO $do$
BEGIN
  PERFORM cron.alter_job(
    (SELECT jobid FROM cron.job WHERE jobname='zone-backfill-isolated-10min'),
    command := $cmd$SELECT public.backfill_stale_zone_metrics(100) WHERE public.cron_should_fire('zone-backfill-isolated-10min');$cmd$,
    active  := true);
END $do$;
