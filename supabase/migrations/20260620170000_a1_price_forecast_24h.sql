-- Migration 20260620170000 · level:2 · lane:A1 · operator-directed (2026-06-20)
-- Lane: A1 (data plane — 24h median-price forecaster)
-- Touches W: CREATE TABLE price_forecast_coeffs_24h; CREATE FUNCTION price_dte_bucket(int),
--            rebuild_price_forecast_coeffs_24h(interval), predict_event_median_24h(bigint);
--            cron price_forecast_coeffs_weekly
-- Touches R: public.event_metrics, public.events, public.performer_metadata,
--            public.latest_event_metrics
-- Pre-reqs: event_metrics (120d), latest_event_metrics matview, performer_metadata
-- Already applied to prod · via MCP 2026-06-20 (coeffs built: 21 buckets)
--
-- ============================================================
-- 24-HOUR MEDIAN PRICE FORECAST
--
-- Backtest finding (107k consecutive-day points, 40d of event_metrics):
--   * 24h median price is a NEAR-RANDOM WALK. Naive "tomorrow = today" = 3.07% MAPE;
--     momentum is WORSE (5.61%); day-to-day change autocorrelation ~0.04 (nil).
--   * The ONLY systematic structure is time-to-event: the typical (median) move is ~0,
--     but the DISPERSION fans out hard near the event and there is a fat upside tail —
--     Sports 0-1d: p25/p75 drift -25%/+17%, 31% of days jump >+10%; 60d+: p25/p75 ~0,
--     ~1% jump. (The "+17% mean" is tail-driven; the median event is flat/slightly down.)
--
-- So an honest forecast is NOT a momentum extrapolation. It is: naive anchor (current
-- median) + a small category x days-to-event MEDIAN drift, wrapped in the empirical
-- p25/p75 band for that bucket, plus the spike-up probability. Far out = ~current, tight;
-- near event = ~current but wide band + real upside-spike risk (the broker signal:
-- hold/expect to pay up). Coefficients are precomputed weekly; the predictor is a cheap
-- lookup so it's safe in an event-page RPC.
-- ============================================================

-- Shared bucket function (used identically by builder + predictor so labels never drift).
CREATE OR REPLACE FUNCTION public.price_dte_bucket(p_dte integer)
RETURNS text IMMUTABLE LANGUAGE sql AS $$
  SELECT CASE
    WHEN p_dte IS NULL THEN NULL
    WHEN p_dte <= 1  THEN '0-1d'
    WHEN p_dte <= 3  THEN '2-3d'
    WHEN p_dte <= 7  THEN '4-7d'
    WHEN p_dte <= 21 THEN '8-21d'
    WHEN p_dte <= 60 THEN '22-60d'
    ELSE '60d+' END
$$;

CREATE TABLE IF NOT EXISTS public.price_forecast_coeffs_24h (
  category      text NOT NULL,             -- Sports|Concerts|Comedy|Theater|Other
  dte_bucket    text NOT NULL,             -- price_dte_bucket() label
  n             integer,
  median_drift  numeric,                   -- fraction (e.g. -0.025 = -2.5%)
  p25_drift     numeric,
  p75_drift     numeric,
  spike_up_rate numeric,                   -- fraction of days moving > +10% in 24h
  computed_at   timestamptz DEFAULT now(),
  PRIMARY KEY (category, dte_bucket)
);
COMMENT ON TABLE public.price_forecast_coeffs_24h IS
  'Empirical 24h retail_median drift coefficients by category x days-to-event bucket '
  '(median/p25/p75 + upside-spike rate). Rebuilt weekly. A1 · mig 20260620170000.';
ALTER TABLE public.price_forecast_coeffs_24h ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.price_forecast_coeffs_24h TO authenticated, service_role;

-- Builder: recompute coefficients from event_metrics history.
CREATE OR REPLACE FUNCTION public.rebuild_price_forecast_coeffs_24h(p_window interval DEFAULT '45 days'::interval)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  WITH daily AS (
    SELECT DISTINCT ON (m.event_id, (m.captured_at AT TIME ZONE 'UTC')::date)
      m.event_id, (m.captured_at AT TIME ZONE 'UTC')::date AS d, m.retail_median
    FROM public.event_metrics m
    WHERE m.captured_at > now() - p_window AND m.retail_median > 0
    ORDER BY m.event_id, (m.captured_at AT TIME ZONE 'UTC')::date, m.captured_at DESC
  ),
  seq AS (
    SELECT s.event_id, s.d, s.retail_median,
      lead(s.retail_median) OVER w AS nxt, lead(s.d) OVER w AS nxt_d, lag(s.d) OVER w AS prev_d
    FROM daily s WINDOW w AS (PARTITION BY s.event_id ORDER BY s.d)
  ),
  j AS (
    SELECT
      CASE WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater')
           THEN pm.top_category_name ELSE 'Other' END AS category,
      public.price_dte_bucket((NULLIF(e.occurs_at_local,'')::timestamptz::date - seq.d)) AS dte_bucket,
      (seq.nxt - seq.retail_median) / seq.retail_median AS chg
    FROM seq
    JOIN public.events e ON e.id = seq.event_id
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    WHERE seq.nxt IS NOT NULL AND seq.nxt_d = seq.d + 1 AND seq.prev_d = seq.d - 1
      AND (NULLIF(e.occurs_at_local,'')::timestamptz::date - seq.d) >= 0
  )
  INSERT INTO public.price_forecast_coeffs_24h
    (category, dte_bucket, n, median_drift, p25_drift, p75_drift, spike_up_rate, computed_at)
  SELECT category, dte_bucket, count(*),
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY chg),
    percentile_cont(0.25) WITHIN GROUP (ORDER BY chg),
    percentile_cont(0.75) WITHIN GROUP (ORDER BY chg),
    count(*) FILTER (WHERE chg > 0.10)::numeric / count(*),
    now()
  FROM j
  WHERE category IS NOT NULL AND dte_bucket IS NOT NULL
  GROUP BY category, dte_bucket
  HAVING count(*) >= 30
  ON CONFLICT (category, dte_bucket) DO UPDATE SET
    n=excluded.n, median_drift=excluded.median_drift, p25_drift=excluded.p25_drift,
    p75_drift=excluded.p75_drift, spike_up_rate=excluded.spike_up_rate, computed_at=excluded.computed_at;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $function$;
REVOKE ALL ON FUNCTION public.rebuild_price_forecast_coeffs_24h(interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rebuild_price_forecast_coeffs_24h(interval) TO service_role;

-- Predictor: cheap per-event lookup (safe in an event-page RPC).
CREATE OR REPLACE FUNCTION public.predict_event_median_24h(p_event_id bigint)
RETURNS jsonb
LANGUAGE sql STABLE SET search_path TO 'public','pg_temp'
AS $function$
  WITH ev AS (
    SELECT e.id,
      (NULLIF(e.occurs_at_local,'')::timestamptz::date - (now() AT TIME ZONE 'UTC')::date) AS dte,
      CASE WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater')
           THEN pm.top_category_name ELSE 'Other' END AS category,
      m.retail_median AS current_median, m.captured_at
    FROM public.events e
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    LEFT JOIN public.latest_event_metrics m ON m.event_id = e.id
    WHERE e.id = p_event_id
  ),
  c AS (
    SELECT ev.*, public.price_dte_bucket(ev.dte::int) AS dte_bucket,
      coalesce(k.median_drift, ko.median_drift, 0)  AS median_drift,
      coalesce(k.p25_drift,   ko.p25_drift,   0)    AS p25_drift,
      coalesce(k.p75_drift,   ko.p75_drift,   0)    AS p75_drift,
      coalesce(k.spike_up_rate, ko.spike_up_rate, 0) AS spike_up_rate,
      coalesce(k.n, ko.n) AS sample_n, coalesce(k.computed_at, ko.computed_at) AS coeffs_asof
    FROM ev
    LEFT JOIN public.price_forecast_coeffs_24h k
      ON k.category = ev.category AND k.dte_bucket = public.price_dte_bucket(ev.dte::int)
    LEFT JOIN public.price_forecast_coeffs_24h ko
      ON ko.category = 'Other' AND ko.dte_bucket = public.price_dte_bucket(ev.dte::int)
  )
  SELECT jsonb_build_object(
    'event_id', p_event_id,
    'current_median', current_median,
    'dte_days', dte,
    'category', category,
    'dte_bucket', dte_bucket,
    'predicted_median_24h', round(current_median * (1 + median_drift), 2),
    'lo_24h', round(current_median * (1 + p25_drift), 2),
    'hi_24h', round(current_median * (1 + p75_drift), 2),
    'spike_up_prob_pct', round(spike_up_rate * 100, 1),
    'sample_n', sample_n,
    'coeffs_asof', coeffs_asof,
    'basis', CASE
      WHEN current_median IS NULL THEN 'no_current_metrics'
      WHEN dte IS NULL OR dte < 0 THEN 'no_or_past_event_date'
      WHEN sample_n IS NULL THEN 'naive_no_coeffs'
      ELSE 'naive_anchor + empirical category x dte drift band' END
  )
  FROM c;
$function$;
REVOKE ALL ON FUNCTION public.predict_event_median_24h(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.predict_event_median_24h(bigint) TO authenticated, service_role;

-- Weekly rebuild (Sunday 08:10 UTC, off-peak T4) — coefficients are slow-moving.
SELECT cron.schedule('price_forecast_coeffs_weekly', '10 8 * * 0', $cron$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('price_forecast_coeffs_weekly') THEN RETURN; END IF;
  PERFORM public.rebuild_price_forecast_coeffs_24h();
END $body$;
$cron$);
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES ('price_forecast_coeffs_weekly', ARRAY[]::int[], 10080, 10080, 1, true,
        '24h price-forecast coefficient rebuild. Weekly Sun 08:10 UTC, off-peak. A1 mig 20260620170000.')
ON CONFLICT (jobname) DO NOTHING;
