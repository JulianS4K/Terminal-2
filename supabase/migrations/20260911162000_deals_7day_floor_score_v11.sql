-- ============================================================================
-- Migration 20260911162000 — 7-day floor on the deal feed · score v1.1 tuned for the 7+ day window
--
-- Lane:     D0 (deals surface)
-- Touches:  scan_listing_deals(…) · gt_deals_retire_tick(int) · deal_score_v1(jsonb) · deal_gate_v1(jsonb)
--           (all CREATE OR REPLACE, same signatures) · deal_signal_snapshot (re-score) ·
--           v_deals_feed_ranked / get_deals_feed / get_deal_signals (timing labels)
-- Pre-reqs: 20260911161800, 20260911161900
--
-- Already applied to prod · via MCP 2026-09-11 (operator: "let do 7 days and more and strengthen
-- that, less is too short a window to convert").
--
-- FLOOR. The scanner admits events ≥ 7 days out (both sources) and the retire tick drops any live
-- row whose event is inside 7 days. Rows flagged today for tonight/tomorrow retire on the next tick.
--
-- SCORE v1.1 — what wins when flagged 7+ days out (72 graded deals, base win 21%):
--   sales in the 7d before the flag   ≥60: 58% (n19) · 20–59: 8% (n52)   ← the dominant signal
--   weekend event                     39% vs weekday 7%
--   7d/14d MA                         rising 38% · flat 20% · falling 0% (n16)
--   cost / event amalgam median       ≥0.8: 4% (n23) · <0.5: 32%
--   moneyness                         ≥0.9: 5% (n21) · 0.6–0.7: 33% · 0.8–0.9: 44% (n9)
--   regime                            DUMPING 0/8 · others ~25%
--   days out                          7–14: 24% · 15–21: 15% · 22–30: 50% (n6) · 31+: no data yet
--   cost                              <$50: 27% · ≥$50: 19%
--   no signal: vs_zone depth, sigma, theta, zone_n, the feed's own win_prob (19/27/18%).
-- Weights = bucket log-odds vs base, shrunk n/(n+10), sum damped ×0.6. In-sample on the 61
-- zone/section rows ≥7d: AUC 0.93 (feed 0.61). Hand rule on a small MLB sample — provisional.
--
-- GATES v1.1: SUPPRESS at-market (moneyness ≥0.9) · SUPPRESS falling-market (MA <0.95 OR regime
-- DUMPING — falling alone was 0/16) · VERIFY too-cheap (moneyness <0.5) · VERIFY thin-market
-- (<20 sales in the prior 7 days — nothing to sell into). The vs-zone part of too-cheap is dropped
-- (deep zone discounts won 25% in this window).
--
-- ROLLBACK: re-apply the bodies from 161800 (scanner, retire tick) and 161600 (score, gate).
-- ============================================================================

-- ── 1. Scanner: 7-day floor (both sources) ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.scan_listing_deals(
  p_source             text,
  p_max_events         integer DEFAULT 25,
  p_z_threshold        numeric DEFAULT 3.5,
  p_min_section_n      integer DEFAULT 5,
  p_min_section_median numeric DEFAULT 50,
  p_min_roi            numeric DEFAULT 0.15,
  p_seller_fee         numeric DEFAULT NULL,
  p_min_realized_n     integer DEFAULT 8,
  p_min_win_prob       numeric DEFAULT 0.70,
  p_degr_ma_days       integer DEFAULT 14,
  p_degr_halflife      numeric DEFAULT 7.0,
  p_degr_floor         numeric DEFAULT -0.25,
  p_degr_ceil          numeric DEFAULT 0.15,
  p_dumping_gate       boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_new int := 0; v_gone int := 0; v_events int := 0;
  v_raw_pass int := 0; v_adj_pass int := 0; v_dumping int := 0; v_gated int := 0;
  v_outlier_only int := 0; v_total int := 0;
  v_z    numeric := GREATEST(p_z_threshold, 0.1);
  v_roi  numeric := GREATEST(p_min_roi, 0);
  v_days int     := GREATEST(coalesce(p_degr_ma_days,14), 3);
  v_hl   numeric := GREATEST(coalesce(p_degr_halflife,7.0), 0.5);
  v_kappa numeric := ln(2.0) / GREATEST(coalesce(p_degr_halflife,7.0), 0.5);
  v_flr  numeric := coalesce(p_degr_floor,-0.25);
  v_ceil numeric := coalesce(p_degr_ceil,0.15);
  v_fee  numeric := coalesce(p_seller_fee,
                    (SELECT seller_fee_pct FROM public.order_fee_schedule
                      WHERE source='sg_seller' ORDER BY effective_from DESC LIMIT 1), 0.10);
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  IF p_source NOT IN ('gotickets','evo') THEN
    RAISE EXCEPTION 'scan_listing_deals: unknown source %', p_source;
  END IF;
  PERFORM set_config('statement_timeout', '45000', true);

  -- 2a. Candidates: deal-capable (curated zone), upcoming (NO 14-day floor), polled in the last
  --     30 min, with a capture newer than the last scan for THIS source. Nearest event first.
  IF p_source = 'gotickets' THEN
    CREATE TEMP TABLE _cand ON COMMIT DROP AS
    WITH pool AS (
      SELECT DISTINCT ON (e.id)
             e.id AS ev, g.gt_event_id, ps.last_polled_listings_at, st.last_gt_cap AS last_cap,
             g.event_time_utc AS starts_at
      FROM public.gotickets_event g
      JOIN public.events e ON e.id = g.tevo_event_id
      JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
      LEFT JOIN public.gotickets_deals_scan_state st ON st.tevo_event_id = e.id
      WHERE g.status = 'AS_SCHEDULED'
        AND g.event_time_utc > now() + interval '7 days'          -- 7-day floor (operator 2026-09-11: <7d is too short to convert)
        AND ps.last_polled_listings_at > now() - interval '30 minutes'
        AND EXISTS (SELECT 1 FROM public.performer_zones pz
                     WHERE pz.performer_id = e.primary_performer_id
                       AND pz.venue_id = e.venue_id AND pz.source = 'curated')
      ORDER BY e.id, ps.last_polled_listings_at DESC
    ),
    fresh AS (SELECT * FROM pool ORDER BY last_polled_listings_at DESC LIMIT GREATEST(p_max_events,1) * 6)
    SELECT f.ev, f.gt_event_id, c.cap, f.starts_at
    FROM fresh f
    CROSS JOIN LATERAL (
      SELECT max(s.captured_at) AS cap FROM public.gotickets_listings_snapshots s
      WHERE s.gt_event_id = f.gt_event_id AND s.captured_at > now() - interval '2 hours') c
    WHERE c.cap IS NOT NULL AND c.cap > coalesce(f.last_cap, 'epoch'::timestamptz)
    ORDER BY f.starts_at ASC, c.cap DESC
    LIMIT GREATEST(p_max_events, 1);
  ELSE
    CREATE TEMP TABLE _cand ON COMMIT DROP AS
    WITH pool AS (
      SELECT e.id AS ev, NULL::bigint AS gt_event_id, ps.last_polled_listings_at, st.last_evo_cap AS last_cap,
             e.occurs_at_local::timestamptz AS starts_at
      FROM public.events e
      JOIN public.evo_listings_poll_state ps ON ps.event_id = e.id
      LEFT JOIN public.gotickets_deals_scan_state st ON st.tevo_event_id = e.id
      WHERE e.occurs_at_local IS NOT NULL
        AND e.occurs_at_local::timestamptz > now() + interval '7 days'   -- 7-day floor
        AND coalesce(e.state, 'shown') <> 'ignored'
        AND ps.last_polled_listings_at > now() - interval '30 minutes'
        AND EXISTS (SELECT 1 FROM public.performer_zones pz
                     WHERE pz.performer_id = e.primary_performer_id
                       AND pz.venue_id = e.venue_id AND pz.source = 'curated')
    ),
    fresh AS (SELECT * FROM pool ORDER BY last_polled_listings_at DESC LIMIT GREATEST(p_max_events,1) * 6)
    SELECT f.ev, f.gt_event_id, c.cap, f.starts_at
    FROM fresh f
    CROSS JOIN LATERAL (
      SELECT max(s.captured_at) AS cap FROM public.listings_snapshots s
      WHERE s.event_id = f.ev AND s.captured_at > now() - interval '2 hours') c
    WHERE c.cap IS NOT NULL AND c.cap > coalesce(f.last_cap, 'epoch'::timestamptz)
    ORDER BY f.starts_at ASC, c.cap DESC
    LIMIT GREATEST(p_max_events, 1);
  END IF;

  SELECT count(*) INTO v_events FROM _cand;
  IF v_events = 0 THEN
    RETURN jsonb_build_object('source', p_source, 'scanned_events', 0, 'new_deals', 0, 'gone', 0, 'at', now());
  END IF;

  -- 2b. The listings of each candidate's newest capture, in one shape for both sources.
  --     price = what WE would pay: GoTickets all-in, TEvo wholesale.
  IF p_source = 'gotickets' THEN
    CREATE TEMP TABLE _lst ON COMMIT DROP AS
    SELECT g.tevo_event_id AS ev, g.gt_event_id, g.gt_listing_id AS listing_id, NULL::bigint AS evo_tg_id,
           btrim(g.section) AS section, g.row, g.quantity, g.all_in_price::numeric AS price,
           g.in_hand_date, c.cap, g.notes,
           (g.row ~* 'wc|wheelchair|accessible' OR g.section ~* 'accessible') AS is_accessible
    FROM public.gotickets_listings_snapshots g
    JOIN _cand c ON c.ev = g.tevo_event_id AND g.captured_at = c.cap
    WHERE g.all_in_price > 0 AND coalesce(g.general_admission,false) = false AND g.section IS NOT NULL;
  ELSE
    CREATE TEMP TABLE _lst ON COMMIT DROP AS
    SELECT l.event_id AS ev, NULL::bigint AS gt_event_id, -l.tevo_ticket_group_id AS listing_id, l.tevo_ticket_group_id AS evo_tg_id,
           btrim(l.section) AS section, l.row, l.quantity, l.wholesale_price::numeric AS price,
           NULL::date AS in_hand_date, c.cap, NULL::text AS notes,
           (coalesce(l.wheelchair,false) OR l.row ~* 'wc|wheelchair|accessible' OR l.section ~* 'accessible') AS is_accessible
    FROM public.listings_snapshots l
    JOIN _cand c ON c.ev = l.event_id AND l.captured_at = c.cap
    WHERE l.wholesale_price > 0 AND l.section IS NOT NULL
      AND NOT coalesce(l.is_owned, false)          -- never flag our own inventory
      AND NOT coalesce(l.is_ancillary, false)
      AND coalesce(l.type, 'event') = 'event';     -- no parking
  END IF;

  -- 2c. Score (unchanged logic: curated-zone MAD outlier → realized anchor → clearing-curve degradation).
  CREATE TEMP TABLE _scored ON COMMIT DROP AS
  WITH emeta AS (
    SELECT e.id AS ev, e.venue_id,
           coalesce(sgc.sg_event_name, ge.name, e.name)                                    AS nm,
           coalesce(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local::timestamptz)::date AS dt,
           e.primary_performer_id AS pid,
           (EXTRACT(dow FROM coalesce(sgc.sg_datetime_utc, ge.event_time_utc, e.occurs_at_local::timestamptz))::int IN (0,5,6)) AS is_weekend,
           CASE WHEN e.event_type='game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category
    FROM public.events e
    LEFT JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = e.id
    LEFT JOIN LATERAL (
      SELECT g2.name, g2.event_time_utc FROM public.gotickets_event g2
      WHERE g2.tevo_event_id = e.id ORDER BY g2.event_time_utc LIMIT 1) ge ON true
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    WHERE e.id IN (SELECT ev FROM _cand)
  ),
  gtz AS (
    SELECT l.*, em.nm, em.dt, em.pid, em.venue_id, em.category, em.is_weekend,
           public.gt_curated_zone_id(em.pid, em.venue_id, l.section) AS zone_id
    FROM _lst l JOIN emeta em ON em.ev = l.ev
  ),
  zs AS (
    SELECT ev, zone_id, count(*) AS n,
           percentile_cont(0.5)  WITHIN GROUP (ORDER BY price)::numeric AS med,
           percentile_cont(0.25) WITHIN GROUP (ORDER BY price)::numeric AS q1,
           percentile_cont(0.75) WITHIN GROUP (ORDER BY price)::numeric AS q3
    FROM gtz WHERE zone_id IS NOT NULL GROUP BY ev, zone_id
  ),
  zm AS (
    SELECT g.ev, g.zone_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(g.price - z.med))::numeric AS madv
    FROM gtz g JOIN zs z USING (ev, zone_id) GROUP BY g.ev, g.zone_id
  ),
  ss AS (
    SELECT ev, section, count(*) AS n, percentile_cont(0.5) WITHIN GROUP (ORDER BY price)::numeric AS med
    FROM _lst GROUP BY ev, section
  ),
  dtrend_daily AS (
    SELECT d.event_id AS ev, d.snapshot_date, avg(d.amalgam_median) AS med
    FROM public.event_listing_snapshot_daily d
    WHERE d.event_id IN (SELECT ev FROM _cand) AND d.amalgam_median IS NOT NULL
    GROUP BY d.event_id, d.snapshot_date
  ),
  dtrend_ranked AS (
    SELECT ev, med, row_number() OVER (PARTITION BY ev ORDER BY snapshot_date DESC) AS rn FROM dtrend_daily
  ),
  dtrend AS (
    SELECT ev,
           avg(med) FILTER (WHERE rn BETWEEN 1 AND v_days)            AS ma_now,
           avg(med) FILTER (WHERE rn BETWEEN v_days+1 AND 2*v_days)   AS ma_prev,
           count(*) FILTER (WHERE rn BETWEEN 1 AND v_days)            AS n_now,
           count(*) FILTER (WHERE rn BETWEEN v_days+1 AND 2*v_days)   AS n_prev
    FROM dtrend_ranked GROUP BY ev
  ),
  evtrend AS (
    SELECT em.ev,
           GREATEST((em.dt - (now() AT TIME ZONE 'utc')::date), 0)::int AS dte_now,
           t.n_now, t.n_prev,
           CASE WHEN t.ma_prev > 0 THEN (t.ma_now/t.ma_prev - 1)*100 END
           - coalesce(round((cn.level_index/nullif(cp.level_index,0) - 1)*100, 1), 0) AS excess_pct,
           (t.n_now >= v_days AND t.n_prev >= (v_days/2) AND t.ma_prev > 0) AS has_hist
    FROM emeta em
    LEFT JOIN dtrend t ON t.ev = em.ev
    LEFT JOIN public.clearing_dte_curve cn
      ON cn.category = em.category
     AND cn.dte_bucket = public.price_dte_bucket(GREATEST((em.dt-(now() AT TIME ZONE 'utc')::date),0)::int)
    LEFT JOIN public.clearing_dte_curve cp
      ON cp.category = em.category
     AND cp.dte_bucket = public.price_dte_bucket((GREATEST((em.dt-(now() AT TIME ZONE 'utc')::date),0) + v_days)::int)
  ),
  evfac AS (
    SELECT et.ev, et.dte_now,
           CASE WHEN et.has_hist THEN round(et.excess_pct::numeric, 1) END AS excess_pct,
           CASE WHEN et.has_hist
                THEN round((1 + GREATEST(LEAST(
                       (et.excess_pct/v_days) * (1 - exp(-v_kappa*et.dte_now)) / v_kappa / 100.0,
                       v_ceil), v_flr))::numeric, 4)
                ELSE 1.0 END AS degr_factor,
           CASE WHEN NOT et.has_hist THEN 'UNKNOWN'
                WHEN et.excess_pct <= -8 THEN 'DUMPING'
                WHEN et.excess_pct <= -3 THEN 'SOFTENING'
                WHEN et.excess_pct >=  5 THEN 'RISING'
                ELSE 'STABLE' END AS regime
    FROM evtrend et
  ),
  outl AS (
    SELECT g.ev, g.gt_event_id, g.listing_id, g.evo_tg_id, g.nm AS event_name, g.dt AS event_date,
           g.pid, g.venue_id, g.category, g.is_weekend, g.zone_id,
           g.section, g.row, g.quantity, g.price, g.in_hand_date, g.cap,
           g.is_accessible, g.notes,
           z.med AS zone_median, z.n AS zone_n,
           sec.med AS section_median, sec.n AS section_n,
           ef.dte_now, ef.excess_pct, ef.degr_factor, ef.regime,
           CASE WHEN m.madv > 0 THEN round(0.6745*(g.price - z.med)/m.madv, 2) END AS mod_z,
           round((g.price/z.med - 1)*100, 0)::int AS vs_zone_pct,
           CASE WHEN sec.med > 0 THEN round((g.price/sec.med - 1)*100, 0)::int END AS vs_section_pct
    FROM gtz g
    JOIN zs z USING (ev, zone_id)
    JOIN zm m USING (ev, zone_id)
    LEFT JOIN ss sec ON sec.ev = g.ev AND sec.section = g.section
    LEFT JOIN evfac ef ON ef.ev = g.ev
    WHERE g.zone_id IS NOT NULL
      AND z.n   >= GREATEST(p_min_section_n,3)
      AND z.med >= GREATEST(p_min_section_median,0)
      AND ( (m.madv > 0 AND 0.6745*(g.price - z.med)/m.madv <= -v_z)
         OR (m.madv = 0 AND g.price < z.q1 - 1.5*(z.q3 - z.q1)) )
  ),
  scored AS (
    SELECT o.*,
           cur.cur_n, cur.cur_median, cur.cur_win_raw, cur.cur_win_adj,
           b.n_sales AS hist_n, b.median_ed AS hist_median,
           (SELECT avg( (px * (1 - v_fee) >= (1 + v_roi) * o.price)::int )::numeric FROM unnest(b.prices_ed) px) AS hist_win_raw,
           (SELECT avg( (px * coalesce(o.degr_factor,1) * (1 - v_fee) >= (1 + v_roi) * o.price)::int )::numeric FROM unnest(b.prices_ed) px) AS hist_win_adj
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
          WHERE sgs.tevo_event_id = o.ev AND sgs.broadcast_price > 0 AND sgs.sale_at_utc > now() - interval '30 days'
          UNION ALL
          SELECT sd.price::numeric, sd.section, GREATEST((o.event_date - sd.sale_timestamp::date),0)
          FROM public.seatdata_sales_snapshots sd
          WHERE sd.tevo_event_id = o.ev AND sd.price > 0 AND sd.sale_timestamp > now() - interval '30 days'
        ) s
        LEFT JOIN public.clearing_dte_curve cs ON cs.category = o.category AND cs.dte_bucket = public.price_dte_bucket(s.sdte)
        LEFT JOIN public.clearing_dte_curve c0 ON c0.category = o.category AND c0.dte_bucket = public.price_dte_bucket(0)
        WHERE EXISTS (
          SELECT 1 FROM public.performer_zone_rules pzr
          WHERE pzr.zone_id = o.zone_id
            AND public.section_in_range(coalesce((regexp_match(s.section,'(\d{2,4})'))[1], s.section), pzr.section_from, pzr.section_to))
      ) z
    ) cur ON true
    LEFT JOIN public.section_sale_baseline_cz b
      ON b.performer_id = o.pid AND b.zone_id = o.zone_id AND b.is_weekend = o.is_weekend
  ),
  chosen AS (
    SELECT s.*,
      CASE WHEN s.cur_n >= p_min_realized_n THEN 'realized' WHEN s.hist_n >= p_min_realized_n THEN 'historic_realized' END AS basis,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_n       ELSE s.hist_n END       AS r_n,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_median  ELSE s.hist_median END  AS r_median,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_win_raw ELSE s.hist_win_raw END AS r_win_raw,
      CASE WHEN s.cur_n >= p_min_realized_n THEN s.cur_win_adj ELSE s.hist_win_adj END AS r_win_adj
    FROM scored s
  )
  SELECT c.ev, c.gt_event_id, c.listing_id, c.evo_tg_id, c.event_name, c.event_date,
         coalesce((SELECT name FROM public.performer_zones WHERE id = c.zone_id), '(zone '||c.zone_id||')') AS zone,
         c.section, c.row, c.quantity, round(c.price,2) AS gt_price,
         round(c.zone_median,2) AS zone_median, c.zone_n, c.vs_zone_pct,
         round(c.section_median,2) AS section_median, c.section_n, c.mod_z, c.vs_section_pct,
         round(c.r_median,2) AS realized_median, c.r_n AS realized_n, c.basis AS resale_basis,
         v_fee AS seller_fee_pct,
         c.dte_now, c.excess_pct AS degr_excess_pct, coalesce(c.degr_factor,1) AS degr_factor, c.regime,
         round(c.r_median * coalesce(c.degr_factor,1) * (1 - v_fee), 2) AS est_net_resale,
         round((c.r_median * coalesce(c.degr_factor,1) * (1 - v_fee) - c.price)/c.price*100, 0)::int AS net_profit_pct,
         round(c.r_win_adj, 3) AS win_prob,
         round(c.r_median * (1 - v_fee), 2) AS est_net_resale_raw,
         round((c.r_median * (1 - v_fee) - c.price)/c.price*100, 0)::int AS net_profit_pct_raw,
         round(c.r_win_raw, 3) AS win_prob_raw,
         CASE WHEN c.basis IS NULL THEN 'outlier'
              WHEN c.notes ~* 'obstruct|limited|partial|restricted|obov|side view|behind|pole|no view' THEN 'low'
              WHEN c.basis='realized' AND c.r_n >= 20 THEN 'high'
              WHEN c.basis='realized' THEN 'med'
              WHEN c.basis='historic_realized' AND c.r_n >= 30 THEN 'med'
              ELSE 'low' END AS confidence,
         c.is_accessible, c.in_hand_date, c.cap AS gt_captured_at
  FROM chosen c;

  SELECT count(*),
         count(*) FILTER (WHERE resale_basis IS NULL),
         count(*) FILTER (WHERE realized_n >= p_min_realized_n AND win_prob_raw >= p_min_win_prob),
         count(*) FILTER (WHERE realized_n >= p_min_realized_n AND win_prob     >= p_min_win_prob),
         count(*) FILTER (WHERE realized_n >= p_min_realized_n AND win_prob     >= p_min_win_prob AND regime='DUMPING')
  INTO v_total, v_outlier_only, v_raw_pass, v_adj_pass, v_dumping FROM _scored;

  CREATE TEMP TABLE _deals ON COMMIT DROP AS
    SELECT * FROM _scored WHERE (NOT p_dumping_gate OR coalesce(regime,'UNKNOWN') <> 'DUMPING');
  v_gated := CASE WHEN p_dumping_gate THEN v_dumping ELSE 0 END;

  -- 2d. Retire this source's rows for the scanned events that no longer qualify (never the other source's).
  UPDATE public.gotickets_deals_feed f SET gone_at = now()
   WHERE f.source = p_source AND f.tevo_event_id IN (SELECT ev FROM _cand) AND f.gone_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM _deals d WHERE d.ev = f.tevo_event_id AND d.listing_id = f.gt_listing_id);
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  -- 2e. Upsert.
  WITH ins AS (
    INSERT INTO public.gotickets_deals_feed AS f
      (source, evo_ticket_group_id,
       tevo_event_id, gt_event_id, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, zone_median, zone_n, vs_zone_pct, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct,
       dte_now, degr_excess_pct, degr_factor, regime,
       est_net_resale, net_profit_pct, win_prob,
       est_net_resale_raw, net_profit_pct_raw, win_prob_raw, confidence,
       is_accessible, in_hand_date, gt_captured_at, first_seen_at, last_seen_at, gone_at)
    SELECT p_source, evo_tg_id,
       ev, gt_event_id, listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, zone_median, zone_n, vs_zone_pct, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct,
       dte_now, degr_excess_pct, degr_factor, regime,
       est_net_resale, net_profit_pct, win_prob,
       est_net_resale_raw, net_profit_pct_raw, win_prob_raw, confidence,
       is_accessible, in_hand_date, gt_captured_at, now(), now(), NULL
    FROM _deals
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      source=excluded.source, evo_ticket_group_id=excluded.evo_ticket_group_id, gt_event_id=excluded.gt_event_id,
      event_name=excluded.event_name, event_date=excluded.event_date, gt_price=excluded.gt_price,
      zone_median=excluded.zone_median, zone_n=excluded.zone_n, vs_zone_pct=excluded.vs_zone_pct,
      section_median=excluded.section_median, section_n=excluded.section_n,
      mod_z=excluded.mod_z, vs_section_pct=excluded.vs_section_pct,
      realized_median=excluded.realized_median, realized_n=excluded.realized_n, resale_basis=excluded.resale_basis,
      seller_fee_pct=excluded.seller_fee_pct,
      dte_now=excluded.dte_now, degr_excess_pct=excluded.degr_excess_pct, degr_factor=excluded.degr_factor, regime=excluded.regime,
      est_net_resale=excluded.est_net_resale, net_profit_pct=excluded.net_profit_pct, win_prob=excluded.win_prob,
      est_net_resale_raw=excluded.est_net_resale_raw, net_profit_pct_raw=excluded.net_profit_pct_raw,
      win_prob_raw=excluded.win_prob_raw, confidence=excluded.confidence,
      zone=excluded.zone, section=excluded.section, "row"=excluded."row", quantity=excluded.quantity,
      is_accessible=excluded.is_accessible, in_hand_date=excluded.in_hand_date,
      gt_captured_at=excluded.gt_captured_at, last_seen_at=now(), gone_at=NULL
    RETURNING (xmax = 0) AS inserted)
  SELECT count(*) FILTER (WHERE inserted) INTO v_new FROM ins;

  -- 2f. Scan state, per source.
  IF p_source = 'gotickets' THEN
    INSERT INTO public.gotickets_deals_scan_state (tevo_event_id, last_gt_cap, last_scanned_at, deals_found)
    SELECT c.ev, c.cap, now(), (SELECT count(*) FROM _deals d WHERE d.ev=c.ev) FROM _cand c
    ON CONFLICT (tevo_event_id) DO UPDATE SET last_gt_cap=excluded.last_gt_cap, last_scanned_at=now(), deals_found=excluded.deals_found;
  ELSE
    INSERT INTO public.gotickets_deals_scan_state (tevo_event_id, last_evo_cap, last_evo_scanned_at, evo_deals_found)
    SELECT c.ev, c.cap, now(), (SELECT count(*) FROM _deals d WHERE d.ev=c.ev) FROM _cand c
    ON CONFLICT (tevo_event_id) DO UPDATE SET last_evo_cap=excluded.last_evo_cap, last_evo_scanned_at=now(), evo_deals_found=excluded.evo_deals_found;
  END IF;

  RETURN jsonb_build_object(
    'source', p_source, 'scanned_events', v_events, 'new_deals', v_new, 'gone', v_gone, 'seller_fee', v_fee,
    'nearest_event', (SELECT min(starts_at) FROM _cand),
    'outliers', jsonb_build_object('scope', 'curated_zone', 'total', v_total, 'outlier_only', v_outlier_only,
                                   'anchored_pass_raw', v_raw_pass, 'anchored_pass_adj', v_adj_pass),
    'degr', jsonb_build_object('ma_days', v_days, 'model', 'ou_mean_reversion', 'halflife_days', v_hl, 'kappa', round(v_kappa,4),
                               'floor', v_flr, 'ceil', v_ceil, 'dumping_gate', p_dumping_gate,
                               'raw_pass', v_raw_pass, 'adj_pass', v_adj_pass, 'dumping_in_adj_pass', v_dumping, 'gated', v_gated),
    'at', now());
END;
$function$;
-- ── 2. Retire tick: rows inside 7 days go ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.gt_deals_retire_tick(p_stale_hours integer DEFAULT 12)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_gone int := 0; v_stale int := 0; v_orphan int := 0; v_past int := 0;
        v_egone int := 0; v_estale int := 0;
        v_hours int := GREATEST(coalesce(p_stale_hours, 12), 1);
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '20000', true);

  -- GoTickets: newest capture per GT event carrying a live deal (bounded PK back-scan).
  CREATE TEMP TABLE _cap ON COMMIT DROP AS
  SELECT e.gt_event_id,
         (SELECT max(s.captured_at) FROM public.gotickets_listings_snapshots s
           WHERE s.gt_event_id = e.gt_event_id AND s.captured_at > now() - make_interval(hours => v_hours)) AS last_cap
  FROM (SELECT DISTINCT gt_event_id FROM public.gotickets_deals_feed
         WHERE gone_at IS NULL AND source = 'gotickets' AND gt_event_id IS NOT NULL) e;

  UPDATE public.gotickets_deals_feed f SET gone_at = now()
  FROM _cap c
  WHERE f.source = 'gotickets' AND c.gt_event_id = f.gt_event_id AND f.gone_at IS NULL
    AND c.last_cap IS NOT NULL AND c.last_cap > coalesce(f.gt_captured_at, f.last_seen_at)
    AND NOT EXISTS (SELECT 1 FROM public.gotickets_listings_snapshots s2
                     WHERE s2.gt_event_id = f.gt_event_id AND s2.captured_at = c.last_cap AND s2.gt_listing_id = f.gt_listing_id);
  GET DIAGNOSTICS v_gone = ROW_COUNT;

  UPDATE public.gotickets_deals_feed f SET gone_at = now()
  FROM _cap c WHERE f.source = 'gotickets' AND c.gt_event_id = f.gt_event_id AND f.gone_at IS NULL AND c.last_cap IS NULL;
  GET DIAGNOSTICS v_stale = ROW_COUNT;

  UPDATE public.gotickets_deals_feed SET gone_at = now()
  WHERE gone_at IS NULL AND source = 'gotickets' AND gt_event_id IS NULL
    AND last_seen_at < now() - make_interval(hours => v_hours);
  GET DIAGNOSTICS v_orphan = ROW_COUNT;

  -- EVO: same idea against listings_snapshots (one captured_at per pull).
  CREATE TEMP TABLE _ecap ON COMMIT DROP AS
  SELECT e.tevo_event_id,
         (SELECT max(s.captured_at) FROM public.listings_snapshots s
           WHERE s.event_id = e.tevo_event_id AND s.captured_at > now() - make_interval(hours => v_hours)) AS last_cap
  FROM (SELECT DISTINCT tevo_event_id FROM public.gotickets_deals_feed WHERE gone_at IS NULL AND source = 'evo') e;

  UPDATE public.gotickets_deals_feed f SET gone_at = now()
  FROM _ecap c
  WHERE f.source = 'evo' AND c.tevo_event_id = f.tevo_event_id AND f.gone_at IS NULL
    AND c.last_cap IS NOT NULL AND c.last_cap > coalesce(f.gt_captured_at, f.last_seen_at)
    AND NOT EXISTS (SELECT 1 FROM public.listings_snapshots s2
                     WHERE s2.event_id = f.tevo_event_id AND s2.captured_at = c.last_cap
                       AND s2.tevo_ticket_group_id = f.evo_ticket_group_id);
  GET DIAGNOSTICS v_egone = ROW_COUNT;

  UPDATE public.gotickets_deals_feed f SET gone_at = now()
  FROM _ecap c WHERE f.source = 'evo' AND c.tevo_event_id = f.tevo_event_id AND f.gone_at IS NULL AND c.last_cap IS NULL;
  GET DIAGNOSTICS v_estale = ROW_COUNT;

  -- Inside 7 days: too short a window to buy and convert (operator 2026-09-11) — retire.
  UPDATE public.gotickets_deals_feed SET gone_at = now()
  WHERE gone_at IS NULL AND event_date IS NOT NULL AND event_date < (now() AT TIME ZONE 'utc')::date + 7;
  GET DIAGNOSTICS v_past = ROW_COUNT;

  RETURN jsonb_build_object('gone', v_gone, 'stale', v_stale + v_orphan, 'evo_gone', v_egone, 'evo_stale', v_estale,
                            'under_7d', v_past, 'stale_hours', v_hours, 'at', now());
END;
$function$;
-- ── 3. Score v1.1 (7+ day window) ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.deal_score_v1(f jsonb)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
AS $fn$
DECLARE z numeric := 0; v numeric; q int;
BEGIN
  IF f IS NULL THEN RETURN NULL; END IF;
  -- resale velocity: SG + CRM sales in the 7 days before the flag
  v := coalesce((f->>'sales_7d')::numeric, 0);
  z := z + CASE WHEN v >= 60 THEN 1.07 WHEN v >= 20 THEN -0.94 ELSE -0.50 END;
  -- weekend event
  z := z + CASE WHEN (f->>'is_weekend')::boolean THEN 0.66 ELSE -1.02 END;
  -- 7-day over 14-day amalgam median
  v := (f->>'ma7_over_ma14')::numeric;
  IF v IS NOT NULL THEN z := z + CASE WHEN v > 1.05 THEN 0.56 WHEN v < 0.95 THEN -1.23 ELSE 0 END; END IF;
  -- cost vs the event amalgam median
  v := (f->>'cost_vs_amalgam')::numeric;
  IF v IS NOT NULL THEN z := z + CASE WHEN v >= 0.8 THEN -1.29 WHEN v < 0.5 THEN 0.41 ELSE 0.15 END; END IF;
  -- moneyness = cost / realized anchor
  v := (f->>'moneyness')::numeric;
  IF v IS NOT NULL THEN
    z := z + CASE WHEN v < 0.5 THEN -0.50 WHEN v < 0.6 THEN -0.26 WHEN v < 0.7 THEN 0.39
                  WHEN v < 0.8 THEN 0.06 WHEN v < 0.9 THEN 0.51 ELSE -1.09 END;
  END IF;
  -- regime
  z := z + CASE f->>'regime' WHEN 'DUMPING' THEN -0.89 WHEN 'SOFTENING' THEN 0.17
                             WHEN 'RISING' THEN 0.17 WHEN 'STABLE' THEN 0.17 ELSE -0.44 END;
  -- days out (the feed only carries 7+)
  v := coalesce((f->>'dte')::numeric, 30);
  z := z + CASE WHEN v <= 14 THEN 0.12 WHEN v <= 21 THEN -0.32 WHEN v <= 30 THEN 0.50 ELSE 0 END;
  -- ticket cost, lot size
  v := coalesce((f->>'cost')::numeric, 0);
  z := z + CASE WHEN v < 50 THEN 0.23 ELSE -0.11 END;
  q := coalesce((f->>'quantity')::int, 2);
  z := z + CASE WHEN q <= 2 THEN 0.10 WHEN q <= 4 THEN -0.10 ELSE -0.35 END;

  z := -1.32 + 0.6 * z;   -- base = logit(0.21)
  RETURN round((1 / (1 + exp(-GREATEST(LEAST(z, 30), -30))))::numeric, 4);
END $fn$;
COMMENT ON FUNCTION public.deal_score_v1(jsonb) IS
  'Market-only heuristic P(win) for deals flagged 7+ days out (v1.1): resale velocity (sales_7d), weekend, 7d/14d MA trend, cost/amalgam, moneyness, regime, days out, cost, lot. Shrunk bucket log-odds from the 2026-09-11 label (72 rows ≥7d). No news/social/team inputs. Provisional. D0 mig 20260911162000.';

CREATE OR REPLACE FUNCTION public.deal_gate_v1(f jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN f IS NULL THEN 'OK'
    WHEN (f->>'moneyness')::numeric >= 0.9 THEN 'SUPPRESS at-market'
    WHEN (f->>'ma7_over_ma14')::numeric < 0.95 OR f->>'regime' = 'DUMPING' THEN 'SUPPRESS falling-market'
    WHEN (f->>'moneyness')::numeric < 0.5 THEN 'VERIFY too-cheap'
    WHEN coalesce((f->>'sales_7d')::numeric, 0) < 20 THEN 'VERIFY thin-market'
    ELSE 'OK' END
$fn$;
COMMENT ON FUNCTION public.deal_gate_v1(jsonb) IS
  'Feed gate v1.1 (7+ day window): SUPPRESS at-market (moneyness ≥0.9, 1/21 won) · SUPPRESS falling-market (7d/14d MA <0.95 = 0/16, or DUMPING = 0/8) · VERIFY too-cheap (<0.5× anchor) · VERIFY thin-market (<20 sales in the prior 7 days). D0 mig 20260911162000.';

-- Re-score every snapshot row (the trigger only fires on a features change).
UPDATE public.deal_signal_snapshot
   SET score_v1 = public.deal_score_v1(features), gate_v1 = public.deal_gate_v1(features);

-- ── 4. Timing labels: the feed only carries 7+ days ───────────────────────────
CREATE OR REPLACE VIEW public.v_deals_feed_ranked AS
SELECT f.tevo_event_id, f.gt_listing_id, f.gt_event_id, f.event_name, f.event_date, s.league,
       f.zone, f.section, f."row", f.quantity, f.gt_price,
       f.win_prob AS feed_win_prob, f.net_profit_pct AS feed_net_profit_pct, f.confidence AS feed_confidence,
       s.score_v1, s.gate_v1, s.score_v0, s.model_prob,
       coalesce(s.model_prob, s.score_v1) AS score,
       s.dte, CASE WHEN s.dte <= 14 THEN '7-14D' WHEN s.dte <= 30 THEN '15-30D' ELSE '31D+' END AS timing,
       s.moneyness, s.ma7_over_ma14, s.regime, s.vs_zone_pct, s.cost_vs_amalgam, s.is_weekend,
       s.as_of_flag, s.captured_at, f.first_seen_at,
       rank() OVER (ORDER BY coalesce(s.model_prob, s.score_v1) DESC NULLS LAST, f.first_seen_at DESC) AS rank,
       f.source, f.evo_ticket_group_id
FROM public.gotickets_deals_feed f
JOIN public.deal_signal_snapshot s ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
WHERE f.gone_at IS NULL;
-- ── 5. get_deals_feed: timing labels ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_deals_feed(
  p_limit integer DEFAULT 100,
  p_since timestamp with time zone DEFAULT NULL,
  p_min_roi numeric DEFAULT NULL,
  p_min_confidence text DEFAULT NULL,
  p_include_gone boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
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
    'active_by_source', (SELECT coalesce(jsonb_object_agg(source, n), '{}'::jsonb) FROM (SELECT source, count(*) AS n FROM public.gotickets_deals_feed WHERE gone_at IS NULL GROUP BY source) s),
    'suppressed_n', (SELECT count(*) FROM public.gotickets_deals_feed f
                       JOIN public.deal_signal_snapshot s ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
                      WHERE f.gone_at IS NULL AND s.gate_v1 LIKE 'SUPPRESS%'),
    'verify_n',     (SELECT count(*) FROM public.gotickets_deals_feed f
                       JOIN public.deal_signal_snapshot s ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
                      WHERE f.gone_at IS NULL AND s.gate_v1 LIKE 'VERIFY%'),
    'score_version', 'v1_market_only',
    'last_scan_at', (SELECT max(GREATEST(last_scanned_at, last_evo_scanned_at)) FROM public.gotickets_deals_scan_state),
    'deals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'source', source, 'evo_ticket_group_id', evo_ticket_group_id,
        'tevo_event_id', tevo_event_id, 'gt_event_id', gt_event_id, 'gt_listing_id', gt_listing_id,
        'event_name', event_name, 'event_date', event_date,
        'zone', zone, 'section', section, 'row', "row", 'quantity', quantity,
        'gt_price', gt_price,
        'zone_median', zone_median, 'zone_n', zone_n, 'vs_zone_pct', vs_zone_pct,
        'section_median', section_median, 'section_n', section_n, 'vs_section_pct', vs_section_pct,
        'realized_median', realized_median, 'realized_n', realized_n,
        'est_net_resale', est_net_resale, 'net_profit_pct', net_profit_pct, 'win_prob', win_prob,
        'est_net_resale_raw', est_net_resale_raw, 'net_profit_pct_raw', net_profit_pct_raw, 'win_prob_raw', win_prob_raw,
        'regime', regime, 'dte_now', dte_now, 'degr_excess_pct', degr_excess_pct, 'degr_factor', degr_factor,
        'seller_fee_pct', seller_fee_pct, 'resale_basis', resale_basis, 'confidence', confidence,
        'mod_z', mod_z, 'is_accessible', is_accessible, 'in_hand_date', in_hand_date,
        'first_seen_at', first_seen_at, 'last_seen_at', last_seen_at, 'gone_at', gone_at,
        'score_v1', score_v1, 'gate', gate_v1, 'timing', timing,
        'dte', s_dte, 'moneyness', moneyness, 'ma7_over_ma14', ma7_over_ma14, 'is_weekend', is_weekend
      ) ORDER BY first_seen_at DESC, score_v1 DESC NULLS LAST)
      FROM (
        SELECT f.*, s.score_v1, s.gate_v1, s.dte AS s_dte, s.moneyness, s.ma7_over_ma14, s.is_weekend,
               CASE WHEN s.dte IS NULL THEN NULL WHEN s.dte <= 14 THEN '7-14D' WHEN s.dte <= 30 THEN '15-30D' ELSE '31D+' END AS timing
        FROM public.gotickets_deals_feed f
        LEFT JOIN public.deal_signal_snapshot s
               ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
        WHERE (p_include_gone OR f.gone_at IS NULL)
          AND (p_include_gone OR s.gate_v1 IS NULL OR s.gate_v1 NOT LIKE 'SUPPRESS%')
          AND (p_since IS NULL OR f.first_seen_at > p_since)
          AND (v_minroi IS NULL OR f.net_profit_pct IS NULL OR f.net_profit_pct >= v_minroi)
          AND (p_min_confidence IS NULL
               OR (p_min_confidence='high' AND f.confidence='high')
               OR (p_min_confidence='med'  AND f.confidence IN ('high','med')))
        ORDER BY f.first_seen_at DESC, s.score_v1 DESC NULLS LAST
        LIMIT LEAST(GREATEST(p_limit,1),500)
      ) q), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;
