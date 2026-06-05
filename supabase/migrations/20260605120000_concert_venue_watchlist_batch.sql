-- ============================================================================
-- MIG 20260605120000 — Concert venue watchlist batch + watch_sources backfill
--
-- Operator directive 2026-06-05: begin tracking ~130 concert/show events
-- at normal collector_cadence using all sources (EVO, SG, TD).
--
-- Strategy:
--   1. Add concert-specific venues (not home to any sports team and thus not
--      already in the watchlist) to watchlist (kind='venue').  Once a venue
--      is in the watchlist, collect-listings discovery will find every TEvo
--      event at that venue and insert it into events + watch_sources
--      automatically on the next sweep.
--
--   2. Immediately backfill watch_sources for events already present in the
--      events table at these venues so evo_listings_poll_tick picks them up
--      on the very next 2-min tick (no waiting for the next collect sweep).
--
-- Venues already in the watchlist (home to sports teams – events at these
-- venues are already tracked via the sports-team performer entries):
--   Allegiant, Ball, Citi Field, Daikin, Enterprise, Frost Bank,
--   Gainbridge, Intuit, Kauffman, Moda Center, Nissan Stadium Nashville,
--   SAP Center, Smoothie King, Toyota Center TX, AT&T Stadium, Busch,
--   Chase Field, Climate Pledge, Globe Life, Huntington Bank, Lincoln Fin,
--   Oracle Park, Petco Park, T-Mobile Arena, T-Mobile Park, Truist Park,
--   Michelob ULTRA Arena, Rocket Arena, Target Center.
--
-- Venues added here (concert-only / missing coverage):
--   Red Rocks Amphitheatre   1290
--   Forest Hills Stadium     520   ← covers Wilco, CAAMP, Zeds Dead, Black
--                                    Crowes, Juneteenth, Jon Batiste, Dermot
--                                    Kennedy on next collect sweep
--   Ryman Auditorium         1366  ← covers Nate Smith (currently SG
--                                    TRACK_BLINDSPOT / no TEvo match yet)
--   MGM Grand Garden Arena   996
--   Pechanga Arena SD        8000
--   T-Mobile Center KC       4603
--   Allstate Arena           33
--   BOK Center               5118
--   CFG Bank Arena           103
--   Bert Ogden Arena         33737
--   Sames Auto Arena         2407
--   Save Mart Center         2839
--   Maine Savings Amphitheater 7425
--   Moody Center ATX         38485
--   Carlson Center           228
--
-- Pending manual TEvo lookup (no event_id found in DB, venue not yet
-- resolved):
--   • VyStar Veterans Memorial Arena, Jacksonville FL
--     (Benson Boone 8/25)
--   • Pratt & Whitney Stadium, East Hartford CT
--     (Post Malone 6/22)
-- ============================================================================

-- ============================================================
-- (1) Add concert-specific venues to watchlist
-- ============================================================
INSERT INTO watchlist (kind, ext_id, label) VALUES
  ('venue', 1290, 'Red Rocks Amphitheatre'),
  ('venue',  520, 'Forest Hills Stadium'),
  ('venue', 1366, 'Ryman Auditorium'),
  ('venue',  996, 'MGM Grand Garden Arena'),
  ('venue', 8000, 'Pechanga Arena - San Diego'),
  ('venue', 4603, 'T-Mobile Center'),
  ('venue',   33, 'Allstate Arena'),
  ('venue', 5118, 'BOK Center'),
  ('venue',  103, 'CFG Bank Arena'),
  ('venue',33737, 'Bert Ogden Arena'),
  ('venue', 2407, 'Sames Auto Arena'),
  ('venue', 2839, 'Save Mart Center'),
  ('venue', 7425, 'Maine Savings Amphitheater'),
  ('venue',38485, 'Moody Center ATX'),
  ('venue',  228, 'Carlson Center')
ON CONFLICT (kind, ext_id) DO NOTHING;

-- ============================================================
-- (2) Immediately backfill watch_sources for events already in
--     the DB at newly-watchlisted venues (future events only).
--     This makes them eligible for evo_listings_poll_tick on
--     the very next 2-min cron tick, without waiting for the
--     collect-listings discovery sweep.
-- ============================================================
INSERT INTO watch_sources (event_id, source_type, source_id, source_label, first_seen)
SELECT
  e.id,
  'venue'     AS source_type,
  e.venue_id  AS source_id,
  e.venue_name AS source_label,
  now()        AS first_seen
FROM events e
WHERE e.venue_id IN (
  1290,  -- Red Rocks
   520,  -- Forest Hills
  1366,  -- Ryman
   996,  -- MGM Grand
  8000,  -- Pechanga
  4603,  -- T-Mobile Center KC
    33,  -- Allstate
  5118,  -- BOK Center
   103,  -- CFG Bank
 33737,  -- Bert Ogden
  2407,  -- Sames Auto
  2839,  -- Save Mart
  7425,  -- Maine Savings
 38485,  -- Moody Center
   228   -- Carlson Center
)
AND e.occurs_at_local IS NOT NULL
AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
AND COALESCE(e.state, 'shown') <> 'ignored'
ON CONFLICT (event_id, source_type, source_id) DO NOTHING;

-- ============================================================
-- (3) Direct evo_listings_poll_state seeding for the
--     newly-added watch_sources rows.
--
--     evo_listings_poll_tick stamps the state on first fire.
--     Inserting NULL last_polled_listings_at here causes the
--     tick to treat these as highest-priority (NULLS FIRST
--     ordering), so they'll be polled immediately.
-- ============================================================
INSERT INTO evo_listings_poll_state (event_id, last_polled_listings_at, listings_polls_today, budget_day)
SELECT
  e.id,
  NULL::timestamptz,   -- NULL → polled first on next tick
  0,
  current_date
FROM events e
WHERE e.venue_id IN (
  1290, 520, 1366, 996, 8000, 4603, 33, 5118, 103, 33737, 2407, 2839, 7425, 38485, 228
)
AND e.occurs_at_local IS NOT NULL
AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
AND COALESCE(e.state, 'shown') <> 'ignored'
ON CONFLICT (event_id) DO NOTHING;   -- don't reset state for already-tracked events

COMMENT ON TABLE watchlist IS
  'User watchlist: sports performers (all 6 leagues auto-maintained by '
  'ensure_major_league_watchlist_coverage) + concert/event venues added '
  'manually (Red Rocks, Forest Hills, Ryman, MGM Grand, Pechanga, '
  'T-Mobile Center KC, Allstate, BOK Center, CFG Bank, Bert Ogden, '
  'Sames Auto, Save Mart, Maine Savings, Moody Center ATX, Carlson '
  'Center — added 2026-06-05 mig 120000).';
