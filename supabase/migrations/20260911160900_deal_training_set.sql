-- ============================================================================
-- Migration 20260911160900 — v_deal_training_set: features at flag time ⋈ outcome label
--
-- Lane:     D0 (deals surface)
-- Touches:  v_deal_training_set (CREATE VIEW) · get_deal_training_set() (new read RPC)
--           Reads: deal_signal_snapshot, gotickets_deal_outcome, v_our_purchase_flips
-- Pre-reqs: 20260911160400 (outcome label), 20260911160800 (feature snapshot),
--           20260911160500 (v_our_purchase_flips)
--
-- The one join the fitted model is trained on: one row per graded deal with the
-- feature vector captured for it and the label. Two labels are exposed:
--   y_win    — market label: gotickets_deal_outcome.outcome = 'WIN' (event-day
--              realized median cleared cost × 1.15 net of fee), zone/section level;
--   y_flip   — our own flip when we actually bought that seat: v_our_purchase_flips
--              flip_roi_pct >= 15 (NULL when we never bought it).
-- Rows with as_of_flag = false are BACKFILLED features (sports/market/social block
-- as of snapshot time, not flag time) — scripts/fit_deal_scorer.py down-weights
-- them by default (--backfill-weight 0.5); pass 0 to exclude.
--
-- READ-ONLY. ROLLBACK: DROP FUNCTION public.get_deal_training_set(int);
--                      DROP VIEW public.v_deal_training_set;
-- ============================================================================

CREATE OR REPLACE VIEW public.v_deal_training_set
WITH (security_invoker = true) AS
SELECT s.tevo_event_id, s.gt_listing_id, s.captured_at, s.as_of_date, s.as_of_flag, s.event_date, s.league,
       o.outcome, o.match_level, o.realized_roi_pct, o.realized_win_share, o.realized_n,
       (o.outcome = 'WIN')::int                                           AS y_win,
       CASE WHEN fl.sales_matched > 0 THEN (fl.flip_roi_pct >= 15)::int END AS y_flip,
       fl.flip_roi_pct,
       s.features,
       s.score_v0, s.model_version, s.model_prob
FROM public.deal_signal_snapshot s
JOIN public.gotickets_deal_outcome o
  ON o.tevo_event_id = s.tevo_event_id AND o.gt_listing_id = s.gt_listing_id
LEFT JOIN LATERAL (
  SELECT f.sales_matched, f.flip_roi_pct
  FROM public.v_our_purchase_flips f
  JOIN public.gotickets_deals_feed d ON d.tevo_event_id = s.tevo_event_id AND d.gt_listing_id = s.gt_listing_id
  WHERE f.tevo_event_id = s.tevo_event_id
    AND f.secnum = (regexp_match(d.section, '(\d{1,4})'))[1]
    AND upper(btrim(f."row")) = upper(btrim(d."row"))
  ORDER BY f.purchased_at LIMIT 1) fl ON true
WHERE o.outcome <> 'NO_COMPS' AND o.match_level IN ('zone', 'section');
GRANT SELECT ON public.v_deal_training_set TO authenticated, service_role;
COMMENT ON VIEW public.v_deal_training_set IS
  'Training rows for the deal winner model: flag-time features (deal_signal_snapshot) joined to the outcome label (y_win = market WIN at zone/section level) and, where we bought the seat, our own flip (y_flip). D0 mig 20260911160900.';

CREATE OR REPLACE FUNCTION public.get_deal_training_set(p_limit int DEFAULT 5000)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_email text := coalesce(auth.jwt()->>'email', ''); v_out jsonb;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '20000', true);
  SELECT jsonb_build_object(
    'generated_at', now(),
    'n', (SELECT count(*) FROM public.v_deal_training_set),
    'n_flag_time', (SELECT count(*) FROM public.v_deal_training_set WHERE as_of_flag),
    'win_rate', (SELECT round(avg(y_win)::numeric, 3) FROM public.v_deal_training_set),
    'rows', coalesce((SELECT jsonb_agg(to_jsonb(t)) FROM (SELECT * FROM public.v_deal_training_set ORDER BY event_date DESC LIMIT GREATEST(LEAST(p_limit, 20000), 1)) t), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $fn$;
REVOKE ALL ON FUNCTION public.get_deal_training_set(int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deal_training_set(int) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deal_training_set(int) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_deal_training_set(int) IS
  'Export v_deal_training_set as jsonb for scripts/fit_deal_scorer.py. Email-gated @s4kent.com. D0 mig 20260911160900.';
