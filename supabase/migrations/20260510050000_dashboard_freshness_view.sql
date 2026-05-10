-- ============================================================================
-- Migration 20260510050000 — v_dashboard_freshness with successful-poll signal
--
-- The proto's freshness queries used `max(timestamp_col)` on the destination
-- table for each source. That measures "last row written", not "last
-- successful poll". For endpoints that can legitimately return empty
-- payloads (SG seller orders /orders endpoint returned meta.total=0
-- repeatedly today), this gave a false-stale signal — dashboard showed
-- "23h" while the cron was firing successfully every 30 min.
--
-- New semantic: GREATEST(data_write, successful_poll_via_pending).
-- For sources backed by a *_pending queue, also consider the latest
-- pending row whose http_status = 200 — that captures "we successfully
-- reached the API" regardless of payload.
--
-- max() over indexed timestamp columns is constant-time (btree last-entry
-- lookup) so no statement_timeout risk under anon. One round-trip query
-- replaces the previous 8 client SELECTs.
-- ============================================================================

CREATE OR REPLACE VIEW v_dashboard_freshness AS
SELECT 'tevo_listings'::text AS source_key,
  (SELECT max(captured_at) FROM listings_snapshots) AS latest_at
UNION ALL SELECT 'seatgeek_listings',
  (SELECT max(captured_at) FROM seatgeek_listings_snapshots)
UNION ALL SELECT 'evo_orders',
  (SELECT max(pulled_at) FROM evo_orders)
UNION ALL SELECT 'sg_orders',
  -- Successful-poll signal: when /orders returns 200 with empty array,
  -- the cron is healthy but no row writes happen. GREATEST() keeps us
  -- honest about which is more recent.
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

GRANT SELECT ON v_dashboard_freshness TO anon;

COMMENT ON VIEW v_dashboard_freshness IS
  'One row per source. For sources whose endpoints can return empty payloads '
  '(currently sg_orders), uses GREATEST(data_write, '
  'successful_poll_via_pending_table_status_200) so the dashboard does not '
  'show a false-stale signal when the cron is healthy and the API just has '
  'no rows to send. Replaces 8 client round-trips with 1 SELECT.';

-- Pattern note: extend GREATEST() to other sources when they go through a
-- *_pending queue and can legitimately return empty payloads. See
-- HANDOFF_INSTRUCTIONS.md for the catalog.
