-- Migration 20260811240000 · lane:D0 · writes:gotickets_deals_feed [+col gt_event_id],
--   scan_gotickets_deals(...) [fn replace], get_deals_feed(...) [fn replace]
--   reads:gotickets_listings_snapshots · pre:mig 20260811220000 (realized-calibrated feed)
--   auth:builder service_role-guarded SECDEF (scanner) + email-gated reader
--
-- WHY (operator-directed 2026-08-11 "add button to open the gotickets event page
-- for listing"). The DEALS feed row identifies a GoTickets listing by (tevo_event_id,
-- gt_listing_id) but never carried the GoTickets EVENT id, so the frontend had no key
-- to link back to the GoTickets event page. gotickets_listings_snapshots already has
-- gt_event_id alongside gt_listing_id; this threads it into the feed so a row can build
--   https://gotickets.com/tickets/<gt_event_id>
-- (GoTickets is a TicketNetwork platform: the numeric event id is the canonical key and
-- the bare /tickets/<id> path 301-redirects to the full slug URL).
--
-- ROLLBACK: revert the two functions to mig 20260811232000 / 20260811220000 defs;
--           ALTER TABLE public.gotickets_deals_feed DROP COLUMN gt_event_id;

ALTER TABLE public.gotickets_deals_feed ADD COLUMN IF NOT EXISTS gt_event_id bigint;
COMMENT ON COLUMN public.gotickets_deals_feed.gt_event_id IS
  'GoTickets event id (gotickets_listings_snapshots.gt_event_id) — lets the UI link to https://gotickets.com/tickets/<gt_event_id>. D0 mig 20260811240000.';

-- Backfill existing rows from the exact source snapshot (tevo_event_id + captured_at
-- keyed by idx_gt_ls_event_time, then gt_listing_id). Feed is tiny; this is instant.
UPDATE public.gotickets_deals_feed f
   SET gt_event_id = s.gt_event_id
  FROM public.gotickets_listings_snapshots s
 WHERE s.tevo_event_id = f.tevo_event_id
   AND s.captured_at   = f.gt_captured_at
   AND s.gt_listing_id = f.gt_listing_id
   AND f.gt_event_id IS NULL;

-- Scanner v7 — identical to v6 (mig 20260811232000) except gt_event_id is threaded
-- from the gt CTE through to the feed insert. Signature unchanged.
CREATE OR REPLACE FUNCTION public.scan_gotickets_deals(p_max_events integer DEFAULT 20, p_z_threshold numeric DEFAULT 3.5, p_min_section_n integer DEFAULT 5, p_min_section_median numeric DEFAULT 50, p_min_roi numeric DEFAULT 0.15, p_seller_fee numeric DEFAULT NULL::numeric, p_min_realized_n integer DEFAULT 8, p_min_win_prob numeric DEFAULT 0.70)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
    SELECT g.tevo_event_id AS ev, g.gt_event_id AS gt_event_id, g.gt_listing_id, btrim(g.section) AS section, g.row, g.quantity,
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
    SELECT gt.ev, gt.gt_event_id, gt.gt_listing_id, em.nm AS event_name, em.dt AS event_date, em.pid, em.category,
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
             percentile_cont(0.5) WITHIN GROUP (ORDER BY px)::numeric AS cur_median,
             avg( (px * coalesce(d.factor,1) * (1 - v_fee) >= (1 + v_roi) * o.price)::int )::numeric AS cur_win
      FROM (
        SELECT sgs.broadcast_price::numeric AS px
        FROM public.seatgeek_sales_snapshots sgs
        WHERE sgs.tevo_event_id = o.ev AND sgs.broadcast_price > 0
          AND sgs.sale_at_utc > now() - interval '45 days'
          AND (regexp_match(sgs.section,'(\d{2,4})'))[1]::int = o.secnum
        UNION ALL
        SELECT sd.price::numeric
        FROM public.seatdata_sales_snapshots sd
        WHERE sd.tevo_event_id = o.ev AND sd.price > 0
          AND sd.sale_timestamp > now() - interval '45 days'
          AND (regexp_match(sd.section,'(\d{2,4})'))[1]::int = o.secnum
      ) allsales
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
  SELECT c.ev, c.gt_event_id, c.gt_listing_id, c.event_name, c.event_date,
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
      (tevo_event_id, gt_event_id, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct, est_net_resale, net_profit_pct, win_prob, confidence,
       is_accessible, in_hand_date, gt_captured_at, first_seen_at, last_seen_at, gone_at)
    SELECT ev, gt_event_id, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct, est_net_resale, net_profit_pct, win_prob, confidence,
       is_accessible, in_hand_date, gt_captured_at, now(), now(), NULL
    FROM _deals
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      gt_event_id=excluded.gt_event_id,
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
$function$;

-- Reader — expose gt_event_id in each deal object. Signature unchanged.
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
