-- Migration 20260812140000 · lane:A1/D0 (author) → applier (apply)
--   writes: performer_eol_calibration [table], refresh_performer_eol_calibration() [fn],
--           predict_event_eol(...) [fn — the EOL price/ROI/win-prob scorer]
--   reads: events, sg_events_canonical, performer_metadata, event_listing_snapshot_daily,
--          clearing_dte_curve, price_dte_bucket
--   auth: refresh service_role-guarded SECDEF; predict read-only STABLE SECDEF
--
-- WHY (operator-directed 2026-08-12). The end-of-life (event-day) price + ROI model, built on
-- an empirical 10-performer calibration study (Dodgers, Yankees + 8). Findings that shaped it:
--   * PERFORMER base-decay DOMINATES: realized event-day return (median-price DTE~24 -> ~2)
--     ranges -30% (Dodgers) to +24% (Astros) — an order of magnitude larger than any adjuster,
--     and the generic Sports clearing curve (~-6%) is badly wrong per team.
--   * sigma is strongly PERFORMER-specific (0.12 Giants .. 0.47 Yankees) -> win-prob width must
--     be conditional, not global.
--   * momentum MEAN-REVERTS (validated the OU degradation term already shipped).
--   * away-team draw, roster star power, AND time-varying contention all test ~0 against the
--     event-day RETURN once the performer is controlled for (within-performer corr ~0) — they
--     live in the price LEVEL, which the comp median already carries. So they are NOT weighted
--     in the EOL-return model (near-event availability/weather/odds are a separate later layer).
--
-- MODEL. For a listing at DTE d with current comp level L (net of nothing — L is the comp price):
--   base_return_p = performer's median event-day return (curve-INCLUSIVE, from history)
--   frac(d)       = share of that decay still ahead at DTE d, distributed via the clearing-curve
--                   shape: (curve[d]-curve[0]) / (curve[ref]-curve[0])   (ref DTE 24)
--   P_eol = L * exp( ln(1+base_return_p) * frac(d) )
--   sigma(d) = sigma_log_p * sqrt(frac(d))          (uncertainty grows with horizon — sqrt-time)
--   ROI  = P_eol*(1-fee)/cost - 1
--   win  = P( P_eol*(1-fee) >= cost*(1+roi_floor) ) via a logistic approx to the normal CDF.
-- Fallback chain: performer row -> category row -> global default, so unknown/thin performers
-- still score. Calibration is refreshed periodically (weekly cron is a fast follow); the same
-- panel logic that computed it is the training substrate that will later replace these medians
-- with a fitted model.
--
-- ROLLBACK: DROP FUNCTION predict_event_eol(...), refresh_performer_eol_calibration();
--           DROP TABLE performer_eol_calibration.

CREATE TABLE IF NOT EXISTS public.performer_eol_calibration (
  performer_id bigint,                       -- NULL = category fallback row
  category     text        NOT NULL,
  n_events     int         NOT NULL,
  base_return  numeric     NOT NULL,          -- median event-day return (curve-inclusive), from ref DTE ~24
  sigma_log    numeric     NOT NULL,          -- stddev of ln(late/early) — win-prob width
  ref_dte      int         NOT NULL DEFAULT 24,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_performer_eol_cal ON public.performer_eol_calibration (coalesce(performer_id, -1), category);
COMMENT ON TABLE public.performer_eol_calibration IS
  'Empirical EOL calibration: per-performer (and per-category fallback) median event-day return + sigma from historical price trajectories. Base of predict_event_eol. Performer base-decay is the dominant EOL term (empirical study 2026-08-12). D0/A1 mig 20260812140000.';

-- Refresh: recompute the calibration from the historical daily price panel.
CREATE OR REPLACE FUNCTION public.refresh_performer_eol_calibration(p_min_n int DEFAULT 8, p_days int DEFAULT 450)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_perf int; v_cat int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout','120000', true);

  CREATE TEMP TABLE _rr ON COMMIT DROP AS
  WITH ev AS (
    SELECT e.id AS ev, e.primary_performer_id AS pid,
           CASE WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name ELSE 'Other' END AS category,
           sgc.sg_datetime_utc::date AS edate
    FROM public.events e
    JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id=e.id
    LEFT JOIN public.performer_metadata pm ON pm.performer_id=e.primary_performer_id
    WHERE sgc.sg_datetime_utc < now() AND sgc.sg_datetime_utc > now() - (p_days||' days')::interval
      AND e.primary_performer_id IS NOT NULL
  ),
  d AS (
    SELECT ev.pid, ev.category,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY dd.amalgam_median) FILTER (WHERE (ev.edate-dd.snapshot_date) BETWEEN 18 AND 30) AS early_med,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY dd.amalgam_median) FILTER (WHERE (ev.edate-dd.snapshot_date) BETWEEN 0 AND 4)  AS late_med
    FROM ev JOIN public.event_listing_snapshot_daily dd ON dd.event_id=ev.ev
    WHERE dd.amalgam_median IS NOT NULL
    GROUP BY ev.ev, ev.pid, ev.category
  )
  SELECT pid, category, (late_med/early_med - 1) AS r, ln(late_med/early_med) AS lr
  FROM d WHERE early_med>0 AND late_med>0;

  TRUNCATE public.performer_eol_calibration;

  INSERT INTO public.performer_eol_calibration (performer_id, category, n_events, base_return, sigma_log)
  SELECT pid, category, count(*),
         round(percentile_cont(0.5) WITHIN GROUP (ORDER BY r)::numeric, 4),
         round(GREATEST(coalesce(stddev_samp(lr),0.30), 0.05)::numeric, 4)
  FROM _rr GROUP BY pid, category HAVING count(*) >= p_min_n;
  GET DIAGNOSTICS v_perf = ROW_COUNT;

  INSERT INTO public.performer_eol_calibration (performer_id, category, n_events, base_return, sigma_log)
  SELECT NULL, category, count(*),
         round(percentile_cont(0.5) WITHIN GROUP (ORDER BY r)::numeric, 4),
         round(GREATEST(coalesce(stddev_samp(lr),0.30), 0.05)::numeric, 4)
  FROM _rr GROUP BY category;
  GET DIAGNOSTICS v_cat = ROW_COUNT;

  RETURN jsonb_build_object('performer_rows', v_perf, 'category_rows', v_cat, 'at', now());
END;
$fn$;
REVOKE ALL ON FUNCTION public.refresh_performer_eol_calibration(int,int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.refresh_performer_eol_calibration(int,int) TO service_role;

-- Scorer: predict event-day price + ROI + win-prob for a listing.
CREATE OR REPLACE FUNCTION public.predict_event_eol(
  p_cost numeric, p_level numeric, p_dte int, p_performer_id bigint,
  p_category text DEFAULT 'Sports', p_fee numeric DEFAULT 0.10, p_roi_floor numeric DEFAULT 0.15)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $fn$
DECLARE
  v_base numeric; v_sigma numeric; v_n int; v_basis text; v_cat text := coalesce(p_category,'Sports');
  c_d numeric; c_0 numeric; c_ref numeric; v_frac numeric; v_mu numeric;
  v_peol numeric; v_net numeric; v_roi numeric; v_hurdle numeric; v_sig numeric; v_z numeric; v_win numeric;
BEGIN
  SELECT base_return, sigma_log, n_events INTO v_base, v_sigma, v_n
  FROM public.performer_eol_calibration WHERE performer_id = p_performer_id LIMIT 1;
  IF FOUND THEN v_basis := 'performer';
  ELSE
    SELECT base_return, sigma_log, n_events INTO v_base, v_sigma, v_n
    FROM public.performer_eol_calibration WHERE performer_id IS NULL AND category = v_cat LIMIT 1;
    IF FOUND THEN v_basis := 'category';
    ELSE v_base := -0.06; v_sigma := 0.30; v_n := 0; v_basis := 'default'; END IF;
  END IF;

  SELECT level_index INTO c_d   FROM public.clearing_dte_curve WHERE category=v_cat AND dte_bucket=public.price_dte_bucket(GREATEST(p_dte,0));
  SELECT level_index INTO c_0   FROM public.clearing_dte_curve WHERE category=v_cat AND dte_bucket=public.price_dte_bucket(0);
  SELECT level_index INTO c_ref FROM public.clearing_dte_curve WHERE category=v_cat AND dte_bucket=public.price_dte_bucket(24);
  v_frac := CASE WHEN c_d IS NULL OR c_0 IS NULL OR c_ref IS NULL OR (c_ref-c_0)=0
                 THEN 1.0 ELSE (c_d - c_0)/(c_ref - c_0) END;
  v_frac := GREATEST(LEAST(v_frac, 1.3), 0);

  v_mu   := ln(1 + GREATEST(v_base, -0.95)) * v_frac;
  v_peol := p_level * exp(v_mu);
  v_net  := v_peol * (1 - p_fee);
  v_roi  := CASE WHEN p_cost>0 THEN v_net/p_cost - 1 END;
  v_hurdle := p_cost * (1 + GREATEST(p_roi_floor,0));
  v_sig  := GREATEST(v_sigma * sqrt(GREATEST(v_frac,0.05)), 0.02);
  v_z    := CASE WHEN v_hurdle>0 AND v_net>0 THEN ln(v_net / v_hurdle) / v_sig END;
  v_win  := CASE WHEN v_z IS NULL THEN NULL ELSE round((1.0/(1.0+exp(-1.702*v_z)))::numeric, 3) END;

  RETURN jsonb_build_object(
    'p_eol', round(v_peol,2), 'est_net_resale', round(v_net,2),
    'roi_pct', round(v_roi*100,0), 'win_prob', v_win,
    'basis', v_basis, 'base_return', v_base, 'sigma_log', v_sigma, 'cal_n', v_n,
    'dte', p_dte, 'horizon_frac', round(v_frac,3), 'level', round(p_level,2), 'cost', round(p_cost,2));
END;
$fn$;
REVOKE ALL ON FUNCTION public.predict_event_eol(numeric,numeric,int,bigint,text,numeric,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.predict_event_eol(numeric,numeric,int,bigint,text,numeric,numeric) TO authenticated, service_role;
COMMENT ON FUNCTION public.predict_event_eol(numeric,numeric,int,bigint,text,numeric,numeric) IS
  'EOL price/ROI/win-prob scorer. P_eol = level * exp(ln(1+performer_base_return) * curve-frac(dte)); sigma grows sqrt(frac); win-prob via logistic-normal. Performer->category->default fallback. Base-decay + per-performer sigma are the empirically dominant EOL terms (study 2026-08-12). D0/A1 mig 20260812140000.';