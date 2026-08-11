-- Migration 20260811203000 · lane:D0 (author) → applier (apply) · writes:get_gotickets_deals(bigint,int,numeric,int,int,numeric) [fn] · reads:gotickets_listings_snapshots,listings_snapshots,event_listing_snapshot_daily,clearing_dte_curve,sg_events_canonical,events,performer_metadata,derive_zone_fallback,price_dte_bucket · pre:derive_zone_fallback (mig 20260507000000), clearing_dte_curve+price_dte_bucket (mig 20260708180040) · auth:OPERATOR-APPROVED read-only SECDEF (email-gated @s4kent.com; authenticated only, no anon)
--
-- WHY (operator-directed 2026-08-11). Backs the new D0 "DEALS" header view.
-- Operator directive: "deals should be exclusive to GoTickets for now, just use
-- the data from the other sites for metrics." So this is a CROSS-MARKET arbitrage
-- scan — GoTickets is the only BUYABLE inventory surfaced; every OTHER source
-- (EVO here, the granular zone-level book) is the benchmark, never listed as a
-- deal itself. A GoTickets listing priced well below the cross-market zone median
-- for the same event × zone is an opportunity.
--
--   COMMON ZONE KEY: derive_zone_fallback(section,row) on BOTH sides — GoTickets
--     and EVO section vocabularies differ textually, so the keyword zone is the
--     apples-to-apples join (curated section_metrics.zone is EVO-only and would
--     not match GoTickets sections).
--   BENCHMARK: EVO (listings_snapshots) latest-capture zone median + count. A zone
--     must carry >= p_min_zone_n EVO listings to be a trustworthy benchmark.
--   DEAL: gt.all_in_price <= (1 - p_min_discount) × evo_zone_median, and
--     >= 0.15 × median (drops fee-parse/spec junk and $0 rows). general_admission
--     + parking excluded. Accessible/wheelchair rows (row ~ WC) are RETURNED but
--     tagged is_accessible so the UI can mark them (they legitimately price low).
--   REGIME OVERLAY (dumping vs opportunity): the event's amalgam 7-day MA vs the
--     measured clearing_dte_curve (same basis as get_event_listing_outliers) gives
--     a DUMPING/SOFTENING/STABLE/RISING regime. A deep discount in a STABLE/RISING
--     market = OPPORTUNITY; in a DUMPING/SOFTENING market it may be a falling knife
--     → verdict CAUTION. Surfaced per event + folded into each deal's verdict.
--
-- Per-event + bounded (latest GoTickets capture within p_max_age_hours, one EVO
-- capture) so it is safe as an on-demand header-page call. Read-only, email-gated.
-- ROLLBACK: DROP FUNCTION public.get_gotickets_deals(bigint,int,numeric,int,int,numeric).

CREATE OR REPLACE FUNCTION public.get_gotickets_deals(
  p_event_id         bigint,
  p_max_age_hours    int     DEFAULT 6,
  p_min_discount     numeric DEFAULT 0.15,
  p_min_zone_n       int     DEFAULT 6,
  p_limit            int     DEFAULT 100,
  p_min_zone_median  numeric DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email  text := coalesce(auth.jwt()->>'email','');
  v_result jsonb;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '12000', true);

  WITH params AS (
    SELECT p_event_id AS ev,
           GREATEST(p_max_age_hours,1)                 AS age,
           LEAST(GREATEST(p_min_discount,0.01),0.95)   AS disc,
           GREATEST(p_min_zone_n,3)                    AS minn,
           LEAST(GREATEST(p_limit,1),500)              AS lim,
           GREATEST(p_min_zone_median,0)               AS minmed
  ),
  -- EVO benchmark: keyword-zone median + count from the latest EVO capture.
  evo_latest AS (
    SELECT max(l.captured_at) AS mx
    FROM public.listings_snapshots l, params
    WHERE l.event_id=params.ev AND l.captured_at > now()-(params.age||' hours')::interval
  ),
  evo_zone AS (
    SELECT coalesce(nullif(public.derive_zone_fallback(l.section,l.row),''),'(unzoned)') AS zone,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY l.retail_price)::numeric AS evo_med,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY l.retail_price)::numeric AS evo_q1,
           min(l.retail_price)::numeric AS evo_getin,
           count(*) AS evo_n
    FROM public.listings_snapshots l
    JOIN evo_latest e ON l.captured_at=e.mx, params
    WHERE l.event_id=params.ev AND l.retail_price>0 AND coalesce(l.is_ancillary,false)=false
    GROUP BY 1
  ),
  -- GoTickets inventory: latest capture, seating only.
  gt_latest AS (
    SELECT max(g.captured_at) AS mx
    FROM public.gotickets_listings_snapshots g, params
    WHERE g.tevo_event_id=params.ev AND g.captured_at > now()-(params.age||' hours')::interval
  ),
  gt AS (
    SELECT g.gt_listing_id, g.section, g.row, g.quantity,
           g.all_in_price::numeric AS price, g.in_hand_date,
           coalesce(nullif(public.derive_zone_fallback(g.section,g.row),''),'(unzoned)') AS zone,
           (g.row ~* 'wc|wheelchair|accessible' OR g.section ~* 'accessible') AS is_accessible
    FROM public.gotickets_listings_snapshots g
    JOIN gt_latest gl ON g.captured_at=gl.mx, params
    WHERE g.tevo_event_id=params.ev AND g.all_in_price>0
      AND coalesce(g.general_admission,false)=false
  ),
  deals AS (
    SELECT gt.*, z.evo_med, z.evo_getin, z.evo_n,
           round((gt.price/z.evo_med - 1)*100,0) AS vs_market_pct
    FROM gt JOIN evo_zone z USING (zone), params
    WHERE z.evo_n >= params.minn
      AND z.evo_med >= params.minmed          -- skip cheap zones (median < $50): tiny $ opportunity, mostly noise
      AND gt.price <= (1-params.disc)*z.evo_med
      AND gt.price >= 0.15*z.evo_med
  ),
  -- Event market regime (amalgam 7d MA vs DTE clearing curve) — dumping vs opportunity.
  ev_cat AS (
    SELECT CASE WHEN e.event_type='game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category
    FROM public.events e LEFT JOIN public.performer_metadata pm ON pm.performer_id=e.primary_performer_id, params
    WHERE e.id=params.ev
  ),
  daily AS (
    SELECT d.snapshot_date, d.amalgam_median,
           row_number() OVER (ORDER BY d.snapshot_date DESC,
             CASE d.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC) AS rn
    FROM public.event_listing_snapshot_daily d, params
    WHERE d.event_id=params.ev AND d.amalgam_median IS NOT NULL
  ),
  ev_date AS (
    SELECT sgc.sg_datetime_utc::date AS d, sgc.sg_event_name AS nm
    FROM public.sg_events_canonical sgc, params
    WHERE sgc.tevo_event_id=params.ev AND sgc.sg_datetime_utc IS NOT NULL LIMIT 1
  ),
  regime AS (
    SELECT (SELECT category FROM ev_cat) AS category,
      (SELECT amalgam_median FROM daily WHERE rn=1) AS cur_med,
      (SELECT avg(amalgam_median) FROM daily WHERE rn<=21) AS ma7,
      (SELECT amalgam_median FROM daily WHERE rn=22) AS med_7d_ago,
      ((SELECT d FROM ev_date)-(SELECT snapshot_date FROM daily WHERE rn=1)) AS dte_now,
      ((SELECT d FROM ev_date)-(SELECT snapshot_date FROM daily WHERE rn=22)) AS dte_7d_ago
  ),
  regime2 AS (
    SELECT r.*,
      cn.level_index AS curve_now, cw.level_index AS curve_7d,
      CASE WHEN r.med_7d_ago>0 THEN round((r.cur_med/r.med_7d_ago-1)*100,1) END AS actual_7d_pct,
      CASE WHEN cw.level_index>0 THEN round((cn.level_index/cw.level_index-1)*100,1) END AS expected_7d_pct
    FROM regime r
    LEFT JOIN public.clearing_dte_curve cn ON cn.category=r.category AND cn.dte_bucket=public.price_dte_bucket(r.dte_now::int)
    LEFT JOIN public.clearing_dte_curve cw ON cw.category=r.category AND cw.dte_bucket=public.price_dte_bucket(r.dte_7d_ago::int)
  ),
  regime3 AS (
    SELECT r.*, round(coalesce(r.actual_7d_pct,0)-coalesce(r.expected_7d_pct,0),1) AS excess_pct,
      CASE
        WHEN r.actual_7d_pct IS NULL THEN 'UNKNOWN'
        WHEN (coalesce(r.actual_7d_pct,0)-coalesce(r.expected_7d_pct,0))<=-6 THEN 'DUMPING'
        WHEN (coalesce(r.actual_7d_pct,0)-coalesce(r.expected_7d_pct,0))<=-2 THEN 'SOFTENING'
        WHEN (coalesce(r.actual_7d_pct,0)-coalesce(r.expected_7d_pct,0))>=4  THEN 'RISING'
        ELSE 'STABLE' END AS regime
    FROM regime2 r
  )
  SELECT jsonb_build_object(
    'event_id', p_event_id,
    'event_name', (SELECT nm FROM ev_date),
    'generated_at', now(),
    'benchmark', 'EVO zone median (derive_zone_fallback)',
    'params', jsonb_build_object('max_age_hours',p_max_age_hours,'min_discount',p_min_discount,
                                 'min_zone_n',p_min_zone_n,'min_zone_median',p_min_zone_median),
    'market', (SELECT jsonb_build_object(
        'category',category,'days_to_event',dte_now,'regime',regime,
        'excess_pct',excess_pct,'actual_7d_pct',actual_7d_pct,'expected_7d_pct',expected_7d_pct) FROM regime3),
    'gt_captured_at', (SELECT mx FROM gt_latest),
    'evo_captured_at', (SELECT mx FROM evo_latest),
    'n_deals', (SELECT count(*) FROM deals),
    'deals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'gt_listing_id', d.gt_listing_id, 'zone', d.zone, 'section', d.section, 'row', d."row",
        'quantity', d.quantity, 'gt_price', round(d.price,2), 'market_median', round(d.evo_med,2),
        'market_getin', round(d.evo_getin,2), 'market_n', d.evo_n, 'vs_market_pct', d.vs_market_pct,
        'in_hand_date', d.in_hand_date, 'is_accessible', d.is_accessible,
        'verdict', CASE
          WHEN (SELECT regime FROM regime3) IN ('DUMPING','SOFTENING') THEN 'CAUTION'
          WHEN (SELECT regime FROM regime3) IN ('STABLE','RISING')      THEN 'OPPORTUNITY'
          ELSE 'REVIEW' END
      ) ORDER BY d.vs_market_pct ASC)
      FROM (SELECT * FROM deals ORDER BY vs_market_pct ASC LIMIT (SELECT lim FROM params)) d), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_gotickets_deals(bigint,int,numeric,int,int,numeric) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_gotickets_deals(bigint,int,numeric,int,int,numeric) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_gotickets_deals(bigint,int,numeric,int,int,numeric) TO authenticated, service_role;

COMMENT ON FUNCTION public.get_gotickets_deals(bigint,int,numeric,int,int,numeric) IS
  'D0 DEALS header view. Cross-market GoTickets arbitrage: GoTickets is the only buyable inventory surfaced; EVO zone median (derive_zone_fallback common key) is the benchmark. Deal = GT all_in_price <= (1-min_discount)×EVO zone median (zone needs >= min_zone_n EVO listings). Amalgam 7d-MA/DTE-curve regime tags each deal OPPORTUNITY vs CAUTION (falling knife). Accessible rows returned + flagged. Email-gated SECDEF, authenticated-only. Mig 20260811203000.';
