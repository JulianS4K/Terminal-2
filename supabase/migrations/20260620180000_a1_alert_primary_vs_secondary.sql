-- Migration 20260620180000 · level:2 · lane:A1 · operator-directed (2026-06-20)
-- Lane: A1 (data plane — alerts engine rule add)
-- Touches W: CREATE OR REPLACE FUNCTION public.compute_alerts_tick()
-- Touches R: public.v_event_primary_vs_secondary (mig 20260620153000) + existing rule views
-- Pre-reqs: alerts engine (mig 20260509390000), v_event_primary_vs_secondary
-- Already applied to prod · via MCP 2026-06-20. NOTE: the compute_alerts_tick_15min cron is
-- currently active=false (pre-existing) — rules are wired in + verified (flip would fire for
-- 54 events, below-face 1) and fire whenever the engine is next enabled/run.
--
-- Adds two rules on top of the existing 7, both off the new primary-vs-secondary spread:
--   primary_flip_opportunity (info) — secondary get-in >= 25% over AXS primary face:
--                                     buy at on-sale / flip into secondary.
--   secondary_below_face     (warn) — secondary trading >= 10% BELOW AXS face:
--                                     dump risk / don't pay up. The "sell" side of the signal.
-- Body is the existing function verbatim + the two new INSERT blocks before RETURN.
-- ============================================================

CREATE OR REPLACE FUNCTION public.compute_alerts_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_fired jsonb := '{}'::jsonb; v_n int;
BEGIN
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'tevo_getin_drop_1h', vw.tevo_event_id, 'warn',
    format('Get-in dropped %s%% in last hour ($%s -> $%s)',
      vw.tevo_getin_d1h_pct, (vw.tevo_getin_now - vw.tevo_getin_d1h)::int, vw.tevo_getin_now::int),
    jsonb_build_object('getin_now', vw.tevo_getin_now, 'd1h', vw.tevo_getin_d1h,
      'd1h_pct', vw.tevo_getin_d1h_pct, 'tevo_now_at', vw.tevo_now_at)
  FROM v_event_velocity_windows vw
  WHERE vw.tevo_getin_d1h_pct IS NOT NULL AND vw.tevo_getin_d1h_pct <= -10 AND vw.tevo_getin_now > 0
    AND _alert_dedupe_ok('tevo_getin_drop_1h', vw.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_getin_drop_1h', v_n);

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'tevo_getin_surge_1h', vw.tevo_event_id, 'info',
    format('Get-in surged %s%% in last hour ($%s -> $%s)',
      vw.tevo_getin_d1h_pct, (vw.tevo_getin_now - vw.tevo_getin_d1h)::int, vw.tevo_getin_now::int),
    jsonb_build_object('getin_now', vw.tevo_getin_now, 'd1h', vw.tevo_getin_d1h,
      'd1h_pct', vw.tevo_getin_d1h_pct, 'tevo_now_at', vw.tevo_now_at)
  FROM v_event_velocity_windows vw
  WHERE vw.tevo_getin_d1h_pct IS NOT NULL AND vw.tevo_getin_d1h_pct >= 10 AND vw.tevo_getin_now > 0
    AND _alert_dedupe_ok('tevo_getin_surge_1h', vw.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_getin_surge_1h', v_n);

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

  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT 'arbitrage_opportunity', ao.tevo_event_id, 'info',
    format('Arb in section %s: SG vs TEvo gap %s%% (TEvo $%s, SG $%s)',
      ao.section, ao.sg_vs_tevo_gap_pct, ao.tevo_retail_median::int, ao.sg_retail_median::int),
    jsonb_build_object('section', ao.section, 'gap_pct', ao.sg_vs_tevo_gap_pct,
      'tevo_median', ao.tevo_retail_median, 'sg_median', ao.sg_retail_median)
  FROM v_arbitrage_opportunities ao
  WHERE abs(ao.sg_vs_tevo_gap_pct) >= 15
    AND _alert_dedupe_ok('arbitrage_opportunity', ao.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('arbitrage_opportunity', v_n);

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
      round(lm.home_winp_24h_ago::numeric, 3),
      round(lm.home_winp_now::numeric, 3),
      round((lm.home_winp_now - lm.home_winp_24h_ago)::numeric, 3)),
    jsonb_build_object('home_winp_now', lm.home_winp_now,
      'home_winp_24h_ago', lm.home_winp_24h_ago,
      'spread_now', lm.spread_now, 'spread_24h_ago', lm.spread_24h_ago)
  FROM v_event_line_movement lm
  WHERE lm.home_winp_24h_ago IS NOT NULL AND lm.home_winp_now IS NOT NULL
    AND abs(lm.home_winp_now - lm.home_winp_24h_ago) >= 0.10
    AND _alert_dedupe_ok('line_movement_24h', lm.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('line_movement_24h', v_n);

  -- NEW: secondary get-in well above AXS primary face -> on-sale flip opportunity.
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

  -- NEW: secondary trading below AXS primary face -> dump risk / don't pay up.
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
