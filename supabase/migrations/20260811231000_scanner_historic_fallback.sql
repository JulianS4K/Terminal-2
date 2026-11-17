-- Migration 20260811231000 · lane:D0 (author) → applier (apply) · writes:scan_gotickets_deals(int,numeric,int,numeric,numeric,numeric,int,numeric) [fn, replace] · reads:+section_sale_baseline,events.primary_performer_id · pre:mig 20260811220000 (v4 scanner), 20260811230000 (section_sale_baseline) · auth:service_role-guarded SECDEF
--
-- WHY (operator-directed "build them all in"). v4 could only judge events with
-- CURRENT SeatGeek sales for the section (coverage gap). v5 adds the HISTORIC
-- fallback: when the current event has < p_min_realized_n realized sales, it uses
-- section_sale_baseline — how the home performer's seats in that section number have
-- ACTUALLY sold historically — to compute the win-probability from the stored price
-- distribution. Widens the feed to events not yet selling on SeatGeek while keeping
-- every deal calibrated on realized sales. (Validated: "Lower 127 @ $21" — no current
-- sales — resolves to Giants sec 127 hist median $48 over 32 sales → win_prob 1.00.)
--
-- Source priority per outlier: current-event realized (basis 'realized', highest
-- confidence) → historic baseline (basis 'historic_realized', 'med' confidence) →
-- none (not surfaced). The win-probability gate (≥ p_min_win_prob, 0.70) and the
-- section-outlier + degrade + net-of-fee math are unchanged.
--
-- ROLLBACK: re-apply mig 20260811220000 (restores the v4 current-only scanner).

CREATE OR REPLACE FUNCTION public.scan_gotickets_deals(
  p_max_events         int     DEFAULT 20,
  p_z_threshold        numeric DEFAULT 3.5,
  p_min_section_n      int     DEFAULT 5,
  p_min_section_median numeric DEFAULT 50,
  p_min_roi            numeric DEFAULT 0.15,
  p_seller_fee         numeric DEFAULT NULL,
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
  v_roi numeric := GREATEST(p_min_roi, 0);
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
  emeta AS (
    SELECT e.id AS ev, sgc.sg_event_name AS nm, sgc.sg_datetime_utc::date AS dt,
           e.primary_performer_id AS pid,
           CASE WHEN e.event_type='game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category
    FROM public.events e
    LEFT JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = e.id
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    WHERE e.id IN (SELECT ev FROM _cand)
  ),
  outl AS (
    SELECT gt.ev, gt.gt_listing_id, em.nm AS event_name, em.dt AS event_date, em.pid, em.category,
           gt.section, gt.secnum, gt.row, gt.quantity, gt.price, gt.in_hand_date, gt.gt_cap,
           gt.is_accessible, gt.notes,
           s.med AS section_median, s.n AS section_n,
           CASE WHEN m.madv > 0 THEN round(0.6745*(gt.price - s.med)/m.madv, 2) END AS mod_z,
           round((gt.price/s.med - 1)*100, 0)::int AS vs_section_pct
    FROM gt
    JOIN ss s USING (ev, section)
    JOIN sm m USING (ev, section)
    LEFT JOIN emeta em ON em.ev = gt.ev
    WHERE s.n >= GREATEST(p_min_section_n,3)
      AND s.med >= GREATEST(p_min_section_median,0)
      AND (
            (m.madv > 0 AND 0.6745*(gt.price - s.med)/m.madv <= -v_z)
         OR (m.madv = 0 AND gt.price < s.q1 - 1.5*(s.q3 - s.q1))
          )
  ),
  deg AS (
    SELECT o.ev,
           coalesce(cev.level_index / nullif(cn.level_index,0), 1)::numeric AS factor
    FROM (SELECT DISTINCT ev, event_date, category FROM outl) o
    LEFT JOIN public.clearing_dte_curve cn
      ON cn.category = o.category
     AND cn.dte_bucket = public.price_dte_bucket((o.event_date - (now() AT TIME ZONE 'utc')::date)::int)
    LEFT JOIN public.clearing_dte_curve cev
      ON cev.category = o.category AND cev.dte_bucket = public.price_dte_bucket(0)
  ),
  -- current-event realized (primary) + historic baseline (fallback), each with win-prob
  scored AS (
    SELECT o.*, coalesce(d.factor,1) AS degrade,
           cur.cur_n, cur.cur_median, cur.cur_win,
           b.n_sales AS hist_n, b.median_price AS hist_median,
           (SELECT avg( (px * coalesce(d.factor,1) * (1 - v_fee) >= (1 + v_roi) * o.price)::int )::numeric
              FROM unnest(b.prices) px) AS hist_win
    FROM outl o
    LEFT JOIN deg d ON d.ev = o.ev
    LEFT JOIN LATERAL (
      SELECT count(*) AS cur_n,
             percentile_cont(0.5) WITHIN GROUP (ORDER BY sgs.broadcast_price)::numeric AS cur_median,
             avg( (sgs.broadcast_price * coalesce(d.factor,1) * (1 - v_fee) >= (1 + v_roi) * o.price)::int )::numeric AS cur_win
      FROM public.seatgeek_sales_snapshots sgs
      WHERE sgs.tevo_event_id = o.ev AND sgs.broadcast_price > 0
        AND sgs.sale_at_utc > now() - interval '45 days'
        AND (regexp_match(sgs.section,'(\d{2,4})'))[1]::int = o.secnum
    ) cur ON true
    LEFT JOIN public.section_sale_baseline b ON b.performer_id = o.pid AND b.secnum = o.secnum
    WHERE o.secnum IS NOT NULL
  ),
  chosen AS (
    SELECT s.*,
      CASE WHEN s.cur_n >= p_min_realized_n THEN 'realized'
           WHEN s.hist_n >= p_min_realized_n THEN 'historic_realized' END AS basis,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_n     ELSE s.hist_n END      AS r_n,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_median ELSE s.hist_median END AS r_median,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_win   ELSE s.hist_win END    AS r_win
    FROM scored s
  )
  SELECT c.ev, c.gt_listing_id, c.event_name, c.event_date,
         coalesce(nullif(public.derive_zone_fallback(c.section, c.row),''),'(unzoned)') AS zone,
         c.section, c.row, c.quantity, round(c.price,2) AS gt_price,
         round(c.section_median,2) AS section_median, c.section_n, c.mod_z, c.vs_section_pct,
         round(c.r_median,2) AS realized_median, c.r_n AS realized_n, c.basis AS resale_basis,
         v_fee AS seller_fee_pct,
         round(c.r_median * c.degrade * (1 - v_fee), 2) AS est_net_resale,
         round((c.r_median * c.degrade * (1 - v_fee) - c.price)/c.price*100, 0)::int AS net_profit_pct,
         round(c.r_win, 3) AS win_prob,
         CASE
           WHEN c.notes ~* 'obstruct|limited|partial|restricted|obov|side view|behind|pole|no view' THEN 'low'
           WHEN c.basis='realized' AND c.r_n >= 20 THEN 'high'
           WHEN c.basis='realized' THEN 'med'
           WHEN c.basis='historic_realized' AND c.r_n >= 30 THEN 'med'
           ELSE 'low' END AS confidence,
         c.is_accessible, c.in_hand_date, c.gt_cap AS gt_captured_at
  FROM chosen c
  WHERE c.basis IS NOT NULL
    AND c.r_n >= p_min_realized_n
    AND c.r_win >= p_min_win_prob;

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
  'Live-feed scanner v5: GoTickets section outlier → realized win-probability, current-event SeatGeek sales primary, section_sale_baseline (historic performer×section) fallback → win_prob ≥ p_min_win_prob (0.70) net of fee. service_role only. D0 mig 20260811231000.';
