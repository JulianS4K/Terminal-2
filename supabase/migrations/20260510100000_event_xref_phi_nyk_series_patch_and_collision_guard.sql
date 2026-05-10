-- ============================================================================
-- Migration 20260510100000 — PHI/NYK series xref patch + collision guard view
--
-- Coworker's bundle pull on Game 5 (PHI @ NYK Mon 5/11) surfaced that the
-- TEvo↔ESPN matcher was returning wrong data: Game 5 was xref'd to ESPN
-- event 401871162, which is actually Game 4 (Sat 5/10 PHI). Every odds /
-- injuries / score lookup for Game 5 was returning Game 4's data.
--
-- ESPN scoreboard probe confirmed all 7 games exist with sequential ids:
--   401871159 = Game 1 (5/4 MSG)   ← MISSED by matcher (no xref)
--   401871160 = Game 2 (5/6 MSG)   ← MISSED by matcher (no xref)
--   401871161 = Game 3 (5/8 PHI)   ← correctly xref'd
--   401871162 = Game 4 (5/10 PHI)  ← correctly xref'd
--   401871163 = Game 5 (5/11 MSG)  ← MIS-MATCHED to Game 4's id
--   401871164 = Game 6 (5/13 PHI)  ← correctly xref'd
--   401871165 = Game 7 (5/16 MSG)  ← correctly xref'd
--
-- This migration fixes the data + installs a guard view, but does NOT fix
-- the source bug (the matcher lives in an edge function — out of scope for
-- a SQL migration).
--
-- ----------------------------------------------------------------------------
-- WIDER FINDING — guard view immediately surfaced 60 team-game collisions
-- ----------------------------------------------------------------------------
-- The bug isn't isolated to playoff series. Spot-check shows two patterns:
--   * Same teams, different dates (series-pair collapse)
--     e.g. Yankees @ Brewers 5/8 + 5/9 → both xref'd to one ESPN id
--   * Different teams entirely sharing one ESPN id (worse)
--     e.g. Tigers @ Mets + Yankees @ Mets → same ESPN id
--
-- The second pattern suggests the matcher is picking first-available ESPN
-- event without validating team identity. Phase-2 follow-up: rewrite the
-- matcher in plpgsql (TEvo and ESPN both expose home/away team strings;
-- a strict "(home_norm, away_norm, occurs_at_local::date)" key would
-- eliminate both patterns).
-- ============================================================================

-- (1) Fix Game 5 (collision repair: 401871162 → 401871163)
UPDATE event_xref
   SET espn_event_id = '401871163',
       match_method = 'manual_collision_repair',
       meta = COALESCE(meta, '{}'::jsonb) || jsonb_build_object(
         'previous_espn_event_id', '401871162',
         'reason', 'matcher returned Game 4 id for Game 5; corrected via ESPN scoreboard probe',
         'repaired_at', now()::text
       ),
       matched_at = now()
 WHERE tevo_event_id = 3345925
   AND espn_event_id = '401871162';

-- (2) Backfill Games 1 + 2 (matcher missed them entirely)
INSERT INTO event_xref(tevo_event_id, espn_event_id, espn_league, espn_slug, match_method, meta)
VALUES
  (3345922, '401871159', 'NBA', 'basketball/nba', 'manual_backfill',
   jsonb_build_object('reason', 'Game 1 missed by team_date matcher; ESPN scoreboard probe',
                      'series', 'PHI @ NYK Round 2', 'game_no', 1)),
  (3345924, '401871160', 'NBA', 'basketball/nba', 'manual_backfill',
   jsonb_build_object('reason', 'Game 2 missed by team_date matcher; ESPN scoreboard probe',
                      'series', 'PHI @ NYK Round 2', 'game_no', 2))
ON CONFLICT DO NOTHING;

-- (3) Collision guard view — flags any ESPN event_id xref'd to multiple TEvo
--     team-game events. Excludes tournament_token_overlap matches because
--     multi-session-per-tournament is by design (one F1 race weekend has
--     Friday/Saturday/Sunday/3-day-pass/2-day-pass session events all
--     legitimately mapping to the single ESPN tournament event).
CREATE OR REPLACE VIEW v_event_xref_collisions AS
SELECT
  ex.espn_event_id,
  ex.espn_league,
  count(*) AS tevo_event_count,
  array_agg(ex.tevo_event_id ORDER BY ex.matched_at DESC) AS tevo_event_ids,
  array_agg(e.name ORDER BY ex.matched_at DESC) AS tevo_event_names,
  array_agg(e.occurs_at_local::text ORDER BY ex.matched_at DESC) AS tevo_event_times,
  max(ex.matched_at) AS most_recent_match
FROM event_xref ex
JOIN events e ON e.id = ex.tevo_event_id
WHERE ex.match_method NOT IN ('tournament_token_overlap')
GROUP BY ex.espn_event_id, ex.espn_league
HAVING count(*) > 1;

GRANT SELECT ON v_event_xref_collisions TO anon;

COMMENT ON VIEW v_event_xref_collisions IS
  'Flags ESPN event_ids xref''d to multiple TEvo team-game events (real bugs). '
  'Tournament matches excluded since multi-session-per-tournament is by design. '
  'On launch: 60 collisions surfaced — phase-2 work to rewrite matcher in '
  'plpgsql with strict (home_norm, away_norm, occurs_at_local::date) key.';
