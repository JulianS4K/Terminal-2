-- Migration 20260811290000 · lane:D0 (author) → applier (apply)
--   writes: gotickets_deals_feed [+cols regime, dte_now, degr_excess_pct, degr_factor,
--            est_net_resale_raw, net_profit_pct_raw, win_prob_raw],
--           scan_gotickets_deals(...) [fn — DROP old 8-arg + CREATE 13-arg],
--           get_deals_feed(...) [fn replace — expose the new degradation fields]
--   reads: + event_listing_snapshot_daily (amalgam_median), clearing_dte_curve, price_dte_bucket
--   pre: mig 20260811280000 (performant scanner — the model this extends),
--        20260708180040 (clearing_dte_curve + price_dte_bucket)
--   auth: scanner service_role-guarded SECDEF · reader email-gated @s4kent.com SECDEF
--
-- WHY (operator-directed 2026-08-11: "it should also factor in event price degradation,
-- factor in [a] 14-day moving average as [an] indicator to project price degradation till
-- time to event"). Operator design answers: (basis) ADJUST — use the event's own trend as a
-- DEVIATION from the category clearing curve, not a replacement; (mode) test BOTH filter
-- changes on the next polls — the adjusted-win refilter runs live, the hard DUMPING gate is a
-- flippable param so successive poll windows can be A/B-compared.
--
-- WHAT. The live scanner already projects each past cleared sale to EVENT DAY via the
-- CATEGORY clearing_dte_curve (a generic average). That misses whether THIS event is bleeding
-- value faster (or firmer) than the category norm. This adds a per-event degradation factor:
--
--   * 14-DAY MA (event's own amalgam_median daily series, slots collapsed to one median/day):
--       actual_pct   = ma(days 1..14) / ma(days 15..28) - 1        -- realized MA-over-MA move
--       expected_pct = curve[dte_now] / curve[dte_now+14] - 1      -- category-expected move
--       excess_pct   = actual_pct - expected_pct                   -- event's deviation FROM curve
--     excess<0 = event dumping FASTER than the category curve predicts (falling knife).
--   * PROJECT FORWARD to event day (now → DTE 0), persist the excess RATE damped + clamped:
--       degr_factor  = 1 + clamp( (excess_pct/14) * dte_now * damp,  floor, ceil )
--     (damp 0.5 — trends mean-revert; floor -25% / ceil +15% — bound runaway extrapolation.)
--   * APPLY: est_net_resale, net_profit_pct, win_prob are recomputed on the DEGRADED comps
--     (each event-day comp × degr_factor). The realized-median (category curve) stays the base;
--     degr_factor is the event-specific deviation ON TOP — no double-count. The RAW (pre-degrade)
--     values are retained in *_raw columns so each poll shows the size of the haircut.
--   * REGIME label from excess_pct (14d-scaled: <=-8 DUMPING · <=-3 SOFTENING · >=+5 RISING ·
--     else STABLE · UNKNOWN when <14d of history). Insufficient history ⇒ factor=1 (no-op; the
--     scanner behaves exactly as mig 280000 for events without a daily series).
--   * REFILTER (live, Option A): a deal must clear p_min_win_prob on the ADJUSTED win — so a
--     falling knife whose degraded win falls below the floor drops out organically.
--   * GATE (Option C, p_dumping_gate — default false): when true, also suppress any DUMPING deal
--     outright. The JSONB return carries per-poll diagnostics (raw-pass / adj-pass / dumping /
--     gated counts) so the effect of BOTH filters is visible without polluting the feed.
--
-- New params appended + all defaulted ⇒ the cascade's `scan_gotickets_deals(30)` binding is
-- unchanged. Must DROP the 8-arg overload first (added defaulted params would otherwise make
-- `scan_gotickets_deals(30)` ambiguous between the two).
--
-- ROLLBACK: DROP FUNCTION public.scan_gotickets_deals(integer,numeric,integer,numeric,numeric,
--   numeric,integer,numeric,integer,numeric,numeric,numeric,boolean); re-apply mig 20260811280000
--   (restores the 8-arg scanner). The added feed columns are nullable + additive; leaving them is
--   harmless, or DROP COLUMN each. Re-apply mig 20260811280000's get_deals_feed to revert reader.

-- 1. Additive feed columns (degradation transparency). All nullable; existing rows backfill NULL.
ALTER TABLE public.gotickets_deals_feed
  ADD COLUMN IF NOT EXISTS regime             text,
  ADD COLUMN IF NOT EXISTS dte_now            integer,
  ADD COLUMN IF NOT EXISTS degr_excess_pct    numeric,
  ADD COLUMN IF NOT EXISTS degr_factor        numeric,
  ADD COLUMN IF NOT EXISTS est_net_resale_raw numeric,
  ADD COLUMN IF NOT EXISTS net_profit_pct_raw integer,
  ADD COLUMN IF NOT EXISTS win_prob_raw       numeric;

COMMENT ON COLUMN public.gotickets_deals_feed.regime IS
  'Event 14d-MA price regime vs category clearing curve: DUMPING/SOFTENING/STABLE/RISING/UNKNOWN. D0 mig 20260811290000.';
COMMENT ON COLUMN public.gotickets_deals_feed.dte_now IS
  'Days to event at scan time (event_date - today UTC). D0 mig 20260811290000.';
COMMENT ON COLUMN public.gotickets_deals_feed.degr_excess_pct IS
  'Event 14d-MA move minus category-curve-expected move (%). Negative = dumping faster than the curve. D0 mig 20260811290000.';
COMMENT ON COLUMN public.gotickets_deals_feed.degr_factor IS
  'Forward degradation multiplier applied to the event-day resale (1.0 = no event-specific adjustment). D0 mig 20260811290000.';
COMMENT ON COLUMN public.gotickets_deals_feed.est_net_resale_raw IS
  'est_net_resale BEFORE the event-specific degradation factor (category-curve only). D0 mig 20260811290000.';
COMMENT ON COLUMN public.gotickets_deals_feed.net_profit_pct_raw IS
  'net_profit_pct BEFORE the event-specific degradation factor. D0 mig 20260811290000.';
COMMENT ON COLUMN public.gotickets_deals_feed.win_prob_raw IS
  'win_prob BEFORE the event-specific degradation factor. D0 mig 20260811290000.';

-- 2. Scanner — DROP the 8-arg overload, CREATE the degradation-aware 13-arg form.
DROP FUNCTION IF EXISTS public.scan_gotickets_deals(integer,numeric,integer,numeric,numeric,numeric,integer,numeric);

CREATE OR REPLACE FUNCTION public.scan_gotickets_deals(
  p_max_events         integer DEFAULT 20,
  p_z_threshold        numeric DEFAULT 3.5,
  p_min_section_n      integer DEFAULT 5,
  p_min_section_median numeric DEFAULT 50,
  p_min_roi            numeric DEFAULT 0.15,
  p_seller_fee         numeric DEFAULT NULL::numeric,
  p_min_realized_n     integer DEFAULT 8,
  p_min_win_prob       numeric DEFAULT 0.70,
  p_degr_ma_days       integer DEFAULT 14,
  p_degr_damp          numeric DEFAULT 0.5,
  p_degr_floor         numeric DEFAULT -0.25,
  p_degr_ceil          numeric DEFAULT 0.15,
  p_dumping_gate       boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_new int := 0; v_gone int := 0; v_events int := 0;
  v_raw_pass int := 0; v_adj_pass int := 0; v_dumping int := 0; v_gated int := 0;
  v_z    numeric := GREATEST(p_z_threshold, 0.1);
  v_roi  numeric := GREATEST(p_min_roi, 0);
  v_days int     := GREATEST(coalesce(p_degr_ma_days,14), 3);
  v_damp numeric := GREATEST(coalesce(p_degr_damp,0.5), 0);
  v_flr  numeric := coalesce(p_degr_floor,-0.25);
  v_ceil numeric := coalesce(p_degr_ceil,0.15);
  v_fee  numeric := coalesce(p_seller_fee,
                    (SELECT seller_fee_pct FROM public.order_fee_schedule
                      WHERE source='sg_seller' ORDER BY effective_from DESC LIMIT 1), 0.10);
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '50000', true);

  CREATE TEMP TABLE _cand ON COMMIT DROP AS
    SELECT c.ev, c.cap
    FROM (
      SELECT g.tevo_event_id AS ev, max(g.captured_at) AS cap
      FROM public.gotickets_listings_snapshots g
      WHERE g.captured_at > now() - interval '4 hours' AND g.tevo_event_id IS NOT NULL
      GROUP BY g.tevo_event_id
    ) c
    LEFT JOIN public.gotickets_deals_scan_state s ON s.tevo_event_id = c.ev
    WHERE c.cap > coalesce(s.last_gt_cap, 'epoch'::timestamptz)
    ORDER BY c.cap DESC
    LIMIT GREATEST(p_max_events, 1);

  SELECT count(*) INTO v_events FROM _cand;
  IF v_events = 0 THEN
    RETURN jsonb_build_object('scanned_events',0,'new_deals',0,'gone',0,'at',now());
  END IF;

  -- Every candidate row scored (NO win filter yet) → temp, so the raw/adjusted refilter and
  -- the dumping gate can be counted for per-poll diagnostics before the feed insert.
  CREATE TEMP TABLE _scored ON COMMIT DROP AS
  WITH gt AS (
    SELECT g.tevo_event_id AS ev, g.gt_event_id AS gt_event_id, g.gt_listing_id, btrim(g.section) AS section, g.row, g.quantity,
           g.all_in_price::numeric AS price, g.in_hand_date, c.cap AS gt_cap, g.notes,
           (g.row ~* 'wc|wheelchair|accessible' OR g.section ~* 'accessible') AS is_accessible
    FROM public.gotickets_listings_snapshots g
    JOIN _cand c ON c.ev = g.tevo_event_id AND g.captured_at = c.cap
    WHERE g.all_in_price > 0 AND coalesce(g.general_admission,false)=false AND g.section IS NOT NULL
  ),
  ss AS (
    SELECT ev, section, count(*) AS n,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY price)::numeric AS med,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY price)::numeric AS q1,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY price)::numeric AS q3
    FROM gt GROUP BY ev, section
  ),
  sm AS (
    SELECT g.ev, g.section, percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(g.price - s.med))::numeric AS madv
    FROM gt g JOIN ss s USING (ev, section) GROUP BY g.ev, g.section
  ),
  emeta AS (
    SELECT e.id AS ev, e.venue_id, sgc.sg_event_name AS nm, sgc.sg_datetime_utc::date AS dt,
           e.primary_performer_id AS pid,
           (EXTRACT(dow FROM sgc.sg_datetime_utc)::int IN (0,5,6)) AS is_weekend,
           CASE WHEN e.event_type='game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category
    FROM public.events e
    LEFT JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = e.id
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    WHERE e.id IN (SELECT ev FROM _cand)
  ),
  -- ── Event-specific 14d-MA degradation (excess over the category clearing curve) ──
  dtrend_daily AS (   -- collapse intraday slots to one amalgam median per date
    SELECT d.event_id AS ev, d.snapshot_date, avg(d.amalgam_median) AS med
    FROM public.event_listing_snapshot_daily d
    WHERE d.event_id IN (SELECT ev FROM _cand) AND d.amalgam_median IS NOT NULL
    GROUP BY d.event_id, d.snapshot_date
  ),
  dtrend_ranked AS (
    SELECT ev, med, row_number() OVER (PARTITION BY ev ORDER BY snapshot_date DESC) AS rn
    FROM dtrend_daily
  ),
  dtrend AS (
    SELECT ev,
           avg(med) FILTER (WHERE rn BETWEEN 1 AND v_days)                 AS ma_now,
           avg(med) FILTER (WHERE rn BETWEEN v_days+1 AND 2*v_days)        AS ma_prev,
           count(*) FILTER (WHERE rn BETWEEN 1 AND v_days)                 AS n_now,
           count(*) FILTER (WHERE rn BETWEEN v_days+1 AND 2*v_days)        AS n_prev
    FROM dtrend_ranked GROUP BY ev
  ),
  evtrend AS (
    SELECT em.ev,
           GREATEST((em.dt - (now() AT TIME ZONE 'utc')::date), 0)::int AS dte_now,
           t.n_now, t.n_prev,
           -- actual event MA-over-MA move vs category-curve-expected move over the same window
           CASE WHEN t.ma_prev > 0 THEN (t.ma_now/t.ma_prev - 1)*100 END
           - coalesce(round((cn.level_index/nullif(cp.level_index,0) - 1)*100, 1), 0) AS excess_pct,
           (t.n_now >= v_days AND t.n_prev >= (v_days/2) AND t.ma_prev > 0)           AS has_hist
    FROM emeta em
    LEFT JOIN dtrend t ON t.ev = em.ev
    LEFT JOIN public.clearing_dte_curve cn
      ON cn.category = em.category
     AND cn.dte_bucket = public.price_dte_bucket(GREATEST((em.dt-(now() AT TIME ZONE 'utc')::date),0)::int)
    LEFT JOIN public.clearing_dte_curve cp
      ON cp.category = em.category
     AND cp.dte_bucket = public.price_dte_bucket((GREATEST((em.dt-(now() AT TIME ZONE 'utc')::date),0) + v_days)::int)
  ),
  evfac AS (   -- forward degradation multiplier + regime label per event
    SELECT et.ev, et.dte_now,
           CASE WHEN et.has_hist THEN round(et.excess_pct, 1) END AS excess_pct,
           CASE WHEN et.has_hist
                THEN round(1 + GREATEST(LEAST( (et.excess_pct/v_days) * et.dte_now * v_damp / 100.0, v_ceil), v_flr), 4)
                ELSE 1.0 END AS degr_factor,
           CASE WHEN NOT et.has_hist THEN 'UNKNOWN'
                WHEN et.excess_pct <= -8 THEN 'DUMPING'
                WHEN et.excess_pct <= -3 THEN 'SOFTENING'
                WHEN et.excess_pct >=  5 THEN 'RISING'
                ELSE 'STABLE' END AS regime
    FROM evtrend et
  ),
  gtz AS (
    SELECT gt.*, em.nm, em.dt, em.pid, em.venue_id, em.category, em.is_weekend,
           public.gt_curated_zone_id(em.pid, em.venue_id, gt.section) AS zone_id
    FROM gt JOIN emeta em ON em.ev = gt.ev
  ),
  outl AS (
    SELECT g.ev, g.gt_event_id, g.gt_listing_id, g.nm AS event_name, g.dt AS event_date,
           g.pid, g.venue_id, g.category, g.is_weekend, g.zone_id,
           g.section, g.row, g.quantity, g.price, g.in_hand_date, g.gt_cap,
           g.is_accessible, g.notes,
           s.med AS section_median, s.n AS section_n,
           ef.dte_now, ef.excess_pct, ef.degr_factor, ef.regime,
           CASE WHEN m.madv > 0 THEN round(0.6745*(g.price - s.med)/m.madv, 2) END AS mod_z,
           round((g.price/s.med - 1)*100, 0)::int AS vs_section_pct
    FROM gtz g
    JOIN ss s USING (ev, section)
    JOIN sm m USING (ev, section)
    LEFT JOIN evfac ef ON ef.ev = g.ev
    WHERE g.zone_id IS NOT NULL
      AND s.n >= GREATEST(p_min_section_n,3)
      AND s.med >= GREATEST(p_min_section_median,0)
      AND (
            (m.madv > 0 AND 0.6745*(g.price - s.med)/m.madv <= -v_z)
         OR (m.madv = 0 AND g.price < s.q1 - 1.5*(s.q3 - s.q1))
          )
  ),
  scored AS (
    SELECT o.*,
           cur.cur_n, cur.cur_median, cur.cur_win_raw, cur.cur_win_adj,
           b.n_sales AS hist_n, b.median_ed AS hist_median,
           (SELECT avg( (px * (1 - v_fee) >= (1 + v_roi) * o.price)::int )::numeric
              FROM unnest(b.prices_ed) px) AS hist_win_raw,
           (SELECT avg( (px * coalesce(o.degr_factor,1) * (1 - v_fee) >= (1 + v_roi) * o.price)::int )::numeric
              FROM unnest(b.prices_ed) px) AS hist_win_adj
    FROM outl o
    LEFT JOIN LATERAL (
      SELECT count(*) AS cur_n,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY px_ed)::numeric AS cur_median,
             avg( (px_ed * (1 - v_fee) >= (1 + v_roi) * o.price)::int )::numeric AS cur_win_raw,
             avg( (px_ed * coalesce(o.degr_factor,1) * (1 - v_fee) >= (1 + v_roi) * o.price)::int )::numeric AS cur_win_adj
      FROM (
        SELECT s.px * COALESCE(c0.level_index / NULLIF(cs.level_index,0), 1) AS px_ed
        FROM (
          SELECT sgs.broadcast_price::numeric AS px, sgs.section AS section,
                 GREATEST((o.event_date - sgs.sale_at_utc::date),0) AS sdte
          FROM public.seatgeek_sales_snapshots sgs
          WHERE sgs.tevo_event_id = o.ev AND sgs.broadcast_price > 0
            AND sgs.sale_at_utc > now() - interval '30 days'
          UNION ALL
          SELECT sd.price::numeric, sd.section,
                 GREATEST((o.event_date - sd.sale_timestamp::date),0)
          FROM public.seatdata_sales_snapshots sd
          WHERE sd.tevo_event_id = o.ev AND sd.price > 0
            AND sd.sale_timestamp > now() - interval '30 days'
        ) s
        LEFT JOIN public.clearing_dte_curve cs ON cs.category = o.category AND cs.dte_bucket = public.price_dte_bucket(s.sdte)
        LEFT JOIN public.clearing_dte_curve c0 ON c0.category = o.category AND c0.dte_bucket = public.price_dte_bucket(0)
        WHERE EXISTS (
          SELECT 1 FROM public.performer_zone_rules pzr
          WHERE pzr.zone_id = o.zone_id
            AND public.section_in_range(coalesce((regexp_match(s.section,'(\d{2,4})'))[1], s.section),
                                        pzr.section_from, pzr.section_to)
        )
      ) z
    ) cur ON true
    LEFT JOIN public.section_sale_baseline_cz b
      ON b.performer_id = o.pid AND b.zone_id = o.zone_id AND b.is_weekend = o.is_weekend
  ),
  chosen AS (
    SELECT s.*,
      CASE WHEN s.cur_n >= p_min_realized_n THEN 'realized'
           WHEN s.hist_n >= p_min_realized_n THEN 'historic_realized' END AS basis,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_n        ELSE s.hist_n END       AS r_n,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_median   ELSE s.hist_median END  AS r_median,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_win_raw  ELSE s.hist_win_raw END AS r_win_raw,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_win_adj  ELSE s.hist_win_adj END AS r_win_adj
    FROM scored s
  )
  SELECT c.ev, c.gt_event_id, c.gt_listing_id, c.event_name, c.event_date,
         coalesce((SELECT name FROM public.performer_zones WHERE id = c.zone_id), '(zone '||c.zone_id||')') AS zone,
         c.section, c.row, c.quantity, round(c.price,2) AS gt_price,
         round(c.section_median,2) AS section_median, c.section_n, c.mod_z, c.vs_section_pct,
         round(c.r_median,2) AS realized_median, c.r_n AS realized_n, c.basis AS resale_basis,
         v_fee AS seller_fee_pct,
         c.dte_now, c.excess_pct AS degr_excess_pct, coalesce(c.degr_factor,1) AS degr_factor, c.regime,
         -- adjusted (event-degradation applied) — the live economics
         round(c.r_median * coalesce(c.degr_factor,1) * (1 - v_fee), 2) AS est_net_resale,
         round((c.r_median * coalesce(c.degr_factor,1) * (1 - v_fee) - c.price)/c.price*100, 0)::int AS net_profit_pct,
         round(c.r_win_adj, 3) AS win_prob,
         -- raw (category-curve only) — for transparency / A-B
         round(c.r_median * (1 - v_fee), 2) AS est_net_resale_raw,
         round((c.r_median * (1 - v_fee) - c.price)/c.price*100, 0)::int AS net_profit_pct_raw,
         round(c.r_win_raw, 3) AS win_prob_raw,
         CASE
           WHEN c.notes ~* 'obstruct|limited|partial|restricted|obov|side view|behind|pole|no view' THEN 'low'
           WHEN c.basis='realized' AND c.r_n >= 20 THEN 'high'
           WHEN c.basis='realized' THEN 'med'
           WHEN c.basis='historic_realized' AND c.r_n >= 30 THEN 'med'
           ELSE 'low' END AS confidence,
         c.is_accessible, c.in_hand_date, c.gt_cap AS gt_captured_at
  FROM chosen c
  WHERE c.basis IS NOT NULL;

  -- Per-poll diagnostics: how each filter reshapes the candidate set.
  SELECT
    count(*) FILTER (WHERE realized_n >= p_min_realized_n AND win_prob_raw >= p_min_win_prob),
    count(*) FILTER (WHERE realized_n >= p_min_realized_n AND win_prob     >= p_min_win_prob),
    count(*) FILTER (WHERE realized_n >= p_min_realized_n AND win_prob     >= p_min_win_prob AND regime='DUMPING')
  INTO v_raw_pass, v_adj_pass, v_dumping
  FROM _scored;

  -- Surviving deals = clear the ADJUSTED win floor (Option A); optionally drop DUMPING (Option C).
  CREATE TEMP TABLE _deals ON COMMIT DROP AS
    SELECT * FROM _scored
    WHERE realized_n >= p_min_realized_n
      AND win_prob   >= p_min_win_prob
      AND (NOT p_dumping_gate OR coalesce(regime,'UNKNOWN') <> 'DUMPING');

  v_gated := CASE WHEN p_dumping_gate THEN v_dumping ELSE 0 END;

  UPDATE public.gotickets_deals_feed f
     SET gone_at = now()
   WHERE f.tevo_event_id IN (SELECT ev FROM _cand)
     AND f.gone_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM _deals d WHERE d.ev=f.tevo_event_id AND d.gt_listing_id=f.gt_listing_id);
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  WITH ins AS (
    INSERT INTO public.gotickets_deals_feed AS f
      (tevo_event_id, gt_event_id, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct,
       dte_now, degr_excess_pct, degr_factor, regime,
       est_net_resale, net_profit_pct, win_prob,
       est_net_resale_raw, net_profit_pct_raw, win_prob_raw, confidence,
       is_accessible, in_hand_date, gt_captured_at, first_seen_at, last_seen_at, gone_at)
    SELECT ev, gt_event_id, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct,
       dte_now, degr_excess_pct, degr_factor, regime,
       est_net_resale, net_profit_pct, win_prob,
       est_net_resale_raw, net_profit_pct_raw, win_prob_raw, confidence,
       is_accessible, in_hand_date, gt_captured_at, now(), now(), NULL
    FROM _deals
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      gt_event_id=excluded.gt_event_id,
      gt_price=excluded.gt_price, section_median=excluded.section_median, section_n=excluded.section_n,
      mod_z=excluded.mod_z, vs_section_pct=excluded.vs_section_pct,
      realized_median=excluded.realized_median, realized_n=excluded.realized_n, resale_basis=excluded.resale_basis,
      seller_fee_pct=excluded.seller_fee_pct,
      dte_now=excluded.dte_now, degr_excess_pct=excluded.degr_excess_pct,
      degr_factor=excluded.degr_factor, regime=excluded.regime,
      est_net_resale=excluded.est_net_resale, net_profit_pct=excluded.net_profit_pct, win_prob=excluded.win_prob,
      est_net_resale_raw=excluded.est_net_resale_raw, net_profit_pct_raw=excluded.net_profit_pct_raw,
      win_prob_raw=excluded.win_prob_raw, confidence=excluded.confidence,
      zone=excluded.zone, section=excluded.section, "row"=excluded."row", quantity=excluded.quantity,
      is_accessible=excluded.is_accessible, in_hand_date=excluded.in_hand_date,
      gt_captured_at=excluded.gt_captured_at, last_seen_at=now(), gone_at=NULL
    RETURNING (xmax = 0) AS inserted
  )
  SELECT count(*) FILTER (WHERE inserted) INTO v_new FROM ins;

  INSERT INTO public.gotickets_deals_scan_state (tevo_event_id, last_gt_cap, last_scanned_at, deals_found)
  SELECT c.ev, c.cap, now(), (SELECT count(*) FROM _deals d WHERE d.ev=c.ev)
  FROM _cand c
  ON CONFLICT (tevo_event_id) DO UPDATE SET
    last_gt_cap=excluded.last_gt_cap, last_scanned_at=now(), deals_found=excluded.deals_found;

  RETURN jsonb_build_object(
    'scanned_events', v_events, 'new_deals', v_new, 'gone', v_gone, 'seller_fee', v_fee,
    'degr', jsonb_build_object(
      'ma_days', v_days, 'damp', v_damp, 'floor', v_flr, 'ceil', v_ceil, 'dumping_gate', p_dumping_gate,
      'raw_pass', v_raw_pass, 'adj_pass', v_adj_pass, 'dumping_in_adj_pass', v_dumping, 'gated', v_gated),
    'at', now());
END;
$function$;

REVOKE ALL ON FUNCTION public.scan_gotickets_deals(integer,numeric,integer,numeric,numeric,numeric,integer,numeric,integer,numeric,numeric,numeric,boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.scan_gotickets_deals(integer,numeric,integer,numeric,numeric,numeric,integer,numeric,integer,numeric,numeric,numeric,boolean) TO service_role;
COMMENT ON FUNCTION public.scan_gotickets_deals(integer,numeric,integer,numeric,numeric,numeric,integer,numeric,integer,numeric,numeric,numeric,boolean) IS
  'GoTickets deal scanner + EVENT-SPECIFIC DEGRADATION. Extends mig 20260811280000: a 14d-MA of the event amalgam_median vs the category clearing_dte_curve gives an excess-over-curve regime (DUMPING/SOFTENING/STABLE/RISING); that excess is projected forward to event day (damped+clamped) as degr_factor, applied to est_net_resale/net_profit/win_prob. Live refilter uses the ADJUSTED win (Option A); p_dumping_gate hard-suppresses DUMPING (Option C, default off). *_raw columns retain pre-degradation values; JSONB return carries raw/adj/dumping/gated counts. D0 mig 20260811290000.';

-- 3. Reader — expose the degradation fields on each deal. Signature unchanged (CREATE OR REPLACE).
CREATE OR REPLACE FUNCTION public.get_deals_feed(p_limit integer DEFAULT 100, p_since timestamp with time zone DEFAULT NULL::timestamp with time zone, p_min_roi numeric DEFAULT NULL::numeric, p_min_confidence text DEFAULT NULL::text, p_include_gone boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_email  text := coalesce(auth.jwt()->>'email','');
  v_minroi int := CASE WHEN p_min_roi IS NULL THEN NULL ELSE round(GREATEST(p_min_roi,0)*100)::int END;
  v_result jsonb;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: %', v_email USING ERRCODE='42501';
  END IF;

  SELECT jsonb_build_object(
    'generated_at', now(),
    'active_deals', (SELECT count(*) FROM public.gotickets_deals_feed WHERE gone_at IS NULL),
    'last_scan_at', (SELECT max(last_scanned_at) FROM public.gotickets_deals_scan_state),
    'deals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'tevo_event_id', tevo_event_id, 'gt_event_id', gt_event_id, 'gt_listing_id', gt_listing_id,
        'event_name', event_name, 'event_date', event_date,
        'zone', zone, 'section', section, 'row', "row", 'quantity', quantity,
        'gt_price', gt_price, 'section_median', section_median,
        'realized_median', realized_median, 'realized_n', realized_n,
        'est_net_resale', est_net_resale, 'net_profit_pct', net_profit_pct, 'win_prob', win_prob,
        'est_net_resale_raw', est_net_resale_raw, 'net_profit_pct_raw', net_profit_pct_raw, 'win_prob_raw', win_prob_raw,
        'regime', regime, 'dte_now', dte_now, 'degr_excess_pct', degr_excess_pct, 'degr_factor', degr_factor,
        'seller_fee_pct', seller_fee_pct, 'resale_basis', resale_basis, 'confidence', confidence,
        'mod_z', mod_z, 'is_accessible', is_accessible, 'in_hand_date', in_hand_date,
        'first_seen_at', first_seen_at, 'last_seen_at', last_seen_at, 'gone_at', gone_at
      ) ORDER BY first_seen_at DESC, win_prob DESC)
      FROM (
        SELECT * FROM public.gotickets_deals_feed f
        WHERE (p_include_gone OR f.gone_at IS NULL)
          AND (p_since IS NULL OR f.first_seen_at > p_since)
          AND (v_minroi IS NULL OR f.net_profit_pct >= v_minroi)
          AND (p_min_confidence IS NULL
               OR (p_min_confidence='high' AND f.confidence='high')
               OR (p_min_confidence='med'  AND f.confidence IN ('high','med')))
        ORDER BY f.first_seen_at DESC, f.win_prob DESC
        LIMIT LEAST(GREATEST(p_limit,1),500)
      ) q), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;
