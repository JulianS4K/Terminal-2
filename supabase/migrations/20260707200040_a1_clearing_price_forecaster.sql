-- Migration 20260707200040 · level:2 · lane:A1 · operator-directed (2026-07-07)
-- ============================================================================
-- CLEARING-PRICE FORECASTER (v1, section-grain) — read-only, display-only.
--
-- Projects the price a listing will actually SELL at (the realized clearing
-- price), NOT the ask. Companion to predict_event_median_24h (mig 20260620170000),
-- which forecasts the *ask* (retail_median). This forecasts the *transaction*.
--
-- Lane:     A1 (data plane — model-owned artifacts only; NEVER writes back to
--           listings_snapshots / EVO / any upstream. No reprice path — honors the
--           RULE-2 listing-source lockdown in CLAUDE.md.)
-- Touches W (all NEW, model-owned): price_clearing_coeffs (table),
--           rebuild_price_clearing_coeffs(interval) (fn), feature_weights (table),
--           v_venue_performer_value (view), predict_event_clearing_price(bigint,text) (fn),
--           cron price_clearing_coeffs_weekly.
-- Touches R: v_event_price_arbitrage, events, performer_metadata, section_metrics,
--           latest_event_metrics, seatgeek_sales_snapshots, seatgeek_event_xref,
--           seatdata_sales_snapshots, venue_section_performer_agg,
--           venue_section_opponent_agg, cast_price_ref, price_dte_bucket().
-- Pre-reqs: 20260620170000 (price_dte_bucket), 20260516120000 (v_event_price_arbitrage),
--           20260703210000 (cast_price_ref), 20260705153500 (venue_section_*_agg).
--
-- MODEL (validated read-only against prod 2026-07-07):
--   expected_clearing = WEIGHTED BLEND of section-grain signals, each contributing by
--   its own weight (feature_weights) × a confidence factor, then × demand_mult:
--     s_realized  realized section median (SG + SeatData, deduped, 45d)   w=realized_sale × n/(n+4)
--     s_ask       section ask × sold_to_ask_ratio(category, dte)          w=amalgam_ask × 0.8
--     s_opp       away-team-specific section median (opponent agg)        w=venue_section_prior × events/(events+6)
--     s_awayadj   home section prior × road-draw mult (away/overall)      w=venue_performer × events/(events+8) × 0.5
--   clearing = Σ(signal×w)/Σ(w over present signals); fall back to bare ask if none.
--   "Each thing has a different weight on price" — weights live in feature_weights (tunable).
--   band = point × (ratio_p25 / ratio_mid, ratio_p75 / ratio_mid)  -- fan-out near event
--
--   Measured ratios (realized / EVO ask), n up to 532/bucket:
--     Sports 60d+ 0.91, 22-60d 0.85, 8-21d 0.89, 2-3d 0.62 (late asks overshoot);
--     Concerts fan 0.67 (60d+) → 0.87 (2-3d). This category×dte structure is the
--     coefficient table; the per-event realized anchor sets the level.
--
--   Attribution surfaced for display (operator-directed — weight to performer,
--   roster, venue×performer): road_draw_away_median (cast_price_ref: e.g. Inter Miami
--   away $276 vs home $100), venue_performer_median (v_venue_performer_value).
--
-- Idempotent (CREATE OR REPLACE + IF NOT EXISTS + cron upsert). Coeffs rebuilt by
-- the weekly cron post-apply; predictor degrades to naive ask until then.
-- ============================================================================

-- ── 1. Per-data-type feature weights (auditable; fitting is a follow-up) ─────
-- "Assign weight to data types" lives HERE — one tunable table, not constants.
-- v1 seeds prior weights; the backtest fitter (v1.1) overwrites weight by measured
-- predictive contribution. confidence_half_life_days drives the freshness discount
-- applied at inference against source_freshness.
CREATE TABLE IF NOT EXISTS public.feature_weights (
  feature_group             text NOT NULL,   -- realized_sale | our_orders | amalgam_ask | venue_performer | performer_median | roster | venue_section_prior | demand_rank | news_buzz
  event_category            text NOT NULL DEFAULT 'ALL',  -- Sports|Concerts|Comedy|Theater|Other|ALL
  weight                    numeric NOT NULL,             -- relative blend weight (0..1+)
  confidence_half_life_days numeric,                      -- freshness decay; NULL = no decay
  n                         integer,                      -- backtest support once fitted
  fitted                    boolean NOT NULL DEFAULT false,
  fitted_at                 timestamptz,
  updated_at                timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feature_group, event_category)
);
ALTER TABLE public.feature_weights ENABLE ROW LEVEL SECURITY;
DO $p$ BEGIN
  CREATE POLICY "service_role_all" ON public.feature_weights
    TO service_role USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL; END $p$;
GRANT SELECT ON public.feature_weights TO authenticated, service_role;
COMMENT ON TABLE public.feature_weights IS
  'Per-data-type blend weights for the clearing/sale-date forecaster. Seeded with '
  'priors; overwritten by the backtest fitter (fitted=true). Applied × a freshness '
  'discount (confidence_half_life_days vs source_freshness). A1 mig 20260707200040.';

-- Seed priors (ordering validated: realized > our orders > amalgam ask > venue×perf
-- > performer median > venue section prior > buzz). Roster is a swing, not a level.
INSERT INTO public.feature_weights (feature_group, event_category, weight, confidence_half_life_days) VALUES
  ('realized_sale',        'ALL', 1.00, 14),
  ('our_orders',           'ALL', 0.90, 30),
  ('amalgam_ask',          'ALL', 0.70, 2),
  ('venue_performer',      'ALL', 0.60, 120),
  ('performer_median',     'ALL', 0.50, 120),
  ('roster',               'ALL', 0.45, 21),
  ('venue_section_prior',  'ALL', 0.40, 120),
  ('demand_rank',          'ALL', 0.35, 3),
  ('news_buzz',            'ALL', 0.15, 2),
  -- v1.1 signal expansion (distributed event-level price anchors; self-degrade when dark)
  ('seatdata_market',      'ALL', 0.55, 3),
  ('performer_history',    'ALL', 0.45, 180),
  ('matchup_history',      'ALL', 0.40, 180)
ON CONFLICT (feature_group, event_category) DO NOTHING;

-- ── 2. venue × performer value (roll up the section aggs to one row per combo) ─
-- Distinct from the venue-blind performer median AND the performer-blind venue band:
-- "how THIS performer prices at THIS venue" (home). Away/road-draw lives in
-- cast_price_ref + venue_section_opponent_agg.
CREATE OR REPLACE VIEW public.v_venue_performer_value
WITH (security_invoker = true) AS
SELECT venue_id, performer_id, max(performer_name) AS performer_name,
       count(*)                                                   AS sections,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY median_price)  AS vp_median,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY median_price_365d) AS vp_median_365d,
       min(min_getin)                                             AS vp_getin,
       sum(events_seen)                                           AS events_seen,
       max(refreshed_at)                                          AS refreshed_at
FROM public.venue_section_performer_agg
GROUP BY venue_id, performer_id;
REVOKE ALL ON public.v_venue_performer_value FROM anon;
GRANT SELECT ON public.v_venue_performer_value TO authenticated, service_role;
COMMENT ON VIEW public.v_venue_performer_value IS
  'One row per (venue, performer): how a performer prices at a specific venue '
  '(home). Rolls up venue_section_performer_agg. Feature for the clearing model. '
  'A1 mig 20260707200040.';

-- ── 3. Clearing-price coefficients (category × dte sold-to-ask ratio + band) ──
CREATE TABLE IF NOT EXISTS public.price_clearing_coeffs (
  category          text NOT NULL,          -- Sports|Concerts|Comedy|Theater|Other
  dte_bucket        text NOT NULL,          -- price_dte_bucket() label
  n                 integer,
  sold_to_ask_ratio numeric,                -- median(realized_median / ask_median)
  ratio_p25         numeric,
  ratio_p75         numeric,
  spike_up_rate     numeric,                -- fraction of events realizing > +10% over ask
  computed_at       timestamptz DEFAULT now(),
  PRIMARY KEY (category, dte_bucket)
);
ALTER TABLE public.price_clearing_coeffs ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.price_clearing_coeffs TO authenticated, service_role;
COMMENT ON TABLE public.price_clearing_coeffs IS
  'Empirical realized-to-ask ratio by category × days-to-event bucket (+p25/p75 band '
  '+ over-ask spike rate). The dte SHAPE of clearing-vs-ask; the per-event realized '
  'anchor sets the level. Rebuilt weekly. A1 mig 20260707200040.';

-- Builder — realized (SG sale median) / ask (EVO retail median) per event, from the
-- pre-built cross-source arbitrage view (already dedupes SG on sg_sale_id).
CREATE OR REPLACE FUNCTION public.rebuild_price_clearing_coeffs(p_window interval DEFAULT '120 days'::interval)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  WITH base AS (
    SELECT a.tevo_event_id,
           a.sg_sale_median_realized / a.tevo_retail_median AS ratio,
           (NULLIF(e.occurs_at_local,'')::timestamptz::date - (now() AT TIME ZONE 'UTC')::date) AS dte,
           CASE WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater')
                THEN pm.top_category_name ELSE 'Other' END AS category
    FROM public.v_event_price_arbitrage a
    JOIN public.events e ON e.id = a.tevo_event_id
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    WHERE a.tevo_retail_median > 0 AND a.sg_sale_median_realized > 0
      -- NOTE: exclude the SG-dark window 2026-06-26→07-02 once a captured_at dim is
      -- available here; v_event_price_arbitrage is a live snapshot so current rows are
      -- post-relight. The window guard bites in the daily-snapshot backtest (mig 2).
  ),
  j AS (
    SELECT category, public.price_dte_bucket(dte::int) AS dte_bucket, ratio
    FROM base WHERE dte >= 0
  )
  INSERT INTO public.price_clearing_coeffs
    (category, dte_bucket, n, sold_to_ask_ratio, ratio_p25, ratio_p75, spike_up_rate, computed_at)
  SELECT category, dte_bucket, count(*),
    percentile_cont(0.5)  WITHIN GROUP (ORDER BY ratio),
    percentile_cont(0.25) WITHIN GROUP (ORDER BY ratio),
    percentile_cont(0.75) WITHIN GROUP (ORDER BY ratio),
    count(*) FILTER (WHERE ratio > 1.10)::numeric / count(*),
    now()
  FROM j
  WHERE category IS NOT NULL AND dte_bucket IS NOT NULL
  GROUP BY category, dte_bucket
  HAVING count(*) >= 15
  ON CONFLICT (category, dte_bucket) DO UPDATE SET
    n=excluded.n, sold_to_ask_ratio=excluded.sold_to_ask_ratio,
    ratio_p25=excluded.ratio_p25, ratio_p75=excluded.ratio_p75,
    spike_up_rate=excluded.spike_up_rate, computed_at=excluded.computed_at;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $function$;
REVOKE ALL ON FUNCTION public.rebuild_price_clearing_coeffs(interval) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rebuild_price_clearing_coeffs(interval) TO service_role;

-- ── 3c. Event demand context (ESPN standings/records/injuries + Reddit/X + rank) ─
-- Surfaces the demand "why" for BOTH clubs and returns a conservative demand_mult.
-- Double-count guard: team strength + road-draw are ALREADY in realized sales and
-- cast_price_ref, so they are DISPLAY-ONLY here. Only FORWARD-looking signals move
-- demand_mult: current injuries (a star out is a change the sale window may not yet
-- reflect) and demand-rank momentum. Records/form/attendance/buzz are returned for
-- context. Every component is optional and self-degrades when its source is
-- absent/stale (sparse MLS buzz, null win_pct, etc.).
CREATE OR REPLACE FUNCTION public.get_event_demand_context(p_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_home_pid bigint; v_away_pid bigint; v_away_name text; v_sg bigint;
  v_home jsonb; v_away jsonb; v_rank jsonb; v_buzz jsonb;
  v_home_out int := 0; v_away_out int := 0;
  v_mult numeric := 1.0; v_rank_now int; v_rank_prev int;
  v_ownbook jsonb; v_attend jsonb; v_weather jsonb; v_stakes int := 0;
  v_att_pct numeric; v_wx_sev text;
BEGIN
  SELECT e.primary_performer_id, lower(btrim(split_part(e.name,' at ',1)))
    INTO v_home_pid, v_away_name
  FROM public.events e WHERE e.id = p_event_id;

  -- away performer: name-parse → performer_metadata, else the non-primary of performer_ids
  SELECT performer_id INTO v_away_pid FROM public.performer_metadata
   WHERE lower(name) = v_away_name ORDER BY popularity_score DESC NULLS LAST LIMIT 1;
  IF v_away_pid IS NULL THEN
    SELECT x::bigint INTO v_away_pid
    FROM public.events e, unnest(e.performer_ids) x
    WHERE e.id = p_event_id AND x::bigint <> v_home_pid LIMIT 1;
  END IF;

  -- team form (latest snapshot per team; win_pct computed from W/L/T if the column is null)
  SELECT jsonb_build_object('performer_id', v_home_pid, 'record', s.record_summary,
           'win_pct', round(coalesce(s.win_pct,
              (s.wins + 0.5*coalesce(s.ties,0)) / NULLIF(s.wins+s.losses+coalesce(s.ties,0),0))::numeric,3),
           'streak', s.streak, 'playoff_seed', s.playoff_seed, 'as_of', s.captured_at::date,
           'stale', (s.captured_at < now() - interval '30 days'))
    INTO v_home
  FROM public.performer_espn_team_xref xr
  JOIN LATERAL (SELECT * FROM public.espn_team_snapshots t
                WHERE t.espn_team_id = xr.espn_team_id AND t.espn_league = xr.espn_league
                ORDER BY t.captured_at DESC LIMIT 1) s ON true
  WHERE xr.tevo_performer_id = v_home_pid;

  SELECT jsonb_build_object('performer_id', v_away_pid, 'record', s.record_summary,
           'win_pct', round(coalesce(s.win_pct,
              (s.wins + 0.5*coalesce(s.ties,0)) / NULLIF(s.wins+s.losses+coalesce(s.ties,0),0))::numeric,3),
           'streak', s.streak, 'playoff_seed', s.playoff_seed, 'as_of', s.captured_at::date,
           'stale', (s.captured_at < now() - interval '30 days'))
    INTO v_away
  FROM public.performer_espn_team_xref xr
  JOIN LATERAL (SELECT * FROM public.espn_team_snapshots t
                WHERE t.espn_team_id = xr.espn_team_id AND t.espn_league = xr.espn_league
                ORDER BY t.captured_at DESC LIMIT 1) s ON true
  WHERE xr.tevo_performer_id = v_away_pid;

  -- current injuries out (last 21d) for each side
  SELECT count(DISTINCT coalesce(i.athlete_name, i.athlete_id::text)) INTO v_home_out
  FROM public.performer_espn_team_xref xr
  JOIN public.espn_injuries_snapshots i
    ON i.espn_team_id = xr.espn_team_id AND i.espn_league = xr.espn_league
  WHERE xr.tevo_performer_id = v_home_pid
    AND i.status ~* '(out|IL|injured reserve|suspension)'
    AND i.captured_at >= now() - interval '21 days';
  SELECT count(DISTINCT coalesce(i.athlete_name, i.athlete_id::text)) INTO v_away_out
  FROM public.performer_espn_team_xref xr
  JOIN public.espn_injuries_snapshots i
    ON i.espn_team_id = xr.espn_team_id AND i.espn_league = xr.espn_league
  WHERE xr.tevo_performer_id = v_away_pid
    AND i.status ~* '(out|IL|injured reserve|suspension)'
    AND i.captured_at >= now() - interval '21 days';

  -- demand rank + momentum (latest sg_market_chart row for the mapped SG event)
  SELECT x.sg_event_id INTO v_sg FROM public.seatgeek_event_xref x WHERE x.tevo_event_id = p_event_id;
  SELECT jsonb_build_object('rank', c.rank, 'prev_rank', c.prev_rank, 'peak_rank', c.peak_rank,
           'days_on_chart', c.days_on_chart, 'ma7_volume', c.ma7_volume, 'ma7_median', c.ma7_median,
           'as_of', c.chart_date),
         c.rank, c.prev_rank
    INTO v_rank, v_rank_now, v_rank_prev
  FROM public.sg_market_chart c WHERE c.sg_event_id = v_sg ORDER BY c.chart_date DESC LIMIT 1;

  -- league-coarse social buzz (7d); often 0 for niche leagues — low weight by design
  SELECT jsonb_build_object(
           'reddit_7d', (SELECT count(*) FROM public.reddit_news r
              WHERE r.league = (SELECT espn_league FROM public.performer_espn_team_xref WHERE tevo_performer_id=v_home_pid LIMIT 1)
                AND r.created_utc >= now()-interval '7 days'),
           'x_7d', (SELECT count(*) FROM public.x_news xn
              WHERE xn.league = (SELECT espn_league FROM public.performer_espn_team_xref WHERE tevo_performer_id=v_home_pid LIMIT 1)
                AND xn.created_utc >= now()-interval '7 days'))
    INTO v_buzz;

  -- OWN-BOOK GAP (v_sg_blindspot_evo_tracking): where SG is clearing vs OUR EVO ask.
  -- gap_pct < 0 = our ask sits ABOVE SG clearing (repricing-down opportunity). Live signal
  -- (SG sold re-lit + EVO live). Display-only — it's about our pricing, not market demand.
  SELECT jsonb_build_object('sg_sold_median', sg_sold_median, 'evo_median', evo_median,
           'evo_getin', evo_getin, 'owned_share', evo_owned_share,
           'gap_pct', round((100*(sg_sold_median - evo_median)/NULLIF(evo_median,0))::numeric,1))
    INTO v_ownbook
  FROM public.v_sg_blindspot_evo_tracking WHERE tevo_event_id = p_event_id LIMIT 1;

  -- Attendance / capacity (home team): near-sellout buildings lift demand.
  SELECT jsonb_build_object('home_pct', a.home_pct, 'home_avg', round(a.home_avg)::int, 'rank', a.rank),
         a.home_pct
    INTO v_attend, v_att_pct
  FROM public.espn_attendance_latest a
  JOIN public.performer_espn_team_xref xr
    ON xr.espn_team_id = a.espn_team_id AND xr.espn_league = a.espn_league
  WHERE xr.tevo_performer_id = v_home_pid LIMIT 1;

  -- Active severe-weather alert (outdoor events) — suppresses late/walk-up demand.
  SELECT jsonb_build_object('severity', severity, 'impact_tier', impact_tier, 'event', event),
         severity
    INTO v_weather, v_wx_sev
  FROM public.v_event_active_weather_alerts WHERE tevo_event_id = p_event_id
  ORDER BY expires_at DESC NULLS LAST LIMIT 1;

  -- Per-event game markets present (stakes/competitiveness). Empty for uncovered leagues.
  SELECT jsonb_array_length(coalesce(public.get_event_prediction_markets(p_event_id)->'game_markets','[]'::jsonb))
    INTO v_stakes;

  -- demand_mult: forward signals only (form/road-draw are display-only — already in the
  -- price anchor). Injuries + rank momentum + attendance + severe-weather. Tight clamp.
  -- Every term null-guards to 0, so a dark/absent feed simply drops out.
  v_mult := 1.0
            - least(v_away_out,3) * 0.04     -- away star(s) out hurts a road-draw game most
            - least(v_home_out,3) * 0.01
            + CASE WHEN v_rank_now IS NOT NULL AND v_rank_prev IS NOT NULL
                        AND v_rank_now < v_rank_prev AND v_rank_now <= 100 THEN 0.05
                   WHEN v_rank_now IS NOT NULL AND v_rank_prev IS NOT NULL
                        AND v_rank_now > v_rank_prev THEN -0.03 ELSE 0 END
            + CASE WHEN v_att_pct >= 95 THEN 0.03 WHEN v_att_pct >= 85 THEN 0.015 ELSE 0 END
            - CASE WHEN v_wx_sev IS NOT NULL THEN 0.05 ELSE 0 END;
  v_mult := greatest(0.90, least(1.15, v_mult));

  RETURN jsonb_build_object(
    'event_id', p_event_id,
    'home', coalesce(v_home, jsonb_build_object('performer_id', v_home_pid, 'applicable', false)),
    'away', coalesce(v_away, jsonb_build_object('performer_id', v_away_pid, 'applicable', false)),
    'injuries_out', jsonb_build_object('home', v_home_out, 'away', v_away_out),
    'demand_rank', coalesce(v_rank, '{}'::jsonb),
    'attendance', v_attend,
    'weather_alert', v_weather,
    'game_markets', v_stakes,
    'own_book_gap', v_ownbook,
    'buzz', v_buzz,
    'demand_mult', round(v_mult, 4),
    'note', 'form/road-draw/own_book are display-only (already in price anchor or about our own pricing); '
            'demand_mult uses injuries + rank momentum + attendance + severe-weather. Null-guarded: '
            'absent/dark feeds (SG-listings movers, dormant SeatData, stale ESPN, uncovered leagues) drop out.'
  );
END; $function$;
REVOKE ALL ON FUNCTION public.get_event_demand_context(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_event_demand_context(bigint) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_event_demand_context(bigint) IS
  'Demand context for both clubs (ESPN records/form/injuries + Reddit/X buzz + SG '
  'demand rank) + a conservative forward-only demand_mult (injuries + rank momentum; '
  'form/road-draw display-only to avoid double-count). A1 mig 20260707200040.';

-- ── 4. Predictor — section-grain clearing price + band + attribution + basis ──
-- Email-gated @s4kent.com read RPC (template: get_venue_section_medians).
CREATE OR REPLACE FUNCTION public.predict_event_clearing_price(p_event_id bigint, p_section text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_email text;
  v_res   jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com'
     AND current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: % is not @s4kent.com', v_email USING ERRCODE='42501';
  END IF;

  WITH ev AS (
    SELECT e.id, e.venue_id, e.primary_performer_id,
           (NULLIF(e.occurs_at_local,'')::timestamptz::date - (now() AT TIME ZONE 'UTC')::date) AS dte,
           CASE WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater')
                THEN pm.top_category_name ELSE 'Other' END AS category,
           lower(btrim(split_part(e.name,' at ',1))) AS away_name
    FROM public.events e
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    WHERE e.id = p_event_id
  ),
  sec_ask AS (
    SELECT retail_median, getin_price, tickets_count
    FROM public.section_metrics
    WHERE event_id = p_event_id
      AND lower(btrim(section)) = lower(btrim(p_section))
      AND coalesce(is_ancillary,false) = false
    ORDER BY captured_at DESC LIMIT 1
  ),
  ev_ask AS ( SELECT retail_median FROM public.latest_event_metrics WHERE event_id = p_event_id ),
  sg AS (  -- realized SG sales for this section (deduped on sg_sale_id)
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY d.broadcast_price) AS med, count(*) AS n
    FROM (
      SELECT DISTINCT ON (ss.sg_sale_id) ss.sg_sale_id, ss.broadcast_price
      FROM public.seatgeek_sales_snapshots ss
      JOIN public.seatgeek_event_xref x ON x.sg_event_id = ss.sg_event_id
      WHERE x.tevo_event_id = p_event_id
        AND lower(btrim(ss.section)) = lower(btrim(p_section))
        AND ss.sale_at_utc >= now() - interval '45 days'
      ORDER BY ss.sg_sale_id, ss.pulled_at DESC
    ) d
  ),
  sd AS (  -- realized SeatData sales for this section (deduped on content_hash)
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY d.price) AS med, count(*) AS n
    FROM (
      SELECT DISTINCT ON (content_hash) content_hash, price
      FROM public.seatdata_sales_snapshots
      WHERE tevo_event_id = p_event_id
        AND lower(btrim(section)) = lower(btrim(p_section))
        AND sale_timestamp >= now() - interval '45 days'
    ) d
  ),
  realized AS (  -- n-weighted blend of the two realized-sale sources
    SELECT (coalesce(sg.med,0)*coalesce(sg.n,0) + coalesce(sd.med,0)*coalesce(sd.n,0))
             / NULLIF(coalesce(sg.n,0)+coalesce(sd.n,0),0) AS med,
           coalesce(sg.n,0)+coalesce(sd.n,0) AS n
    FROM sg, sd
  ),
  coeff_f AS (  -- category×dte ratio, fall back to the 'Other' category if thin
    SELECT coalesce(c.sold_to_ask_ratio, ko.sold_to_ask_ratio) AS ratio,
           coalesce(c.ratio_p25, ko.ratio_p25) AS ratio_p25,
           coalesce(c.ratio_p75, ko.ratio_p75) AS ratio_p75,
           coalesce(c.spike_up_rate, ko.spike_up_rate) AS spike_up_rate,
           coalesce(c.n, ko.n) AS n
    FROM ev
    LEFT JOIN public.price_clearing_coeffs c
      ON c.category = ev.category AND c.dte_bucket = public.price_dte_bucket(ev.dte::int)
    LEFT JOIN public.price_clearing_coeffs ko
      ON ko.category = 'Other' AND ko.dte_bucket = public.price_dte_bucket(ev.dte::int)
  ),
  attribution AS (
    SELECT
      (SELECT vp_median FROM public.v_venue_performer_value v
        WHERE v.venue_id = ev.venue_id AND v.performer_id = ev.primary_performer_id) AS venue_performer_median,
      (SELECT away_median_price FROM public.cast_price_ref cr
        WHERE lower(cr.entity_name) = ev.away_name ORDER BY cr.away_events DESC NULLS LAST LIMIT 1) AS road_draw_away_median,
      (SELECT overall_median_price FROM public.cast_price_ref cr
        WHERE cr.tevo_performer_id = ev.primary_performer_id LIMIT 1) AS home_performer_median
    FROM ev
  ),
  perf_prior AS (  -- home team's cross-event median for THIS section (venue×performer×section)
    SELECT pa.median_price, pa.events_seen
    FROM public.venue_section_performer_agg pa, ev
    WHERE pa.venue_id = ev.venue_id AND pa.performer_id = ev.primary_performer_id
      AND pa.section_key = lower(btrim(p_section)) LIMIT 1
  ),
  opp_prior AS (  -- away-team-specific section median (visiting draw), when the venue has it
    SELECT oa.median_price, oa.events_seen
    FROM public.venue_section_opponent_agg oa, ev
    WHERE oa.venue_id = ev.venue_id AND oa.performer_id = ev.primary_performer_id
      AND lower(oa.opponent_name) = ev.away_name
      AND oa.section_key = lower(btrim(p_section)) LIMIT 1
  ),
  road AS (  -- away team's road-draw multiplier (how much it travels above its own baseline)
    SELECT cr.away_median_price, cr.overall_median_price,
           greatest(1.0, least(5.0, cr.away_median_price / NULLIF(cr.overall_median_price,0))) AS mult
    FROM public.cast_price_ref cr, ev
    WHERE lower(cr.entity_name) = ev.away_name
    ORDER BY cr.away_events DESC NULLS LAST LIMIT 1
  ),
  sdstat AS (  -- SeatData secondary event median (3rd market); dormant→drops out
    SELECT median_price FROM public.seatdata_event_stats
    WHERE tevo_event_id = p_event_id ORDER BY snapshot_ts DESC LIMIT 1
  ),
  phist AS (  -- performer season price median (SG historic); sparse for niche leagues→drops out
    SELECT hp.median_price FROM public.v_sg_historic_per_performer hp, ev
    WHERE hp.tevo_performer_id = ev.primary_performer_id ORDER BY hp.latest DESC LIMIT 1
  ),
  w AS (  -- per-data-type weights (tunable via feature_weights; event_category='ALL' in v1)
    SELECT
      coalesce(max(weight) FILTER (WHERE feature_group='realized_sale'),1.0)      AS w_real,
      coalesce(max(weight) FILTER (WHERE feature_group='amalgam_ask'),0.7)        AS w_ask,
      coalesce(max(weight) FILTER (WHERE feature_group='venue_performer'),0.6)    AS w_vp,
      coalesce(max(weight) FILTER (WHERE feature_group='venue_section_prior'),0.4) AS w_opp,
      coalesce(max(weight) FILTER (WHERE feature_group='seatdata_market'),0.55)   AS w_sd,
      coalesce(max(weight) FILTER (WHERE feature_group='performer_history'),0.45) AS w_hist
    FROM public.feature_weights WHERE event_category = 'ALL'
  ),
  base AS (
    -- ev is the 1-row anchor; sec_ask/ev_ask/priors may be empty (LEFT JOIN keeps the row).
    SELECT ev.dte, ev.category, public.price_dte_bucket(ev.dte::int) AS dte_bucket,
      sa.retail_median AS section_ask, ea.retail_median AS event_ask,
      sa.getin_price AS section_getin, sa.tickets_count AS section_tix,
      r.med AS realized_med, r.n AS realized_n,
      cf.ratio, cf.ratio_p25, cf.ratio_p75, cf.spike_up_rate, cf.n AS coeff_n,
      at.venue_performer_median, at.road_draw_away_median, at.home_performer_median,
      coalesce(sa.retail_median, ea.retail_median) AS base_ask,
      pp.median_price AS perf_prior_med, pp.events_seen AS perf_events,
      op.median_price AS opp_prior_med,  op.events_seen AS opp_events,
      rd.mult AS road_mult,
      sdstat.median_price AS sd_med, phist.median_price AS hist_med,
      w.w_real, w.w_ask, w.w_vp, w.w_opp, w.w_sd, w.w_hist
    FROM ev
    LEFT JOIN sec_ask sa ON true
    LEFT JOIN ev_ask  ea ON true
    CROSS JOIN realized r
    CROSS JOIN coeff_f  cf
    CROSS JOIN attribution at
    LEFT JOIN perf_prior pp ON true
    LEFT JOIN opp_prior  op ON true
    LEFT JOIN road       rd ON true
    LEFT JOIN sdstat ON true
    LEFT JOIN phist  ON true
    CROSS JOIN w
  ),
  sig AS (
    -- Section-grain price signals + EFFECTIVE weight (per-data-type weight × confidence):
    --   s_realized  realized SG+SeatData median          conf = n/(n+4)
    --   s_ask       section ask × category×dte ratio      conf = 0.8 (structural)
    --   s_opp       away-team-specific section median      conf = events/(events+6)
    --   s_awayadj   home section prior × road-draw mult    conf = events/(events+8) × 0.5
    -- s_awayadj lifts the cheap regular-game home price to the visiting draw so a
    -- marquee opponent (e.g. Inter Miami road mult ~2.75) isn't dragged down.
    SELECT base.*,
      realized_med AS s_realized,
      CASE WHEN base_ask IS NOT NULL AND ratio IS NOT NULL THEN base_ask * ratio END AS s_ask,
      opp_prior_med AS s_opp,
      CASE WHEN perf_prior_med IS NOT NULL THEN perf_prior_med * coalesce(road_mult,1.0) END AS s_awayadj,
      w_real * (realized_n::numeric / (realized_n + 4))                                    AS ew_realized,
      CASE WHEN base_ask IS NOT NULL AND ratio IS NOT NULL THEN w_ask * 0.8 ELSE 0 END     AS ew_ask,
      CASE WHEN opp_prior_med IS NOT NULL THEN w_opp * (opp_events::numeric/(opp_events+6)) ELSE 0 END       AS ew_opp,
      CASE WHEN perf_prior_med IS NOT NULL THEN w_vp * (perf_events::numeric/(perf_events+8)) * 0.5 ELSE 0 END AS ew_awayadj,
      -- v1.1: event-level anchors distributed to section by section_ask/event_ask (null→drop)
      CASE WHEN sd_med IS NOT NULL AND section_ask IS NOT NULL AND event_ask IS NOT NULL
           THEN sd_med * (section_ask / NULLIF(event_ask,0)) END AS s_sd,
      CASE WHEN hist_med IS NOT NULL AND section_ask IS NOT NULL AND event_ask IS NOT NULL
           THEN hist_med * (section_ask / NULLIF(event_ask,0)) END AS s_hist,
      CASE WHEN sd_med IS NOT NULL AND section_ask IS NOT NULL AND event_ask IS NOT NULL THEN w_sd * 0.7 ELSE 0 END AS ew_sd,
      CASE WHEN hist_med IS NOT NULL AND section_ask IS NOT NULL AND event_ask IS NOT NULL THEN w_hist * 0.5 ELSE 0 END AS ew_hist
    FROM base
  ),
  est AS (
    -- WEIGHTED BLEND: Σ(signal × effective_weight) / Σ(effective_weight over present signals).
    SELECT sig.*,
      ( coalesce(s_realized,0)*ew_realized + coalesce(s_ask,0)*ew_ask
        + coalesce(s_opp,0)*ew_opp + coalesce(s_awayadj,0)*ew_awayadj
        + coalesce(s_sd,0)*ew_sd + coalesce(s_hist,0)*ew_hist )
      / NULLIF( (CASE WHEN s_realized IS NOT NULL THEN ew_realized ELSE 0 END)
              + (CASE WHEN s_ask      IS NOT NULL THEN ew_ask      ELSE 0 END)
              + (CASE WHEN s_opp      IS NOT NULL THEN ew_opp      ELSE 0 END)
              + (CASE WHEN s_awayadj  IS NOT NULL THEN ew_awayadj  ELSE 0 END)
              + (CASE WHEN s_sd       IS NOT NULL THEN ew_sd       ELSE 0 END)
              + (CASE WHEN s_hist     IS NOT NULL THEN ew_hist     ELSE 0 END), 0) AS clearing_blend,
      public.get_event_demand_context(p_event_id) AS demand_ctx
    FROM sig
  ),
  fin AS (
    -- Fall back to bare ask if no weighted signals; apply the forward-only demand_mult
    -- scaled by prior-reliance (fresh realized sales already embed demand).
    SELECT est.*,
      coalesce(est.clearing_blend, est.base_ask) AS clearing_raw,
      (est.demand_ctx->>'demand_mult')::numeric  AS demand_mult,
      4.0/(coalesce(est.realized_n,0)+4)          AS prior_reliance,
      coalesce(est.clearing_blend, est.base_ask)
        * (1 + ((est.demand_ctx->>'demand_mult')::numeric - 1) * (4.0/(coalesce(est.realized_n,0)+4))) AS clearing
    FROM est
  )
  SELECT jsonb_build_object(
    'event_id', p_event_id,
    'section', p_section,
    'dte_days', dte,
    'category', category,
    'dte_bucket', dte_bucket,
    'section_ask_median', section_ask,
    'section_getin', section_getin,
    'section_tickets', section_tix,
    'realized_section_median', round(realized_med::numeric, 2),
    'realized_sample_n', realized_n,
    'sold_to_ask_ratio', ratio,
    'expected_clearing', round(clearing::numeric, 2),
    'lo', round((clearing * coalesce(ratio_p25 / NULLIF(ratio,0), 0.85))::numeric, 2),
    'hi', round((clearing * coalesce(ratio_p75 / NULLIF(ratio,0), 1.15))::numeric, 2),
    'over_ask_spike_prob_pct', round(coalesce(spike_up_rate,0) * 100, 1),
    -- per-signal weighting (operator-directed: each data type has its own weight on price)
    'signals', jsonb_build_object(
      'realized_sale',    jsonb_build_object('value', round(s_realized::numeric,2), 'eff_weight', round(ew_realized::numeric,3)),
      'ask_x_ratio',      jsonb_build_object('value', round(s_ask::numeric,2),      'eff_weight', round(ew_ask::numeric,3)),
      'opponent_section', jsonb_build_object('value', round(s_opp::numeric,2),      'eff_weight', round(ew_opp::numeric,3)),
      'away_adj_prior',   jsonb_build_object('value', round(s_awayadj::numeric,2),  'eff_weight', round(ew_awayadj::numeric,3)),
      'seatdata_market',  jsonb_build_object('value', round(s_sd::numeric,2),       'eff_weight', round(ew_sd::numeric,3)),
      'performer_history',jsonb_build_object('value', round(s_hist::numeric,2),     'eff_weight', round(ew_hist::numeric,3))
    ),
    'road_draw_mult', round(road_mult::numeric, 3),
    'price_heading_24h', (public.predict_event_median_24h(p_event_id) -> 'predicted_median_24h'),
    -- attribution (operator-directed: weight to performer / roster / venue×performer)
    'venue_performer_median', round(venue_performer_median::numeric, 2),
    'road_draw_away_median',  round(road_draw_away_median::numeric, 2),
    'home_performer_median',  round(home_performer_median::numeric, 2),
    -- demand layer (ESPN standings/records/injuries + Reddit/X + rank momentum)
    'demand_mult', demand_mult,
    'demand_mult_applied', round((1 + (demand_mult - 1) * prior_reliance)::numeric, 4),
    'demand_context', demand_ctx,
    'coeff_sample_n', coeff_n,
    'basis', CASE
      WHEN clearing IS NULL THEN 'no_market_data'
      WHEN dte IS NULL OR dte < 0 THEN 'past_or_no_event_date'
      WHEN clearing_blend IS NOT NULL THEN 'weighted_blend(realized+ask+section_priors)×demand'
      ELSE 'fallback_bare_ask' END
  ) INTO v_res
  FROM fin;

  RETURN v_res;
END; $function$;
REVOKE ALL ON FUNCTION public.predict_event_clearing_price(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.predict_event_clearing_price(bigint, text) TO authenticated, service_role;
COMMENT ON FUNCTION public.predict_event_clearing_price(bigint, text) IS
  'Section-grain CLEARING price (not ask) as a WEIGHTED BLEND of section-grain signals '
  '(realized SG+SeatData, ask×ratio, away-team section prior, road-draw-adjusted home '
  'prior), each × its feature_weights weight × a confidence factor, then × demand_mult. '
  'Returns band + per-signal weights + attribution. Read-only, @s4kent.com-gated. A1 mig 20260707200040.';

-- ── 5. Weekly coefficient rebuild (Sun 08:20 UTC, off-peak; slow-moving) ──────
SELECT cron.schedule('price_clearing_coeffs_weekly', '20 8 * * 0', $cron$
DO $body$ BEGIN
  IF NOT public.cron_should_fire('price_clearing_coeffs_weekly') THEN RETURN; END IF;
  PERFORM public.rebuild_price_clearing_coeffs();
END $body$;
$cron$);
INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES ('price_clearing_coeffs_weekly', ARRAY[]::int[], 10080, 10080, 1, true,
        'Clearing-price realized-to-ask coefficient rebuild. Weekly Sun 08:20 UTC, off-peak. A1 mig 20260707200040.')
ON CONFLICT (jobname) DO NOTHING;
