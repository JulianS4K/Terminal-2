-- Migration 20260811220000 · lane:D0 (author) → applier (apply) · alters:gotickets_deals_feed (realized-sales profit cols) · writes:scan_gotickets_deals(int,numeric,int,numeric,numeric,numeric,int) [fn, replace], get_deals_feed(int,timestamptz,numeric,text,boolean) [fn, replace], get_deal_backtest(int,int) [fn] · reads:gotickets_listings_snapshots,seatgeek_sales_snapshots,order_fee_schedule,sg_events_canonical,events,performer_metadata,clearing_dte_curve,derive_zone_fallback,price_dte_bucket · pre:mig 20260811210000 (feed + scanner) · auth:scanner service_role-guarded SECDEF; readers email-gated (@s4kent.com)
--
-- WHY (operator-directed 2026-08-11 "use existing sale data and historic … we have
-- shit tons of data"). The v3 feed judged profit off GoTickets ASKING prices, which
-- are systematically inflated vs what seats actually clear — measured: of 4 flagged
-- "deals", realized SeatGeek sales made ALL FOUR unprofitable net of fees (Main 229
-- @ $43 clears $36 → -24%; Lower 101 @ $31 clears $24 → -30%; Prem Lower Box 109 @
-- $51 clears $56 → ~break-even after the 10% resale fee). So the deal test is now
-- calibrated on 17.7M realized SeatGeek sales, net of the real resale fee.
--
-- DEAL (three gates, all must pass):
--   GATE 1 — SECTION LOW OUTLIER on GoTickets (unchanged): per (event × section)
--     median+MAD modified z ≤ -threshold (IQR fence fallback), section n≥5, med≥$50.
--   GATE 2 — REALIZED RESALE ANCHOR: the resale reference is the MEDIAN REALIZED
--     SeatGeek sale price for the same event × SECTION NUMBER (the stable key — GT
--     "Lower 127" ↔ SG "lower box 127" both → 127) over the last p_realized_days
--     (default 45d), requiring ≥ p_min_realized_n sales (default 4). No realized
--     comparables ⇒ NOT surfaced (we don't guess). Discounted to event day by the
--     clearing_dte_curve (assumed degradation).
--   GATE 3 — PROBABILISTIC ≥70% odds of a ≥15% net flip (operator: "it's all
--     probability based … make the odds at least 70% of getting a 15% ROI"). Over
--     the realized sales for the (event × section-number), win_prob = fraction whose
--     net proceeds clear the hurdle:  broadcast_price × degrade × (1 − seller_fee)
--     ≥ (1 + p_min_roi) × gt_price. A deal requires win_prob ≥ p_min_win_prob (0.70)
--     over ≥ p_min_realized_n sales (default 8, so the probability is meaningful).
--     seller_fee from order_fee_schedule (default sg_seller 10%); degrade to event
--     day from the clearing curve. est_net_resale / net_profit_pct (median-based) are
--     also stored as the expected-case readout.
--
-- Each deal carries: win_prob (the odds), realized_n (liquidity — how many comparable
-- seats actually sold), and a confidence tag (sample depth, downgraded when the
-- GoTickets note flags obstruction). get_deal_backtest() closes the loop: it
-- re-derives what the model would have flagged from a GT snapshot N days ago and
-- scores it against the realized sales that followed — the empirical win-rate that
-- validates the 70% gate.
--
-- ROLLBACK: DROP FUNCTION get_deal_backtest(int,int); re-apply mig 20260811210000
--   (restores the v3 scanner/reader); the added feed columns are additive (safe to
--   leave) or DROP them.

-- ── 1. Realized-sales profit columns on the feed ─────────────────────────────
ALTER TABLE public.gotickets_deals_feed
  ADD COLUMN IF NOT EXISTS realized_median numeric,
  ADD COLUMN IF NOT EXISTS realized_n      int,
  ADD COLUMN IF NOT EXISTS resale_basis    text,
  ADD COLUMN IF NOT EXISTS seller_fee_pct  numeric,
  ADD COLUMN IF NOT EXISTS est_net_resale  numeric,
  ADD COLUMN IF NOT EXISTS net_profit_pct  int,
  ADD COLUMN IF NOT EXISTS win_prob        numeric,   -- P(realized sale clears the 15% net hurdle)
  ADD COLUMN IF NOT EXISTS confidence      text;

-- ── 2. Scanner v4 — realized-sales anchor, net of fees ───────────────────────
DROP FUNCTION IF EXISTS public.scan_gotickets_deals(int,numeric,int,numeric,numeric);
DROP FUNCTION IF EXISTS public.scan_gotickets_deals(int,numeric,int,numeric,numeric,numeric,int);
CREATE OR REPLACE FUNCTION public.scan_gotickets_deals(
  p_max_events         int     DEFAULT 20,
  p_z_threshold        numeric DEFAULT 3.5,
  p_min_section_n      int     DEFAULT 5,
  p_min_section_median numeric DEFAULT 50,
  p_min_roi            numeric DEFAULT 0.15,
  p_seller_fee         numeric DEFAULT NULL,   -- NULL → look up sg_seller from order_fee_schedule
  p_min_realized_n     int     DEFAULT 8,
  p_min_win_prob       numeric DEFAULT 0.70
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $fn$
DECLARE
  v_new int := 0; v_gone int := 0; v_events int := 0;
  v_z   numeric := GREATEST(p_z_threshold, 0.1);
  v_fee numeric := coalesce(p_seller_fee,
                    (SELECT seller_fee_pct FROM public.order_fee_schedule
                      WHERE source='sg_seller' ORDER BY effective_from DESC LIMIT 1), 0.10);
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '55000', true);

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

  CREATE TEMP TABLE _deals ON COMMIT DROP AS
  WITH gt AS (
    SELECT g.tevo_event_id AS ev, g.gt_listing_id, btrim(g.section) AS section, g.row, g.quantity,
           g.all_in_price::numeric AS price, g.in_hand_date, c.cap AS gt_cap, g.notes,
           (regexp_match(g.section,'(\d{2,4})'))[1]::int AS secnum,
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
  edate AS (
    SELECT sgc.tevo_event_id AS ev, sgc.sg_event_name AS nm, sgc.sg_datetime_utc::date AS dt
    FROM public.sg_events_canonical sgc WHERE sgc.tevo_event_id IN (SELECT ev FROM _cand)
  ),
  -- GATE 1: section low outliers (few rows survive)
  outl AS (
    SELECT gt.ev, gt.gt_listing_id, ed.nm AS event_name, ed.dt AS event_date,
           gt.section, gt.secnum, gt.row, gt.quantity, gt.price, gt.in_hand_date, gt.gt_cap,
           gt.is_accessible, gt.notes,
           s.med AS section_median, s.n AS section_n,
           CASE WHEN m.madv > 0 THEN round(0.6745*(gt.price - s.med)/m.madv, 2) END AS mod_z,
           round((gt.price/s.med - 1)*100, 0)::int AS vs_section_pct
    FROM gt
    JOIN ss s USING (ev, section)
    JOIN sm m USING (ev, section)
    LEFT JOIN edate ed ON ed.ev = gt.ev
    WHERE s.n >= GREATEST(p_min_section_n,3)
      AND s.med >= GREATEST(p_min_section_median,0)
      AND (
            (m.madv > 0 AND 0.6745*(gt.price - s.med)/m.madv <= -v_z)
         OR (m.madv = 0 AND gt.price < s.q1 - 1.5*(s.q3 - s.q1))
          )
  ),
  cat AS (
    SELECT e.id AS ev,
           CASE WHEN e.event_type='game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category
    FROM public.events e LEFT JOIN public.performer_metadata pm ON pm.performer_id=e.primary_performer_id
    WHERE e.id IN (SELECT DISTINCT ev FROM outl)
  ),
  deg AS (
    SELECT o.ev,
           coalesce(cev.level_index / nullif(cn.level_index,0), 1)::numeric AS factor
    FROM (SELECT DISTINCT ev, event_date FROM outl) o
    LEFT JOIN cat c ON c.ev = o.ev
    LEFT JOIN public.clearing_dte_curve cn
      ON cn.category = c.category
     AND cn.dte_bucket = public.price_dte_bucket((o.event_date - (now() AT TIME ZONE 'utc')::date)::int)
    LEFT JOIN public.clearing_dte_curve cev
      ON cev.category = c.category AND cev.dte_bucket = public.price_dte_bucket(0)
  ),
  -- GATE 2+3: realized SeatGeek anchor by event × section NUMBER + win-probability.
  -- win_prob = fraction of realized sales whose net proceeds clear the 15% hurdle:
  --   broadcast_price × degrade × (1-fee) >= (1+p_min_roi) × gt_price
  scored AS (
    SELECT o.*, coalesce(d.factor,1) AS degrade,
           rz.realized_median, rz.realized_n, rz.win_prob
    FROM outl o
    LEFT JOIN deg d ON d.ev = o.ev
    LEFT JOIN LATERAL (
      SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY sgs.broadcast_price)::numeric AS realized_median,
             count(*) AS realized_n,
             avg( (sgs.broadcast_price * coalesce(d.factor,1) * (1 - v_fee)
                     >= (1 + GREATEST(p_min_roi,0)) * o.price)::int )::numeric AS win_prob
      FROM public.seatgeek_sales_snapshots sgs
      WHERE sgs.tevo_event_id = o.ev
        AND sgs.broadcast_price > 0
        AND sgs.sale_at_utc > now() - interval '45 days'
        AND (regexp_match(sgs.section,'(\d{2,4})'))[1]::int = o.secnum
    ) rz ON true
    WHERE o.secnum IS NOT NULL
  )
  SELECT s.ev, s.gt_listing_id, s.event_name, s.event_date,
         coalesce(nullif(public.derive_zone_fallback(s.section, s.row),''),'(unzoned)') AS zone,
         s.section, s.row, s.quantity, round(s.price,2) AS gt_price,
         round(s.section_median,2) AS section_median, s.section_n, s.mod_z, s.vs_section_pct,
         round(s.realized_median,2) AS realized_median, s.realized_n, 'realized'::text AS resale_basis,
         v_fee AS seller_fee_pct,
         round(s.realized_median * s.degrade * (1 - v_fee), 2) AS est_net_resale,
         round((s.realized_median * s.degrade * (1 - v_fee) - s.price)/s.price*100, 0)::int AS net_profit_pct,
         round(s.win_prob, 3) AS win_prob,
         CASE
           WHEN s.notes ~* 'obstruct|limited|partial|restricted|obov|side view|behind|pole|no view' THEN 'low'
           WHEN s.realized_n >= 20 THEN 'high'
           WHEN s.realized_n >= 8  THEN 'med'
           ELSE 'low' END AS confidence,
         s.is_accessible, s.in_hand_date, s.gt_cap AS gt_captured_at
  FROM scored s
  WHERE s.realized_n >= GREATEST(p_min_realized_n,1)
    AND s.win_prob >= p_min_win_prob;

  UPDATE public.gotickets_deals_feed f
     SET gone_at = now()
   WHERE f.tevo_event_id IN (SELECT ev FROM _cand)
     AND f.gone_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM _deals d WHERE d.ev=f.tevo_event_id AND d.gt_listing_id=f.gt_listing_id);
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  WITH ins AS (
    INSERT INTO public.gotickets_deals_feed AS f
      (tevo_event_id, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct, est_net_resale, net_profit_pct, win_prob, confidence,
       is_accessible, in_hand_date, gt_captured_at, first_seen_at, last_seen_at, gone_at)
    SELECT ev, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct, est_net_resale, net_profit_pct, win_prob, confidence,
       is_accessible, in_hand_date, gt_captured_at, now(), now(), NULL
    FROM _deals
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      gt_price=excluded.gt_price, section_median=excluded.section_median, section_n=excluded.section_n,
      mod_z=excluded.mod_z, vs_section_pct=excluded.vs_section_pct,
      realized_median=excluded.realized_median, realized_n=excluded.realized_n, resale_basis=excluded.resale_basis,
      seller_fee_pct=excluded.seller_fee_pct, est_net_resale=excluded.est_net_resale,
      net_profit_pct=excluded.net_profit_pct, win_prob=excluded.win_prob, confidence=excluded.confidence,
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

  RETURN jsonb_build_object('scanned_events',v_events,'new_deals',v_new,'gone',v_gone,'seller_fee',v_fee,'at',now());
END;
$fn$;
REVOKE ALL ON FUNCTION public.scan_gotickets_deals(int,numeric,int,numeric,numeric,numeric,int,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.scan_gotickets_deals(int,numeric,int,numeric,numeric,numeric,int,numeric) TO service_role;
COMMENT ON FUNCTION public.scan_gotickets_deals(int,numeric,int,numeric,numeric,numeric,int,numeric) IS
  'Live-feed scanner v4 (GoTickets section low outliers, calibrated on realized SeatGeek sales): section outlier → realized SG sales by event×section-number → win_prob = P(sale×degrade×(1-fee) ≥ (1+min_roi)×buy) ≥ p_min_win_prob (0.70) over ≥p_min_realized_n sales. service_role only. D0 mig 20260811220000.';

-- ── 3. Feed reader — expose net-profit + realized + confidence ───────────────
DROP FUNCTION IF EXISTS public.get_deals_feed(int,timestamptz,numeric,boolean);
CREATE OR REPLACE FUNCTION public.get_deals_feed(
  p_limit          int         DEFAULT 100,
  p_since          timestamptz DEFAULT NULL,
  p_min_roi        numeric     DEFAULT NULL,
  p_min_confidence text        DEFAULT NULL,   -- 'high' | 'med'
  p_include_gone   boolean     DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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
        'tevo_event_id', tevo_event_id, 'gt_listing_id', gt_listing_id,
        'event_name', event_name, 'event_date', event_date,
        'zone', zone, 'section', section, 'row', "row", 'quantity', quantity,
        'gt_price', gt_price, 'section_median', section_median,
        'realized_median', realized_median, 'realized_n', realized_n,
        'est_net_resale', est_net_resale, 'net_profit_pct', net_profit_pct, 'win_prob', win_prob,
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
$fn$;
REVOKE ALL ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,text,boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,text,boolean) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,text,boolean) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_deals_feed(int,timestamptz,numeric,text,boolean) IS
  'D0 DEALS live feed reader (realized-calibrated). Newest-first; p_since incremental, p_min_roi filters NET profit, p_min_confidence filters realized-sample confidence. Email-gated SECDEF. Mig 20260811220000.';

-- ── 4. Backtest — score the model against realized sales (calibration) ───────
CREATE OR REPLACE FUNCTION public.get_deal_backtest(
  p_lookback_days int DEFAULT 21,
  p_max_events    int DEFAULT 60
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_email text := coalesce(auth.jwt()->>'email','');
  v_fee numeric := coalesce((SELECT seller_fee_pct FROM public.order_fee_schedule WHERE source='sg_seller' ORDER BY effective_from DESC LIMIT 1),0.10);
  v_result jsonb;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: %', v_email USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout','30000',true);

  -- For a sample of events with realized sales, re-derive section outliers from a
  -- GoTickets snapshot ~p_lookback_days ago, then compare the buy price to the
  -- realized sale prices that occurred AFTER that snapshot (net of fee). Reports the
  -- realized-profit distribution of what the model would have bought.
  WITH ev AS (
    SELECT DISTINCT s.tevo_event_id AS ev
    FROM public.seatgeek_sales_snapshots s
    WHERE s.sale_at_utc > now() - (p_lookback_days||' days')::interval
    LIMIT p_max_events
  ),
  gtsnap AS (  -- a GT capture ~lookback ago per event
    SELECT g.tevo_event_id AS ev, g.gt_listing_id, btrim(g.section) AS section,
           g.all_in_price::numeric AS price, (regexp_match(g.section,'(\d{2,4})'))[1]::int AS secnum,
           g.captured_at
    FROM public.gotickets_listings_snapshots g
    JOIN ev ON ev.ev = g.tevo_event_id
    WHERE g.captured_at BETWEEN now() - ((p_lookback_days+1)||' days')::interval
                            AND now() - ((p_lookback_days-1)||' days')::interval
      AND g.all_in_price > 0 AND coalesce(g.general_admission,false)=false AND g.section IS NOT NULL
  ),
  ss AS (
    SELECT ev, section, count(*) n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY price)::numeric med,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY price)::numeric q1,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY price)::numeric q3
    FROM gtsnap GROUP BY ev, section
  ),
  sm AS (SELECT g.ev,g.section, percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(g.price-s.med))::numeric madv
         FROM gtsnap g JOIN ss s USING(ev,section) GROUP BY g.ev,g.section),
  flagged AS (  -- section outliers at the lookback snapshot
    SELECT g.ev, g.secnum, g.price AS buy_price
    FROM gtsnap g JOIN ss s USING(ev,section) JOIN sm m USING(ev,section)
    WHERE s.n>=5 AND s.med>=50 AND g.secnum IS NOT NULL
      AND ((m.madv>0 AND 0.6745*(g.price-s.med)/m.madv <= -3.5) OR (m.madv=0 AND g.price < s.q1-1.5*(s.q3-s.q1)))
  ),
  scored AS (  -- realized sales AFTER the snapshot, same event × section-number
    SELECT f.ev, f.buy_price,
      (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY sgs.broadcast_price)::numeric
         FROM public.seatgeek_sales_snapshots sgs
         WHERE sgs.tevo_event_id=f.ev AND sgs.broadcast_price>0
           AND (regexp_match(sgs.section,'(\d{2,4})'))[1]::int = f.secnum
           AND sgs.sale_at_utc > now() - (p_lookback_days||' days')::interval) AS realized_after
    FROM flagged f
  ),
  net AS (
    SELECT ev, buy_price, realized_after,
           (realized_after*(1-v_fee) - buy_price)/buy_price AS realized_roi
    FROM scored WHERE realized_after IS NOT NULL AND buy_price>0
  )
  SELECT jsonb_build_object(
    'lookback_days', p_lookback_days, 'seller_fee', v_fee,
    'flagged_with_realized', (SELECT count(*) FROM net),
    'won_pct_ge_15', round(100.0*(SELECT count(*) FROM net WHERE realized_roi>=0.15)/NULLIF((SELECT count(*) FROM net),0),1),
    'won_pct_ge_0',  round(100.0*(SELECT count(*) FROM net WHERE realized_roi>=0)/NULLIF((SELECT count(*) FROM net),0),1),
    'median_realized_roi_pct', round((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY realized_roi) FROM net)*100,1),
    'p25_realized_roi_pct',    round((SELECT percentile_cont(0.25) WITHIN GROUP (ORDER BY realized_roi) FROM net)*100,1),
    'p75_realized_roi_pct',    round((SELECT percentile_cont(0.75) WITHIN GROUP (ORDER BY realized_roi) FROM net)*100,1)
  ) INTO v_result;

  RETURN v_result;
END;
$fn$;
REVOKE ALL ON FUNCTION public.get_deal_backtest(int,int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deal_backtest(int,int) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deal_backtest(int,int) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_deal_backtest(int,int) IS
  'Calibration: re-derives section-outlier flags from a GoTickets snapshot ~p_lookback_days ago and scores buy price vs the realized SeatGeek sales that followed (net of fee) → win-rate + realized-ROI distribution. Email-gated. Mig 20260811220000.';
