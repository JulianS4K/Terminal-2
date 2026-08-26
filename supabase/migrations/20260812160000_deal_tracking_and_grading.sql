-- Migration 20260812160000 · lane:D0/A1 (author) → applier (apply)
--   writes: deal_tracking [table], track_current_deals(text) [fn], evaluate_tracked_deals(text) [fn]
--   reads: v_deals_all_models, event_listing_snapshot_daily, seatgeek_sales_snapshots, seatdata_sales_snapshots
--   auth: service_role-guarded SECDEF
--
-- WHY (operator-directed 2026-08-12: "track those listings that are potentially undervalued and
-- in a week or 2 we'll check"). Pins the CURRENT undervalued-deal cohort with every model
-- version's prediction, then grades those predictions against what actually happens:
--   * track_current_deals(tag)   — snapshot the live v_deals_all_models set into deal_tracking.
--   * evaluate_tracked_deals(tag)— for each tracked listing, attach the current SPOT comp level
--     and, once the event matures, the REALIZED event-day clearing price (final-window SG+SeatData
--     sales median); compute each model's absolute error and a per-listing verdict; return a
--     summary (matured count, per-model MAE, v2-better count). Run now for a baseline, and again
--     in ~2 weeks (a Routine is scheduled) when the near events have settled.
-- Grades predicted GROSS event-day price: v2 uses v2_p_eol; v1's gross = v1_net/(1-fee). realized
-- is EVENT-level (final-window sales median) — a market-clearing proxy; section-level realized is
-- a later refinement where sales are dense enough.
--
-- ROLLBACK: DROP FUNCTION evaluate_tracked_deals(text), track_current_deals(text); DROP TABLE deal_tracking.

CREATE TABLE IF NOT EXISTS public.deal_tracking (
  cohort_tag    text        NOT NULL,
  tevo_event_id bigint      NOT NULL,
  gt_listing_id bigint      NOT NULL,
  event_name text, section text, zone text, event_date date, performer_id bigint, category text,
  entry_at   timestamptz NOT NULL DEFAULT now(),
  entry_dte  int, entry_cost numeric, entry_spot numeric,
  v1_roi_pct int, v1_win numeric, v1_net numeric,
  v2_roi_pct int, v2_win numeric, v2_net numeric, v2_p_eol numeric, v2_base_return numeric,
  -- filled by evaluate_tracked_deals:
  eval_at timestamptz, eval_dte int, eval_spot numeric, realized_eol numeric,
  v1_abs_err numeric, v2_abs_err numeric, verdict text,
  PRIMARY KEY (cohort_tag, tevo_event_id, gt_listing_id)
);
COMMENT ON TABLE public.deal_tracking IS
  'Pinned cohorts of potentially-undervalued listings + every model version''s entry prediction, graded against realized event-day clearing once events mature. D0 mig 20260812160000.';

CREATE OR REPLACE FUNCTION public.track_current_deals(p_tag text)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_rows int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501'; END IF;
  INSERT INTO public.deal_tracking
    (cohort_tag, tevo_event_id, gt_listing_id, event_name, section, zone, event_date, performer_id, category,
     entry_dte, entry_cost, entry_spot, v1_roi_pct, v1_win, v1_net, v2_roi_pct, v2_win, v2_net, v2_p_eol, v2_base_return)
  SELECT p_tag, tevo_event_id, gt_listing_id, event_name, section, zone, event_date, performer_id, category,
     dte, cost, spot_level, v1_roi_pct, v1_win, v1_net, v2_roi_pct, v2_win, v2_net, v2_p_eol, v2_base_return
  FROM public.v_deals_all_models
  ON CONFLICT (cohort_tag, tevo_event_id, gt_listing_id) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$fn$;
REVOKE ALL ON FUNCTION public.track_current_deals(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.track_current_deals(text) TO service_role;

CREATE OR REPLACE FUNCTION public.evaluate_tracked_deals(p_tag text, p_fee numeric DEFAULT 0.10)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501'; END IF;

  UPDATE public.deal_tracking t SET
    eval_at = now(),
    eval_dte = (t.event_date - (now() AT TIME ZONE 'utc')::date),
    eval_spot = sp.lvl,
    realized_eol = rz.med,
    v1_abs_err = CASE WHEN rz.med IS NOT NULL AND t.v1_net IS NOT NULL THEN round(abs(t.v1_net/(1-p_fee) - rz.med),2) END,
    v2_abs_err = CASE WHEN rz.med IS NOT NULL AND t.v2_p_eol IS NOT NULL THEN round(abs(t.v2_p_eol - rz.med),2) END,
    verdict = CASE
      WHEN rz.med IS NULL THEN 'pending ('|| GREATEST((t.event_date-(now() AT TIME ZONE 'utc')::date),0) ||'d to event)'
      WHEN t.v2_p_eol IS NULL OR t.v1_net IS NULL THEN 'incomplete'
      WHEN abs(t.v2_p_eol - rz.med) < abs(t.v1_net/(1-p_fee) - rz.med) THEN 'v2_better'
      ELSE 'v1_better' END
  FROM public.deal_tracking d
  LEFT JOIN LATERAL (
    SELECT amalgam_median AS lvl FROM public.event_listing_snapshot_daily el
    WHERE el.event_id = d.tevo_event_id AND el.amalgam_median IS NOT NULL
    ORDER BY el.snapshot_date DESC LIMIT 1) sp ON true
  LEFT JOIN LATERAL (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY px)::numeric AS med FROM (
      SELECT sgs.broadcast_price::numeric AS px FROM public.seatgeek_sales_snapshots sgs
        WHERE sgs.tevo_event_id=d.tevo_event_id AND sgs.broadcast_price>0
          AND sgs.sale_at_utc::date BETWEEN d.event_date-4 AND d.event_date
      UNION ALL
      SELECT sd.price::numeric FROM public.seatdata_sales_snapshots sd
        WHERE sd.tevo_event_id=d.tevo_event_id AND sd.price>0
          AND sd.sale_timestamp::date BETWEEN d.event_date-4 AND d.event_date
    ) s) rz ON true
  WHERE t.cohort_tag = p_tag AND d.cohort_tag = t.cohort_tag
    AND d.tevo_event_id = t.tevo_event_id AND d.gt_listing_id = t.gt_listing_id;

  SELECT jsonb_build_object(
    'cohort', p_tag,
    'tracked', count(*),
    'matured', count(*) FILTER (WHERE realized_eol IS NOT NULL),
    'pending', count(*) FILTER (WHERE realized_eol IS NULL),
    'v1_mae', round(avg(v1_abs_err),2),
    'v2_mae', round(avg(v2_abs_err),2),
    'v2_better', count(*) FILTER (WHERE verdict='v2_better'),
    'v1_better', count(*) FILTER (WHERE verdict='v1_better'),
    'at', now()
  ) INTO v FROM public.deal_tracking WHERE cohort_tag = p_tag;
  RETURN v;
END;
$fn$;
REVOKE ALL ON FUNCTION public.evaluate_tracked_deals(text,numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.evaluate_tracked_deals(text,numeric) TO service_role;