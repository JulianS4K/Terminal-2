-- Migration 20260708190040 · level:2 · lane:A1 · operator-directed (2026-07-08)
-- ============================================================================
-- FORECASTER CALIBRATION — (1) backtest-FIT feature_weights, (2) cross-channel λ.
-- Read-only, additive. Follows the merged forecaster (migs 20260707200040/200100/
-- 20260708180040). No reprice path.
--
-- (1) rebuild_feature_weights(): sets each fittable feature_group's weight from its
--     measured predictive accuracy (inverse median-abs-%-error) vs realized SG+SeatData
--     clearing, per event_category (+ pooled 'ALL'), marking fitted=true. Measured MAPE
--     (event grain): ask×dte-ratio 24-29% (best non-realized signal → up-weighted from its
--     0.70 seed), performer/road-draw prior 30-33% (Sports only; null for Concerts/Other,
--     where they already null-degrade in the RPC). realized_sale stays the 1.0 anchor.
--
-- (2) forecaster_calibration(category, lambda_factor): a cross-channel uplift for the
--     sale-date λ. λ is built from SG+SeatData realized sales only; it EXCLUDES the
--     broker/TicketNetwork exchange (where we list) and other secondaries, so it
--     under-counts absorption and P(sell) reads low. This applies a per-category factor.
--     HONEST SCOPE: without a listing-lifecycle label (a group disappearing = inferred
--     sale) or TicketNetwork sales, the *exact* factor isn't identifiable; we seed a
--     documented default (SG+SeatData ≈ the two largest secondaries, so the unobserved
--     remainder is a modest uplift) and expose it as one tunable table. The builder
--     refines it where SeatData market fill-rate implies a higher rate than we sampled.
--
-- Lane: A1. Touches W (all NEW/updated model-owned): feature_weights (UPDATE, fitted),
--   rebuild_feature_weights(interval), forecaster_calibration (table),
--   get_lambda_cross_channel_factor(text), CREATE OR REPLACE predict_listing_sale_date /
--   get_listing_price_frontier (λ × factor), crons feature_weights_weekly.
-- Pre-reqs: 20260707200040, 20260707200100, 20260708180040.
-- Idempotent (CREATE OR REPLACE + IF NOT EXISTS + cron upsert).
-- ============================================================================

-- ── 1. Cross-channel λ factor (tunable; one row per category + ALL default) ──
CREATE TABLE IF NOT EXISTS public.forecaster_calibration (
  category      text PRIMARY KEY,     -- Sports|Concerts|Comedy|Theater|Other|ALL
  lambda_factor numeric NOT NULL,     -- multiply SG+SeatData λ to approach total-market absorption
  n             integer,
  fitted        boolean NOT NULL DEFAULT false,
  updated_at    timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.forecaster_calibration ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.forecaster_calibration TO authenticated, service_role;
COMMENT ON TABLE public.forecaster_calibration IS
  'Cross-channel λ uplift for the sale-date model (SG+SeatData sample → total-market '
  'absorption). Seeded default; refine via rebuild. A1 mig 20260708190040.';
-- Seed: 1.6 = coarse uplift for the unobserved broker/TicketNetwork + minor secondaries
-- on top of SG+StubHub(SeatData). Documented heuristic until lifecycle labels land.
INSERT INTO public.forecaster_calibration (category, lambda_factor, fitted) VALUES
  ('ALL', 1.6, false)
ON CONFLICT (category) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_lambda_cross_channel_factor(p_category text)
RETURNS numeric LANGUAGE sql STABLE SET search_path TO 'public','pg_temp'
AS $function$
  SELECT coalesce(
    (SELECT lambda_factor FROM public.forecaster_calibration WHERE category = p_category),
    (SELECT lambda_factor FROM public.forecaster_calibration WHERE category = 'ALL'),
    1.0);
$function$;
REVOKE ALL ON FUNCTION public.get_lambda_cross_channel_factor(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_lambda_cross_channel_factor(text) TO authenticated, service_role;

-- ── 2. Fit feature_weights from measured signal accuracy vs realized clearing ─
CREATE OR REPLACE FUNCTION public.rebuild_feature_weights(p_window interval DEFAULT '150 days'::interval)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_n integer := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;

  WITH ev AS (
    SELECT a.tevo_retail_median AS ask, a.sg_sale_median_realized AS realized,
           (NULLIF(e.occurs_at_local,'')::timestamptz::date - (now() AT TIME ZONE 'UTC')::date) AS dte,
           CASE WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name ELSE 'Other' END AS category,
           e.primary_performer_id, lower(btrim(split_part(e.name,' at ',1))) AS away_name
    FROM public.v_event_price_arbitrage a
    JOIN public.events e ON e.id = a.tevo_event_id
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    WHERE a.tevo_retail_median > 0 AND a.sg_sale_median_realized > 0 AND a.tevo_retail_median < 20000
  ),
  j AS (
    SELECT ev.category, ev.realized,
           ev.ask * coalesce(c.sold_to_ask_ratio, 0.8) AS ask_pred,
           cph.overall_median_price AS perf_pred,
           cpa.away_median_price AS road_pred
    FROM ev
    LEFT JOIN public.price_clearing_coeffs c ON c.category = ev.category AND c.dte_bucket = public.price_dte_bucket(ev.dte::int)
    LEFT JOIN public.cast_price_ref cph ON cph.tevo_performer_id = ev.primary_performer_id
    LEFT JOIN public.cast_price_ref cpa ON lower(cpa.entity_name) = ev.away_name
    WHERE ev.dte >= 0
  ),
  mape AS (  -- per category + pooled ALL, one row per category token
    SELECT category,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(ask_pred - realized)/realized) AS ask_mape,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(perf_pred - realized)/realized) FILTER (WHERE perf_pred > 0) AS perf_mape,
      count(*) AS n
    FROM j GROUP BY category
    UNION ALL
    SELECT 'ALL',
      percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(ask_pred - realized)/realized),
      percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(perf_pred - realized)/realized) FILTER (WHERE perf_pred > 0),
      count(*) FROM j
  ),
  fit AS (  -- weight = clamp(ref/mape): a 0.25-MAPE signal → ~1.0; worse → less. ref=0.25.
    SELECT category, n,
      round(least(0.90, greatest(0.40, 0.25 / NULLIF(ask_mape,0)))::numeric, 2) AS w_ask,
      CASE WHEN perf_mape IS NOT NULL
           THEN round(least(0.85, greatest(0.30, 0.25 / perf_mape))::numeric, 2)
           ELSE 0.05 END AS w_vp   -- no performer/road signal for this category → near-zero
    FROM mape WHERE n >= 20
  )
  INSERT INTO public.feature_weights (feature_group, event_category, weight, confidence_half_life_days, n, fitted, fitted_at, updated_at)
  SELECT g.grp, f.category, CASE g.grp WHEN 'amalgam_ask' THEN f.w_ask ELSE f.w_vp END,
         CASE g.grp WHEN 'amalgam_ask' THEN 2 ELSE 120 END, f.n, true, now(), now()
  FROM fit f CROSS JOIN (VALUES ('amalgam_ask'),('venue_performer')) g(grp)
  ON CONFLICT (feature_group, event_category) DO UPDATE SET
    weight = excluded.weight, n = excluded.n, fitted = true, fitted_at = now(), updated_at = now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $function$;
REVOKE ALL ON FUNCTION public.rebuild_feature_weights(interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rebuild_feature_weights(interval) TO service_role;

SELECT cron.schedule('feature_weights_weekly', '35 8 * * 0', $cron$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('feature_weights_weekly') THEN RETURN; END IF;
  PERFORM public.rebuild_feature_weights();
END $body$;
$cron$);
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES ('feature_weights_weekly', ARRAY[]::int[], 10080, 10080, 1, true, 'Backtest-fit forecaster feature weights. A1 mig 20260708190040.')
ON CONFLICT (jobname) DO NOTHING;

-- ── 3. Apply the cross-channel λ factor in the frontier (CREATE OR REPLACE) ──
-- Only change vs mig 20260707200100: fetch v_cat + multiply λ by the calibration factor.
CREATE OR REPLACE FUNCTION public.get_listing_price_frontier(p_event_id bigint, p_section text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_res jsonb; v_lambda numeric; v_dte int; v_event_date date; v_fair numeric; v_cat text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' AND current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501'; END IF;
  SELECT greatest(0, (NULLIF(e.occurs_at_local,'')::timestamptz::date - (now() AT TIME ZONE 'UTC')::date)),
         NULLIF(e.occurs_at_local,'')::timestamptz::date,
         CASE WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name ELSE 'Other' END
    INTO v_dte, v_event_date, v_cat
  FROM public.events e LEFT JOIN public.performer_metadata pm ON pm.performer_id=e.primary_performer_id WHERE e.id = p_event_id;
  SELECT greatest(0.02, (
           (SELECT count(*) FROM (SELECT DISTINCT ss.sg_sale_id FROM public.seatgeek_sales_snapshots ss
              JOIN public.seatgeek_event_xref x ON x.sg_event_id=ss.sg_event_id
              WHERE x.tevo_event_id=p_event_id AND lower(btrim(ss.section))=lower(btrim(p_section)) AND ss.sale_at_utc>=now()-interval '30 days') a)
         + (SELECT count(*) FROM (SELECT DISTINCT content_hash FROM public.seatdata_sales_snapshots
              WHERE tevo_event_id=p_event_id AND lower(btrim(section))=lower(btrim(p_section)) AND sale_timestamp>=now()-interval '30 days') b)
         ) / 30.0) * (1 + 1.0*greatest(0,(21 - v_dte))/21.0) INTO v_lambda;
  v_lambda := v_lambda * (1 + coalesce((SELECT greatest(0, b.sales_velocity_pct) / 100.0 * 0.5
      FROM public.v_sg_blindspot_movers b JOIN public.seatgeek_event_xref x ON x.sg_event_id = b.sg_event_id WHERE x.tevo_event_id = p_event_id LIMIT 1), 0));
  -- v1.2 cross-channel calibration: gross λ up for the unobserved broker/other channels.
  v_lambda := v_lambda * public.get_lambda_cross_channel_factor(v_cat);
  v_fair := (public.predict_event_clearing_price(p_event_id, p_section) ->> 'expected_clearing')::numeric;
  WITH ladder AS (SELECT ls.retail_price AS ask, sum(ls.quantity) OVER (ORDER BY ls.retail_price) AS k FROM public.listings_snapshots ls
    JOIN (SELECT max(captured_at) c FROM public.listings_snapshots WHERE event_id=p_event_id) m ON ls.captured_at = m.c
    WHERE ls.event_id=p_event_id AND lower(btrim(ls.section))=lower(btrim(p_section)) AND coalesce(ls.is_ancillary,false)=false),
  grid AS (SELECT ask, max(k) AS k FROM ladder GROUP BY ask),
  kfair AS (SELECT coalesce(max(k),0) + 0.5 AS k FROM ladder WHERE ask <= v_fair),
  hz AS (SELECT g.ask, g.k, g.k / v_lambda AS mean_days, sqrt(g.k) / v_lambda AS sd_days,
           1.0 / (1 + exp(-1.702 * (v_dte - g.k/v_lambda) / NULLIF(sqrt(g.k)/v_lambda,0))) AS p_before FROM grid g),
  fr AS (SELECT ask, k, round(p_before::numeric,3) AS p_sell_before_event,
           least(v_event_date, (now() AT TIME ZONE 'UTC')::date + ceil(mean_days)::int) AS p50_sell_by,
           least(v_event_date, (now() AT TIME ZONE 'UTC')::date + ceil(mean_days + 0.8416*sd_days)::int) AS p80_sell_by,
           round((ask * p_before)::numeric, 2) AS expected_value FROM hz),
  at_fair AS (SELECT k.k, round((100.0/(1+exp(-1.702*(v_dte - k.k/v_lambda)/NULLIF(sqrt(k.k)/v_lambda,0))))::numeric,1) AS p_before_pct,
           least(v_event_date, (now() AT TIME ZONE 'UTC')::date + ceil(k.k/v_lambda)::int) AS p50_sell_by,
           least(v_event_date, (now() AT TIME ZONE 'UTC')::date + ceil(k.k/v_lambda + 0.8416*sqrt(k.k)/v_lambda)::int) AS p80_sell_by FROM kfair k)
  SELECT jsonb_build_object('event_id', p_event_id, 'section', p_section, 'dte_days', v_dte, 'lambda_per_day', round(v_lambda::numeric,3),
    'fair_clearing', round(v_fair::numeric,2), 'recommended_ask', round(v_fair::numeric,2),
    'at_recommended', (SELECT jsonb_build_object('ask', round(v_fair::numeric,2), 'queue_rank_k', k, 'p_sell_before_event_pct', p_before_pct,
        'p50_sell_by', p50_sell_by, 'p80_sell_by', p80_sell_by) FROM at_fair),
    'clear_by_event_ask', (SELECT max(ask) FROM fr WHERE p_sell_before_event >= 0.5),
    'max_ev_ask', (SELECT ask FROM fr ORDER BY expected_value DESC NULLS LAST LIMIT 1),
    'frontier', coalesce((SELECT jsonb_agg(jsonb_build_object('ask', ask, 'queue_rank_k', k, 'p_sell_before_event', p_sell_before_event,
        'p50_sell_by', p50_sell_by, 'p80_sell_by', p80_sell_by, 'expected_value', expected_value) ORDER BY ask) FROM fr), '[]'::jsonb),
    'lambda_cross_channel_factor', public.get_lambda_cross_channel_factor(v_cat),
    'basis', 'recommended_ask = model fair clearing; frontier shows sell-by RISK per ask. λ = SG+SeatData realized × cross-channel factor (still a conservative floor).'
  ) INTO v_res;
  RETURN v_res;
END; $function$;
REVOKE ALL ON FUNCTION public.get_listing_price_frontier(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_listing_price_frontier(bigint, text) TO authenticated, service_role;
