-- Migration 20260620200000 · level:2 · lane:A1 · operator-directed (2026-06-20)
-- Lane: A1 (data plane — alerts engine v2: volatility-normalized + hysteresis)
-- Touches W: CREATE TABLE alert_state; CREATE OR REPLACE FUNCTION compute_alerts_tick()
-- Touches R: public.v_event_price_vol (mig 20260620200000), existing rule views
-- Pre-reqs: alerts engine (mig 20260509390000), v_event_price_vol, v_event_primary_vs_secondary
--
-- ============================================================
-- ALERTS v2 — fix the noisy fixed-threshold rules using stock-market alert design.
--
-- WHY: the v1 get-in rules fired on a fixed +/-10%/24h. But the TYPICAL event's get-in
-- already swings ~7%/day (measured), so 10% is barely >1 sigma — the rule spammed routine
-- volatility while MISSING genuinely abnormal moves on stable events (e.g. Shakira +8% =
-- 5.4 sigma; Phillies -4% = -5.2 sigma — both invisible to a 10% rule).
--
-- FIXES (mirroring TradingView / ATR / volatility-stop systems):
--   1. Volatility-normalized thresholds — z-score the 24h move against each event's own
--      daily sigma (its "ATR"), so the bar adapts per event. (v_event_price_vol)
--   2. Hysteresis / deadband — fire only on the edge INTO the alert zone and don't re-fire
--      until the signal has cleared a lower exit band (alert_state). Kills flip-flop.
--   3. Range-breakout alert — get-in breaks its 14d high/low (52-week-high analog).
--   4. Trailing-drawdown alert — get-in fell off its 14d peak by a vol-aware amount; the
--      holder "trailing stop" / sell signal.
-- v1 fixed get-in drop/surge rules are REPLACED by these. Discrete-event rules (inventory,
-- ESPN status, competing event, line movement, primary-flip, below-face) keep their 6h
-- cooldown — they're not price-flapping signals. The v1 arbitrage rule is PARKED (its
-- v_arbitrage_opportunities source runs >55s and was blowing the tick's slot budget — the
-- reason the compute_alerts_tick_15min cron sat disabled).
-- Already applied to prod · via MCP 2026-06-20 (view + alert_state + tick; arb rule dropped).
-- ============================================================

-- Per-event volatility/structure stats (sigma_daily = event's own "ATR"); basis for the
-- z-scored, breakout and trailing-drawdown rules below.
CREATE OR REPLACE VIEW public.v_event_price_vol
WITH (security_invoker = true) AS
WITH up AS (
  SELECT id FROM public.events
  WHERE NULLIF(occurs_at_local,'')::timestamptz BETWEEN now() AND now() + interval '60 days'
),
daily AS (
  SELECT DISTINCT ON (m.event_id, (m.captured_at AT TIME ZONE 'UTC')::date)
    m.event_id, (m.captured_at AT TIME ZONE 'UTC')::date AS d, m.getin_price
  FROM public.event_metrics m JOIN up ON up.id = m.event_id
  WHERE m.captured_at > now() - interval '14 days' AND m.getin_price > 0
  ORDER BY m.event_id, (m.captured_at AT TIME ZONE 'UTC')::date, m.captured_at DESC
),
chg AS (
  SELECT event_id, d, getin_price,
    (getin_price - lag(getin_price) OVER w) / NULLIF(lag(getin_price) OVER w, 0) AS dchg
  FROM daily WINDOW w AS (PARTITION BY event_id ORDER BY d)
),
stats AS (
  SELECT event_id,
    count(*) FILTER (WHERE dchg IS NOT NULL) AS days_n,
    stddev_samp(dchg) AS sigma_daily,
    max(getin_price) AS peak_14d, min(getin_price) AS low_14d,
    max(getin_price) FILTER (WHERE d < (now() AT TIME ZONE 'UTC')::date) AS peak_prior,
    min(getin_price) FILTER (WHERE d < (now() AT TIME ZONE 'UTC')::date) AS low_prior
  FROM chg GROUP BY event_id
)
SELECT
  vw.tevo_event_id, vw.name, vw.venue_name, vw.occurs_at_local,
  vw.tevo_getin_now AS getin_now, vw.tevo_median_now AS median_now, vw.tevo_tix_now AS tix_now,
  vw.tevo_getin_d1h_pct AS getin_d1h_pct, vw.tevo_getin_d24h_pct AS getin_d24h_pct,
  s.days_n, round((s.sigma_daily*100)::numeric,2) AS sigma_daily_pct,
  s.peak_14d, s.low_14d, s.peak_prior, s.low_prior,
  round((vw.tevo_getin_d24h_pct/100.0 / NULLIF(s.sigma_daily,0))::numeric, 2) AS move_z_24h,
  greatest(round(((s.peak_14d - vw.tevo_getin_now)/NULLIF(s.peak_14d,0)*100)::numeric,1), 0) AS drawdown_from_peak_pct,
  (s.days_n >= 7 AND vw.tevo_getin_now > s.peak_prior) AS breakout_up,
  (s.days_n >= 7 AND vw.tevo_getin_now < s.low_prior)  AS breakout_down
FROM stats s
JOIN public.v_event_velocity_windows vw ON vw.tevo_event_id = s.event_id
WHERE vw.tevo_getin_now > 0;
COMMENT ON VIEW public.v_event_price_vol IS
  'Per-event (upcoming 60d) volatility stats: sigma_daily (own ATR), 14d range, trailing '
  'drawdown, z-scored 24h move. Basis for volatility-normalized alerts. A1 · mig 20260620200000.';
GRANT SELECT ON public.v_event_price_vol TO authenticated, service_role;

-- Hysteresis state: one row per (rule, event); is_active gates edge-triggering.
CREATE TABLE IF NOT EXISTS public.alert_state (
  rule_key      text   NOT NULL,
  tevo_event_id bigint NOT NULL,
  is_active     boolean NOT NULL DEFAULT false,
  last_fired_at timestamptz,
  updated_at    timestamptz DEFAULT now(),
  PRIMARY KEY (rule_key, tevo_event_id)
);
COMMENT ON TABLE public.alert_state IS
  'Hysteresis state for volatility alerts: fire on inactive->active edge, clear at the exit '
  'band. Stops threshold flip-flop. A1 · mig 20260620200000.';
ALTER TABLE public.alert_state ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.compute_alerts_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_fired jsonb := '{}'::jsonb; v_n int;
BEGIN
  -- Materialize the volatility stats once per tick (the heavy read), then reuse.
  CREATE TEMP TABLE _vol ON COMMIT DROP AS SELECT * FROM public.v_event_price_vol;

  -- Per-event signal staging for the hysteresis (volatility) rules: fire/clear + payload.
  CREATE TEMP TABLE _sig ON COMMIT DROP AS
    SELECT 'getin_zscore_move'::text AS rule_key, v.tevo_event_id,
      (v.days_n>=7 AND v.sigma_daily_pct>0 AND abs(v.move_z_24h)>=2.5 AND abs(v.getin_d24h_pct)>=4) AS fire,
      (abs(v.move_z_24h) < 1.0) AS clr,
      (CASE WHEN abs(v.move_z_24h)>=4 THEN 'critical' WHEN abs(v.move_z_24h)>=3 THEN 'warn' ELSE 'info' END)::text AS severity,
      format('Get-in %s %s%% in 24h = %s sigma move (typical %s%%/day) -> $%s',
        CASE WHEN v.getin_d24h_pct>=0 THEN 'UP' ELSE 'DOWN' END,
        round(v.getin_d24h_pct,1), v.move_z_24h, v.sigma_daily_pct, v.getin_now::int) AS message,
      jsonb_build_object('move_pct',v.getin_d24h_pct,'z',v.move_z_24h,'sigma_pct',v.sigma_daily_pct,'getin',v.getin_now) AS payload
    FROM _vol v
    UNION ALL
    SELECT 'getin_breakout', v.tevo_event_id,
      (v.days_n>=7 AND (v.breakout_up OR v.breakout_down)),
      (NOT v.breakout_up AND NOT v.breakout_down),
      'info',
      format('Get-in broke 14d %s: $%s (prior %s $%s)',
        CASE WHEN v.breakout_up THEN 'HIGH' ELSE 'LOW' END, v.getin_now::int,
        CASE WHEN v.breakout_up THEN 'high' ELSE 'low' END,
        CASE WHEN v.breakout_up THEN v.peak_prior ELSE v.low_prior END::int),
      jsonb_build_object('getin',v.getin_now,'peak_prior',v.peak_prior,'low_prior',v.low_prior,
        'dir',CASE WHEN v.breakout_up THEN 'up' ELSE 'down' END)
    FROM _vol v
    UNION ALL
    SELECT 'getin_trailing_drawdown', v.tevo_event_id,
      (v.days_n>=7 AND v.drawdown_from_peak_pct >= greatest(12, 2.5*v.sigma_daily_pct)),
      (v.drawdown_from_peak_pct < greatest(8, 1.5*v.sigma_daily_pct)),
      'warn',
      format('Get-in down %s%% from 14d peak $%s -> $%s (trailing stop)',
        v.drawdown_from_peak_pct, v.peak_14d::int, v.getin_now::int),
      jsonb_build_object('drawdown_pct',v.drawdown_from_peak_pct,'peak',v.peak_14d,'getin',v.getin_now)
    FROM _vol v;

  -- FIRE: edge into the alert zone (fire AND not already active), respecting a 6h re-arm floor.
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT s.rule_key, s.tevo_event_id, s.severity, s.message, s.payload
  FROM _sig s
  LEFT JOIN public.alert_state st ON st.rule_key=s.rule_key AND st.tevo_event_id=s.tevo_event_id
  WHERE s.fire AND coalesce(st.is_active,false)=false
    AND _alert_dedupe_ok(s.rule_key, s.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('volatility_rules_fired', v_n);

  -- Mark newly-fired (and any new) events active.
  INSERT INTO public.alert_state(rule_key, tevo_event_id, is_active, last_fired_at, updated_at)
  SELECT s.rule_key, s.tevo_event_id, true, now(), now()
  FROM _sig s
  LEFT JOIN public.alert_state st ON st.rule_key=s.rule_key AND st.tevo_event_id=s.tevo_event_id
  WHERE s.fire AND coalesce(st.is_active,false)=false
  ON CONFLICT (rule_key, tevo_event_id) DO UPDATE SET is_active=true, last_fired_at=now(), updated_at=now();

  -- CLEAR: active events whose signal fell back through the exit band (deadband reset).
  UPDATE public.alert_state st SET is_active=false, updated_at=now()
  FROM _sig s
  WHERE st.rule_key=s.rule_key AND st.tevo_event_id=s.tevo_event_id AND st.is_active AND s.clr;

  -- ===== Discrete-event rules (unchanged; 6h cooldown is right for non-flapping signals) =====
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'tevo_inventory_low_48h', e.id, 'warn',
    format('Inventory low: %s tickets, event in %s hours',
      lem.tickets_count, round(extract(epoch from (e.occurs_at_local::timestamptz - now()))/3600)),
    jsonb_build_object('tickets', lem.tickets_count, 'occurs_at', e.occurs_at_local)
  FROM events e JOIN latest_event_metrics lem ON lem.event_id = e.id
  WHERE e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '48 hours'
    AND lem.tickets_count < 25 AND lem.tickets_count > 0
    AND _alert_dedupe_ok('tevo_inventory_low_48h', e.id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_inventory_low_48h', v_n);

  -- NOTE: the v1 'arbitrage_opportunity' rule is intentionally PARKED here. Its source view
  -- v_arbitrage_opportunities (section-level TEvo<->SG cross join over firehoses) runs >55s
  -- on its own and was blowing the whole tick's slot budget — the reason the cron sat
  -- disabled. Every other rule sums to ~15-20s. Re-add this rule only after that view is
  -- optimized or precomputed into a small table by its own slower cron. (A1 2026-06-20)

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'espn_status_change', x.tevo_event_id, 'critical',
    format('ESPN status: %s', ee.status_short),
    jsonb_build_object('espn_status', ee.status_short, 'state', ee.state, 'captured_at', ee.captured_at)
  FROM event_xref x
  JOIN LATERAL (SELECT * FROM espn_event_snapshots ee WHERE ee.espn_event_id = x.espn_event_id ORDER BY captured_at DESC LIMIT 1) ee ON true
  WHERE lower(ee.status_short) IN ('postponed','delayed','canceled','cancelled','suspended')
    AND _alert_dedupe_ok('espn_status_change', x.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('espn_status_change', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'competing_event_added', ecs.tevo_event_id, 'info',
    format('%s competing event(s) within +/-24h x 20mi', ecs.competitors_count),
    jsonb_build_object('competitors', ecs.competitors)
  FROM event_competitors_snapshot ecs
  WHERE ecs.competitors_count > 0
    AND _alert_dedupe_ok('competing_event_added', ecs.tevo_event_id, interval '24 hours');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('competing_event_added', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'line_movement_24h', lm.tevo_event_id, 'info',
    format('Line moved: home win-prob %s -> %s (%s pts)',
      round(lm.home_winp_24h_ago::numeric, 3), round(lm.home_winp_now::numeric, 3),
      round((lm.home_winp_now - lm.home_winp_24h_ago)::numeric, 3)),
    jsonb_build_object('home_winp_now', lm.home_winp_now, 'home_winp_24h_ago', lm.home_winp_24h_ago,
      'spread_now', lm.spread_now, 'spread_24h_ago', lm.spread_24h_ago)
  FROM v_event_line_movement lm
  WHERE lm.home_winp_24h_ago IS NOT NULL AND lm.home_winp_now IS NOT NULL
    AND abs(lm.home_winp_now - lm.home_winp_24h_ago) >= 0.10
    AND _alert_dedupe_ok('line_movement_24h', lm.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('line_movement_24h', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'primary_flip_opportunity', pv.tevo_event_id, 'info',
    format('Flip vs face: secondary get-in $%s is %s%% over AXS face $%s (%s)',
      pv.best_secondary_getin::int, pv.flip_margin_pct, pv.axs_primary_getin::int, pv.event_name),
    jsonb_build_object('axs_face', pv.axs_primary_getin, 'secondary_getin', pv.best_secondary_getin,
      'flip_margin', pv.flip_margin, 'flip_margin_pct', pv.flip_margin_pct)
  FROM v_event_primary_vs_secondary pv
  WHERE pv.signal = 'secondary_premium' AND pv.flip_margin_pct >= 25
    AND _alert_dedupe_ok('primary_flip_opportunity', pv.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('primary_flip_opportunity', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'secondary_below_face', pv.tevo_event_id, 'warn',
    format('Secondary $%s is %s%% BELOW AXS face $%s (%s) - dump risk',
      pv.best_secondary_getin::int, pv.flip_margin_pct, pv.axs_primary_getin::int, pv.event_name),
    jsonb_build_object('axs_face', pv.axs_primary_getin, 'secondary_getin', pv.best_secondary_getin,
      'flip_margin', pv.flip_margin, 'flip_margin_pct', pv.flip_margin_pct)
  FROM v_event_primary_vs_secondary pv
  WHERE pv.signal = 'below_face' AND pv.flip_margin_pct <= -10
    AND _alert_dedupe_ok('secondary_below_face', pv.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('secondary_below_face', v_n);

  RETURN jsonb_build_object('fired_counts', v_fired, 'ran_at', now());
END; $function$;
