-- ============================================================================
-- Migration 20260911161400 — snapshot_deal_signals(): one liquidity row per (event, as_of_date)
--
-- Lane:     D0 (deals surface)
-- Touches:  snapshot_deal_signals(int,boolean,int) (CREATE OR REPLACE, same signature)
-- Pre-reqs: 20260911160800
--
-- Already applied to prod · via MCP 2026-09-11 (fix to the just-applied 160800; the full
-- 5,163-row feed backfill completed under this body).
--
-- The 450-row backfill batch (snapshot_deal_signals(450, true, 0)) failed with
-- "ON CONFLICT DO UPDATE command cannot affect row a second time". Root cause: the
-- `_liq` temp table was built from DISTINCT (ev, gt_event_id, as_of_date) but joined
-- back on (ev, as_of_date) only, so a feed event whose listings sit under two or more
-- GoTickets event ids (double-mapped hubs, re-listed events) fanned every candidate
-- listing out once per gt_event_id and the upsert saw the same (tevo_event_id,
-- gt_listing_id) twice. Only the 4c block changes:
--   • `_liq` is grouped to (ev, as_of_date);
--   • gt_listings_n sums the latest-capture listing depth across all of that event's
--     gt_event_ids (depth is per GT event, so the sum is the event's total depth);
--   • sg_sales_7d / crm_sales_7d / our_inventory_n were already keyed by the TEvo event
--     and are unchanged.
-- Behaviour for single-gt_event_id events (the overwhelming majority) is identical.
-- ============================================================================

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

  -- 4c. Liquidity block per (event, as_of_date) — exactly one row per key (mig 161400):
  --     gt depth is summed over every gt_event_id the event's candidates sit under.
  CREATE TEMP TABLE _liq ON COMMIT DROP AS
  WITH ev AS (SELECT DISTINCT ev, as_of_date FROM _c),
  gt AS (
    SELECT c.ev, c.as_of_date, sum(
      (SELECT count(*)::int FROM public.gotickets_listings_snapshots g
        WHERE g.gt_event_id = c.gt_event_id
          AND g.captured_at = (SELECT max(g2.captured_at) FROM public.gotickets_listings_snapshots g2 WHERE g2.gt_event_id = c.gt_event_id))
    )::int AS gt_listings_n
    FROM (SELECT DISTINCT ev, gt_event_id, as_of_date FROM _c) c
    GROUP BY c.ev, c.as_of_date
  )
  SELECT ev.ev, ev.as_of_date,
         gt.gt_listings_n,
         (SELECT count(DISTINCT x.sg_sale_id)::int FROM public.seatgeek_sales_snapshots x
           WHERE x.tevo_event_id = ev.ev AND x.sale_at_utc::date BETWEEN ev.as_of_date - 7 AND ev.as_of_date) AS sg_sales_7d,
         (SELECT count(*)::int FROM public.v_s4kcs_orders c
           WHERE c.tevo_event_id = ev.ev AND c.purchase_date BETWEEN ev.as_of_date - 7 AND ev.as_of_date) AS crm_sales_7d,
         (SELECT i.s4k_listings FROM public.v_s4k_inventoried_events i WHERE i.event_id = ev.ev) AS our_inventory_n
  FROM ev LEFT JOIN gt ON gt.ev = ev.ev AND gt.as_of_date = ev.as_of_date;

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

COMMENT ON FUNCTION public.snapshot_deal_signals(int,boolean,int) IS
  'Flag-time feature snapshot per feed row (price/vol/momentum, liquidity, team state, prediction-market futures, social, venue, context) + v0/fitted score. Liquidity block is one row per (event, as_of_date) since mig 20260911161400. D0 mig 20260911160800.';
