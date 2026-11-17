-- Migration 20260811193000 · lane:D0 (author) → applier (apply) · writes:get_event_listing_outliers(bigint,numeric,int,int) [fn, CREATE OR REPLACE — supersedes mig 20260810180000 body, same signature] · reads:listings_snapshots,ticketsdata_listings_snapshots,ticketsdata_event_xref,aq_event_map,sg_events_canonical,section_metrics,event_listing_snapshot_daily,clearing_dte_curve,events,performer_metadata,derive_zone_fallback,price_dte_bucket · pre:mig 20260810180000 (v1 zone RPC), 20260708180040 (clearing_dte_curve + price_dte_bucket), section_metrics.zone (curated persisted zone) · auth:OPERATOR-APPROVED read-only SECDEF (email-gated @s4kent.com; authenticated only, no anon)
--
-- WHY (operator-directed 2026-08-11). Extends the zone-level Outliers RPC from a
-- static cross-sectional snapshot into a THREE-AXIS deal / dumping detector, so a
-- flag answers not just "is this seat mispriced vs its zone?" but "is it a real
-- OPPORTUNITY or a falling knife being DUMPED?" — the operator's stated purpose.
--
--   AXIS 1 — CROSS-SECTION (where): each seat vs its zone peers, robust median+MAD
--     modified z (Iglewicz-Hoaglin), IQR fallback. Unchanged from v1 EXCEPT the
--     benchmark is now built over LIQUID splits only (see Axis-Q) and the zone key
--     prefers the CURATED manual map.
--   AXIS Q — QUANTITY AS PROBABILITY (comparability): a listing's sellable split
--     (splits[]) is weighted by P(split) = its frequency across the event book per
--     source. Pairs ({2}) are ~52% of a typical book; a qty-14 block is ~0.2%. The
--     zone median/MAD is computed over LIQUID splits (P >= p_liq, default 3%) ONLY,
--     so a rare block can neither drag the benchmark nor be flagged as a fake steal.
--     Rare-split seats are returned (split_class='rare') but never flagged — thin
--     comparables, not deals. This kills the class of false LOW/HIGH that pure
--     quantity-blind detection produced (e.g. a lone group-of-14 reading as a steal).
--   AXIS 2/3 — TRAJECTORY × TIME-TO-EVENT (why + when): from the 7-day moving
--     average (event_listing_snapshot_daily amalgam median, 21 slots = 7d) and the
--     measured clearing_dte_curve. The market's actual 7d move is compared to what
--     the DTE curve PREDICTS for this event's days-to-event; the EXCESS (actual −
--     expected) is the regime. A price sliding only as fast as the curve is normal
--     clearing, NOT dumping; sliding FASTER is genuine dumping pressure.
--       regime: excess<=-6 DUMPING · <=-2 SOFTENING · >=+4 RISING · else STABLE.
--     Per-outlier verdict crosses direction × regime:
--       LOW  + (DUMPING|SOFTENING) => DUMPING     (falling knife — avoid)
--       LOW  + (STABLE|RISING)     => OPPORTUNITY  (isolated steal — buy)
--       HIGH + (DUMPING|SOFTENING) => STALE        (will be undercut)
--       HIGH + (STABLE|RISING)     => RIDE         (justified vs a firm market)
--     urgency from DTE: <=7 HIGH · <=21 MED · else LOW (how actionable now).
--
-- Trajectory is EVENT-level from the amalgam daily series (all sources), attached as
-- market context to every outlier; EVO's own 7d MA is also surfaced. GoTickets has
-- no dedicated daily-median column, so its outliers inherit the amalgam regime
-- (documented limitation; per-source GT trajectory is a phase-2 once GT lands in the
-- daily rollup).
--
-- ZONE KEY (operator directive 2026-08-11 "use the zones we added manually"): prefer
-- the CURATED persisted zone section_metrics.zone (recency-bounded to p_max_age_hours
-- so it is an index scan, NOT the 8GB seq-scan the unbounded read triggers), LEFT
-- JOINed per section; fall back to derive_zone_fallback(section,row) when a section
-- (e.g. any GoTickets section, absent from section_metrics) has no curated tag, then
-- '(unzoned)'. zone_source records which resolver won per listing.
--
-- Non-seating inventory (parking/lots/hospitality) still excluded from baseline +
-- get-in exactly as v1. Read-only (SELECT only) + email-gated. Bounded statement
-- timeout. ROLLBACK: re-apply mig 20260810180000 (restores the v1 body; signature is
-- identical so grants/rollback are unaffected).

CREATE OR REPLACE FUNCTION public.get_event_listing_outliers(
  p_event_id      bigint,
  p_z_threshold   numeric DEFAULT 3.5,
  p_min_group     int     DEFAULT 4,
  p_max_age_hours int     DEFAULT 48
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email  text;
  v_result jsonb;
  v_liq    numeric := 0.03;   -- P(split) liquidity floor: below this a split is 'rare' (not benchmarked, not flagged)
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  PERFORM set_config('statement_timeout', '12000', true);

  WITH params AS (
    SELECT p_event_id AS ev,
           GREATEST(p_z_threshold, 0.1)  AS zt,
           GREATEST(p_min_group, 2)      AS ming,
           GREATEST(p_max_age_hours, 1)  AS age,
           v_liq                         AS liq
  ),
  -- GoTickets TD event ids mapped to this tevo event (one → many).
  gt_ids AS (
    SELECT DISTINCT tdx.event_id AS td_id
    FROM public.ticketsdata_event_xref tdx
    JOIN public.aq_event_map aem        ON aem.aq_short_event_id = tdx.aq_short_event_id
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id, params
    WHERE tdx.active = true AND sgc.tevo_event_id = params.ev
  ),
  evo_latest AS (
    SELECT max(l.captured_at) AS mx
    FROM public.listings_snapshots l, params
    WHERE l.event_id = params.ev
      AND l.captured_at > now() - (params.age || ' hours')::interval
  ),
  gt_latest AS (
    SELECT t.event_id, max(t.captured_at) AS mx
    FROM public.ticketsdata_listings_snapshots t, params
    WHERE t.platform = 'GT'
      AND t.event_id IN (SELECT td_id FROM gt_ids)
      AND t.captured_at > now() - (params.age || ' hours')::interval
    GROUP BY t.event_id
  ),
  -- Curated persisted zone per section (recency-bounded → index scan). EVO sections only.
  sm_zone AS (
    SELECT DISTINCT ON (lower(btrim(sm.section)))
           lower(btrim(sm.section)) AS sec_key, sm.zone AS cz
    FROM public.section_metrics sm, params
    WHERE sm.event_id = params.ev
      AND sm.captured_at > now() - (params.age || ' hours')::interval
      AND sm.zone IS NOT NULL AND sm.zone <> ''
    ORDER BY lower(btrim(sm.section)), sm.captured_at DESC
  ),
  raw AS (
    SELECT 'EVO'::text AS source,
           l.tevo_ticket_group_id::text AS listing_id,
           l.section, l.row, l.quantity,
           l.retail_price::numeric AS price,
           l.is_owned, l.captured_at,
           coalesce(l.splits, ARRAY[l.quantity])::int[] AS splits,
           (l.is_ancillary IS TRUE) AS nonseat_flag
    FROM public.listings_snapshots l, evo_latest e, params
    WHERE l.event_id = params.ev AND l.captured_at = e.mx AND l.retail_price > 0
    UNION ALL
    SELECT 'GT'::text,
           t.td_listing_id,
           t.section, t.row, t.quantity,
           t.list_price::numeric,
           NULL::boolean, t.captured_at,
           -- GameTime (ticketsdata platform=GT) exposes no split structure → the
           -- split signature degrades to the quantity itself. P(split) for GT is
           -- therefore a quantity-frequency, which is the correct fallback.
           ARRAY[t.quantity]::int[],
           (t.is_parking IS TRUE)
    FROM public.ticketsdata_listings_snapshots t
    JOIN gt_latest g ON g.event_id = t.event_id AND t.captured_at = g.mx
    WHERE t.platform = 'GT' AND t.list_price > 0
  ),
  classed AS (
    SELECT r.*,
           r.splits::text AS sig,
           -- curated zone first, then keyword fallback, then '(unzoned)'
           coalesce(sz.cz, nullif(public.derive_zone_fallback(r.section, r.row), ''), '(unzoned)') AS zone,
           CASE WHEN sz.cz IS NOT NULL THEN 'curated'
                WHEN nullif(public.derive_zone_fallback(r.section, r.row), '') IS NOT NULL THEN 'fallback'
                ELSE 'none' END AS zone_source,
           -- coarsened buyer-comparability class (peer pool label)
           CASE WHEN r.quantity <= 2 THEN 'pair'
                WHEN r.quantity <= 4 THEN 'small'
                ELSE 'block' END AS qty_class,
           NOT (
             r.nonseat_flag
             OR coalesce(r.section, '') ~* '\y(parking|garage|valet|lot|hospitality|shuttle|prepaid)\y'
           ) AS is_seating
    FROM raw r
    LEFT JOIN sm_zone sz ON sz.sec_key = lower(btrim(r.section))
  ),
  -- P(split): frequency of each exact split signature across the seating book, per source.
  split_freq AS (
    SELECT source, sig,
           count(*)                                                   AS sig_n,
           count(*)::numeric / sum(count(*)) OVER (PARTITION BY source) AS p_split
    FROM classed WHERE is_seating GROUP BY source, sig
  ),
  tagged AS (
    SELECT c.*, sf.sig_n, sf.p_split,
           -- liquid = common enough to trust as a comparable; rare = thin comps
           (sf.p_split >= (SELECT liq FROM params) OR sf.sig_n >= 10) AS is_liquid
    FROM classed c JOIN split_freq sf USING (source, sig)
  ),
  -- Robust stats PER (source × zone) over LIQUID seating listings only.
  zstats AS (
    SELECT source, zone,
           count(*)                                                    AS n,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY price)::numeric AS med,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY price)::numeric AS q1,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY price)::numeric AS q3,
           min(price)::numeric                                         AS getin
    FROM tagged WHERE is_seating AND is_liquid GROUP BY source, zone
  ),
  zmad AS (
    SELECT t.source, t.zone,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(t.price - z.med))::numeric AS madv
    FROM tagged t JOIN zstats z USING (source, zone)
    WHERE t.is_seating AND t.is_liquid GROUP BY t.source, t.zone
  ),
  -- ── Market trajectory (Axis 2/3): event-level 7d MA + DTE-curve regime ──
  ev_cat AS (
    SELECT CASE WHEN e.event_type = 'game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category
    FROM public.events e
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id, params
    WHERE e.id = params.ev
  ),
  daily AS (
    SELECT d.snapshot_date, d.amalgam_median, d.evo_retail_median,
           row_number() OVER (ORDER BY d.snapshot_date DESC,
             CASE d.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC) AS rn
    FROM public.event_listing_snapshot_daily d, params
    WHERE d.event_id = params.ev AND d.amalgam_median IS NOT NULL
  ),
  ev_date AS (
    SELECT sgc.sg_datetime_utc::date AS d
    FROM public.sg_events_canonical sgc, params
    WHERE sgc.tevo_event_id = params.ev AND sgc.sg_datetime_utc IS NOT NULL
    LIMIT 1
  ),
  market AS (
    SELECT
      (SELECT category FROM ev_cat)                                        AS category,
      (SELECT amalgam_median FROM daily WHERE rn = 1)                      AS cur_med,
      (SELECT avg(amalgam_median) FROM daily WHERE rn <= 21)               AS ma7,
      (SELECT amalgam_median FROM daily WHERE rn = 22)                     AS med_7d_ago,
      (SELECT evo_retail_median FROM daily WHERE rn = 1)                   AS evo_cur,
      (SELECT avg(evo_retail_median) FROM daily WHERE rn <= 21)            AS evo_ma7,
      ((SELECT d FROM ev_date) - (SELECT snapshot_date FROM daily WHERE rn = 1))  AS dte_now,
      ((SELECT d FROM ev_date) - (SELECT snapshot_date FROM daily WHERE rn = 22)) AS dte_7d_ago
  ),
  regime AS (
    SELECT m.*,
      cn.level_index AS curve_now, cw.level_index AS curve_7d,
      -- actual 7d % move of the amalgam median
      CASE WHEN m.med_7d_ago > 0 THEN round((m.cur_med / m.med_7d_ago - 1) * 100, 1) END AS actual_7d_pct,
      -- expected 7d % move per the DTE clearing curve for this category
      CASE WHEN cw.level_index > 0 THEN round((cn.level_index / cw.level_index - 1) * 100, 1) END AS expected_7d_pct
    FROM market m
    LEFT JOIN public.clearing_dte_curve cn ON cn.category = m.category AND cn.dte_bucket = public.price_dte_bucket(m.dte_now::int)
    LEFT JOIN public.clearing_dte_curve cw ON cw.category = m.category AND cw.dte_bucket = public.price_dte_bucket(m.dte_7d_ago::int)
  ),
  regime2 AS (
    SELECT r.*,
      round(coalesce(r.actual_7d_pct,0) - coalesce(r.expected_7d_pct,0), 1) AS excess_pct,
      CASE WHEN r.ma7 > 0 THEN round((r.cur_med / r.ma7 - 1) * 100, 1) END   AS px_vs_ma_pct,
      CASE
        WHEN r.actual_7d_pct IS NULL THEN 'UNKNOWN'
        WHEN (coalesce(r.actual_7d_pct,0) - coalesce(r.expected_7d_pct,0)) <= -6 THEN 'DUMPING'
        WHEN (coalesce(r.actual_7d_pct,0) - coalesce(r.expected_7d_pct,0)) <= -2 THEN 'SOFTENING'
        WHEN (coalesce(r.actual_7d_pct,0) - coalesce(r.expected_7d_pct,0)) >=  4 THEN 'RISING'
        ELSE 'STABLE'
      END AS regime,
      CASE WHEN r.dte_now IS NULL THEN NULL
           WHEN r.dte_now <= 7 THEN 'HIGH' WHEN r.dte_now <= 21 THEN 'MED' ELSE 'LOW' END AS urgency
    FROM regime r
  ),
  scored AS (
    SELECT t.*, z.n AS zone_n, z.med, z.q1, z.q3, m.madv,
           CASE WHEN m.madv > 0 THEN round(0.6745 * (t.price - z.med) / m.madv, 2) END AS mod_z,
           CASE WHEN z.med > 0  THEN round((t.price / z.med - 1) * 100, 1) END          AS dev_pct,
           CASE WHEN m.madv > 0 THEN 'mad' ELSE 'iqr' END                               AS method,
           CASE
             -- non-seating, rare split, or a zone too small to judge → never flagged
             WHEN NOT t.is_seating OR NOT t.is_liquid OR z.n < (SELECT ming FROM params) THEN NULL
             WHEN m.madv > 0 AND abs(0.6745 * (t.price - z.med) / m.madv) >= (SELECT zt FROM params)
               THEN CASE WHEN t.price > z.med THEN 'HIGH' ELSE 'LOW' END
             WHEN m.madv = 0 AND (t.price > z.q3 + 1.5 * (z.q3 - z.q1)
                              OR  t.price < z.q1 - 1.5 * (z.q3 - z.q1))
               THEN CASE WHEN t.price > z.med THEN 'HIGH' ELSE 'LOW' END
             ELSE NULL
           END AS direction
    FROM tagged t
    LEFT JOIN zstats z USING (source, zone)
    LEFT JOIN zmad m  USING (source, zone)
  ),
  scored_v AS (
    SELECT s.*,
      CASE
        WHEN s.direction = 'LOW'  AND (SELECT regime FROM regime2) IN ('DUMPING','SOFTENING') THEN 'DUMPING'
        WHEN s.direction = 'LOW'  AND (SELECT regime FROM regime2) IN ('STABLE','RISING')     THEN 'OPPORTUNITY'
        WHEN s.direction = 'HIGH' AND (SELECT regime FROM regime2) IN ('DUMPING','SOFTENING') THEN 'STALE'
        WHEN s.direction = 'HIGH' AND (SELECT regime FROM regime2) IN ('STABLE','RISING')     THEN 'RIDE'
        WHEN s.direction IS NOT NULL THEN 'REVIEW'   -- flagged but regime UNKNOWN (no daily history)
        ELSE NULL
      END AS verdict
    FROM scored s
  ),
  zone_summary AS (
    SELECT z.source, z.zone, z.n, z.getin, z.med, round(m.madv, 2) AS mad,
           (z.n >= (SELECT ming FROM params)) AS scored,
           (SELECT count(*) FROM scored_v x WHERE x.source = z.source AND x.zone = z.zone AND x.direction = 'LOW')  AS low_count,
           (SELECT count(*) FROM scored_v x WHERE x.source = z.source AND x.zone = z.zone AND x.direction = 'HIGH') AS high_count
    FROM zstats z JOIN zmad m USING (source, zone)
  ),
  src_summary AS (
    SELECT d.source,
           (SELECT count(*) FROM tagged c WHERE c.source = d.source AND c.is_seating)                    AS n_seat,
           (SELECT count(*) FROM tagged c WHERE c.source = d.source AND c.is_seating AND c.is_liquid)    AS n_liquid,
           (SELECT count(*) FROM tagged c WHERE c.source = d.source AND c.is_seating AND NOT c.is_liquid) AS n_rare,
           (SELECT count(*) FROM tagged c WHERE c.source = d.source AND NOT c.is_seating)                AS n_nonseat,
           (SELECT min(price)   FROM tagged c WHERE c.source = d.source AND c.is_seating)                AS getin,
           (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY price)::numeric
              FROM tagged c WHERE c.source = d.source AND c.is_seating)                                  AS src_med,
           (SELECT count(*) FROM zstats z WHERE z.source = d.source AND z.n >= (SELECT ming FROM params)) AS zones_scored,
           (SELECT count(*) FROM scored_v x WHERE x.source = d.source AND x.direction = 'LOW')           AS low_count,
           (SELECT count(*) FROM scored_v x WHERE x.source = d.source AND x.direction = 'HIGH')          AS high_count,
           (SELECT max(c.captured_at) FROM tagged c WHERE c.source = d.source)                           AS captured_at
    FROM (SELECT DISTINCT source FROM tagged) d
  )
  SELECT jsonb_build_object(
    'event_id', p_event_id,
    'generated_at', now(),
    'scope', 'zone',
    'params', jsonb_build_object(
      'z_threshold', p_z_threshold, 'min_group', p_min_group, 'max_age_hours', p_max_age_hours,
      'liquidity_floor', v_liq),
    'market', (
      SELECT jsonb_build_object(
        'category', category, 'days_to_event', dte_now,
        'dte_bucket', public.price_dte_bucket(dte_now::int),
        'current_median', round(cur_med,2), 'ma_7d', round(ma7,2), 'px_vs_ma_pct', px_vs_ma_pct,
        'evo_current', round(evo_cur,2), 'evo_ma_7d', round(evo_ma7,2),
        'actual_7d_pct', actual_7d_pct, 'expected_7d_pct', expected_7d_pct, 'excess_pct', excess_pct,
        'regime', regime, 'urgency', urgency,
        'basis', 'amalgam daily median · 21-slot(7d) MA · vs clearing_dte_curve'
      ) FROM regime2),
    'sources', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'source', source, 'captured_at', captured_at,
        'n_seating', n_seat, 'n_liquid', n_liquid, 'n_rare_split', n_rare,
        'n_nonseating_excluded', n_nonseat,
        'getin', getin, 'median', src_med, 'zones_scored', zones_scored,
        'low_count', low_count, 'high_count', high_count
      ) ORDER BY source) FROM src_summary), '[]'::jsonb),
    'zones', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'source', source, 'zone', zone, 'n', n, 'getin', getin, 'median', med,
        'mad', mad, 'scored', scored, 'low_count', low_count, 'high_count', high_count
      ) ORDER BY source, n DESC) FROM zone_summary), '[]'::jsonb),
    'outliers', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'source', source, 'listing_id', listing_id, 'section', section, 'row', "row",
        'quantity', quantity, 'price', price, 'is_owned', is_owned,
        'zone', zone, 'zone_source', zone_source, 'zone_n', zone_n,
        'split', sig, 'p_split_pct', round(p_split*100,1), 'qty_class', qty_class,
        'baseline_median', med, 'mad', round(madv, 2), 'mod_z', mod_z,
        'deviation_pct', dev_pct, 'direction', direction, 'verdict', verdict,
        'method', method, 'captured_at', captured_at
      ) ORDER BY source, abs(coalesce(mod_z, 999)) DESC, dev_pct DESC)
      FROM scored_v WHERE direction IS NOT NULL), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_event_listing_outliers(bigint,numeric,int,int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_event_listing_outliers(bigint,numeric,int,int) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_event_listing_outliers(bigint,numeric,int,int) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_event_listing_outliers(bigint,numeric,int,int) IS
  'D0 event-page "Outliers" tab — THREE-AXIS deal/dumping detector. Axis1 zone cross-section (curated section_metrics.zone, fallback derive_zone_fallback; robust median+MAD mod-z, IQR fallback). AxisQ quantity-as-probability: benchmark built over LIQUID splits only (P(split)>=3% of source book), rare splits returned but never flagged. Axis2/3 trajectory×DTE: 7-day MA (event_listing_snapshot_daily amalgam) vs measured clearing_dte_curve → regime (DUMPING/SOFTENING/STABLE/RISING) → per-outlier verdict (DUMPING/OPPORTUNITY/STALE/RIDE) + urgency. EVO+GoTickets book. Email-gated SECDEF, authenticated-only. Supersedes mig 20260810180000 body (same signature). Mig 20260811193000.';
