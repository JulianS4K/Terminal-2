-- Migration 20260819232000 · level:data-collection · lane:D0 · writes:scan_gotickets_deals(13-arg)[replace],get_deals_feed(5-arg)[replace],gotickets_deals_feed(+zone_median,+zone_n,+vs_zone_pct) · reads:gotickets_event,gt_listings_poll_state,performer_zones,gotickets_listings_snapshots · pre:20260811273000 (curated-zone scanner v2), 20260811280000 (perf incident fix), 20260819230530 (drain/scan cron split) · auth:OPERATOR-DIRECTED 2026-08-19
-- feat (2026-08-19) — deal feed becomes a ZONE-level outlier feed; the realized anchor is optional.
--
-- OPERATOR DIRECTIVE. "Robust outlier in its zone not section." + "2 is optional, just report
-- outliers" (gate 2 = the realized SeatGeek resale anchor).
--
-- WHAT CHANGES
--   1. OUTLIER SCOPE — median + MAD (z <= -3.5) is computed across the listings in the same
--      CURATED ZONE, not the same section string. `mod_z` is therefore a zone z-score from here
--      on, and the new zone_median / zone_n / vs_zone_pct columns carry the zone statistics.
--      section_median / section_n / vs_section_pct keep their old section meaning and are now
--      reference-only (nothing gates on them).
--   2. REALIZED ANCHOR OPTIONAL — an outlier is reported whether or not SeatGeek/SeatData
--      realized comps exist for its event x zone. Where they exist the row still carries
--      realized_median / est_net_resale / net_profit_pct / win_prob and a high/med/low
--      confidence; where they don't, those columns are NULL and confidence is 'outlier'.
--      The >=15% / >=70% thresholds no longer FILTER the feed — they are scoring inputs, and
--      the operator narrows to proven rows with the UI's MIN PROFIT control (get_deals_feed's
--      p_min_roi). Reporting an outlier only when comps happen to exist made having comps a
--      reason to be dropped, which is the opposite of "just report outliers".
--   3. get_deals_feed — the p_min_roi filter is now NULL-safe (`net_profit_pct IS NULL OR ...`),
--      otherwise the UI's default 15% filter would hide every one of the new anchor-less rows;
--      and the payload gains zone_median / zone_n / vs_zone_pct / vs_section_pct.
--
--   3b. EVENT NAME/DATE — coalesce from gotickets_event when sg_events_canonical has no row.
--      24 of the first 24 anchor-less outliers came back with NULL event_name AND NULL
--      event_date: those events are deal-capable (curated zone keys on performer+venue) but
--      unmapped to SeatGeek, and under the old anchor-required rule they never produced a row,
--      so the gap was invisible. A NULL event_date also disables the <14d retire rule from mig
--      20260811264000 for exactly those rows.
--
--   4. CANDIDATE BUILD (perf — this is the statement that has been timing out). Was: aggregate
--      4h of the 330M-row gotickets_listings_snapshots grouped by tevo_event_id, every run. That
--      blew the scanner's own 50s budget repeatedly (7 of 12 runs at 23:00 UTC), and until mig
--      20260819230530 split the crons it took the drain down with it. Now: start from the events
--      that can actually produce a deal — GT events with a CURATED zone, >=14d out, polled in
--      the last 30 min — take the 4x freshest-polled of those, and resolve each one's newest
--      capture with a bounded LATERAL max() that rides the snapshots PK
--      (gt_event_id, captured_at, gt_listing_id). ~120 index probes at ~8ms instead of a
--      multi-million-row aggregate. Same freshest-first ordering, same _cand(ev, cap) shape.
--
-- DRIFT NOTE. The deployed scan_gotickets_deals is the 13-arg form (degradation params
-- p_degr_* + p_dumping_gate); the newest version in git (mig 20260811280000) is the 8-arg form,
-- so prod carried a definition no migration file describes. This migration is written against
-- the DEPLOYED definition (pg_get_functiondef, md5 495353672f213269d700f0de853591da) and keeps
-- the 13-arg signature exactly — replacing rather than overloading, so `scan_gotickets_deals(30)`
-- stays unambiguous. Applying this file also brings the tree back in sync with prod.
--
-- Already applied to prod · via MCP 2026-08-19 23:16 UTC, + the emeta name/date fallback at
--   23:22 UTC and the upsert name/date refresh at 23:26 UTC. Deployed scan_gotickets_deals md5 da949a2506380bdc6fec661473b3f795
--   and get_deals_feed md5 abaf9a4f467fdb863a372b01d708d02a both match the locally tested build
--   byte-for-byte. First prod run: 30 events scanned in 3.2s (was timing out at 50s), 24 zone
--   outliers, all 24 anchor-less — i.e. every one of them invisible under the old rule.
--
-- ROLLBACK: restore the mig 20260811273000 scanner + the pre-existing get_deals_feed; the three
--   added columns are additive and can stay (DROP COLUMN if a clean revert is wanted).

ALTER TABLE public.gotickets_deals_feed
  ADD COLUMN IF NOT EXISTS zone_median numeric,
  ADD COLUMN IF NOT EXISTS zone_n      integer,
  ADD COLUMN IF NOT EXISTS vs_zone_pct integer;

COMMENT ON COLUMN public.gotickets_deals_feed.zone_median IS
  'Median all-in price across the listings in this listing''s CURATED zone at gt_captured_at. The outlier test runs against this (mod_z is a zone z-score). D0 mig 20260819232000.';
COMMENT ON COLUMN public.gotickets_deals_feed.section_median IS
  'Median all-in price across the listings in this listing''s SECTION. Reference only since mig 20260819232000 — the outlier gate uses zone_median.';

CREATE OR REPLACE FUNCTION public.scan_gotickets_deals(p_max_events integer DEFAULT 20, p_z_threshold numeric DEFAULT 3.5, p_min_section_n integer DEFAULT 5, p_min_section_median numeric DEFAULT 50, p_min_roi numeric DEFAULT 0.15, p_seller_fee numeric DEFAULT NULL::numeric, p_min_realized_n integer DEFAULT 8, p_min_win_prob numeric DEFAULT 0.70, p_degr_ma_days integer DEFAULT 14, p_degr_halflife numeric DEFAULT 7.0, p_degr_floor numeric DEFAULT '-0.25'::numeric, p_degr_ceil numeric DEFAULT 0.15, p_dumping_gate boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
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
  PERFORM set_config('statement_timeout', '50000', true);

  -- Candidates: deal-capable events only (curated zone, >=14d out), freshest-polled first, with
  -- each event's newest capture resolved by a bounded PK probe. See the header's perf note.
  CREATE TEMP TABLE _cand ON COMMIT DROP AS
  WITH pool AS (
    SELECT DISTINCT ON (e.id)
           e.id AS ev, g.gt_event_id, ps.last_polled_listings_at, st.last_gt_cap
    FROM public.gotickets_event g
    JOIN public.events e ON e.id = g.tevo_event_id
    JOIN public.gt_listings_poll_state ps ON ps.gt_event_id = g.gt_event_id
    LEFT JOIN public.gotickets_deals_scan_state st ON st.tevo_event_id = e.id
    WHERE g.status = 'AS_SCHEDULED'
      AND g.event_time_utc > now() + interval '14 days'
      AND ps.last_polled_listings_at > now() - interval '30 minutes'
      AND EXISTS (SELECT 1 FROM public.performer_zones pz
                   WHERE pz.performer_id = e.primary_performer_id
                     AND pz.venue_id = e.venue_id
                     AND pz.source = 'curated')
    ORDER BY e.id, ps.last_polled_listings_at DESC
  ),
  freshest AS (
    SELECT * FROM pool ORDER BY last_polled_listings_at DESC LIMIT GREATEST(p_max_events,1) * 4
  )
  SELECT f.ev, c.cap
  FROM freshest f
  CROSS JOIN LATERAL (
    SELECT max(s.captured_at) AS cap
    FROM public.gotickets_listings_snapshots s
    WHERE s.gt_event_id = f.gt_event_id
      AND s.captured_at > now() - interval '2 hours'
  ) c
  WHERE c.cap IS NOT NULL
    AND c.cap > coalesce(f.last_gt_cap, 'epoch'::timestamptz)
  ORDER BY c.cap DESC
  LIMIT GREATEST(p_max_events, 1);

  SELECT count(*) INTO v_events FROM _cand;
  IF v_events = 0 THEN
    RETURN jsonb_build_object('scanned_events',0,'new_deals',0,'gone',0,'at',now());
  END IF;

  CREATE TEMP TABLE _scored ON COMMIT DROP AS
  WITH gt AS (
    SELECT g.tevo_event_id AS ev, g.gt_event_id AS gt_event_id, g.gt_listing_id, btrim(g.section) AS section, g.row, g.quantity,
           g.all_in_price::numeric AS price, g.in_hand_date, c.cap AS gt_cap, g.notes,
           (g.row ~* 'wc|wheelchair|accessible' OR g.section ~* 'accessible') AS is_accessible
    FROM public.gotickets_listings_snapshots g
    JOIN _cand c ON c.ev = g.tevo_event_id AND g.captured_at = c.cap
    WHERE g.all_in_price > 0 AND coalesce(g.general_admission,false)=false AND g.section IS NOT NULL
  ),
  emeta AS (
    -- Name/date fall back to the GoTickets event when there is no SeatGeek canonical row.
    -- Curated zones key on performer+venue, so an event can be deal-capable without an SG
    -- mapping; before the anchor became optional those events never produced a row, so the
    -- NULLs never showed. The GT fallback is read through a LIMIT-1 lateral because
    -- gotickets_event is not unique on tevo_event_id — a plain join would duplicate listings.
    SELECT e.id AS ev, e.venue_id,
           coalesce(sgc.sg_event_name, ge.name)                        AS nm,
           coalesce(sgc.sg_datetime_utc, ge.event_time_utc)::date      AS dt,
           e.primary_performer_id AS pid,
           (EXTRACT(dow FROM coalesce(sgc.sg_datetime_utc, ge.event_time_utc))::int IN (0,5,6)) AS is_weekend,
           CASE WHEN e.event_type='game' THEN 'Sports'
                WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                ELSE 'Other' END AS category
    FROM public.events e
    LEFT JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = e.id
    LEFT JOIN LATERAL (
      SELECT g2.name, g2.event_time_utc
      FROM public.gotickets_event g2
      WHERE g2.tevo_event_id = e.id
      ORDER BY g2.event_time_utc
      LIMIT 1
    ) ge ON true
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    WHERE e.id IN (SELECT ev FROM _cand)
  ),
  gtz AS (
    SELECT gt.*, em.nm, em.dt, em.pid, em.venue_id, em.category, em.is_weekend,
           public.gt_curated_zone_id(em.pid, em.venue_id, gt.section) AS zone_id
    FROM gt JOIN emeta em ON em.ev = gt.ev
  ),
  -- ZONE statistics: the outlier test (operator directive 2026-08-19).
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
  -- SECTION statistics: reference only, nothing gates on these any more.
  ss AS (
    SELECT ev, section, count(*) AS n,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY price)::numeric AS med
    FROM gt GROUP BY ev, section
  ),
  dtrend_daily AS (
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
    SELECT g.ev, g.gt_event_id, g.gt_listing_id, g.nm AS event_name, g.dt AS event_date,
           g.pid, g.venue_id, g.category, g.is_weekend, g.zone_id,
           g.section, g.row, g.quantity, g.price, g.in_hand_date, g.gt_cap,
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
      AND (
            (m.madv > 0 AND 0.6745*(g.price - z.med)/m.madv <= -v_z)
         OR (m.madv = 0 AND g.price < z.q1 - 1.5*(z.q3 - z.q1))
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
         CASE
           WHEN c.basis IS NULL THEN 'outlier'
           WHEN c.notes ~* 'obstruct|limited|partial|restricted|obov|side view|behind|pole|no view' THEN 'low'
           WHEN c.basis='realized' AND c.r_n >= 20 THEN 'high'
           WHEN c.basis='realized' THEN 'med'
           WHEN c.basis='historic_realized' AND c.r_n >= 30 THEN 'med'
           ELSE 'low' END AS confidence,
         c.is_accessible, c.in_hand_date, c.gt_cap AS gt_captured_at
  FROM chosen c;   -- every zone outlier, anchored or not (was: WHERE c.basis IS NOT NULL)

  SELECT
    count(*),
    count(*) FILTER (WHERE resale_basis IS NULL),
    count(*) FILTER (WHERE realized_n >= p_min_realized_n AND win_prob_raw >= p_min_win_prob),
    count(*) FILTER (WHERE realized_n >= p_min_realized_n AND win_prob     >= p_min_win_prob),
    count(*) FILTER (WHERE realized_n >= p_min_realized_n AND win_prob     >= p_min_win_prob AND regime='DUMPING')
  INTO v_total, v_outlier_only, v_raw_pass, v_adj_pass, v_dumping
  FROM _scored;

  -- The >=15% / >=70% thresholds no longer filter; only the (default-off) dumping gate does.
  CREATE TEMP TABLE _deals ON COMMIT DROP AS
    SELECT * FROM _scored
    WHERE (NOT p_dumping_gate OR coalesce(regime,'UNKNOWN') <> 'DUMPING');

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
       gt_price, zone_median, zone_n, vs_zone_pct, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct,
       dte_now, degr_excess_pct, degr_factor, regime,
       est_net_resale, net_profit_pct, win_prob,
       est_net_resale_raw, net_profit_pct_raw, win_prob_raw, confidence,
       is_accessible, in_hand_date, gt_captured_at, first_seen_at, last_seen_at, gone_at)
    SELECT ev, gt_event_id, gt_listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, zone_median, zone_n, vs_zone_pct, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct,
       dte_now, degr_excess_pct, degr_factor, regime,
       est_net_resale, net_profit_pct, win_prob,
       est_net_resale_raw, net_profit_pct_raw, win_prob_raw, confidence,
       is_accessible, in_hand_date, gt_captured_at, now(), now(), NULL
    FROM _deals
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      gt_event_id=excluded.gt_event_id,
      -- name/date must refresh too: they were INSERT-only, so a row that first appeared while
      -- its event had no SG canonical row (or was renamed/rescheduled) kept a stale value for
      -- the life of the row — the upsert path is the only one a re-seen listing ever takes.
      event_name=excluded.event_name, event_date=excluded.event_date,
      gt_price=excluded.gt_price,
      zone_median=excluded.zone_median, zone_n=excluded.zone_n, vs_zone_pct=excluded.vs_zone_pct,
      section_median=excluded.section_median, section_n=excluded.section_n,
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
    'outliers', jsonb_build_object(
      'scope', 'curated_zone', 'total', v_total, 'outlier_only', v_outlier_only,
      'anchored_pass_raw', v_raw_pass, 'anchored_pass_adj', v_adj_pass),
    'degr', jsonb_build_object(
      'ma_days', v_days, 'model', 'ou_mean_reversion', 'halflife_days', v_hl, 'kappa', round(v_kappa,4),
      'floor', v_flr, 'ceil', v_ceil, 'dumping_gate', p_dumping_gate,
      'raw_pass', v_raw_pass, 'adj_pass', v_adj_pass, 'dumping_in_adj_pass', v_dumping, 'gated', v_gated),
    'at', now());
END;
$function$;

REVOKE ALL ON FUNCTION public.scan_gotickets_deals(integer,numeric,integer,numeric,numeric,numeric,integer,numeric,integer,numeric,numeric,numeric,boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.scan_gotickets_deals(integer,numeric,integer,numeric,numeric,numeric,integer,numeric,integer,numeric,numeric,numeric,boolean) TO service_role;

-- get_deals_feed: NULL-safe ROI filter (anchor-less rows have no net_profit_pct and would
-- otherwise be hidden by the UI's default 15% filter) + zone fields in the payload.
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
        'gt_price', gt_price,
        'zone_median', zone_median, 'zone_n', zone_n, 'vs_zone_pct', vs_zone_pct,
        'section_median', section_median, 'section_n', section_n, 'vs_section_pct', vs_section_pct,
        'realized_median', realized_median, 'realized_n', realized_n,
        'est_net_resale', est_net_resale, 'net_profit_pct', net_profit_pct, 'win_prob', win_prob,
        'est_net_resale_raw', est_net_resale_raw, 'net_profit_pct_raw', net_profit_pct_raw, 'win_prob_raw', win_prob_raw,
        'regime', regime, 'dte_now', dte_now, 'degr_excess_pct', degr_excess_pct, 'degr_factor', degr_factor,
        'seller_fee_pct', seller_fee_pct, 'resale_basis', resale_basis, 'confidence', confidence,
        'mod_z', mod_z, 'is_accessible', is_accessible, 'in_hand_date', in_hand_date,
        'first_seen_at', first_seen_at, 'last_seen_at', last_seen_at, 'gone_at', gone_at
      ) ORDER BY first_seen_at DESC, win_prob DESC NULLS LAST)
      FROM (
        SELECT * FROM public.gotickets_deals_feed f
        WHERE (p_include_gone OR f.gone_at IS NULL)
          AND (p_since IS NULL OR f.first_seen_at > p_since)
          AND (v_minroi IS NULL OR f.net_profit_pct IS NULL OR f.net_profit_pct >= v_minroi)
          AND (p_min_confidence IS NULL
               OR (p_min_confidence='high' AND f.confidence='high')
               OR (p_min_confidence='med'  AND f.confidence IN ('high','med')))
        ORDER BY f.first_seen_at DESC, f.win_prob DESC NULLS LAST
        LIMIT LEAST(GREATEST(p_limit,1),500)
      ) q), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.get_deals_feed(integer,timestamptz,numeric,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_deals_feed(integer,timestamptz,numeric,text,boolean) TO authenticated, service_role;
