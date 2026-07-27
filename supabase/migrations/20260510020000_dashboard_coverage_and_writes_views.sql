-- ============================================================================
-- Migration 20260510020000 — Dashboard coverage + writes views (anon-readable)
--
-- Phase 1 follow-up: the live data quality dashboard
-- (https://terminal-2-dashboard.web.app) was showing nonsense numbers
-- because it tried to compute coverage/writes from many client-side
-- count round-trips:
--
--   Symptom                          Root cause
--   -------------------------------- -----------------------------------------
--   Coverage TEvo<60m = 4227%        counted ROWS in listings_snapshots, not
--                                    distinct events. With 8.79M rows this
--                                    dwarfs the 570-game denominator.
--   Coverage ESPN xref = 106%        counted ALL espn_event_id rows ever, not
--                                    just upcoming games.
--   Coverage Wiki bio = 0%           SELECT used performer_wikipedia.performer_id
--                                    (col is tevo_performer_id) — query errored
--                                    silently → treated as 0.
--   Coverage Weather = 0%            SELECT used weather_observations.event_id
--                                    (col is tevo_venue_id) — same silent error.
--   Writes tevo_listings = 0         PostgREST exact-count over 8.79M rows
--                                    timed out and returned null.
--   Writes weather_obs = 0           Same timeout on 153k-row weather_observations.
--
-- Fix: server-side aggregation in two views, granted SELECT to anon. Each
-- view returns a single row; the dashboard collapses 12 round-trips → 2.
-- Plus all 5 coverage metrics now count DISTINCT upcoming games and use
-- the correct columns.
-- ============================================================================

-- ============================================================================
-- v_dashboard_coverage — single-row coverage scoreboard
-- ============================================================================

CREATE OR REPLACE VIEW v_dashboard_coverage AS
WITH denom_30d AS (
  SELECT count(*)::numeric AS n FROM events
  WHERE event_type = 'game'
    AND occurs_at_local::timestamptz BETWEEN now() AND now() + interval '30 days'
),
denom_16d AS (
  SELECT count(*)::numeric AS n FROM events
  WHERE event_type = 'game'
    AND occurs_at_local::timestamptz BETWEEN now() AND now() + interval '16 days'
)
SELECT
  -- TEvo <60m: distinct upcoming games with at least one listings refresh in last 60 min
  round(100.0 * (
    SELECT count(*) FROM events e
    WHERE e.event_type='game'
      AND e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '30 days'
      AND EXISTS (SELECT 1 FROM listings_snapshots l
                   WHERE l.event_id = e.id
                     AND l.captured_at > now() - interval '60 minutes')
  )::numeric / NULLIF((SELECT n FROM denom_30d), 0), 1) AS tevo_fresh_pct,

  -- ESPN xref: distinct upcoming games with an ESPN event_xref row
  round(100.0 * (
    SELECT count(*) FROM events e
    WHERE e.event_type='game'
      AND e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '30 days'
      AND EXISTS (SELECT 1 FROM event_xref ex
                   WHERE ex.tevo_event_id = e.id AND ex.espn_event_id IS NOT NULL)
  )::numeric / NULLIF((SELECT n FROM denom_30d), 0), 1) AS espn_xref_pct,

  -- Wiki bio: distinct upcoming games whose primary_performer has a non-rejected wiki entry
  round(100.0 * (
    SELECT count(*) FROM events e
    WHERE e.event_type='game'
      AND e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '30 days'
      AND EXISTS (SELECT 1 FROM performer_wikipedia pw
                   WHERE pw.tevo_performer_id = e.primary_performer_id
                     AND NOT pw.is_rejected)
  )::numeric / NULLIF((SELECT n FROM denom_30d), 0), 1) AS wiki_pct,

  -- Weather (≤16d): venue-scoped match — does the event time fall within ±30min of any forecast row?
  round(100.0 * (
    SELECT count(*) FROM events e
    WHERE e.event_type='game'
      AND e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '16 days'
      AND EXISTS (SELECT 1 FROM weather_observations w
                   WHERE w.tevo_venue_id = e.venue_id
                     AND w.is_forecast
                     AND w.observed_at BETWEEN e.occurs_at_local::timestamptz - interval '30 minutes'
                                            AND e.occurs_at_local::timestamptz + interval '30 minutes')
  )::numeric / NULLIF((SELECT n FROM denom_16d), 0), 1) AS weather_pct,

  -- SG → TEvo: distinct upcoming games with a SeatGeek xref row
  round(100.0 * (
    SELECT count(*) FROM events e
    WHERE e.event_type='game'
      AND e.occurs_at_local::timestamptz BETWEEN now() AND now() + interval '30 days'
      AND EXISTS (SELECT 1 FROM seatgeek_event_xref sx WHERE sx.tevo_event_id = e.id)
  )::numeric / NULLIF((SELECT n FROM denom_30d), 0), 1) AS sg_to_tevo_pct;

COMMENT ON VIEW v_dashboard_coverage IS
  'Single-row coverage scoreboard for the data quality dashboard. All five '
  'metrics computed against upcoming sports games (next 30d for most, 16d for '
  'weather since that is Open-Meteo''s forecast horizon). Replaces the proto''s '
  'broken row-counting approach that produced > 100% values.';

-- ============================================================================
-- v_dashboard_writes_24h — single-row last-24h write counts
-- ============================================================================

CREATE OR REPLACE VIEW v_dashboard_writes_24h AS
SELECT
  (SELECT count(*) FROM listings_snapshots          WHERE captured_at > now() - interval '24 hours') AS tevo_listings,
  (SELECT count(*) FROM seatgeek_listings_snapshots WHERE captured_at > now() - interval '24 hours') AS sg_listings,
  (SELECT count(*) FROM evo_orders                  WHERE pulled_at   > now() - interval '24 hours') AS evo_orders,
  (SELECT count(*) FROM seatgeek_orders             WHERE pulled_at   > now() - interval '24 hours') AS sg_orders,
  (SELECT count(*) FROM espn_event_snapshots        WHERE captured_at > now() - interval '24 hours') AS espn_snapshots,
  (SELECT count(*) FROM reddit_posts                WHERE pulled_at   > now() - interval '24 hours') AS reddit_posts,
  (SELECT count(*) FROM weather_observations        WHERE fetched_at  > now() - interval '24 hours') AS weather_obs;

COMMENT ON VIEW v_dashboard_writes_24h IS
  'Single-row last-24h write counts. Server-side aggregation avoids PostgREST '
  'exact-count timeouts that were returning 0 for 8.79M-row listings_snapshots '
  'and 153k-row weather_observations.';

-- ============================================================================
-- Anon SELECT grants
-- ============================================================================

GRANT SELECT ON v_dashboard_coverage  TO anon;
GRANT SELECT ON v_dashboard_writes_24h TO anon;

-- ============================================================================
-- Also: three RLS-enabled tables had no policy → anon saw empty rows
-- (broke Freshness/ESPN, Coverage/ESPN_xref, Writes/tevo_listings).
-- Open them for SELECT to anon to match the rest of the public tables.
-- (Idempotent — uses CREATE POLICY IF NOT EXISTS via DROP-first pattern.)
-- ============================================================================

DROP POLICY IF EXISTS anon_select_dashboard ON espn_event_snapshots;
DROP POLICY IF EXISTS anon_select_dashboard ON event_xref;
DROP POLICY IF EXISTS anon_select_dashboard ON listings_snapshots;
CREATE POLICY anon_select_dashboard ON espn_event_snapshots FOR SELECT TO anon USING (true);
CREATE POLICY anon_select_dashboard ON event_xref            FOR SELECT TO anon USING (true);
CREATE POLICY anon_select_dashboard ON listings_snapshots    FOR SELECT TO anon USING (true);
