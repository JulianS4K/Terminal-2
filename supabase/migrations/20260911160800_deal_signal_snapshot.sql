-- ============================================================================
-- Migration 20260911160800 — DEAL SIGNALS: per-deal feature snapshot + winner score
--
-- Lane:     D0 (deals surface)
-- Touches:  deal_signal_snapshot (W, new) · deal_model_coef (W, new) ·
--           snapshot_deal_signals() (W, new fn) · deal_score_v0(jsonb) · deal_score(jsonb,text) ·
--           get_deal_signals() (new read RPC) · cron_policy (+1) · cron.job (deal_signals_snapshot_10min)
--           Reads: gotickets_deals_feed, events, performer_metadata, event_listing_snapshot_daily,
--           clearing_dte_curve, gotickets_listings_snapshots, seatgeek_sales_snapshots, v_s4kcs_orders,
--           performer_espn_team_xref, v_espn_team_state, espn_attendance_latest, v_espn_injuries_current,
--           espn_news, espn_transactions, prediction_market_xref, prediction_markets,
--           v_event_betting_odds_latest, v_performer_reddit_pulse, venue_baselines, performer_stat_card,
--           event_sentiment, v_event_nws_alerts
-- Pre-reqs: 20260911160300 (feed prod columns: regime/zone_median/…), 20260811220000 (feed win_prob),
--           20260702235600 (prediction markets), 20260708180040 (clearing_dte_curve + price_dte_bucket)
--
-- WHY (operator direction 2026-09-11: "let's build an algorithm to detect winners
-- using all the data. think options metrics plus similar, also include kalshi and
-- nba"). The feed today is a single cross-sectional test (is this seat cheap vs
-- its zone?) with a realized anchor bolted on. Grading it (mig 20260911160400)
-- showed the anchor over-predicts ~2x and that the REGIME tag was the strongest
-- discriminator we had. A winner is a function of far more than one snapshot, so
-- this migration does two things:
--
--   1. FEATURE SNAPSHOT. For every feed row, capture ONE wide row of signals AT
--      FLAG TIME (that is the only honest training row: features known when the
--      buy decision was possible, label known later). Backfilled rows for deals
--      already in the feed compute the price/volatility block as of first_seen_at
--      (daily history exists) but the sports/market/social block as of now —
--      `as_of_flag=false` marks them so a fit can down-weight or exclude them.
--
--      Feature families (an option-pricing framing, because a ticket IS a
--      decaying claim on an uncertain event-day price):
--        · MONEYNESS      cost / realized anchor (strike vs spot); cost / amalgam
--                         market median; vs_zone_pct, mod_z (how far out-of-band).
--        · VOLATILITY     sigma_14d = stdev of daily log-changes of the event's
--                         amalgam median (implied-vol proxy); range_pct_14d.
--        · MOMENTUM/DRIFT ma7_over_ma14 (short vs long MA); the scanner's regime
--                         + degr_excess_pct (drift vs the clearing curve).
--        · THETA          theta_7d = clearing_dte_curve level change expected over
--                         the next 7 days at this DTE (time decay of the claim).
--        · LIQUIDITY      GoTickets listing depth, SG+CRM sales in the last 7d,
--                         quantity/split class, our own inventory on the event.
--        · TEAM (home = primary performer, ESPN): win_pct, games_back, playoff
--                         seed, streak, injuries, attendance home_pct; opponent
--                         win_pct (away = the other performer_ids entry).
--        · MARKETS        Kalshi/Polymarket futures for the home performer
--                         (highest-volume open futures market: yes_price + volume;
--                         at 14+ days out game markets rarely exist yet) and ESPN
--                         odds when the game is within scoreboard range.
--        · SOCIAL         reddit pulse, ESPN news + transactions (7d). ⚠ Measured
--                         2026-09-11: ALL FOUR social/news ingests have written 0
--                         rows in 7 days while their crons show active — these
--                         columns will be NULL/0 until A1 repairs them (KANBAN).
--        · CONTEXT        venue ratio (zone median / venue baseline), performer
--                         30d price + sold trends, ask-over-sold spread, event
--                         sentiment index, weather alert, weekend, DTE, accessible.
--
--   2. SCORE. `deal_score_v0(features)` is a hand-weighted logistic seeded from
--      the grading (DUMPING → 9–12% win, top-bucket 84% predicted → 42% actual,
--      unanchored rows → ~11%): it shrinks the feed's win_prob, penalises dumping,
--      volatility, negative theta and rare splits, rewards cheapness vs anchor
--      and market, momentum, liquidity, team strength and attendance. It is a
--      PLACEHOLDER with explicit weights, not a fit. `deal_model_coef` +
--      `deal_score(features, version)` are the plug for a FITTED model:
--      scripts/fit_deal_scorer.py fits a standardised L2 logistic regression on
--      v_deal_training_set (mig 20260911160900: snapshot ⋈ outcome label) and
--      emits the coefficient rows; the snapshot then carries both `score_v0` and
--      `model_prob` (NULL until a version is loaded) so the two can be compared
--      on the same deals before either drives the page.
--
-- Coverage measured on a 300-deal sample (2026-09-11): the feed is 100% sports
-- (curated zones exist only for teams): NHL 65% · NBA 25% · MLB 9% · NFL 1%.
-- 14-day amalgam history ≥10 days: 91–100%. Performer-level futures: 100%.
-- Event-level odds / game markets: 0–19% (games too far out). Curated-zone
-- historic baseline: MLB/NFL only. Reddit: 0% (dead ingest).
--
-- READ-ONLY upstream: no API call. Bounded: p_max rows/run, statement_timeout.
-- ROLLBACK: SELECT cron.unschedule('deal_signals_snapshot_10min');
--           DELETE FROM public.cron_policy WHERE jobname='deal_signals_snapshot_10min';
--           DROP FUNCTION public.get_deal_signals(int,numeric,text);
--           DROP FUNCTION public.snapshot_deal_signals(int,boolean,int);
--           DROP FUNCTION public.deal_score(jsonb,text); DROP FUNCTION public.deal_score_v0(jsonb);
--           DROP TABLE public.deal_signal_snapshot; DROP TABLE public.deal_model_coef;
-- ============================================================================

-- ── 1. Snapshot table ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.deal_signal_snapshot (
  tevo_event_id      bigint      NOT NULL,
  gt_listing_id      bigint      NOT NULL,
  captured_at        timestamptz NOT NULL DEFAULT now(),
  as_of_date         date        NOT NULL,      -- date the price/vol block is computed as of
  as_of_flag         boolean     NOT NULL,      -- true = captured at flag time; false = backfilled
  event_date         date,
  league             text,
  category           text,
  -- moneyness
  cost               numeric,
  quantity           int,
  anchor_med         numeric,                    -- feed realized_median at capture
  anchor_n           int,
  anchor_basis       text,
  moneyness          numeric,                    -- cost / anchor_med
  amalgam_med        numeric,                    -- event amalgam median as of as_of_date
  cost_vs_amalgam    numeric,                    -- cost / amalgam_med
  zone_median        numeric,
  zone_n             int,
  vs_zone_pct        int,
  mod_z              numeric,
  section_median     numeric,
  vs_section_pct     int,
  -- volatility / momentum / theta
  ma_days            int,
  sigma_14d          numeric,
  range_pct_14d      numeric,
  ma7_over_ma14      numeric,
  regime             text,
  degr_excess_pct    numeric,
  degr_factor        numeric,
  theta_7d           numeric,
  dte                int,
  -- liquidity
  gt_listings_n      int,
  sales_7d           int,
  sg_sales_7d        int,
  crm_sales_7d       int,
  our_inventory_n    int,
  -- team / opponent
  home_win_pct       numeric,
  home_games_back    numeric,
  home_playoff_seed  int,
  home_streak        int,                        -- +W / -L run length
  home_injuries_n    int,
  home_att_pct       numeric,
  opp_win_pct        numeric,
  -- markets
  pm_fut_yes         numeric,
  pm_fut_volume      numeric,
  pm_fut_title       text,
  pm_fut_source      text,
  odds_home_win_prob numeric,
  -- social
  reddit_posts_7d    int,
  reddit_score_24h   numeric,
  espn_news_7d       int,
  espn_txn_7d        int,
  -- context
  venue_med          numeric,
  venue_ratio        numeric,                    -- zone_median / venue_med
  perf_trend_px_30d  numeric,
  perf_trend_sold_30d numeric,
  perf_ask_over_sold numeric,
  sentiment_index    numeric,
  weather_alert      boolean,
  is_weekend         boolean,
  is_accessible      boolean,
  -- feed prediction at capture
  pred_win_prob      numeric,
  pred_net_profit_pct int,
  pred_confidence    text,
  -- scores
  features           jsonb       NOT NULL DEFAULT '{}'::jsonb,
  score_v0           numeric,
  model_version      text,
  model_prob         numeric,
  meta               jsonb       NOT NULL DEFAULT '{}'::jsonb,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tevo_event_id, gt_listing_id)
);
ALTER TABLE public.deal_signal_snapshot ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS deal_signal_snapshot_score_idx ON public.deal_signal_snapshot (score_v0 DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS deal_signal_snapshot_event_idx ON public.deal_signal_snapshot (event_date);
GRANT SELECT ON public.deal_signal_snapshot TO authenticated, service_role;
COMMENT ON TABLE public.deal_signal_snapshot IS
  'One wide feature row per GoTickets deal, captured at flag time (as_of_flag) or backfilled: moneyness / volatility / momentum / theta / liquidity / team / markets / social / context, plus score_v0 (heuristic logistic) and model_prob (fitted coefficients from deal_model_coef). Written by snapshot_deal_signals(). D0 mig 20260911160800.';

-- ── 2. Coefficients for a fitted model ───────────────────────────────────────
-- One row per (version, feature). feature='__intercept__' holds the bias (mean/sd
-- ignored). Scoring standardises each feature as (x - mean) / sd before applying
-- coef, and treats a missing feature as its mean (contributes 0).
CREATE TABLE IF NOT EXISTS public.deal_model_coef (
  model_version text        NOT NULL,
  feature       text        NOT NULL,
  coef          numeric     NOT NULL,
  mean          numeric,
  sd            numeric,
  fitted_at     timestamptz NOT NULL DEFAULT now(),
  n_train       int,
  notes         text,
  PRIMARY KEY (model_version, feature)
);
ALTER TABLE public.deal_model_coef ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.deal_model_coef TO authenticated, service_role;
COMMENT ON TABLE public.deal_model_coef IS
  'Standardised logistic-regression coefficients per model_version for deal_score(features, version). Emitted by scripts/fit_deal_scorer.py from v_deal_training_set. Row feature=__intercept__ is the bias. D0 mig 20260911160800.';

CREATE OR REPLACE FUNCTION public.deal_score(p_features jsonb, p_version text)
RETURNS numeric
LANGUAGE sql STABLE
AS $fn$
  WITH c AS (SELECT feature, coef, mean, sd FROM public.deal_model_coef WHERE model_version = p_version),
  z AS (
    SELECT sum(CASE WHEN c.feature = '__intercept__' THEN c.coef
                    WHEN (p_features ->> c.feature) IS NULL OR c.sd IS NULL OR c.sd = 0 THEN 0
                    ELSE c.coef * (((p_features ->> c.feature)::numeric - coalesce(c.mean, 0)) / c.sd) END) AS lin,
           count(*) AS n
    FROM c
  )
  SELECT CASE WHEN n = 0 THEN NULL
              ELSE round((1 / (1 + exp(-GREATEST(LEAST(lin, 30), -30))))::numeric, 4) END
  FROM z;
$fn$;
COMMENT ON FUNCTION public.deal_score(jsonb,text) IS
  'P(win) from deal_model_coef for a model_version over a features jsonb (standardised linear-logistic; missing feature = mean). NULL when the version has no coefficients. D0 mig 20260911160800.';

-- ── 3. Heuristic v0 score (explicit weights; seeded from the 2026-09-11 grading) ─
CREATE OR REPLACE FUNCTION public.deal_score_v0(f jsonb)
RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
AS $fn$
DECLARE
  z numeric := -0.35;
  v numeric; p numeric;
BEGIN
  -- Feed win_prob: keep it, but shrink the logit by half (84% predicted → ~42% observed).
  p := (f->>'pred_win_prob')::numeric;
  IF p IS NULL THEN z := z - 0.9;                       -- un-anchored rows won ~11%
  ELSE p := LEAST(GREATEST(p, 0.02), 0.98); z := z + 0.5 * ln(p / (1 - p)); END IF;
  -- Regime (drift vs the clearing curve): the strongest single discriminator so far.
  z := z + CASE f->>'regime' WHEN 'DUMPING' THEN -1.3 WHEN 'SOFTENING' THEN -0.5
                             WHEN 'RISING' THEN 0.3 WHEN 'STABLE' THEN 0 ELSE -0.2 END;
  -- Moneyness: cheaper vs the realized anchor is better (log, clamped).
  v := (f->>'moneyness')::numeric;
  IF v IS NOT NULL AND v > 0 THEN z := z - 2.0 * LEAST(GREATEST(ln(v), -1.5), 1.5); END IF;
  -- Cheapness vs the whole-event market median (weaker, the zone may be premium).
  v := (f->>'cost_vs_amalgam')::numeric;
  IF v IS NOT NULL AND v > 0 THEN z := z - 0.8 * LEAST(GREATEST(ln(v), -1.0), 1.0); END IF;
  -- Volatility of the event's market median: uncertainty is a cost.
  v := (f->>'sigma_14d')::numeric;
  IF v IS NOT NULL THEN z := z - 4.0 * LEAST(GREATEST(v, 0), 0.3); END IF;
  -- Momentum: short MA over long MA.
  v := (f->>'ma7_over_ma14')::numeric;
  IF v IS NOT NULL THEN z := z + 3.0 * LEAST(GREATEST(v - 1, -0.2), 0.2); END IF;
  -- Theta: expected clearing-curve move over the next 7 days (negative = decay).
  v := (f->>'theta_7d')::numeric;
  IF v IS NOT NULL THEN z := z + 2.0 * LEAST(GREATEST(v, -0.5), 0.5); END IF;
  -- Liquidity: realized sales in the last 7 days.
  v := (f->>'sales_7d')::numeric;
  IF v IS NOT NULL THEN z := z + 0.15 * ln(1 + GREATEST(v, 0)); END IF;
  -- Team strength / standing / health / draw.
  v := (f->>'home_win_pct')::numeric;
  IF v IS NOT NULL THEN z := z + 0.8 * (v - 0.5); END IF;
  v := (f->>'home_games_back')::numeric;
  IF v IS NOT NULL THEN z := z - 0.05 * LEAST(GREATEST(v, 0), 20); END IF;
  v := (f->>'home_injuries_n')::numeric;
  IF v IS NOT NULL THEN z := z - 0.03 * LEAST(GREATEST(v, 0), 20); END IF;
  v := (f->>'home_att_pct')::numeric;
  IF v IS NOT NULL AND v > 0 THEN z := z + 0.6 * LEAST(GREATEST(v - 0.85, -0.5), 0.2); END IF;
  v := (f->>'opp_win_pct')::numeric;
  IF v IS NOT NULL THEN z := z + 0.4 * (v - 0.5); END IF;
  -- Prediction markets: championship-class futures odds vs a 1-in-32 baseline.
  v := (f->>'pm_fut_yes')::numeric;
  IF v IS NOT NULL AND v > 0 THEN z := z + 0.5 * LEAST(GREATEST(ln(v / 0.03), -0.7), 0.7); END IF;
  -- Split class: singles and blocks of 6+ are thin comparables.
  v := (f->>'quantity')::numeric;
  IF v IS NOT NULL AND (v = 1 OR v >= 6) THEN z := z - 0.4; END IF;
  -- Far-out claims carry more path risk; weekends draw.
  v := (f->>'dte')::numeric;
  IF v IS NOT NULL AND v > 120 THEN z := z - 0.3; END IF;
  IF (f->>'is_weekend')::boolean THEN z := z + 0.2; END IF;
  IF (f->>'weather_alert')::boolean THEN z := z - 0.3; END IF;
  RETURN round((1 / (1 + exp(-GREATEST(LEAST(z, 30), -30))))::numeric, 4);
END $fn$;
COMMENT ON FUNCTION public.deal_score_v0(jsonb) IS
  'Heuristic logistic P(win) with explicit hand weights seeded from the 2026-09-11 grading (placeholder until deal_model_coef carries a fitted version). D0 mig 20260911160800.';

-- ── 4. Snapshot builder ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.snapshot_deal_signals(
  p_max           int     DEFAULT 400,
  p_backfill      boolean DEFAULT false,   -- true: also rows already flagged (as_of = first_seen date)
  p_refresh_hours int     DEFAULT 24       -- re-snapshot ACTIVE rows older than this (0 = never)
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_start timestamptz := clock_timestamp();
  v_n int := 0; v_version text; v_out jsonb;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);

  -- The fitted version to score with, if any: newest fitted_at.
  SELECT model_version INTO v_version FROM public.deal_model_coef
   WHERE feature = '__intercept__' ORDER BY fitted_at DESC LIMIT 1;

  -- 4a. Candidates.
  CREATE TEMP TABLE _c ON COMMIT DROP AS
  SELECT f.tevo_event_id AS ev, f.gt_listing_id, f.gt_event_id, f.event_date,
         f.gt_price::numeric AS cost, f.quantity, f.is_accessible,
         f.realized_median AS anchor_med, f.realized_n AS anchor_n, f.resale_basis AS anchor_basis,
         f.zone_median, f.zone_n, f.vs_zone_pct, f.mod_z, f.section_median, f.vs_section_pct,
         f.regime, f.degr_excess_pct, f.degr_factor,
         f.win_prob AS pred_win_prob, f.net_profit_pct AS pred_net_profit_pct, f.confidence AS pred_confidence,
         CASE WHEN s.tevo_event_id IS NULL AND f.first_seen_at < now() - interval '2 hours'
              THEN f.first_seen_at::date ELSE current_date END        AS as_of_date,
         (s.tevo_event_id IS NULL AND f.first_seen_at >= now() - interval '2 hours')
           OR (s.tevo_event_id IS NOT NULL AND s.as_of_flag)         AS as_of_flag,
         e.primary_performer_id AS pid, e.venue_id,
         (SELECT x FROM unnest(e.performer_ids) x WHERE x <> e.primary_performer_id LIMIT 1) AS opp_pid,
         pm.espn_league AS league,
         CASE coalesce(pm.top_category_name, 'Other')
              WHEN 'Sports' THEN 'Sports' WHEN 'Concerts' THEN 'Concerts' WHEN 'Comedy' THEN 'Comedy' ELSE 'Other' END AS category,
         (extract(isodow FROM f.event_date) IN (5, 6, 7)) AS is_weekend
  FROM public.gotickets_deals_feed f
  JOIN public.events e ON e.id = f.tevo_event_id
  LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
  LEFT JOIN public.deal_signal_snapshot s
         ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
  WHERE f.gt_price > 0
    AND (
          s.tevo_event_id IS NULL AND (p_backfill OR f.first_seen_at >= now() - interval '2 hours')
       OR (p_refresh_hours > 0 AND f.gone_at IS NULL AND s.captured_at < now() - make_interval(hours => p_refresh_hours))
        )
  ORDER BY f.first_seen_at DESC
  LIMIT p_max;

  SELECT count(*) INTO v_n FROM _c;
  IF v_n = 0 THEN
    RETURN jsonb_build_object('candidates', 0, 'written', 0, 'model_version', v_version,
                              'elapsed_ms', round(extract(epoch FROM clock_timestamp() - v_start) * 1000));
  END IF;

  -- 4b. Price / volatility / momentum block per (event, as_of_date).
  CREATE TEMP TABLE _ma ON COMMIT DROP AS
  WITH ev AS (SELECT DISTINCT ev, as_of_date FROM _c),
  daily AS (
    SELECT ev.ev, ev.as_of_date, s.snapshot_date, avg(s.amalgam_median) AS med
    FROM ev JOIN public.event_listing_snapshot_daily s
      ON s.event_id = ev.ev AND s.snapshot_date BETWEEN ev.as_of_date - 14 AND ev.as_of_date AND s.amalgam_median > 0
    GROUP BY 1, 2, 3
  ),
  ret AS (
    SELECT *, ln(med / lag(med) OVER (PARTITION BY ev, as_of_date ORDER BY snapshot_date)) AS r FROM daily
  )
  SELECT ev, as_of_date,
         count(med)::int AS ma_days,
         round(stddev_samp(r)::numeric, 4) AS sigma_14d,
         round(((max(med) - min(med)) / NULLIF(percentile_cont(0.5) WITHIN GROUP (ORDER BY med), 0))::numeric, 4) AS range_pct_14d,
         round((avg(med) FILTER (WHERE snapshot_date > as_of_date - 7) / NULLIF(avg(med), 0))::numeric, 4) AS ma7_over_ma14,
         round((array_agg(med ORDER BY snapshot_date DESC))[1]::numeric, 2) AS amalgam_med
  FROM ret GROUP BY ev, as_of_date;

  -- 4c. Liquidity block per event (current listing depth; sales in the 7d before as_of).
  CREATE TEMP TABLE _liq ON COMMIT DROP AS
  WITH ev AS (SELECT DISTINCT ev, gt_event_id, as_of_date FROM _c)
  SELECT ev.ev, ev.as_of_date,
         (SELECT count(*)::int FROM public.gotickets_listings_snapshots g
           WHERE g.gt_event_id = ev.gt_event_id
             AND g.captured_at = (SELECT max(g2.captured_at) FROM public.gotickets_listings_snapshots g2 WHERE g2.gt_event_id = ev.gt_event_id)) AS gt_listings_n,
         (SELECT count(DISTINCT x.sg_sale_id)::int FROM public.seatgeek_sales_snapshots x
           WHERE x.tevo_event_id = ev.ev AND x.sale_at_utc::date BETWEEN ev.as_of_date - 7 AND ev.as_of_date) AS sg_sales_7d,
         (SELECT count(*)::int FROM public.v_s4kcs_orders c
           WHERE c.tevo_event_id = ev.ev AND c.purchase_date BETWEEN ev.as_of_date - 7 AND ev.as_of_date) AS crm_sales_7d,
         (SELECT i.s4k_listings FROM public.v_s4k_inventoried_events i WHERE i.event_id = ev.ev) AS our_inventory_n
  FROM ev;

  -- 4d. Team / market / social / context block per performer (+ event-level bits).
  CREATE TEMP TABLE _team ON COMMIT DROP AS
  WITH p AS (SELECT DISTINCT pid FROM _c UNION SELECT DISTINCT opp_pid FROM _c WHERE opp_pid IS NOT NULL)
  SELECT p.pid,
         ts.win_pct, ts.games_back, ts.playoff_seed,
         CASE WHEN ts.streak ~ '^W\d+' THEN substring(ts.streak from '\d+')::int
              WHEN ts.streak ~ '^L\d+' THEN -substring(ts.streak from '\d+')::int END AS streak_n,
         (SELECT count(*)::int FROM public.v_espn_injuries_current i WHERE i.espn_team_id = x.espn_team_id AND i.espn_league = x.espn_league) AS injuries_n,
         att.home_pct,
         (SELECT count(*)::int FROM public.espn_news n WHERE n.espn_team_id = x.espn_team_id AND n.published_at > now() - interval '7 days') AS news_7d,
         (SELECT count(*)::int FROM public.espn_transactions t WHERE t.espn_team_id = x.espn_team_id AND t.txn_date > current_date - 7) AS txn_7d,
         fut.yes_price AS pm_fut_yes, fut.volume AS pm_fut_volume, fut.title AS pm_fut_title, fut.source AS pm_fut_source,
         rp.posts_7d AS reddit_posts_7d, rp.score_24h AS reddit_score_24h,
         sc.trend_px_30d, sc.trend_sold_30d, sc.ask_over_sold_pct
  FROM p
  LEFT JOIN LATERAL (SELECT espn_team_id, espn_league FROM public.performer_espn_team_xref x WHERE x.tevo_performer_id = p.pid LIMIT 1) x ON true
  LEFT JOIN public.v_espn_team_state ts ON ts.espn_team_id = x.espn_team_id AND ts.espn_league = x.espn_league
  LEFT JOIN LATERAL (SELECT home_pct FROM public.espn_attendance_latest a WHERE a.espn_team_id = x.espn_team_id AND a.espn_league = x.espn_league ORDER BY season DESC LIMIT 1) att ON true
  LEFT JOIN LATERAL (
    SELECT pm.yes_price, pm.volume, pm.title, pm.source
    FROM public.prediction_market_xref xr JOIN public.prediction_markets pm ON pm.source = xr.source AND pm.market_id = xr.market_id
    WHERE xr.tevo_performer_id = p.pid AND pm.market_type = 'futures'
      AND coalesce(pm.status, '') NOT IN ('closed','settled','finalized','resolved')
    ORDER BY pm.volume DESC NULLS LAST LIMIT 1) fut ON true
  LEFT JOIN public.v_performer_reddit_pulse rp ON rp.tevo_performer_id = p.pid
  LEFT JOIN public.performer_stat_card sc ON sc.performer_id = p.pid;

  -- 4e. Assemble, score, upsert.
  WITH rows_ AS (
    SELECT c.*,
      m.ma_days, m.sigma_14d, m.range_pct_14d, m.ma7_over_ma14, m.amalgam_med,
      l.gt_listings_n, l.sg_sales_7d, l.crm_sales_7d, l.our_inventory_n,
      th.win_pct AS home_win_pct, th.games_back AS home_games_back, th.playoff_seed AS home_playoff_seed,
      th.streak_n AS home_streak, th.injuries_n AS home_injuries_n, th.home_pct AS home_att_pct,
      th.news_7d AS espn_news_7d, th.txn_7d AS espn_txn_7d,
      th.pm_fut_yes, th.pm_fut_volume, th.pm_fut_title, th.pm_fut_source,
      th.reddit_posts_7d, th.reddit_score_24h,
      th.trend_px_30d AS perf_trend_px_30d, th.trend_sold_30d AS perf_trend_sold_30d, th.ask_over_sold_pct AS perf_ask_over_sold,
      ta.win_pct AS opp_win_pct,
      (c.event_date - c.as_of_date)::int AS dte,
      (SELECT round((c7.level_index / NULLIF(c0.level_index, 0) - 1)::numeric, 4)
         FROM public.clearing_dte_curve c0
         JOIN public.clearing_dte_curve c7 ON c7.category = c0.category
          AND c7.dte_bucket = public.price_dte_bucket(GREATEST((c.event_date - c.as_of_date) - 7, 0)::int)
        WHERE c0.category = c.category AND c0.dte_bucket = public.price_dte_bucket(GREATEST(c.event_date - c.as_of_date, 0)::int)) AS theta_7d,
      (SELECT o.home_win_prob FROM public.v_event_betting_odds_latest o WHERE o.tevo_event_id = c.ev LIMIT 1) AS odds_home_win_prob,
      (SELECT vb.median_retail FROM public.venue_baselines vb WHERE vb.venue_id = c.venue_id) AS venue_med,
      (SELECT es.sentiment_index FROM public.event_sentiment es WHERE es.event_id = c.ev ORDER BY es.captured_at DESC LIMIT 1) AS sentiment_index,
      EXISTS (SELECT 1 FROM public.v_event_nws_alerts w WHERE w.tevo_event_id = c.ev) AS weather_alert
    FROM _c c
    LEFT JOIN _ma  m  ON m.ev = c.ev AND m.as_of_date = c.as_of_date
    LEFT JOIN _liq l  ON l.ev = c.ev AND l.as_of_date = c.as_of_date
    LEFT JOIN _team th ON th.pid = c.pid
    LEFT JOIN _team ta ON ta.pid = c.opp_pid
  ),
  feat AS (
    SELECT r.*,
      CASE WHEN r.anchor_med > 0 THEN round(r.cost / r.anchor_med, 4) END AS moneyness,
      CASE WHEN r.amalgam_med > 0 THEN round(r.cost / r.amalgam_med, 4) END AS cost_vs_amalgam,
      CASE WHEN r.venue_med > 0 AND r.zone_median IS NOT NULL THEN round(r.zone_median / r.venue_med, 4) END AS venue_ratio,
      coalesce(r.sg_sales_7d, 0) + coalesce(r.crm_sales_7d, 0) AS sales_7d
    FROM rows_ r
  ),
  js AS (
    SELECT f.*,
      jsonb_strip_nulls(jsonb_build_object(
        'cost', f.cost, 'quantity', f.quantity, 'moneyness', f.moneyness, 'cost_vs_amalgam', f.cost_vs_amalgam,
        'vs_zone_pct', f.vs_zone_pct, 'mod_z', f.mod_z, 'vs_section_pct', f.vs_section_pct, 'zone_n', f.zone_n,
        'sigma_14d', f.sigma_14d, 'range_pct_14d', f.range_pct_14d, 'ma7_over_ma14', f.ma7_over_ma14,
        'regime', f.regime, 'degr_excess_pct', f.degr_excess_pct, 'degr_factor', f.degr_factor, 'theta_7d', f.theta_7d, 'dte', f.dte,
        'gt_listings_n', f.gt_listings_n, 'sales_7d', f.sales_7d, 'sg_sales_7d', f.sg_sales_7d, 'crm_sales_7d', f.crm_sales_7d,
        'our_inventory_n', f.our_inventory_n,
        'home_win_pct', f.home_win_pct, 'home_games_back', f.home_games_back, 'home_playoff_seed', f.home_playoff_seed,
        'home_streak', f.home_streak, 'home_injuries_n', f.home_injuries_n, 'home_att_pct', f.home_att_pct, 'opp_win_pct', f.opp_win_pct,
        'pm_fut_yes', f.pm_fut_yes, 'pm_fut_volume', f.pm_fut_volume, 'odds_home_win_prob', f.odds_home_win_prob,
        'reddit_posts_7d', f.reddit_posts_7d, 'reddit_score_24h', f.reddit_score_24h, 'espn_news_7d', f.espn_news_7d, 'espn_txn_7d', f.espn_txn_7d,
        'venue_ratio', f.venue_ratio, 'perf_trend_px_30d', f.perf_trend_px_30d, 'perf_trend_sold_30d', f.perf_trend_sold_30d,
        'perf_ask_over_sold', f.perf_ask_over_sold, 'sentiment_index', f.sentiment_index,
        'weather_alert', f.weather_alert, 'is_weekend', f.is_weekend, 'is_accessible', f.is_accessible,
        'pred_win_prob', f.pred_win_prob, 'pred_net_profit_pct', f.pred_net_profit_pct,
        'anchored', (f.anchor_med IS NOT NULL), 'league', f.league, 'as_of_flag', f.as_of_flag)) AS features
    FROM feat f
  ),
  ins AS (
    INSERT INTO public.deal_signal_snapshot AS s (
      tevo_event_id, gt_listing_id, captured_at, as_of_date, as_of_flag, event_date, league, category,
      cost, quantity, anchor_med, anchor_n, anchor_basis, moneyness, amalgam_med, cost_vs_amalgam,
      zone_median, zone_n, vs_zone_pct, mod_z, section_median, vs_section_pct,
      ma_days, sigma_14d, range_pct_14d, ma7_over_ma14, regime, degr_excess_pct, degr_factor, theta_7d, dte,
      gt_listings_n, sales_7d, sg_sales_7d, crm_sales_7d, our_inventory_n,
      home_win_pct, home_games_back, home_playoff_seed, home_streak, home_injuries_n, home_att_pct, opp_win_pct,
      pm_fut_yes, pm_fut_volume, pm_fut_title, pm_fut_source, odds_home_win_prob,
      reddit_posts_7d, reddit_score_24h, espn_news_7d, espn_txn_7d,
      venue_med, venue_ratio, perf_trend_px_30d, perf_trend_sold_30d, perf_ask_over_sold, sentiment_index,
      weather_alert, is_weekend, is_accessible, pred_win_prob, pred_net_profit_pct, pred_confidence,
      features, score_v0, model_version, model_prob, updated_at)
    SELECT j.ev, j.gt_listing_id, now(), j.as_of_date, j.as_of_flag, j.event_date, j.league, j.category,
      j.cost, j.quantity, j.anchor_med, j.anchor_n, j.anchor_basis, j.moneyness, j.amalgam_med, j.cost_vs_amalgam,
      j.zone_median, j.zone_n, j.vs_zone_pct, j.mod_z, j.section_median, j.vs_section_pct,
      j.ma_days, j.sigma_14d, j.range_pct_14d, j.ma7_over_ma14, j.regime, j.degr_excess_pct, j.degr_factor, j.theta_7d, j.dte,
      j.gt_listings_n, j.sales_7d, j.sg_sales_7d, j.crm_sales_7d, j.our_inventory_n,
      j.home_win_pct, j.home_games_back, j.home_playoff_seed, j.home_streak, j.home_injuries_n, j.home_att_pct, j.opp_win_pct,
      j.pm_fut_yes, j.pm_fut_volume, j.pm_fut_title, j.pm_fut_source, j.odds_home_win_prob,
      j.reddit_posts_7d, j.reddit_score_24h, j.espn_news_7d, j.espn_txn_7d,
      j.venue_med, j.venue_ratio, j.perf_trend_px_30d, j.perf_trend_sold_30d, j.perf_ask_over_sold, j.sentiment_index,
      j.weather_alert, j.is_weekend, j.is_accessible, j.pred_win_prob, j.pred_net_profit_pct, j.pred_confidence,
      j.features, public.deal_score_v0(j.features), v_version,
      CASE WHEN v_version IS NOT NULL THEN public.deal_score(j.features, v_version) END, now()
    FROM js j
    ON CONFLICT (tevo_event_id, gt_listing_id) DO UPDATE SET
      captured_at = now(), as_of_date = excluded.as_of_date, as_of_flag = excluded.as_of_flag,
      cost = excluded.cost, quantity = excluded.quantity, anchor_med = excluded.anchor_med, anchor_n = excluded.anchor_n,
      anchor_basis = excluded.anchor_basis, moneyness = excluded.moneyness, amalgam_med = excluded.amalgam_med,
      cost_vs_amalgam = excluded.cost_vs_amalgam, zone_median = excluded.zone_median, zone_n = excluded.zone_n,
      vs_zone_pct = excluded.vs_zone_pct, mod_z = excluded.mod_z, section_median = excluded.section_median,
      vs_section_pct = excluded.vs_section_pct, ma_days = excluded.ma_days, sigma_14d = excluded.sigma_14d,
      range_pct_14d = excluded.range_pct_14d, ma7_over_ma14 = excluded.ma7_over_ma14, regime = excluded.regime,
      degr_excess_pct = excluded.degr_excess_pct, degr_factor = excluded.degr_factor, theta_7d = excluded.theta_7d, dte = excluded.dte,
      gt_listings_n = excluded.gt_listings_n, sales_7d = excluded.sales_7d, sg_sales_7d = excluded.sg_sales_7d,
      crm_sales_7d = excluded.crm_sales_7d, our_inventory_n = excluded.our_inventory_n,
      home_win_pct = excluded.home_win_pct, home_games_back = excluded.home_games_back, home_playoff_seed = excluded.home_playoff_seed,
      home_streak = excluded.home_streak, home_injuries_n = excluded.home_injuries_n, home_att_pct = excluded.home_att_pct,
      opp_win_pct = excluded.opp_win_pct, pm_fut_yes = excluded.pm_fut_yes, pm_fut_volume = excluded.pm_fut_volume,
      pm_fut_title = excluded.pm_fut_title, pm_fut_source = excluded.pm_fut_source, odds_home_win_prob = excluded.odds_home_win_prob,
      reddit_posts_7d = excluded.reddit_posts_7d, reddit_score_24h = excluded.reddit_score_24h,
      espn_news_7d = excluded.espn_news_7d, espn_txn_7d = excluded.espn_txn_7d,
      venue_med = excluded.venue_med, venue_ratio = excluded.venue_ratio, perf_trend_px_30d = excluded.perf_trend_px_30d,
      perf_trend_sold_30d = excluded.perf_trend_sold_30d, perf_ask_over_sold = excluded.perf_ask_over_sold,
      sentiment_index = excluded.sentiment_index, weather_alert = excluded.weather_alert, is_weekend = excluded.is_weekend,
      is_accessible = excluded.is_accessible, pred_win_prob = excluded.pred_win_prob,
      pred_net_profit_pct = excluded.pred_net_profit_pct, pred_confidence = excluded.pred_confidence,
      features = excluded.features, score_v0 = excluded.score_v0, model_version = excluded.model_version,
      model_prob = excluded.model_prob, updated_at = now()
    RETURNING as_of_flag, score_v0
  )
  SELECT jsonb_build_object(
    'candidates', v_n, 'written', count(*),
    'at_flag_time', count(*) FILTER (WHERE as_of_flag), 'backfilled', count(*) FILTER (WHERE NOT as_of_flag),
    'score_v0_median', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY score_v0))::numeric, 3),
    'score_v0_ge_0_6', count(*) FILTER (WHERE score_v0 >= 0.6),
    'model_version', v_version,
    'elapsed_ms', round(extract(epoch FROM clock_timestamp() - v_start) * 1000))
  INTO v_out
  FROM ins;
  RETURN v_out;
END $fn$;

REVOKE ALL ON FUNCTION public.snapshot_deal_signals(int,boolean,int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.snapshot_deal_signals(int,boolean,int) TO service_role;
COMMENT ON FUNCTION public.snapshot_deal_signals(int,boolean,int) IS
  'Build/refresh deal_signal_snapshot rows for new feed deals (flag-time features), optionally backfill existing ones (as_of = first_seen date for the price/vol block), and score with deal_score_v0 + the newest fitted deal_model_coef version. service_role only. D0 mig 20260911160800.';

-- ── 5. Read RPC for the DEALS page ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_deal_signals(
  p_limit      int     DEFAULT 100,
  p_min_score  numeric DEFAULT NULL,   -- on score_v0 (or model_prob when present)
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
    'model_version', (SELECT model_version FROM public.deal_model_coef WHERE feature = '__intercept__' ORDER BY fitted_at DESC LIMIT 1),
    'active_scored', (SELECT count(*) FROM public.deal_signal_snapshot s JOIN public.gotickets_deals_feed f
                        ON f.tevo_event_id = s.tevo_event_id AND f.gt_listing_id = s.gt_listing_id WHERE f.gone_at IS NULL),
    'deals', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'tevo_event_id', f.tevo_event_id, 'gt_listing_id', f.gt_listing_id, 'gt_event_id', f.gt_event_id,
        'event_name', f.event_name, 'event_date', f.event_date, 'league', s.league,
        'section', f.section, 'row', f."row", 'quantity', f.quantity, 'gt_price', f.gt_price,
        'zone', f.zone, 'vs_zone_pct', f.vs_zone_pct, 'regime', f.regime,
        'pred_win_prob', f.win_prob, 'pred_net_profit_pct', f.net_profit_pct, 'confidence', f.confidence,
        'score_v0', s.score_v0, 'model_prob', s.model_prob, 'score', coalesce(s.model_prob, s.score_v0),
        'moneyness', s.moneyness, 'sigma_14d', s.sigma_14d, 'ma7_over_ma14', s.ma7_over_ma14, 'theta_7d', s.theta_7d,
        'dte', s.dte, 'sales_7d', s.sales_7d, 'gt_listings_n', s.gt_listings_n,
        'home_win_pct', s.home_win_pct, 'home_injuries_n', s.home_injuries_n, 'pm_fut_yes', s.pm_fut_yes, 'pm_fut_title', s.pm_fut_title,
        'as_of_flag', s.as_of_flag, 'captured_at', s.captured_at, 'first_seen_at', f.first_seen_at
      ) ORDER BY coalesce(s.model_prob, s.score_v0) DESC NULLS LAST, f.first_seen_at DESC)
      FROM (
        SELECT f.*, s.*
        FROM public.gotickets_deals_feed f
        JOIN public.deal_signal_snapshot s ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
        WHERE f.gone_at IS NULL
          AND (p_min_score IS NULL OR coalesce(s.model_prob, s.score_v0) >= p_min_score)
          AND (p_league IS NULL OR s.league = p_league)
        ORDER BY coalesce(s.model_prob, s.score_v0) DESC NULLS LAST, f.first_seen_at DESC
        LIMIT GREATEST(LEAST(p_limit, 500), 1)
      ) AS x(f, s)
    ), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END $fn$;
REVOKE ALL ON FUNCTION public.get_deal_signals(int,numeric,text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_deal_signals(int,numeric,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_deal_signals(int,numeric,text) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_deal_signals(int,numeric,text) IS
  'D0 DEALS page: active deals ranked by winner score (fitted model_prob when a version is loaded, else score_v0) with the key features. Email-gated @s4kent.com. D0 mig 20260911160800.';

-- ── 6. Cron: snapshot new deals every 10 minutes (gated) ─────────────────────
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, work_check_sql, daily_max_fires, notes)
VALUES
  ('deal_signals_snapshot_10min',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23], 10, 20,
   $wc$SELECT EXISTS (SELECT 1 FROM public.gotickets_deals_feed f
                     LEFT JOIN public.deal_signal_snapshot s ON s.tevo_event_id = f.tevo_event_id AND s.gt_listing_id = f.gt_listing_id
                     WHERE f.gt_price > 0 AND (s.tevo_event_id IS NULL OR (f.gone_at IS NULL AND s.captured_at < now() - interval '24 hours')))$wc$,
   144,
   'Flag-time feature snapshot + winner score for new GoTickets deals; refreshes active rows daily. mig 20260911160800')
ON CONFLICT (jobname) DO UPDATE SET work_check_sql = excluded.work_check_sql, notes = excluded.notes, updated_at = now();

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('deal_signals_snapshot_10min')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'deal_signals_snapshot_10min');
    PERFORM cron.schedule('deal_signals_snapshot_10min', '6-59/10 * * * *', $body$
      DO $b$ BEGIN
        IF NOT public.cron_should_fire('deal_signals_snapshot_10min') THEN RETURN; END IF;
        PERFORM public.snapshot_deal_signals(400, false, 24);
      END $b$;
    $body$);
  END IF;
END;
$cron$;
