-- ============================================================================
-- Migration 20260510040000 — Materialize v_dashboard_writes_24h
--
-- Live dashboard at terminal-2-dashboard.web.app was showing every "Last 24h
-- writes" value as 0 even though Coverage values rendered correctly. Root
-- cause: the regular view's 7 inline count(*) subqueries timed out under
-- the anon role's 8-second statement_timeout. Walking the index entries on
-- listings_snapshots (8.79M rows, ~847k matching the WHERE clause) alone
-- takes longer than that budget on this tier.
--
-- Direct PostgREST probe with anon key returned:
--   {"code":"57014","message":"canceling statement due to statement timeout"}
--
-- The supabase-js client treats that as a generic error and the dashboard
-- falls back to its mock object — but the proto's "success" branch with
-- the bad data went out unchanged because the function's catch returned
-- mock values that look real.
--
-- Fix: convert to a MATERIALIZED VIEW refreshed every 60s by cron. Anon
-- SELECTs become O(1) — single-row read. Refresh runs as the cron-job
-- owner (not anon) so it has unlimited statement_timeout.
-- ============================================================================

DROP VIEW IF EXISTS v_dashboard_writes_24h CASCADE;

CREATE MATERIALIZED VIEW v_dashboard_writes_24h AS
SELECT
  1::int AS id,                              -- single row; unique idx for CONCURRENTLY refresh
  (SELECT count(*) FROM listings_snapshots          WHERE captured_at > now() - interval '24 hours')::bigint AS tevo_listings,
  (SELECT count(*) FROM seatgeek_listings_snapshots WHERE captured_at > now() - interval '24 hours')::bigint AS sg_listings,
  (SELECT count(*) FROM evo_orders                  WHERE pulled_at   > now() - interval '24 hours')::bigint AS evo_orders,
  (SELECT count(*) FROM seatgeek_orders             WHERE pulled_at   > now() - interval '24 hours')::bigint AS sg_orders,
  (SELECT count(*) FROM espn_event_snapshots        WHERE captured_at > now() - interval '24 hours')::bigint AS espn_snapshots,
  (SELECT count(*) FROM reddit_posts                WHERE pulled_at   > now() - interval '24 hours')::bigint AS reddit_posts,
  (SELECT count(*) FROM weather_observations        WHERE fetched_at  > now() - interval '24 hours')::bigint AS weather_obs,
  now() AS refreshed_at;

CREATE UNIQUE INDEX v_dashboard_writes_24h_pk ON v_dashboard_writes_24h(id);

GRANT SELECT ON v_dashboard_writes_24h TO anon;

COMMENT ON MATERIALIZED VIEW v_dashboard_writes_24h IS
  'Materialized snapshot of last-24h write counts. Refreshed every 60s by '
  'cron job dashboard_writes_24h_refresh_60s. Anon reads are O(1). Was a '
  'regular view but the inline count(*) subqueries timed out under anon''s '
  '8s statement_timeout (caught by terminal-2-dashboard.web.app showing '
  'all-zero writes panel even though Coverage rendered correctly).';

SELECT cron.schedule(
  'dashboard_writes_24h_refresh_60s',
  '* * * * *',
  $$ REFRESH MATERIALIZED VIEW CONCURRENTLY v_dashboard_writes_24h; $$
);

REFRESH MATERIALIZED VIEW v_dashboard_writes_24h;
