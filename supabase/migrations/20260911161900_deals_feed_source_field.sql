-- ============================================================================
-- Migration 20260911161900 — deals feed RPCs + view carry `source` (gotickets | evo)
--
-- Lane:     D0 (deals surface)
-- Touches:  get_deals_feed(int,timestamptz,numeric,text,boolean) · v_deals_feed_ranked ·
--           get_deal_signals(int,numeric,text)  (all CREATE OR REPLACE, same signatures)
-- Pre-reqs: 20260911161800 (source column), 20260911161700
--
-- Already applied to prod · via MCP 2026-09-11 (with 161800).
--
-- Adds `source` + `evo_ticket_group_id` to every row the terminal reads and to the ranked view,
-- plus per-source live counts in the envelope, so the page can badge EVO vs GT and only link to
-- GoTickets when there is a GT event. No filtering change.
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
  'D0 DEALS live feed (newest first, both sources). Rows carry source (gotickets|evo), score_v1 + gate + timing; SUPPRESS-gated rows hidden (suppressed_n / verify_n / active_by_source in the envelope). Email-gated @s4kent.com. mig 20260911161900.';

CREATE OR REPLACE VIEW public.v_deals_feed_ranked AS
SELECT f.tevo_event_id, f.gt_listing_id, f.gt_event_id, f.event_name, f.event_date, s.league,
       f.zone, f.section, f."row", f.quantity, f.gt_price,
       f.win_prob AS feed_win_prob, f.net_profit_pct AS feed_net_profit_pct, f.confidence AS feed_confidence,
       s.score_v1, s.gate_v1, s.score_v0, s.model_prob,
       coalesce(s.model_prob, s.score_v1) AS score,
       s.dte, CASE WHEN s.dte <= 1 THEN 'LAST-DAY' WHEN s.dte <= 7 THEN 'THIS-WEEK' WHEN s.dte <= 14 THEN '2-WEEKS' ELSE 'FAR' END AS timing,
       s.moneyness, s.ma7_over_ma14, s.regime, s.vs_zone_pct, s.cost_vs_amalgam, s.is_weekend,
       s.as_of_flag, s.captured_at, f.first_seen_at,
       rank() OVER (ORDER BY coalesce(s.model_prob, s.score_v1) DESC NULLS LAST, f.first_seen_at DESC) AS rank,
       f.source, f.evo_ticket_group_id          -- appended last: CREATE OR REPLACE VIEW cannot reorder columns
FROM public.gotickets_deals_feed f
JOIN public.deal_signal_snapshot s ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
WHERE f.gone_at IS NULL;

CREATE OR REPLACE FUNCTION public.get_deal_signals(
  p_limit      int     DEFAULT 100,
  p_min_score  numeric DEFAULT NULL,
  p_league     text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_email text := coalesce(auth.jwt()->>'email', ''); v_out jsonb;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '10000', true);
  SELECT jsonb_build_object(
    'generated_at', now(),
    'score_version', coalesce((SELECT model_version FROM public.deal_model_coef WHERE feature = '__intercept__' ORDER BY fitted_at DESC LIMIT 1), 'v1_market_only'),
    'model_version', (SELECT model_version FROM public.deal_model_coef WHERE feature = '__intercept__' ORDER BY fitted_at DESC LIMIT 1),
    'active_scored', (SELECT count(*) FROM public.v_deals_feed_ranked r WHERE p_league IS NULL OR r.league = p_league),
    'suppressed_n', (SELECT count(*) FROM public.v_deals_feed_ranked r WHERE r.gate_v1 LIKE 'SUPPRESS%' AND (p_league IS NULL OR r.league = p_league)),
    'verify_n',     (SELECT count(*) FROM public.v_deals_feed_ranked r WHERE r.gate_v1 LIKE 'VERIFY%'   AND (p_league IS NULL OR r.league = p_league)),
    'deals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'source', r.source, 'evo_ticket_group_id', r.evo_ticket_group_id,
        'tevo_event_id', r.tevo_event_id, 'gt_listing_id', r.gt_listing_id, 'gt_event_id', r.gt_event_id,
        'event_name', r.event_name, 'event_date', r.event_date, 'league', r.league,
        'section', r.section, 'row', r."row", 'quantity', r.quantity, 'gt_price', r.gt_price,
        'zone', r.zone, 'vs_zone_pct', r.vs_zone_pct, 'regime', r.regime,
        'pred_win_prob', r.feed_win_prob, 'pred_net_profit_pct', r.feed_net_profit_pct, 'confidence', r.feed_confidence,
        'score', r.score, 'score_v1', r.score_v1, 'score_v0', r.score_v0, 'model_prob', r.model_prob,
        'gate', r.gate_v1, 'timing', r.timing, 'rank', r.rank,
        'moneyness', r.moneyness, 'ma7_over_ma14', r.ma7_over_ma14, 'cost_vs_amalgam', r.cost_vs_amalgam,
        'dte', r.dte, 'is_weekend', r.is_weekend,
        'as_of_flag', r.as_of_flag, 'captured_at', r.captured_at, 'first_seen_at', r.first_seen_at
      ) ORDER BY r.rank)
      FROM (
        SELECT * FROM public.v_deals_feed_ranked r
        WHERE r.gate_v1 NOT LIKE 'SUPPRESS%'
          AND (p_min_score IS NULL OR r.score >= p_min_score)
          AND (p_league IS NULL OR r.league = p_league)
        ORDER BY r.rank
        LIMIT GREATEST(LEAST(p_limit, 500), 1)
      ) r
    ), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $fn$;
