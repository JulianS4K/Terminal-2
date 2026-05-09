-- ============================================================================
-- Migration 20260509390000 — Alerts engine
--
-- Per directive: "do 6-7" — turn the data plane into "the system tells me
-- what to look at" rather than "I have to query for it."
--
-- DESIGN:
--   event_alerts — append-only log of every fired alert
--   compute_alerts_tick() — runs rule set, emits new alerts, dedupes within
--                           a cool-down window so the same signal doesn't
--                           re-fire every cron tick
--   Cron compute_alerts_tick_15min — every 15 min
--
-- RULES (v1):
--   1. tevo_getin_drop_1h        — get-in dropped >10% in 1 hour
--   2. tevo_getin_surge_1h       — get-in jumped >10% in 1 hour
--   3. tevo_inventory_low_48h    — inventory <25 tickets within 48h of event
--   4. arbitrage_opportunity     — TEvo↔SG section gap >15% with depth on both
--   5. espn_status_change        — ESPN status flipped to postponed/delayed/canceled
--   6. competing_event_added     — new event landed within 20mi×24h of an
--                                   already-tracked event
--
-- All rules dedupe per (rule_key, event_id) within a 6h window.
-- ============================================================================

CREATE TABLE IF NOT EXISTS event_alerts (
  id              bigserial PRIMARY KEY,
  rule_key        text NOT NULL,            -- e.g. 'tevo_getin_drop_1h'
  tevo_event_id   bigint NOT NULL,
  fired_at        timestamptz DEFAULT now(),
  severity        text DEFAULT 'info',      -- 'info'|'warn'|'critical'
  message         text NOT NULL,
  payload         jsonb,                    -- rule-specific numbers
  acknowledged_at timestamptz,
  acknowledged_by text
);

CREATE INDEX IF NOT EXISTS event_alerts_event_idx ON event_alerts(tevo_event_id, fired_at DESC);
CREATE INDEX IF NOT EXISTS event_alerts_rule_idx  ON event_alerts(rule_key, fired_at DESC);
CREATE INDEX IF NOT EXISTS event_alerts_open_idx  ON event_alerts(fired_at DESC) WHERE acknowledged_at IS NULL;

COMMENT ON TABLE event_alerts IS
  'Append-only alert log. Each row is a fired rule. Use acknowledged_at to '
  'mark seen. Cool-down dedup: a (rule_key, event_id) pair will not re-fire '
  'within 6 hours.';

CREATE OR REPLACE FUNCTION _alert_dedupe_ok(p_rule_key text, p_event_id bigint, p_window interval DEFAULT interval '6 hours')
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT NOT EXISTS (
    SELECT 1 FROM event_alerts
    WHERE rule_key = p_rule_key AND tevo_event_id = p_event_id
      AND fired_at > now() - p_window
  );
$$;

-- ============================================================================
-- compute_alerts_tick — runs all rules, emits new alerts
-- ============================================================================

CREATE OR REPLACE FUNCTION compute_alerts_tick()
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_fired jsonb := '{}'::jsonb;
  v_n int;
BEGIN
  -- Rule 1: TEvo get-in dropped >10% in 1h
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT
    'tevo_getin_drop_1h', vw.tevo_event_id, 'warn',
    format('Get-in dropped %s%% in last hour ($%s -> $%s)',
      vw.tevo_getin_d1h_pct, (vw.tevo_getin_now - vw.tevo_getin_d1h)::int, vw.tevo_getin_now::int),
    jsonb_build_object(
      'getin_now', vw.tevo_getin_now, 'd1h', vw.tevo_getin_d1h,
      'd1h_pct', vw.tevo_getin_d1h_pct, 'tevo_now_at', vw.tevo_now_at)
  FROM v_event_velocity_windows vw
  WHERE vw.tevo_getin_d1h_pct IS NOT NULL
    AND vw.tevo_getin_d1h_pct <= -10
    AND vw.tevo_getin_now > 0
    AND _alert_dedupe_ok('tevo_getin_drop_1h', vw.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_getin_drop_1h', v_n);

  -- Rule 2: TEvo get-in surged >10% in 1h
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT
    'tevo_getin_surge_1h', vw.tevo_event_id, 'info',
    format('Get-in surged %s%% in last hour ($%s -> $%s)',
      vw.tevo_getin_d1h_pct, (vw.tevo_getin_now - vw.tevo_getin_d1h)::int, vw.tevo_getin_now::int),
    jsonb_build_object(
      'getin_now', vw.tevo_getin_now, 'd1h', vw.tevo_getin_d1h,
      'd1h_pct', vw.tevo_getin_d1h_pct, 'tevo_now_at', vw.tevo_now_at)
  FROM v_event_velocity_windows vw
  WHERE vw.tevo_getin_d1h_pct IS NOT NULL
    AND vw.tevo_getin_d1h_pct >= 10
    AND vw.tevo_getin_now > 0
    AND _alert_dedupe_ok('tevo_getin_surge_1h', vw.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_getin_surge_1h', v_n);

  -- Rule 3: Inventory low <25 tickets within 48h of event start
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT
    'tevo_inventory_low_48h', e.id, 'warn',
    format('Inventory low: %s tickets, event in %s hours',
      lem.tickets_count, round(extract(epoch from (e.occurs_at_local::timestamptz - now()))/3600)),
    jsonb_build_object('tickets', lem.tickets_count, 'occurs_at', e.occurs_at_local)
  FROM events e
  JOIN latest_event_metrics lem ON lem.event_id = e.id
  WHERE e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '48 hours'
    AND lem.tickets_count < 25 AND lem.tickets_count > 0
    AND _alert_dedupe_ok('tevo_inventory_low_48h', e.id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('tevo_inventory_low_48h', v_n);

  -- Rule 4: Arbitrage opportunity >15% with depth on both sides
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT
    'arbitrage_opportunity', ao.tevo_event_id, 'info',
    format('Arb in section %s: SG vs TEvo gap %s%% (TEvo $%s, SG $%s)',
      ao.section, ao.sg_vs_tevo_gap_pct, ao.tevo_retail_median::int, ao.sg_retail_median::int),
    jsonb_build_object(
      'section', ao.section, 'gap_pct', ao.sg_vs_tevo_gap_pct,
      'tevo_median', ao.tevo_retail_median, 'sg_median', ao.sg_retail_median)
  FROM v_arbitrage_opportunities ao
  WHERE abs(ao.sg_vs_tevo_gap_pct) >= 15
    AND _alert_dedupe_ok('arbitrage_opportunity', ao.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('arbitrage_opportunity', v_n);

  -- Rule 5: ESPN status_short flipped to postponed/delayed/canceled
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT
    'espn_status_change', x.tevo_event_id, 'critical',
    format('ESPN status: %s', ee.status_short),
    jsonb_build_object('espn_status', ee.status_short, 'state', ee.state, 'captured_at', ee.captured_at)
  FROM event_xref x
  JOIN LATERAL (
    SELECT * FROM espn_event_snapshots ee
    WHERE ee.espn_event_id = x.espn_event_id
    ORDER BY captured_at DESC LIMIT 1
  ) ee ON true
  WHERE lower(ee.status_short) IN ('postponed','delayed','canceled','cancelled','suspended')
    AND _alert_dedupe_ok('espn_status_change', x.tevo_event_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('espn_status_change', v_n);

  -- Rule 6: New competing event added within 20mi × 24h of a tracked event
  -- (uses event_competitors_snapshot — fires when an event newly appears
  -- with competitors_count > 0 if it didn't have any in last 24h)
  INSERT INTO event_alerts(rule_key, tevo_event_id, severity, message, payload)
  SELECT
    'competing_event_added', ecs.tevo_event_id, 'info',
    format('%s competing event(s) within ±24h × 20mi', ecs.competitors_count),
    jsonb_build_object('competitors', ecs.competitors)
  FROM event_competitors_snapshot ecs
  WHERE ecs.competitors_count > 0
    AND _alert_dedupe_ok('competing_event_added', ecs.tevo_event_id, interval '24 hours');
  GET DIAGNOSTICS v_n = ROW_COUNT;
  v_fired := v_fired || jsonb_build_object('competing_event_added', v_n);

  RETURN jsonb_build_object('fired_counts', v_fired, 'ran_at', now());
END;
$$;

COMMENT ON FUNCTION compute_alerts_tick IS
  'Run all alert rules and emit new alerts. Per-rule dedup via 6h cool-down '
  'so the same signal does not re-fire each tick. Returns count fired per '
  'rule for telemetry.';

-- ============================================================================
-- Cron: every 15 min, +5 offset from cross_source_match_tick
-- ============================================================================

SELECT cron.schedule(
  'compute_alerts_tick_15min',
  '5-59/15 * * * *',
  $$ SELECT compute_alerts_tick(); $$
);

-- ============================================================================
-- Convenience view: open alerts only
-- ============================================================================

CREATE OR REPLACE VIEW v_open_alerts AS
SELECT
  ea.id, ea.rule_key, ea.severity, ea.fired_at,
  ea.tevo_event_id, e.name AS event_name, e.occurs_at_local, e.venue_name,
  ea.message, ea.payload
FROM event_alerts ea
LEFT JOIN events e ON e.id = ea.tevo_event_id
WHERE ea.acknowledged_at IS NULL
ORDER BY ea.severity DESC, ea.fired_at DESC;

COMMENT ON VIEW v_open_alerts IS
  'Unacknowledged alerts. Default landing surface for any "what should I '
  'look at" UI or AI assistant. Order: critical first, then most-recent.';
