-- Migration 20260608210000 · lane:D0 (author) → A1 (apply) · writes:performer_home_venues (INSERT only), performer_metrics_daily (via refresh) · reads:events,v_canonical_performer,event_listing_snapshot_daily · pre:performer_metrics_daily + refresh_entity_metrics_daily must exist (mig 20260605151100) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (prod DML on performer_home_venues + repopulates the daily metrics table)
--
-- D0 — BACKFILL home venues so HOME/AWAY metrics populate for sports performers.
--
-- Problem: performer_metrics_daily emits 'home'/'away' splits only for sports
-- performers (what_event_type='game'), and the split is decided by
--   event.venue_id = ANY(v_canonical_performer.home_venue_ids).
-- home_venue_ids resolves (live, via the entity_performer_map VIEW) from the
-- performer_home_venues base table. That table was missing ~half of sports
-- performers (125 of 257 had NULL home_venue_ids), so EVERY one of their games
-- fell through to the 'away' branch — the 'home' split was systematically
-- under-populated (252 performers had away rows, only 118 had home rows).
--
-- Fix (this migration): derive the home venue for the missing performers from
-- their own event→venue distribution (the modal / most-frequent venue) and seed
-- performer_home_venues. A real home/away team plays the bulk of its games at one
-- building and scatters its away games across many others, so the modal venue is
-- a strong home signal. CONSERVATIVE guards keep out leagues / tours / one-off
-- championships (e.g. "NFL", "Monster Jam", WWE, UFC) that have no real home:
--   * modal venue share >= 50% of the performer's events
--   * >= 4 events total (enough signal)
--   * >= 4 DISTINCT venues (a touring act / single-site residency clusters at 1-3;
--       a true team has many away venues — this is what filters non-teams)
-- This selects 10 clean franchises (NWSL/WNBA/MLS) as of 2026-06-08. Idempotent:
-- ON CONFLICT (performer_id) DO NOTHING — never overwrites a curated home venue.
-- source='tevo_modal' tags the provenance (and makes a future revert a one-liner).
--
-- Then repopulate the stored daily metrics so the home/away rows actually appear,
-- by re-running refresh_entity_metrics_daily across every stored snapshot_date.

-- ============================================================================
-- 1. Seed missing home venues (modal-venue derivation, conservative guards)
-- ============================================================================
WITH missing AS (
  SELECT cp.tevo_performer_id AS pid,
         cp.tevo_performer_name AS pname,
         coalesce(cp.espn_league, cp.category_name, cp.parent_category_name, 'OTHER') AS league
  FROM public.v_canonical_performer cp
  WHERE cp.what_event_type = 'game'
    AND cp.home_venue_ids IS NULL
),
ev AS (
  SELECT m.pid, m.pname, m.league, e.venue_id, e.venue_name, e.venue_location
  FROM missing m
  JOIN public.events e ON m.pid = ANY(e.performer_ids)
  WHERE e.venue_id IS NOT NULL
),
ranked AS (
  SELECT pid, pname, league, venue_id, venue_name,
         max(venue_location)                               AS venue_location,
         count(*)                                          AS ev_at_venue,
         sum(count(*)) OVER (PARTITION BY pid)             AS ev_total,
         count(*)      OVER (PARTITION BY pid)             AS distinct_venues,
         row_number()  OVER (PARTITION BY pid
                             ORDER BY count(*) DESC, venue_id) AS rn
  FROM ev
  GROUP BY pid, pname, league, venue_id, venue_name
),
picked AS (
  SELECT pid, pname, league, venue_id, venue_name, venue_location
  FROM ranked
  WHERE rn = 1
    AND ev_at_venue::numeric / ev_total >= 0.5   -- modal share >= 50%
    AND ev_total >= 4                            -- enough signal
    AND distinct_venues >= 4                     -- real team (not a tour/residency)
)
INSERT INTO public.performer_home_venues
  (performer_id, performer_name, venue_id, venue_name, venue_location, league, source)
SELECT p.pid, p.pname, p.venue_id, p.venue_name, p.venue_location, p.league, 'tevo_modal'
FROM picked p
ON CONFLICT (performer_id) DO NOTHING;

-- ============================================================================
-- 2. Repopulate the daily performer metrics so the home/away splits appear
--    (idempotent delete+insert per date inside the refresh fn)
-- ============================================================================
DO $$
DECLARE v_d date;
BEGIN
  FOR v_d IN SELECT DISTINCT snapshot_date FROM public.event_listing_snapshot_daily ORDER BY 1 LOOP
    PERFORM public.refresh_entity_metrics_daily(v_d);
  END LOOP;
END $$;
