-- ============================================================================
-- Migration 20260911161700 — get_deals_feed(): carry score_v1 + gate + timing; hide SUPPRESSED rows
--
-- Lane:     D0 (deals surface)
-- Touches:  get_deals_feed(int,timestamptz,numeric,text,boolean) (CREATE OR REPLACE, same signature)
-- Pre-reqs: 20260911161600 (deal_score_v1 / gate_v1 on deal_signal_snapshot)
--
-- Already applied to prod · via MCP 2026-09-11 (operator: "use other metrics to strengthen feed").
--
-- The terminal DEALS page (static/terminal/deals.{html,js}) polls this RPC, not get_deal_signals,
-- so the market-only score has to ride here or the page never sees it. Changes:
--   • LEFT JOIN deal_signal_snapshot: every row carries score_v1, gate, timing, dte, moneyness,
--     ma7_over_ma14 (null for the ~0.5% of rows the 10-min snapshot cron has not reached yet);
--   • rows whose gate is SUPPRESS … are dropped from `deals` (envelope still reports
--     active_deals, plus suppressed_n / verify_n so the header can say what was hidden);
--   • sort stays newest-first (it is a live feed) — ranking by score is get_deal_signals' job.
-- p_include_gone=true still returns gone rows (and, for audit, does NOT apply the gate).
--
-- ROLLBACK: re-apply the body from mig 20260811240000.
-- ============================================================================

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
    'suppressed_n', (SELECT count(*) FROM public.gotickets_deals_feed f
                       JOIN public.deal_signal_snapshot s ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
                      WHERE f.gone_at IS NULL AND s.gate_v1 LIKE 'SUPPRESS%'),
    'verify_n',     (SELECT count(*) FROM public.gotickets_deals_feed f
                       JOIN public.deal_signal_snapshot s ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
                      WHERE f.gone_at IS NULL AND s.gate_v1 LIKE 'VERIFY%'),
    'score_version', 'v1_market_only',
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
        'first_seen_at', first_seen_at, 'last_seen_at', last_seen_at, 'gone_at', gone_at,
        'score_v1', score_v1, 'gate', gate_v1, 'timing', timing,
        'dte', s_dte, 'moneyness', moneyness, 'ma7_over_ma14', ma7_over_ma14, 'is_weekend', is_weekend
      ) ORDER BY first_seen_at DESC, score_v1 DESC NULLS LAST)
      FROM (
        SELECT f.*, s.score_v1, s.gate_v1, s.dte AS s_dte, s.moneyness, s.ma7_over_ma14, s.is_weekend,
               CASE WHEN s.dte IS NULL THEN NULL WHEN s.dte <= 1 THEN 'LAST-DAY' WHEN s.dte <= 7 THEN 'THIS-WEEK'
                    WHEN s.dte <= 14 THEN '2-WEEKS' ELSE 'FAR' END AS timing
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
COMMENT ON FUNCTION public.get_deals_feed(integer,timestamptz,numeric,text,boolean) IS
  'D0 DEALS live feed (newest first). Since mig 20260911161700 each row carries the market-only score_v1 + gate + timing from deal_signal_snapshot and SUPPRESS-gated rows are hidden (suppressed_n / verify_n in the envelope). Email-gated @s4kent.com.';
