-- ============================================================================
-- Migration 20260510060000 — Dashboard signal-health fixes
--
-- Audit pass on the live dashboard surfaced 3 real bugs + 2 false-positive
-- thresholds. Real bugs are fixed in this migration:
--
--   1. EVO orders had the same false-stale freshness signal as sg_orders —
--      cron polls 200 OK but writes 0 rows when payload is empty. Add
--      evo_orders to v_dashboard_freshness GREATEST() pattern.
--
--   2. README claimed info-tier alerts auto-ack at insert. Audit shows
--      that never shipped — 95 info-tier alerts piling up.
--
--   3. tevo_getin_drop_1h (warn) is a transient signal — the price
--      already moved, no value in keeping it open forever. 88 unacked.
--
--   The compute_alerts_tick() function only INSERTs; it has zero auto-ack
--   logic. New auto_ack_stale_alerts() function handles that on its own
--   30-min cron, with policy:
--     - info-tier (any rule):                 ack after 2h
--     - tevo_getin_drop_1h (warn):            ack after 6h
--     - tevo_inventory_low_48h (warn):        ack when event time passes
--     - critical (espn_status_change etc):    NEVER auto-ack
--
-- (Threshold tweaks for false-positive panel cells live in the UI repo's
-- src/lib/config.ts — weather_forecast bumped warn 60→300, bad 180→480 to
-- fit the queue function's 4-hour throttle; nws_alert_pending gets a
-- per-queue override at warnAt 800 / badAt 1500 since 50 states × every
-- 10 min naturally has ~500-row in-flight depth.)
-- ============================================================================

-- (1) Extend v_dashboard_freshness — evo_orders now uses GREATEST(write, poll)
CREATE OR REPLACE VIEW v_dashboard_freshness AS
SELECT 'tevo_listings'::text AS source_key,
  (SELECT max(captured_at) FROM listings_snapshots) AS latest_at
UNION ALL SELECT 'seatgeek_listings',
  (SELECT max(captured_at) FROM seatgeek_listings_snapshots)
UNION ALL SELECT 'evo_orders',
  GREATEST(
    (SELECT max(pulled_at) FROM evo_orders),
    (SELECT max(p.fired_at) FROM evo_orders_pending p
       JOIN net._http_response h ON h.id = p.request_id
      WHERE h.status_code = 200)
  )
UNION ALL SELECT 'sg_orders',
  GREATEST(
    (SELECT max(pulled_at) FROM seatgeek_orders),
    (SELECT max(p.fired_at) FROM sg_seller_pending p
       JOIN net._http_response h ON h.id = p.request_id
      WHERE p.scope = 'orders' AND h.status_code = 200)
  )
UNION ALL SELECT 'espn_snapshots',
  (SELECT max(captured_at) FROM espn_event_snapshots)
UNION ALL SELECT 'wikipedia',
  (SELECT max(last_refreshed_at) FROM performer_wikipedia)
UNION ALL SELECT 'weather_forecast',
  (SELECT max(fetched_at) FROM weather_observations WHERE is_forecast = true)
UNION ALL SELECT 'reddit',
  (SELECT max(pulled_at) FROM reddit_posts);

-- (2) auto_ack_stale_alerts — TTL-based cleanup of transient open alerts
CREATE OR REPLACE FUNCTION auto_ack_stale_alerts()
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_info int; v_drop int; v_inv int;
BEGIN
  -- Info-tier: signal is in price/data already; ack after 2h.
  UPDATE event_alerts
     SET acknowledged_at = now(), acknowledged_by = 'auto_stale_2h'
   WHERE acknowledged_at IS NULL
     AND severity = 'info'
     AND fired_at < now() - interval '2 hours';
  GET DIAGNOSTICS v_info = ROW_COUNT;

  -- tevo_getin_drop_1h: the drop already happened; ack after 6h.
  UPDATE event_alerts
     SET acknowledged_at = now(), acknowledged_by = 'auto_stale_6h'
   WHERE acknowledged_at IS NULL
     AND rule_key = 'tevo_getin_drop_1h'
     AND fired_at < now() - interval '6 hours';
  GET DIAGNOSTICS v_drop = ROW_COUNT;

  -- tevo_inventory_low_48h: event has passed; signal is moot.
  UPDATE event_alerts ea
     SET acknowledged_at = now(), acknowledged_by = 'auto_event_past'
    FROM events e
   WHERE ea.tevo_event_id = e.id
     AND ea.acknowledged_at IS NULL
     AND ea.rule_key = 'tevo_inventory_low_48h'
     AND e.occurs_at_local::timestamptz < now();
  GET DIAGNOSTICS v_inv = ROW_COUNT;

  -- Critical alerts (espn_status_change etc) are NEVER auto-acked — broker
  -- must see and ack manually.
  RETURN jsonb_build_object(
    'info_acked',         v_info,
    'getin_drop_acked',   v_drop,
    'inv_low_past_acked', v_inv,
    'ran_at',             now()
  );
END $$;

COMMENT ON FUNCTION auto_ack_stale_alerts() IS
  'TTL-based auto-ack for transient open alerts. info=2h, '
  'tevo_getin_drop_1h=6h, tevo_inventory_low_48h=event-past. Critical '
  'never auto-acks. Schedule: cron auto_ack_stale_alerts_30min.';

SELECT cron.schedule(
  'auto_ack_stale_alerts_30min',
  '8-59/30 * * * *',
  $$ SELECT public.auto_ack_stale_alerts(); $$
);
