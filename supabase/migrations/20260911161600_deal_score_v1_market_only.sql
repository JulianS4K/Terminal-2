-- ============================================================================
-- Migration 20260911161600 — deal_score_v1: market-only winner score + hard gates on the feed
--
-- Lane:     D0 (deals surface)
-- Touches:  deal_score_v1(jsonb) · deal_gate_v1(jsonb) (new, IMMUTABLE) ·
--           deal_signal_snapshot (+score_v1, +gate_v1, trigger, index, one-shot backfill) ·
--           get_deal_signals(int,numeric,text) (CREATE OR REPLACE, same signature) ·
--           v_deals_feed_ranked (new view, service_role)
-- Pre-reqs: 20260911160800, 20260911160400 (the label the weights come from)
--
-- Already applied to prod · via MCP 2026-09-11 (operator: "ignore news feed for now, use other
-- metrics to strengthen feed more").
--
-- WHAT THE LABEL SAYS (80 zone/section-graded deals, all MLB, 2026-08-11 → 09-11; base win 30%):
--   days to event      ≤1: 89% (n 9) · 2–7: 40% · 8–14: 26% · 15+: 17%
--   weekend event      50% vs weekday 14%
--   7d MA / 14d MA     rising >1.05: 45% · flat: 32% · falling <0.95: 13%
--   moneyness          0.5–0.7: 46% · 0.7–0.9: 33% · ≥0.9: 0% (n 18) · <0.5: 0% (n 3, mis-anchored)
--   regime             STABLE 45% · RISING 38% · DUMPING 14% · SOFTENING 13%
--   quantity           1–2: 35% · 3–4: 23% · 5+: 0%
--   cost               <$50: 38% · ≥$50: 27%
--   vs_zone_pct        <-50: 0% · -50..-35: 16% · -35..-20: 30%  (deeper "discount" = wrong seat)
--   cost / amalgam med ≥0.8: 16% · <0.8: 37%
--   No usable signal: sigma_14d, theta_7d, gt_listings_n (all MLB rows have sales_7d 21+).
--   News / social / team / market-futures blocks are deliberately NOT used (operator).
--
-- v1 = logistic over those buckets. Weights are the bucket log-odds vs base, SHRUNK toward 0
-- by n/(n+10) and the sum damped ×0.6 because the buckets overlap (weekend ⊂ dte, regime ⊂ MA).
-- In-sample on the 80: AUC 0.94 (feed's own win_prob 0.67); top-16 by v1 won 94%, bottom-32 won 3%.
-- It is still a HAND RULE fitted by eye on 80 MLB rows: provisional until ~300 flag-time labels,
-- and the active feed today is NHL/NBA preseason (dte 15+), where it will mostly say "wait".
--
-- GATES (deal_gate_v1) make the feed smaller, not just re-ranked:
--   SUPPRESS  moneyness ≥ 0.9          — priced at market, 0/18 ever won
--   SUPPRESS  DUMPING/SOFTENING + falling MA — 1 win in 9
--   VERIFY    moneyness < 0.5 or vs_zone < -50 — "too cheap": obstructed / mis-zoned until a human looks
--   OK        everything else
-- get_deal_signals() now ranks by coalesce(model_prob, score_v1), hides SUPPRESS rows (count in
-- the envelope), and carries gate_v1 + timing so the terminal can badge them.
--
-- ROLLBACK: DROP VIEW v_deals_feed_ranked; DROP TRIGGER deal_signal_snapshot_score_v1 ON
-- deal_signal_snapshot; DROP FUNCTION deal_signal_snapshot_score_v1_tg(), deal_gate_v1(jsonb),
-- deal_score_v1(jsonb); ALTER TABLE deal_signal_snapshot DROP COLUMN score_v1, DROP COLUMN gate_v1;
-- re-apply get_deal_signals from 160800.
-- ============================================================================

-- ── 1. Score ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.deal_score_v1(f jsonb)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
AS $fn$
DECLARE
  z numeric := 0; v numeric; q int;
BEGIN
  IF f IS NULL THEN RETURN NULL; END IF;

  -- timing (strongest): last-day flags win, 15+ days out mostly do not
  v := (f->>'dte')::numeric;
  IF v IS NOT NULL THEN
    z := z + CASE WHEN v <= 1 THEN 1.40 WHEN v <= 7 THEN 0.22 WHEN v <= 14 THEN -0.13 ELSE -0.60 END;
  END IF;
  -- weekend event
  z := z + CASE WHEN (f->>'is_weekend')::boolean THEN 0.66 ELSE -0.79 END;
  -- 7-day over 14-day amalgam median (the "15-day MA change")
  v := (f->>'ma7_over_ma14')::numeric;
  IF v IS NOT NULL THEN
    z := z + CASE WHEN v > 1.05 THEN 0.45 WHEN v < 0.95 THEN -0.74 ELSE 0 END;
  END IF;
  -- moneyness = cost / realized anchor
  v := (f->>'moneyness')::numeric;
  IF v IS NOT NULL THEN
    z := z + CASE WHEN v < 0.5 THEN -0.50 WHEN v < 0.7 THEN 0.54 WHEN v < 0.9 THEN 0.10 ELSE -1.30 END;
  END IF;
  -- regime
  z := z + CASE f->>'regime' WHEN 'DUMPING' THEN -0.58 WHEN 'SOFTENING' THEN -0.44
                             WHEN 'RISING' THEN 0.29 WHEN 'STABLE' THEN 0.34 ELSE -0.22 END;
  -- lot size
  q := coalesce((f->>'quantity')::int, 2);
  z := z + CASE WHEN q <= 2 THEN 0.19 WHEN q <= 4 THEN -0.24 ELSE -0.35 END;
  -- ticket cost
  v := coalesce((f->>'cost')::numeric, 0);
  z := z + CASE WHEN v < 50 THEN 0.27 ELSE -0.12 END;
  -- discount vs the zone median: deeper than -35% is a wrong-seat signal, not a bargain
  v := (f->>'vs_zone_pct')::numeric;
  z := z + CASE WHEN v IS NULL THEN 0.20 WHEN v < -50 THEN -0.50 WHEN v < -35 THEN -0.52
                WHEN v < -20 THEN 0 ELSE -0.12 END;
  -- cost vs the event's amalgam median
  v := (f->>'cost_vs_amalgam')::numeric;
  IF v IS NOT NULL THEN
    z := z + CASE WHEN v >= 0.8 THEN -0.57 ELSE 0.25 END;
  END IF;

  z := -0.85 + 0.6 * z;   -- base = logit(0.30); 0.6 damps the overlapping buckets
  RETURN round((1 / (1 + exp(-GREATEST(LEAST(z, 30), -30))))::numeric, 4);
END $fn$;
COMMENT ON FUNCTION public.deal_score_v1(jsonb) IS
  'Market-only heuristic P(win): days-to-event, weekend, 7d/14d MA trend, moneyness, regime, lot size, cost, vs-zone discount, cost/amalgam. Weights = shrunk bucket log-odds from the 2026-09-11 label (80 MLB rows; in-sample AUC 0.94). No news/social/team inputs. Provisional until ~300 labels. D0 mig 20260911161600.';

-- ── 2. Gate ──────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.deal_gate_v1(f jsonb)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $fn$
  SELECT CASE
    WHEN f IS NULL THEN 'OK'
    WHEN (f->>'moneyness')::numeric >= 0.9 THEN 'SUPPRESS at-market'
    WHEN f->>'regime' IN ('DUMPING','SOFTENING') AND (f->>'ma7_over_ma14')::numeric < 0.95 THEN 'SUPPRESS falling-market'
    WHEN (f->>'moneyness')::numeric < 0.5 OR (f->>'vs_zone_pct')::numeric < -50 THEN 'VERIFY too-cheap'
    ELSE 'OK' END
$fn$;
COMMENT ON FUNCTION public.deal_gate_v1(jsonb) IS
  'Feed gate from the 2026-09-11 label: at-market (moneyness ≥0.9, 0/18 wins) and dumping/softening+falling-MA (1/9) are SUPPRESSED; <0.5× anchor or <-50% vs zone is VERIFY (wrong-seat risk). D0 mig 20260911161600.';

-- ── 3. Stored on the snapshot (trigger keeps it current; one-shot backfill) ──
ALTER TABLE public.deal_signal_snapshot
  ADD COLUMN IF NOT EXISTS score_v1 numeric,
  ADD COLUMN IF NOT EXISTS gate_v1  text;

CREATE OR REPLACE FUNCTION public.deal_signal_snapshot_score_v1_tg()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  NEW.score_v1 := public.deal_score_v1(NEW.features);
  NEW.gate_v1  := public.deal_gate_v1(NEW.features);
  RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS deal_signal_snapshot_score_v1 ON public.deal_signal_snapshot;
CREATE TRIGGER deal_signal_snapshot_score_v1
  BEFORE INSERT OR UPDATE OF features ON public.deal_signal_snapshot
  FOR EACH ROW EXECUTE FUNCTION public.deal_signal_snapshot_score_v1_tg();

UPDATE public.deal_signal_snapshot
   SET score_v1 = public.deal_score_v1(features), gate_v1 = public.deal_gate_v1(features)
 WHERE score_v1 IS NULL;

CREATE INDEX IF NOT EXISTS deal_signal_snapshot_score_v1_idx
  ON public.deal_signal_snapshot (score_v1 DESC NULLS LAST);

-- ── 4. Ranked feed view (service_role; the RPC below is the client surface) ──
CREATE OR REPLACE VIEW public.v_deals_feed_ranked AS
SELECT f.tevo_event_id, f.gt_listing_id, f.gt_event_id, f.event_name, f.event_date, s.league,
       f.zone, f.section, f."row", f.quantity, f.gt_price,
       f.win_prob AS feed_win_prob, f.net_profit_pct AS feed_net_profit_pct, f.confidence AS feed_confidence,
       s.score_v1, s.gate_v1, s.score_v0, s.model_prob,
       coalesce(s.model_prob, s.score_v1) AS score,
       s.dte, CASE WHEN s.dte <= 1 THEN 'LAST-DAY' WHEN s.dte <= 7 THEN 'THIS-WEEK' WHEN s.dte <= 14 THEN '2-WEEKS' ELSE 'FAR' END AS timing,
       s.moneyness, s.ma7_over_ma14, s.regime, s.vs_zone_pct, s.cost_vs_amalgam, s.is_weekend,
       s.as_of_flag, s.captured_at, f.first_seen_at,
       rank() OVER (ORDER BY coalesce(s.model_prob, s.score_v1) DESC NULLS LAST, f.first_seen_at DESC) AS rank
FROM public.gotickets_deals_feed f
JOIN public.deal_signal_snapshot s ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
WHERE f.gone_at IS NULL;
REVOKE ALL ON public.v_deals_feed_ranked FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_deals_feed_ranked TO service_role;
COMMENT ON VIEW public.v_deals_feed_ranked IS
  'Active GoTickets deals ranked by the winner score (fitted model_prob when loaded, else score_v1), with gate_v1 (OK / VERIFY too-cheap / SUPPRESS …) and timing. SQL-side consumer of the same ranking get_deal_signals() serves the terminal. D0 mig 20260911161600.';

-- ── 5. RPC: rank by v1, hide SUPPRESS rows, carry gate + timing ──────────────
CREATE OR REPLACE FUNCTION public.get_deal_signals(
  p_limit      int     DEFAULT 100,
  p_min_score  numeric DEFAULT NULL,   -- on coalesce(model_prob, score_v1)
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
REVOKE ALL ON FUNCTION public.get_deal_signals(int,numeric,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deal_signals(int,numeric,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deal_signals(int,numeric,text) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_deal_signals(int,numeric,text) IS
  'D0 DEALS page: active deals ranked by the winner score (fitted model_prob when loaded, else market-only score_v1), SUPPRESS-gated rows hidden (counted in suppressed_n), each row carrying gate + timing + the market features. Email-gated @s4kent.com. D0 mig 20260911161600.';
