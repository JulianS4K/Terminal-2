-- ============================================================================
-- Migration 20260708132000 — Conference dimension for NCAA football teams
--
-- Lane:     data plane (A1)
-- Touches:  espn_teams_canonical (add conference, conference_abbr)
--
-- Operator directive (2026-07-08): "for ncaa split further into conferences."
--
-- College football is one ESPN league (slug football/college-football) but ~130
-- FBS + FCS teams span ~11 FBS conferences (SEC, Big Ten, ACC, Big 12, ...) plus
-- FCS conferences. Conference is a strong pricing/draw factor (an SEC home game
-- vs a MAC home game), so we capture it as a first-class dimension rather than
-- splitting espn_league (which must stay 'NCAAF' — the collector fetches by slug,
-- and conference_rank in espn_team_snapshots is already conference-relative).
--
-- Values are populated by the espn-seed-teams edge function ('conferences' mode),
-- which walks the ESPN standings hierarchy (isConference nodes carry the name).
-- Nullable: non-NCAAF rows and any team ESPN doesn't place in a conference stay
-- NULL.
-- ============================================================================

ALTER TABLE espn_teams_canonical ADD COLUMN IF NOT EXISTS conference      text;
ALTER TABLE espn_teams_canonical ADD COLUMN IF NOT EXISTS conference_abbr text;

COMMENT ON COLUMN espn_teams_canonical.conference IS
  'Conference name for NCAAF teams (e.g. "Southeastern Conference"), from the '
  'ESPN standings isConference nodes. NULL for single-table leagues. Refresh via '
  'espn-seed-teams mode=conferences on realignment.';
