-- ============================================================================
-- Migration 20260911162100 — event-day PRICE MODEL (bucket v1) wired into the scanner + RESULTS ledger
--
-- Lane:     D0 (deals surface)
-- Touches:  deal_price_train · deal_price_train_state · deal_price_adjust (new tables) ·
--           deal_price_bkt_*() · deal_price_train_build(int,int) · deal_price_adjust_refresh(text,int) ·
--           deal_price_predict(…) (new) ·
--           gotickets_deals_feed (+pred_final_price, pred_roi_pct, pred_p15, price_bucket, price_model_version) ·
--           scan_listing_deals(…) (CREATE OR REPLACE — writes the prediction) ·
--           v_deal_results (new view) · get_deal_results(int) (new RPC) · cron deal_price_train_nightly
-- Pre-reqs: 20260911162000, 20260911160400 (the label)
--
-- Already applied to prod · via MCP 2026-09-11 (operator: "do it and track all results we get, so we
-- can see wins").
--
-- WHY. The scanner priced resale as realized-anchor × a clearing-curve degradation factor. On the 42
-- graded deals flagged ≥7d out that misses the actual event-day clearing price by a median 32%
-- (anchor alone: 28%) and runs 16% HIGH on median — the 15% hurdle was judged against a biased
-- number. The miss is predictable: prior-week resale velocity (corr 0.66 with the drift) and the
-- 7d/14d trend (0.36) explain most of it. And the target — event-day realized zone median — exists
-- for EVERY played curated-zone event (635 in 60 days), not just the 104 flagged deals.
--
-- MODEL (bucket v1, non-parametric, refits nightly):
--   training row = (played event, curated zone, T ∈ {7,14,21,30} days out):
--     anchor   = zone realized median over the 30 days before T          (what the scanner sees)
--     velocity = event resales (SG dedup + SeatData) in the 7 days before T
--     trend    = 7-day / 14-day amalgam listing MA at T
--     weekend, category, dte = T
--     actual   = zone realized median on event day (d-2..d), n ≥ 8
--     log_ratio = ln(actual / anchor)                                     ← the thing to predict
--   deal_price_adjust = per (dte_bkt, velocity_bkt, trend_bkt, weekend) the distribution of
--   log_ratio (median, quartiles, full array) plus 'any' roll-ups. Lookup falls back to coarser
--   buckets when n < 15.
--   deal_price_predict(anchor, cost, fee, dte, velocity, trend, weekend) →
--     pred_final = anchor × exp(median log_ratio); pred_roi = pred_final×(1-fee)/cost − 1;
--     p15 = share of the bucket's log_ratios that clear ln(1.15×cost / ((1−fee)×anchor)).
--   A parametric fit can replace the bucket medians later under the same table shape.
--
-- SCANNER. Every flagged deal now carries pred_final_price / pred_roi_pct / pred_p15 / price_bucket /
-- price_model_version next to the legacy est_net_resale / win_prob (kept for comparison).
--
-- RESULTS LEDGER. v_deal_results = every graded deal with what we predicted (feed row + flag-time
-- snapshot) beside what happened (gotickets_deal_outcome). get_deal_results(p_days) serves the
-- terminal: W/F/L totals by source, calibration of pred_p15 / pred_roi / score_v1, model-vs-legacy
-- price error, and the latest graded rows. Pre-model rows have NULL predictions.
--
-- BACKFILL: deal_price_train_build(60, N) in batches, then deal_price_adjust_refresh('bkt_v1').
-- READ-ONLY upstream. ROLLBACK: drop the new objects; re-apply scan_listing_deals from 162000;
-- ALTER TABLE gotickets_deals_feed DROP the five columns.
-- ============================================================================

-- ── 1. Training rows ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.deal_price_train (
  tevo_event_id bigint      NOT NULL,
  zone_id       bigint      NOT NULL,
  dte           int         NOT NULL,
  event_date    date        NOT NULL,
  category      text,
  is_weekend    boolean     NOT NULL,
  anchor        numeric     NOT NULL,
  anchor_n      int         NOT NULL,
  ma14          numeric,
  ma7           numeric,
  trend         numeric,
  velocity_7d   int         NOT NULL,
  actual        numeric     NOT NULL,
  actual_n      int         NOT NULL,
  log_ratio     numeric     NOT NULL,
  built_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tevo_event_id, zone_id, dte)
);
CREATE INDEX IF NOT EXISTS deal_price_train_date_idx ON public.deal_price_train (event_date DESC);
REVOKE ALL ON public.deal_price_train FROM PUBLIC, anon;
GRANT SELECT ON public.deal_price_train TO authenticated, service_role;
COMMENT ON TABLE public.deal_price_train IS
  'Price-model training rows: one per played curated-zone event × zone × T days out. anchor = zone realized median in the 30d before T; actual = event-day zone realized median; log_ratio = ln(actual/anchor). Built nightly by deal_price_train_build(). D0 mig 20260911162100.';

CREATE TABLE IF NOT EXISTS public.deal_price_train_state (
  tevo_event_id bigint PRIMARY KEY,
  built_at      timestamptz NOT NULL DEFAULT now(),
  rows_written  int NOT NULL DEFAULT 0
);
REVOKE ALL ON public.deal_price_train_state FROM PUBLIC, anon;
GRANT SELECT ON public.deal_price_train_state TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.deal_price_bkt_dte(p int)       RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN p <= 14 THEN '7-14' WHEN p <= 21 THEN '15-21' WHEN p <= 30 THEN '22-30' ELSE '31+' END $$;
CREATE OR REPLACE FUNCTION public.deal_price_bkt_vel(p int)       RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN coalesce(p,0) >= 60 THEN '60+' WHEN coalesce(p,0) >= 20 THEN '20-59' ELSE '<20' END $$;
CREATE OR REPLACE FUNCTION public.deal_price_bkt_trend(p numeric) RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN p IS NULL THEN 'unknown' WHEN p < 0.95 THEN 'falling' WHEN p > 1.05 THEN 'rising' ELSE 'flat' END $$;

CREATE OR REPLACE FUNCTION public.deal_price_train_build(p_days_back integer DEFAULT 60, p_max_events integer DEFAULT 40)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE v_events int := 0; v_rows int := 0; v_start timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '55000', true);

  CREATE TEMP TABLE _ev ON COMMIT DROP AS
  SELECT e.id AS ev, e.occurs_at_local::date AS d, e.primary_performer_id AS pid, e.venue_id,
         (EXTRACT(isodow FROM e.occurs_at_local::timestamptz)::int IN (5,6,7)) AS is_weekend,
         CASE WHEN e.event_type='game' THEN 'Sports'
              WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
              ELSE 'Other' END AS category
  FROM public.events e
  LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
  WHERE e.occurs_at_local IS NOT NULL
    AND e.occurs_at_local::timestamptz BETWEEN now() - make_interval(days => GREATEST(p_days_back,1)) AND now() - interval '1 day'
    AND EXISTS (SELECT 1 FROM public.performer_zones pz WHERE pz.performer_id = e.primary_performer_id AND pz.venue_id = e.venue_id AND pz.source='curated')
    AND NOT EXISTS (SELECT 1 FROM public.deal_price_train_state st WHERE st.tevo_event_id = e.id)
  ORDER BY e.occurs_at_local::timestamptz
  LIMIT GREATEST(p_max_events, 1);
  SELECT count(*) INTO v_events FROM _ev;
  IF v_events = 0 THEN RETURN jsonb_build_object('events', 0, 'rows', 0); END IF;

  CREATE TEMP TABLE _sales ON COMMIT DROP AS
  WITH raw AS (
    SELECT DISTINCT ON (s.sg_sale_id) s.tevo_event_id AS ev, s.broadcast_price::numeric AS px, s.section, s.sale_at_utc::date AS sd
    FROM public.seatgeek_sales_snapshots s JOIN _ev e ON e.ev = s.tevo_event_id
    WHERE s.broadcast_price > 0 AND s.sale_at_utc >= (e.d - 45)::timestamptz AND s.sale_at_utc < (e.d + 1)::timestamptz
    ORDER BY s.sg_sale_id, s.pulled_at DESC
  ),
  raw2 AS (
    SELECT ev, px, section, sd FROM raw
    UNION ALL
    SELECT sd.tevo_event_id, sd.price::numeric, sd.section, sd.sale_timestamp::date
    FROM public.seatdata_sales_snapshots sd JOIN _ev e ON e.ev = sd.tevo_event_id
    WHERE sd.price > 0 AND sd.sale_timestamp >= (e.d - 45)::timestamptz AND sd.sale_timestamp < (e.d + 1)::timestamptz
  )
  SELECT r.ev, r.px, r.sd, z.zone_id
  FROM raw2 r
  JOIN _ev e ON e.ev = r.ev
  LEFT JOIN LATERAL (
    SELECT pz.id AS zone_id FROM public.performer_zones pz
    JOIN public.performer_zone_rules pzr ON pzr.zone_id = pz.id
    WHERE pz.performer_id = e.pid AND pz.venue_id = e.venue_id AND pz.source = 'curated'
      AND public.section_in_range(coalesce((regexp_match(r.section, '(\d{2,4})'))[1], r.section), pzr.section_from, pzr.section_to)
    LIMIT 1) z ON true;

  CREATE TEMP TABLE _ma ON COMMIT DROP AS
  SELECT d.event_id AS ev, d.snapshot_date, avg(d.amalgam_median) AS med
  FROM public.event_listing_snapshot_daily d JOIN _ev e ON e.ev = d.event_id
  WHERE d.amalgam_median > 0 AND d.snapshot_date BETWEEN e.d - 45 AND e.d
  GROUP BY 1, 2;

  WITH t AS (SELECT unnest(ARRAY[7,14,21,30]) AS dte),
  tgt AS (
    SELECT s.ev, s.zone_id, count(*) AS n, percentile_cont(0.5) WITHIN GROUP (ORDER BY s.px)::numeric AS med
    FROM _sales s JOIN _ev e ON e.ev = s.ev
    WHERE s.zone_id IS NOT NULL AND s.sd BETWEEN e.d - 2 AND e.d
    GROUP BY 1, 2 HAVING count(*) >= 8
  ),
  anc AS (
    SELECT s.ev, s.zone_id, t.dte, count(*) AS n, percentile_cont(0.5) WITHIN GROUP (ORDER BY s.px)::numeric AS med
    FROM _sales s JOIN _ev e ON e.ev = s.ev CROSS JOIN t
    WHERE s.zone_id IS NOT NULL AND s.sd >= e.d - t.dte - 30 AND s.sd < e.d - t.dte
    GROUP BY 1, 2, 3 HAVING count(*) >= 8
  ),
  vel AS (
    SELECT s.ev, t.dte, count(*) AS n
    FROM _sales s JOIN _ev e ON e.ev = s.ev CROSS JOIN t
    WHERE s.sd >= e.d - t.dte - 7 AND s.sd < e.d - t.dte
    GROUP BY 1, 2
  ),
  ma AS (
    SELECT m.ev, t.dte,
           avg(m.med) FILTER (WHERE m.snapshot_date BETWEEN e.d - t.dte - 13 AND e.d - t.dte) AS ma14,
           avg(m.med) FILTER (WHERE m.snapshot_date BETWEEN e.d - t.dte - 6  AND e.d - t.dte) AS ma7
    FROM _ma m JOIN _ev e ON e.ev = m.ev CROSS JOIN t
    GROUP BY 1, 2
  ),
  ins AS (
    INSERT INTO public.deal_price_train
      (tevo_event_id, zone_id, dte, event_date, category, is_weekend, anchor, anchor_n, ma14, ma7, trend, velocity_7d, actual, actual_n, log_ratio)
    SELECT a.ev, a.zone_id, a.dte, e.d, e.category, e.is_weekend, round(a.med,2), a.n,
           round(ma.ma14::numeric,2), round(ma.ma7::numeric,2),
           CASE WHEN ma.ma14 > 0 THEN round((ma.ma7/ma.ma14)::numeric,4) END,
           coalesce(v.n,0), round(g.med,2), g.n, round(ln(g.med / a.med)::numeric, 4)
    FROM anc a
    JOIN tgt g ON g.ev = a.ev AND g.zone_id = a.zone_id
    JOIN _ev e ON e.ev = a.ev
    LEFT JOIN vel v ON v.ev = a.ev AND v.dte = a.dte
    LEFT JOIN ma ON ma.ev = a.ev AND ma.dte = a.dte
    WHERE a.med > 0 AND g.med > 0
    ON CONFLICT (tevo_event_id, zone_id, dte) DO NOTHING
    RETURNING tevo_event_id)
  SELECT count(*) INTO v_rows FROM ins;

  INSERT INTO public.deal_price_train_state (tevo_event_id, built_at, rows_written)
  SELECT e.ev, now(), (SELECT count(*) FROM public.deal_price_train tr WHERE tr.tevo_event_id = e.ev) FROM _ev e
  ON CONFLICT (tevo_event_id) DO UPDATE SET built_at = now(), rows_written = excluded.rows_written;

  RETURN jsonb_build_object('events', v_events, 'rows', v_rows,
                            'elapsed_ms', round(extract(epoch FROM clock_timestamp() - v_start) * 1000));
END $fn$;
COMMENT ON FUNCTION public.deal_price_train_build(integer,integer) IS
  'Build price-model training rows for played curated-zone events not yet built (oldest first, <= p_max_events per call): per zone × T∈{7,14,21,30}: anchor (30d realized median before T), velocity (7d resales before T), 7d/14d listing MA trend, event-day actual (d-2..d, n>=8). service_role only. D0 mig 20260911162100.';

-- ── 2. Bucket model ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.deal_price_adjust (
  model_version text NOT NULL,
  dte_bkt       text NOT NULL,
  vel_bkt       text NOT NULL,
  trend_bkt     text NOT NULL,
  weekend       text NOT NULL,
  n             int  NOT NULL,
  med_log       numeric NOT NULL,
  p25_log       numeric,
  p75_log       numeric,
  log_ratios    numeric[] NOT NULL,
  refreshed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (model_version, dte_bkt, vel_bkt, trend_bkt, weekend)
);
REVOKE ALL ON public.deal_price_adjust FROM PUBLIC, anon;
GRANT SELECT ON public.deal_price_adjust TO authenticated, service_role;
COMMENT ON TABLE public.deal_price_adjust IS
  'Bucket price model: distribution of ln(event-day zone median / 30d realized anchor at T) per (days-out, velocity, trend, weekend) bucket, with ''any'' roll-ups for fallback. Refit by deal_price_adjust_refresh(). D0 mig 20260911162100.';

CREATE OR REPLACE FUNCTION public.deal_price_adjust_refresh(p_version text DEFAULT 'bkt_v1', p_train_days integer DEFAULT 120)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_n int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  DELETE FROM public.deal_price_adjust WHERE model_version = p_version;
  INSERT INTO public.deal_price_adjust (model_version, dte_bkt, vel_bkt, trend_bkt, weekend, n, med_log, p25_log, p75_log, log_ratios)
  SELECT p_version,
         coalesce(dte_bkt, 'any'), coalesce(vel_bkt, 'any'), coalesce(trend_bkt, 'any'), coalesce(weekend, 'any'),
         count(*),
         round(percentile_cont(0.5)  WITHIN GROUP (ORDER BY log_ratio)::numeric, 4),
         round(percentile_cont(0.25) WITHIN GROUP (ORDER BY log_ratio)::numeric, 4),
         round(percentile_cont(0.75) WITHIN GROUP (ORDER BY log_ratio)::numeric, 4),
         (array_agg(log_ratio ORDER BY log_ratio))[1:2000]
  FROM (
    SELECT public.deal_price_bkt_dte(dte) AS dte_bkt, public.deal_price_bkt_vel(velocity_7d) AS vel_bkt,
           public.deal_price_bkt_trend(trend) AS trend_bkt, is_weekend::text AS weekend, log_ratio
    FROM public.deal_price_train
    WHERE event_date >= current_date - GREATEST(p_train_days, 7)
  ) t
  GROUP BY GROUPING SETS ((dte_bkt, vel_bkt, trend_bkt, weekend), (dte_bkt, vel_bkt, trend_bkt), (dte_bkt, vel_bkt), (dte_bkt), ());
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('version', p_version, 'buckets', v_n,
                            'train_rows', (SELECT count(*) FROM public.deal_price_train WHERE event_date >= current_date - GREATEST(p_train_days, 7)));
END $fn$;
COMMENT ON FUNCTION public.deal_price_adjust_refresh(text,integer) IS
  'Refit the bucket price model from deal_price_train (last p_train_days of played events): full buckets + roll-ups via GROUPING SETS. service_role only. D0 mig 20260911162100.';

CREATE OR REPLACE FUNCTION public.deal_price_predict(
  p_anchor numeric, p_cost numeric, p_fee numeric, p_dte integer, p_velocity integer, p_trend numeric, p_weekend boolean,
  p_version text DEFAULT 'bkt_v1', p_min_n integer DEFAULT 15)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE r record; v_need numeric; v_p15 numeric;
BEGIN
  IF p_anchor IS NULL OR p_anchor <= 0 OR p_cost IS NULL OR p_cost <= 0 THEN RETURN NULL; END IF;
  SELECT a.* INTO r FROM public.deal_price_adjust a
  WHERE a.model_version = p_version AND a.n >= GREATEST(p_min_n, 1)
    AND a.dte_bkt   IN (public.deal_price_bkt_dte(p_dte), 'any')
    AND a.vel_bkt   IN (public.deal_price_bkt_vel(p_velocity), 'any')
    AND a.trend_bkt IN (public.deal_price_bkt_trend(p_trend), 'any')
    AND a.weekend   IN (coalesce(p_weekend,false)::text, 'any')
  ORDER BY (a.dte_bkt <> 'any')::int + (a.vel_bkt <> 'any')::int + (a.trend_bkt <> 'any')::int + (a.weekend <> 'any')::int DESC,
           a.n DESC
  LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_need := ln(1.15 * p_cost / ((1 - coalesce(p_fee, 0.10)) * p_anchor));
  SELECT round(avg((x >= v_need)::int)::numeric, 3) INTO v_p15 FROM unnest(r.log_ratios) x;
  RETURN jsonb_build_object(
    'pred_final', round(p_anchor * exp(r.med_log), 2),
    'pred_net',   round(p_anchor * exp(r.med_log) * (1 - coalesce(p_fee, 0.10)), 2),
    'pred_roi_pct', round((p_anchor * exp(r.med_log) * (1 - coalesce(p_fee, 0.10)) / p_cost - 1) * 100)::int,
    'p15', v_p15,
    'bucket', r.dte_bkt || '|' || r.vel_bkt || '|' || r.trend_bkt || '|' || r.weekend,
    'n', r.n, 'version', p_version);
END $fn$;
COMMENT ON FUNCTION public.deal_price_predict(numeric,numeric,numeric,integer,integer,numeric,boolean,text,integer) IS
  'Predicted event-day price for a deal: anchor × exp(median log_ratio of the matching bucket), predicted net ROI, and p15 = share of the bucket that clears a 15% net flip at this cost. Falls back to coarser buckets below p_min_n rows. D0 mig 20260911162100.';

-- ── 3. Feed carries the prediction ───────────────────────────────────────────
ALTER TABLE public.gotickets_deals_feed
  ADD COLUMN IF NOT EXISTS pred_final_price    numeric,
  ADD COLUMN IF NOT EXISTS pred_roi_pct        int,
  ADD COLUMN IF NOT EXISTS pred_p15            numeric,
  ADD COLUMN IF NOT EXISTS price_bucket        text,
  ADD COLUMN IF NOT EXISTS price_model_version text;

-- ── 4. Scanner writes it ─────────────────────────────────────────────────────
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
  evvel AS (
    -- prior-7-day resale velocity per event (SG dedup + SeatData) — the price model's main input
    SELECT c.ev,
           (SELECT count(DISTINCT s.sg_sale_id) FROM public.seatgeek_sales_snapshots s
             WHERE s.tevo_event_id = c.ev AND s.broadcast_price > 0 AND s.sale_at_utc > now() - interval '7 days')
         + (SELECT count(*) FROM public.seatdata_sales_snapshots sd
             WHERE sd.tevo_event_id = c.ev AND sd.price > 0 AND sd.sale_timestamp > now() - interval '7 days') AS velocity_7d
    FROM _cand c
  ),
  evtrend7 AS (
    SELECT ev, CASE WHEN avg(med) FILTER (WHERE rn BETWEEN 1 AND 14) > 0
                    THEN round((avg(med) FILTER (WHERE rn BETWEEN 1 AND 7) / avg(med) FILTER (WHERE rn BETWEEN 1 AND 14))::numeric, 4) END AS trend7_14
    FROM dtrend_ranked GROUP BY ev
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
  ),
  priced AS (
    SELECT c.*, v.velocity_7d, t.trend7_14,
           public.deal_price_predict(c.r_median, c.price, v_fee, c.dte_now, v.velocity_7d::int, t.trend7_14, c.is_weekend) AS pm
    FROM chosen c
    LEFT JOIN evvel v ON v.ev = c.ev
    LEFT JOIN evtrend7 t ON t.ev = c.ev
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
         c.is_accessible, c.in_hand_date, c.cap AS gt_captured_at,
         (c.pm->>'pred_final')::numeric AS pred_final_price, (c.pm->>'pred_roi_pct')::int AS pred_roi_pct,
         (c.pm->>'p15')::numeric AS pred_p15, c.pm->>'bucket' AS price_bucket, c.pm->>'version' AS price_model_version
  FROM priced c;

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
       is_accessible, in_hand_date, gt_captured_at, first_seen_at, last_seen_at, gone_at,
       pred_final_price, pred_roi_pct, pred_p15, price_bucket, price_model_version)
    SELECT p_source, evo_tg_id,
       ev, gt_event_id, listing_id, event_name, event_date, zone, section, "row", quantity,
       gt_price, zone_median, zone_n, vs_zone_pct, section_median, section_n, mod_z, vs_section_pct,
       realized_median, realized_n, resale_basis, seller_fee_pct,
       dte_now, degr_excess_pct, degr_factor, regime,
       est_net_resale, net_profit_pct, win_prob,
       est_net_resale_raw, net_profit_pct_raw, win_prob_raw, confidence,
       is_accessible, in_hand_date, gt_captured_at, now(), now(), NULL,
       pred_final_price, pred_roi_pct, pred_p15, price_bucket, price_model_version
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
      gt_captured_at=excluded.gt_captured_at, last_seen_at=now(), gone_at=NULL,
      pred_final_price=excluded.pred_final_price, pred_roi_pct=excluded.pred_roi_pct, pred_p15=excluded.pred_p15,
      price_bucket=excluded.price_bucket, price_model_version=excluded.price_model_version
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
COMMENT ON FUNCTION public.scan_listing_deals(text,integer,numeric,integer,numeric,numeric,numeric,integer,numeric,integer,numeric,numeric,numeric,boolean) IS
  'Deal scanner for one listing source (gotickets | evo): events with a curated zone, 7+ days out, polled in the last 30 min, newest capture newer than the last scan — nearest event first. Curated-zone MAD outliers → realized anchor → PRICE MODEL (deal_price_predict: pred_final_price / pred_roi_pct / pred_p15) → gotickets_deals_feed. D0 mig 20260911161800 / 162000 / 162100.';

-- ── 5. Results ledger ────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.v_deal_results AS
SELECT o.tevo_event_id, o.gt_listing_id, f.source, f.event_name, o.event_date, f.first_seen_at, s.dte AS dte_at_flag,
       f.section, f."row", o.quantity, o.cost,
       f.pred_final_price, f.pred_roi_pct, f.pred_p15, f.price_bucket, f.price_model_version,
       f.est_net_resale AS legacy_est_net_resale, f.win_prob AS legacy_win_prob,
       s.score_v1, s.gate_v1,
       o.realized_med AS actual_final_price, o.realized_n AS actual_n, o.realized_roi_pct AS actual_roi_pct,
       o.outcome, o.match_level, o.graded_at,
       CASE WHEN f.pred_final_price > 0 AND o.realized_med > 0 THEN round(ln(f.pred_final_price / o.realized_med)::numeric, 4) END AS price_err_log,
       CASE WHEN f.est_net_resale > 0 AND o.realized_med > 0 THEN round(ln((f.est_net_resale / (1 - coalesce(o.seller_fee_pct,0.10))) / o.realized_med)::numeric, 4) END AS legacy_err_log
FROM public.gotickets_deal_outcome o
JOIN public.gotickets_deals_feed f ON f.tevo_event_id = o.tevo_event_id AND f.gt_listing_id = o.gt_listing_id
LEFT JOIN public.deal_signal_snapshot s ON s.tevo_event_id = o.tevo_event_id AND s.gt_listing_id = o.gt_listing_id
WHERE o.outcome IN ('WIN','FLAT','LOSS');
REVOKE ALL ON public.v_deal_results FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_deal_results TO service_role;
COMMENT ON VIEW public.v_deal_results IS
  'Every graded deal: what we predicted (feed row: price-model pred_final_price / pred_roi_pct / pred_p15, legacy est_net_resale / win_prob; snapshot score_v1 / gate) beside what happened (gotickets_deal_outcome). price_err_log = ln(pred/actual). D0 mig 20260911162100.';

CREATE OR REPLACE FUNCTION public.get_deal_results(p_days integer DEFAULT 30)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE v_email text := coalesce(auth.jwt()->>'email', ''); v_out jsonb; v_since date := current_date - GREATEST(p_days, 1);
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '10000', true);
  SELECT jsonb_build_object(
    'generated_at', now(), 'since', v_since,
    'totals', (SELECT jsonb_build_object('graded', count(*), 'win', count(*) FILTER (WHERE outcome='WIN'), 'flat', count(*) FILTER (WHERE outcome='FLAT'),
                 'loss', count(*) FILTER (WHERE outcome='LOSS'), 'win_rate', round(avg((outcome='WIN')::int)::numeric, 3),
                 'median_actual_roi_pct', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY actual_roi_pct)::numeric, 1))
               FROM public.v_deal_results WHERE event_date >= v_since),
    'by_source', (SELECT coalesce(jsonb_object_agg(source, j), '{}'::jsonb) FROM (
                 SELECT source, jsonb_build_object('graded', count(*), 'win', count(*) FILTER (WHERE outcome='WIN'), 'win_rate', round(avg((outcome='WIN')::int)::numeric,3)) AS j
                 FROM public.v_deal_results WHERE event_date >= v_since GROUP BY source) x),
    'by_score_v1', (SELECT coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'n', n, 'win_rate', w) ORDER BY b), '[]'::jsonb) FROM (
                 SELECT CASE WHEN score_v1 >= 0.5 THEN 'a ≥0.50' WHEN score_v1 >= 0.3 THEN 'b 0.30-0.50' WHEN score_v1 >= 0.15 THEN 'c 0.15-0.30' WHEN score_v1 IS NOT NULL THEN 'd <0.15' ELSE 'e n/a' END AS b,
                        count(*) AS n, round(avg((outcome='WIN')::int)::numeric,3) AS w
                 FROM public.v_deal_results WHERE event_date >= v_since GROUP BY 1) x),
    'by_pred_p15', (SELECT coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'n', n, 'win_rate', w, 'avg_p15', p) ORDER BY b), '[]'::jsonb) FROM (
                 SELECT CASE WHEN pred_p15 >= 0.7 THEN 'a ≥0.70' WHEN pred_p15 >= 0.5 THEN 'b 0.50-0.70' WHEN pred_p15 >= 0.3 THEN 'c 0.30-0.50' WHEN pred_p15 IS NOT NULL THEN 'd <0.30' ELSE 'e pre-model' END AS b,
                        count(*) AS n, round(avg((outcome='WIN')::int)::numeric,3) AS w, round(avg(pred_p15)::numeric,3) AS p
                 FROM public.v_deal_results WHERE event_date >= v_since GROUP BY 1) x),
    'by_pred_roi', (SELECT coalesce(jsonb_agg(jsonb_build_object('bucket', b, 'n', n, 'win_rate', w, 'median_actual_roi', r) ORDER BY b), '[]'::jsonb) FROM (
                 SELECT CASE WHEN pred_roi_pct >= 30 THEN 'a ≥30%' WHEN pred_roi_pct >= 15 THEN 'b 15-30%' WHEN pred_roi_pct >= 0 THEN 'c 0-15%' WHEN pred_roi_pct IS NOT NULL THEN 'd <0%' ELSE 'e pre-model' END AS b,
                        count(*) AS n, round(avg((outcome='WIN')::int)::numeric,3) AS w, round(percentile_cont(0.5) WITHIN GROUP (ORDER BY actual_roi_pct)::numeric,1) AS r
                 FROM public.v_deal_results WHERE event_date >= v_since GROUP BY 1) x),
    'price_error', (SELECT jsonb_build_object('n_model', count(price_err_log), 'model_median_abs_log', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(price_err_log))::numeric,3),
                     'model_median_bias_log', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY price_err_log)::numeric,3),
                     'legacy_median_abs_log', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(legacy_err_log))::numeric,3),
                     'legacy_median_bias_log', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY legacy_err_log)::numeric,3))
                 FROM public.v_deal_results WHERE event_date >= v_since),
    'model', (SELECT jsonb_build_object('version', model_version, 'buckets', count(*), 'refreshed_at', max(refreshed_at), 'train_rows', (SELECT count(*) FROM public.deal_price_train))
              FROM public.deal_price_adjust GROUP BY model_version ORDER BY max(refreshed_at) DESC LIMIT 1),
    'recent', (SELECT coalesce(jsonb_agg(jsonb_build_object('source', source, 'event', event_name, 'event_date', event_date, 'section', section, 'qty', quantity, 'cost', cost,
                  'pred_final', pred_final_price, 'pred_roi_pct', pred_roi_pct, 'pred_p15', pred_p15, 'score_v1', score_v1, 'gate', gate_v1,
                  'actual_final', actual_final_price, 'actual_roi_pct', actual_roi_pct, 'outcome', outcome, 'graded_at', graded_at) ORDER BY graded_at DESC, event_date DESC), '[]'::jsonb)
               FROM (SELECT * FROM public.v_deal_results WHERE event_date >= v_since ORDER BY graded_at DESC, event_date DESC LIMIT 60) r)
  ) INTO v_out;
  RETURN v_out;
END $fn$;
REVOKE ALL ON FUNCTION public.get_deal_results(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deal_results(integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deal_results(integer) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_deal_results(integer) IS
  'D0 DEALS results strip: graded deals in the last p_days — W/F/L totals, by source, calibration of score_v1 / pred_p15 / pred_roi, price-model vs legacy error, latest 60 rows. Email-gated @s4kent.com. D0 mig 20260911162100.';

-- ── 6. Nightly refit ─────────────────────────────────────────────────────────
DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN RETURN; END IF;
  PERFORM cron.unschedule('deal_price_train_nightly') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'deal_price_train_nightly');
  PERFORM cron.schedule('deal_price_train_nightly', '35 6 * * *', $body$
    DO $b$ DECLARE r jsonb; BEGIN
      IF NOT public.cron_try_lock('deal_price_train') THEN RETURN; END IF;
      FOR i IN 1..8 LOOP
        r := public.deal_price_train_build(3, 40);
        EXIT WHEN (r->>'events')::int = 0;
      END LOOP;
      PERFORM public.deal_price_adjust_refresh('bkt_v1');
    END $b$;$body$);
END;
$cron$;
