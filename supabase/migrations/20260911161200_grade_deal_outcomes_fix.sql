-- ============================================================================
-- Migration 20260911161200 — grade_deal_outcomes(): fix ambiguous column in the chosen CTE
--
-- Lane:     D0 (deals surface)
-- Touches:  grade_deal_outcomes(int,int,int,numeric,numeric,int) (CREATE OR REPLACE, same signature)
-- Pre-reqs: 20260911160400
--
-- Already applied to prod · via MCP 2026-09-11 (fix to the just-applied label).
--
-- First run of grade_deal_outcomes(300) failed with 42702 "column reference zone_n is
-- ambiguous": the `chosen` CTE selected `coalesce(a.zone_n,0) AS zone_n … a.*`, so the
-- aggregate's own zone_n / sec_n / ev_n (and ev, gt_listing_id) were emitted twice and the
-- downstream CASE could not resolve them. Body below is identical to 160400's except the
-- CTE now lists the aggregate columns explicitly. No schema change.
-- ROLLBACK: re-apply the 160400 body (which re-introduces the bug — do not).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.grade_deal_outcomes(
  p_max           int     DEFAULT 300,
  p_window_days   int     DEFAULT 4,
  p_min_comps     int     DEFAULT 3,
  p_roi_target    numeric DEFAULT 0.15,
  p_fee           numeric DEFAULT NULL,
  p_regrade_days  int     DEFAULT 14
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_fee     numeric;
  v_start   timestamptz := clock_timestamp();
  v_cand    int := 0;
  v_written int := 0;
  v_out     jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  -- One bounded set-based pass; the cron budget is 3 min, leave headroom.
  PERFORM set_config('statement_timeout', '170000', true);

  v_fee := coalesce(p_fee,
             (SELECT seller_fee_pct FROM public.order_fee_schedule
               WHERE source = 'sg_seller' ORDER BY effective_from DESC LIMIT 1),
             0.10);

  -- 2a. Candidates: played deals never graded, or graded NO_COMPS recently enough
  --     that late sales could still upgrade them.
  CREATE TEMP TABLE _cand ON COMMIT DROP AS
  SELECT f.tevo_event_id AS ev, f.gt_listing_id, f.event_date, f.section, f.quantity,
         f.gt_price::numeric AS cost, f.first_seen_at, f.gone_at,
         f.win_prob, f.net_profit_pct, f.confidence, f.resale_basis,
         f.realized_n AS pred_realized_n, f.regime, f.mod_z, f.vs_zone_pct,
         f.zone AS zone_name,
         public.gt_curated_zone_id(e.primary_performer_id, e.venue_id, f.section) AS zone_id,
         (regexp_match(f.section, '(\d{1,4})'))[1] AS secnum
  FROM public.gotickets_deals_feed f
  JOIN public.events e ON e.id = f.tevo_event_id
  LEFT JOIN public.gotickets_deal_outcome o
         ON o.tevo_event_id = f.tevo_event_id AND o.gt_listing_id = f.gt_listing_id
  WHERE f.gt_price > 0
    AND f.event_date <= current_date - 1
    AND (o.tevo_event_id IS NULL
         OR (o.outcome = 'NO_COMPS' AND f.event_date >= current_date - p_regrade_days))
  ORDER BY f.event_date DESC, f.first_seen_at
  LIMIT p_max;

  SELECT count(*) INTO v_cand FROM _cand;
  IF v_cand = 0 THEN
    RETURN jsonb_build_object('candidates', 0, 'written', 0, 'fee', v_fee,
                              'elapsed_ms', round(extract(epoch FROM clock_timestamp() - v_start) * 1000));
  END IF;

  -- 2b. Realized pool per event, event-day window, three sources, each deduped
  --     exactly as PROJECT_BIBLE §7 requires (SG 11x duplication).
  CREATE TEMP TABLE _pool ON COMMIT DROP AS
  WITH ev AS (SELECT DISTINCT ev, event_date FROM _cand)
  SELECT ev.ev, 'sg'::text AS src, s.broadcast_price::numeric AS px, s.section
  FROM ev
  JOIN LATERAL (
    SELECT DISTINCT ON (x.sg_sale_id) x.broadcast_price, x.section
    FROM public.seatgeek_sales_snapshots x
    WHERE x.tevo_event_id = ev.ev AND x.broadcast_price > 0
      AND x.sale_at_utc::date BETWEEN ev.event_date - p_window_days AND ev.event_date
    ORDER BY x.sg_sale_id, x.pulled_at DESC
  ) s ON true
  UNION ALL
  SELECT ev.ev, 'sd', s.price::numeric, s.section
  FROM ev
  JOIN LATERAL (
    SELECT DISTINCT ON (x.content_hash) x.price, x.section
    FROM public.seatdata_sales_snapshots x
    WHERE x.tevo_event_id = ev.ev AND x.price > 0
      AND x.sale_timestamp::date BETWEEN ev.event_date - p_window_days AND ev.event_date
    ORDER BY x.content_hash, x.pulled_at DESC
  ) s ON true
  UNION ALL
  SELECT ev.ev, 'crm', c.price_per_ticket::numeric, c.section
  FROM ev
  JOIN public.v_s4kcs_orders c
    ON c.tevo_event_id = ev.ev AND c.price_per_ticket > 0
   AND c.order_status <> 'REJECTED'
   AND (c.purchase_date IS NULL
        OR c.purchase_date BETWEEN ev.event_date - p_window_days AND ev.event_date);

  -- 2c. Tag each (deal, sale) pair with the two match predicates.
  CREATE TEMP TABLE _tag ON COMMIT DROP AS
  SELECT c.ev, c.gt_listing_id, p.src, p.px,
         (c.zone_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.performer_zone_rules pzr
            WHERE pzr.zone_id = c.zone_id
              AND public.section_in_range(
                    coalesce((regexp_match(p.section, '(\d{2,4})'))[1], p.section),
                    pzr.section_from, pzr.section_to)))                       AS in_zone,
         (c.secnum IS NOT NULL
          AND (regexp_match(p.section, '(\d{1,4})'))[1] = c.secnum)          AS same_sec,
         (p.px * (1 - v_fee) >= (1 + p_roi_target) * c.cost)                  AS clears
  FROM _cand c JOIN _pool p ON p.ev = c.ev;

  -- 2d. Per-level aggregates, then pick the finest level that has enough comps.
  CREATE TEMP TABLE _agg ON COMMIT DROP AS
  SELECT ev, gt_listing_id,
    count(*) FILTER (WHERE in_zone)                                            AS zone_n,
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY px) FILTER (WHERE in_zone)    AS zone_med,
    percentile_cont(0.25) WITHIN GROUP (ORDER BY px) FILTER (WHERE in_zone)    AS zone_p25,
    percentile_cont(0.75) WITHIN GROUP (ORDER BY px) FILTER (WHERE in_zone)    AS zone_p75,
    avg(clears::int) FILTER (WHERE in_zone)                                    AS zone_win,
    count(*) FILTER (WHERE in_zone AND src='sg')                               AS zone_sg,
    count(*) FILTER (WHERE in_zone AND src='sd')                               AS zone_sd,
    count(*) FILTER (WHERE in_zone AND src='crm')                              AS zone_crm,
    count(*) FILTER (WHERE same_sec)                                           AS sec_n,
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY px) FILTER (WHERE same_sec)   AS sec_med,
    percentile_cont(0.25) WITHIN GROUP (ORDER BY px) FILTER (WHERE same_sec)   AS sec_p25,
    percentile_cont(0.75) WITHIN GROUP (ORDER BY px) FILTER (WHERE same_sec)   AS sec_p75,
    avg(clears::int) FILTER (WHERE same_sec)                                   AS sec_win,
    count(*) FILTER (WHERE same_sec AND src='sg')                              AS sec_sg,
    count(*) FILTER (WHERE same_sec AND src='sd')                              AS sec_sd,
    count(*) FILTER (WHERE same_sec AND src='crm')                             AS sec_crm,
    count(*)                                                                   AS ev_n,
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY px)                           AS ev_med,
    percentile_cont(0.25) WITHIN GROUP (ORDER BY px)                           AS ev_p25,
    percentile_cont(0.75) WITHIN GROUP (ORDER BY px)                           AS ev_p75,
    avg(clears::int)                                                           AS ev_win,
    count(*) FILTER (WHERE src='sg')                                           AS ev_sg,
    count(*) FILTER (WHERE src='sd')                                           AS ev_sd,
    count(*) FILTER (WHERE src='crm')                                          AS ev_crm
  FROM _tag GROUP BY ev, gt_listing_id;

  WITH chosen AS (
    -- explicit columns: `a.*` would re-emit ev/gt_listing_id/zone_n and make them ambiguous downstream
    SELECT c.*,
      coalesce(a.zone_n,0) AS zone_n, a.zone_med, a.zone_p25, a.zone_p75, a.zone_win,
      coalesce(a.zone_sg,0) AS zone_sg, coalesce(a.zone_sd,0) AS zone_sd, coalesce(a.zone_crm,0) AS zone_crm,
      coalesce(a.sec_n,0) AS sec_n, a.sec_med, a.sec_p25, a.sec_p75, a.sec_win,
      coalesce(a.sec_sg,0) AS sec_sg, coalesce(a.sec_sd,0) AS sec_sd, coalesce(a.sec_crm,0) AS sec_crm,
      coalesce(a.ev_n,0) AS ev_n, a.ev_med, a.ev_p25, a.ev_p75, a.ev_win,
      coalesce(a.ev_sg,0) AS ev_sg, coalesce(a.ev_sd,0) AS ev_sd, coalesce(a.ev_crm,0) AS ev_crm,
      CASE WHEN coalesce(a.zone_n,0) >= p_min_comps THEN 'zone'
           WHEN coalesce(a.sec_n,0)  >= p_min_comps THEN 'section'
           WHEN coalesce(a.ev_n,0)   >= p_min_comps THEN 'event'
           ELSE 'none' END AS lvl
    FROM _cand c LEFT JOIN _agg a ON a.ev = c.ev AND a.gt_listing_id = c.gt_listing_id
  ),
  readout AS (
    SELECT ch.*,
      CASE lvl WHEN 'zone' THEN zone_n WHEN 'section' THEN sec_n WHEN 'event' THEN ev_n ELSE 0 END      AS r_n,
      CASE lvl WHEN 'zone' THEN zone_med WHEN 'section' THEN sec_med WHEN 'event' THEN ev_med END        AS r_med,
      CASE lvl WHEN 'zone' THEN zone_p25 WHEN 'section' THEN sec_p25 WHEN 'event' THEN ev_p25 END        AS r_p25,
      CASE lvl WHEN 'zone' THEN zone_p75 WHEN 'section' THEN sec_p75 WHEN 'event' THEN ev_p75 END        AS r_p75,
      CASE lvl WHEN 'zone' THEN zone_win WHEN 'section' THEN sec_win WHEN 'event' THEN ev_win END        AS r_win,
      CASE lvl WHEN 'zone' THEN zone_sg WHEN 'section' THEN sec_sg WHEN 'event' THEN ev_sg ELSE 0 END    AS r_sg,
      CASE lvl WHEN 'zone' THEN zone_sd WHEN 'section' THEN sec_sd WHEN 'event' THEN ev_sd ELSE 0 END    AS r_sd,
      CASE lvl WHEN 'zone' THEN zone_crm WHEN 'section' THEN sec_crm WHEN 'event' THEN ev_crm ELSE 0 END AS r_crm
    FROM chosen ch
  ),
  ins AS (
    INSERT INTO public.gotickets_deal_outcome AS o (
      tevo_event_id, gt_listing_id, event_date, section, secnum, zone_id, zone_name, quantity, cost, first_seen_at,
      pred_win_prob, pred_net_profit_pct, pred_confidence, pred_resale_basis, pred_realized_n,
      pred_regime, pred_mod_z, pred_vs_zone_pct,
      zone_n, zone_med, sec_n, sec_med, ev_n, ev_med,
      match_level, realized_n, realized_med, realized_p25, realized_p75,
      realized_sg_n, realized_sd_n, realized_crm_n, seller_fee_pct,
      realized_net, realized_roi_pct, realized_win_share, outcome,
      listing_gone_at, hours_alive, gone_before_event,
      graded_at, grade_version, params, updated_at)
    SELECT r.ev, r.gt_listing_id, r.event_date, r.section, r.secnum, r.zone_id, r.zone_name, r.quantity, r.cost, r.first_seen_at,
      r.win_prob, r.net_profit_pct, r.confidence, r.resale_basis, r.pred_realized_n,
      r.regime, r.mod_z, r.vs_zone_pct,
      r.zone_n, round(r.zone_med::numeric,2), r.sec_n, round(r.sec_med::numeric,2), r.ev_n, round(r.ev_med::numeric,2),
      r.lvl, r.r_n, round(r.r_med::numeric,2), round(r.r_p25::numeric,2), round(r.r_p75::numeric,2),
      r.r_sg, r.r_sd, r.r_crm, v_fee,
      round((r.r_med * (1 - v_fee))::numeric, 2),
      round(((r.r_med * (1 - v_fee) - r.cost) / r.cost * 100)::numeric, 1),
      round(r.r_win::numeric, 3),
      CASE WHEN r.lvl = 'none' OR r.r_med IS NULL           THEN 'NO_COMPS'
           WHEN r.r_med * (1 - v_fee) >= (1 + p_roi_target) * r.cost THEN 'WIN'
           WHEN r.r_med * (1 - v_fee) >= r.cost                       THEN 'FLAT'
           ELSE 'LOSS' END,
      r.gone_at,
      round(extract(epoch FROM (coalesce(r.gone_at, r.event_date::timestamptz) - r.first_seen_at)) / 3600.0, 1),
      (r.gone_at IS NOT NULL AND r.gone_at < r.event_date::timestamptz),
      now(), 1,
      jsonb_build_object('window_days', p_window_days, 'min_comps', p_min_comps,
                         'roi_target', p_roi_target, 'fee', v_fee),
      now()
    FROM readout r
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      zone_n = excluded.zone_n, zone_med = excluded.zone_med,
      sec_n = excluded.sec_n, sec_med = excluded.sec_med,
      ev_n = excluded.ev_n, ev_med = excluded.ev_med,
      match_level = excluded.match_level, realized_n = excluded.realized_n,
      realized_med = excluded.realized_med, realized_p25 = excluded.realized_p25, realized_p75 = excluded.realized_p75,
      realized_sg_n = excluded.realized_sg_n, realized_sd_n = excluded.realized_sd_n, realized_crm_n = excluded.realized_crm_n,
      seller_fee_pct = excluded.seller_fee_pct, realized_net = excluded.realized_net,
      realized_roi_pct = excluded.realized_roi_pct, realized_win_share = excluded.realized_win_share,
      outcome = excluded.outcome,
      listing_gone_at = excluded.listing_gone_at, hours_alive = excluded.hours_alive,
      gone_before_event = excluded.gone_before_event,
      graded_at = now(), params = excluded.params, updated_at = now()
    RETURNING outcome, match_level
  )
  SELECT jsonb_build_object(
    'candidates', v_cand,
    'written', coalesce(sum(n) FILTER (WHERE grp = 'o'), 0),
    'by_outcome', jsonb_object_agg(outcome, n) FILTER (WHERE grp = 'o'),
    'by_level',   jsonb_object_agg(match_level, n) FILTER (WHERE grp = 'l')
  ) INTO v_out
  FROM (
    SELECT 'o' grp, outcome, NULL::text match_level, count(*) n FROM ins GROUP BY outcome
    UNION ALL
    SELECT 'l', NULL, match_level, count(*) FROM ins GROUP BY match_level
  ) s;

  v_out := v_out || jsonb_build_object(
    'fee', v_fee,
    'elapsed_ms', round(extract(epoch FROM clock_timestamp() - v_start) * 1000));
  RETURN v_out;
END;
$fn$;
