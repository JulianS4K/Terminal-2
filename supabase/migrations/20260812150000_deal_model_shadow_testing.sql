-- Migration 20260812150000 · lane:D0/A1 (author) → applier (apply)
--   writes: v_deals_all_models [view], deal_model_shadow [table], snapshot_deal_models() [fn],
--           refresh_performer_eol_calibration weekly cron, deal_model_shadow 10-min cron
--   reads: gotickets_deals_feed, events, performer_metadata, event_listing_snapshot_daily, predict_event_eol
--   auth: view read-only; snapshot fn service_role-guarded SECDEF
--
-- WHY (operator-directed 2026-08-12: "test all versions in real time"). Champion/challenger
-- shadow harness. The live scanner (v1: degradation-only, mean-reverting OU) remains the gate
-- that decides what surfaces — NON-DESTRUCTIVE. Alongside it, every currently-surfaced deal is
-- ALSO scored by v2 (predict_event_eol: empirical performer base-decay + per-performer sigma) on
-- the current SPOT comp level, in real time. v_deals_all_models shows all versions side by side;
-- deal_model_shadow records them every 10 min so, once events mature and realized_eol is filled,
-- each version's predictions can be scored against what actually cleared and the best model wins
-- on evidence. (v3 = performer-EOL refit on realized SALES; adds as another column later.)
--
-- SCOPE NOTE: this compares versions on the v1-SURFACED deal set (the ones that matter most — are
-- they real?). Capturing the full candidate pool so v2 can pick INDEPENDENTLY of v1 (deals v1
-- rejected) is a scanner-emit follow-up.
--
-- ROLLBACK: cron.unschedule('deal_model_shadow_10min'), cron.unschedule('performer_eol_cal_weekly');
--   DROP FUNCTION snapshot_deal_models(); DROP TABLE deal_model_shadow; DROP VIEW v_deals_all_models.

-- 1. Real-time all-versions comparison for currently-surfaced deals.
CREATE OR REPLACE VIEW public.v_deals_all_models AS
WITH spot AS (   -- current SPOT cross-market comp median per active-feed event
  SELECT DISTINCT ON (d.event_id) d.event_id AS ev, d.amalgam_median AS lvl
  FROM public.event_listing_snapshot_daily d
  WHERE d.event_id IN (SELECT tevo_event_id FROM public.gotickets_deals_feed WHERE gone_at IS NULL)
    AND d.amalgam_median IS NOT NULL
  ORDER BY d.event_id, d.snapshot_date DESC,
    CASE d.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC
),
base AS (
  SELECT f.tevo_event_id, f.gt_listing_id, f.gt_event_id, f.event_name, f.section, f.zone, f.event_date,
         f.gt_price, f.section_median, f.confidence, f.regime, f.first_seen_at,
         f.est_net_resale AS v1_net, f.net_profit_pct AS v1_roi_pct, f.win_prob AS v1_win,
         e.primary_performer_id AS performer_id,
         CASE WHEN e.event_type='game' THEN 'Sports'
              WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
              ELSE 'Other' END AS category,
         coalesce(sp.lvl, f.section_median) AS spot_level,
         coalesce(f.dte_now, (f.event_date - (now() AT TIME ZONE 'utc')::date)::int) AS dte
  FROM public.gotickets_deals_feed f
  JOIN public.events e ON e.id = f.tevo_event_id
  LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
  LEFT JOIN spot sp ON sp.ev = f.tevo_event_id
  WHERE f.gone_at IS NULL
)
SELECT b.tevo_event_id, b.gt_listing_id, b.gt_event_id, b.event_name, b.section, b.zone, b.event_date,
       b.dte, b.performer_id, b.category, b.gt_price AS cost, round(b.spot_level,2) AS spot_level,
       -- v1: degradation-only (live champion)
       b.v1_roi_pct, b.v1_win, b.v1_net,
       -- v2: performer-EOL (challenger)
       (m.j->>'roi_pct')::int          AS v2_roi_pct,
       (m.j->>'win_prob')::numeric      AS v2_win,
       (m.j->>'est_net_resale')::numeric AS v2_net,
       (m.j->>'p_eol')::numeric         AS v2_p_eol,
       (m.j->>'base_return')::numeric   AS v2_base_return,
       (m.j->>'basis')                  AS v2_basis,
       b.confidence, b.regime, b.first_seen_at
FROM base b
CROSS JOIN LATERAL (SELECT public.predict_event_eol(b.gt_price, b.spot_level, b.dte, b.performer_id, b.category) AS j) m;

COMMENT ON VIEW public.v_deals_all_models IS
  'Champion/challenger real-time comparison: each surfaced deal scored by v1 (degradation-only, live gate) and v2 (performer-EOL on spot comp level). Basis of the shadow test. D0 mig 20260812150000.';

-- 2. History table — snapshot the comparison each poll; realized_eol filled once events mature.
CREATE TABLE IF NOT EXISTS public.deal_model_shadow (
  captured_at   timestamptz NOT NULL DEFAULT now(),
  tevo_event_id bigint, gt_listing_id bigint, event_name text, section text, event_date date,
  dte int, performer_id bigint, category text, cost numeric, spot_level numeric,
  v1_roi_pct int, v1_win numeric, v1_net numeric,
  v2_roi_pct int, v2_win numeric, v2_net numeric, v2_p_eol numeric, v2_base_return numeric,
  realized_eol numeric, realized_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_deal_model_shadow_key ON public.deal_model_shadow (tevo_event_id, gt_listing_id, captured_at DESC);
CREATE INDEX IF NOT EXISTS idx_deal_model_shadow_unrealized ON public.deal_model_shadow (event_date) WHERE realized_eol IS NULL;
COMMENT ON TABLE public.deal_model_shadow IS
  'Per-poll snapshot of v_deals_all_models (all model versions'' predictions). realized_eol backfilled from final-window sales once each event matures, to score which model predicts best. D0 mig 20260812150000.';

-- 3. Snapshot function (called by cron).
CREATE OR REPLACE FUNCTION public.snapshot_deal_models()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_rows int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  INSERT INTO public.deal_model_shadow
    (captured_at, tevo_event_id, gt_listing_id, event_name, section, event_date, dte, performer_id, category,
     cost, spot_level, v1_roi_pct, v1_win, v1_net, v2_roi_pct, v2_win, v2_net, v2_p_eol, v2_base_return)
  SELECT now(), tevo_event_id, gt_listing_id, event_name, section, event_date, dte, performer_id, category,
     cost, spot_level, v1_roi_pct, v1_win, v1_net, v2_roi_pct, v2_win, v2_net, v2_p_eol, v2_base_return
  FROM public.v_deals_all_models;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$fn$;
REVOKE ALL ON FUNCTION public.snapshot_deal_models() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.snapshot_deal_models() TO service_role;

-- 4. Schedules: shadow snapshot every 10 min; calibration refresh weekly (Mon 09:00 UTC).
SELECT cron.schedule('deal_model_shadow_10min', '*/10 * * * *',
  $$SELECT public.snapshot_deal_models();$$);
SELECT cron.schedule('performer_eol_cal_weekly', '0 9 * * 1',
  $$SELECT public.refresh_performer_eol_calibration();$$);