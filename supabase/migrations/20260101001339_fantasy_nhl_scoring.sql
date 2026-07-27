-- ============================================================================
-- Migration 20260705180000 — Fantasy: add NHL (hockey) support
--
-- The 2026-07-04 fantasy engine (migs 20260704*) covers basketball (NBA/WNBA),
-- baseball (MLB) and football (NFL) but NOT hockey: there is no hockey ruleset,
-- no hockey sport profile, and `_fantasy_sport_for_league` routes 'NHL' through
-- its ELSE branch to the string 'nhl' (inconsistent with the 'basketball' /
-- 'baseball' / 'football' convention). Net effect today: an NHL fantasy league
-- resolves a NULL ruleset and scores nothing. This migration makes the engine
-- NHL-ready in its own idiom (no new parallel tables):
--   1. `_fantasy_sport_for_league`: 'NHL' -> 'hockey' (was -> 'nhl').
--   2. `fantasy_scoring_rulesets`: seed 'NHL Standard Points' (sport='hockey').
--   3. `fantasy_sport_profiles`: seed the 'hockey' roster template (C/LW/RW/D/G).
--
-- ⚠ PAIRED FOLLOW-UP (REQUIRED for NHL to actually score, needs ESPN access):
--   The NHL game-log/season-stat INGEST is not yet wired. `espn-league-collect`'s
--   STATS_CONFIG (season stats) and the gamelog CATEGORY_MAP cover only
--   baseball/mlb + basketball/{nba,wnba} (+ football/nfl) — there is no
--   "hockey/nhl" entry, so no NHL stat rows exist to score. Adding that entry
--   requires verifying ESPN's common/v3 hockey category param + the exact stat
--   `names` it returns for skaters/goalies against a LIVE endpoint (unreachable
--   from the CI sandbox by egress policy). The `rules` keys below use ESPN's
--   conventional hockey field names but are PROVISIONAL: reconcile them with the
--   actual `espn_player_gamelog.stats` keys when the ingest lands. Until then this
--   migration is inert-but-correct (no hockey rows → no mis-scoring).
--
-- NOT APPLIED TO PROD (Applier action, PROJECT_BIBLE §2.1). Idempotent.
-- ============================================================================

-- (1) Route NHL to the 'hockey' sport (preserves the hardened signature from
--     mig 20260704260000 — LANGUAGE sql IMMUTABLE + locked search_path).
CREATE OR REPLACE FUNCTION public._fantasy_sport_for_league(p_league text)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public','pg_temp' AS $function$
  SELECT CASE upper(p_league)
    WHEN 'NBA' THEN 'basketball' WHEN 'WNBA' THEN 'basketball'
    WHEN 'MLB' THEN 'baseball'   WHEN 'NFL'  THEN 'football'
    WHEN 'NHL' THEN 'hockey'
    ELSE lower(p_league) END;
$function$;

-- (2) NHL scoring ruleset. Standard points-league weights; skater + goalie in one
--     ruleset (a gamelog row is either a skater or a goalie line, like MLB's
--     batting/pitching split). Keys = ESPN conventional hockey `names`
--     (PROVISIONAL — see the follow-up note above).
INSERT INTO public.fantasy_scoring_rulesets (name, sport, rules, is_default)
SELECT 'NHL Standard Points', 'hockey',
  '{"goals":3,"assists":2,"shotsTotal":0.5,"blockedShots":0.5,"powerPlayGoals":0.5,'
  '"shortHandedGoals":1,"gameWinningGoals":0.5,"plusMinus":0.5,'
  '"saves":0.2,"goalsAgainst":-1,"shutouts":3,"wins":2}'::jsonb,
  true
WHERE NOT EXISTS (SELECT 1 FROM public.fantasy_scoring_rulesets WHERE name = 'NHL Standard Points');

-- (3) Hockey roster template: C, LW, RW, 2×D, UTIL (any skater), G + 3 bench.
--     Eligibility from espn_athletes.position_abbr hockey vocab (C/LW/RW/D/G;
--     F tolerated as a wing/util). Mirrors the basketball/baseball/football seeds
--     in mig 20260704210000.
INSERT INTO public.fantasy_sport_profiles (sport, roster_slots, bench, default_ruleset_name)
VALUES (
  'hockey',
  '[{"slot":"C","elig":["C"]},
    {"slot":"LW","elig":["LW","F"]},
    {"slot":"RW","elig":["RW","F"]},
    {"slot":"D","elig":["D"]},
    {"slot":"D","elig":["D"]},
    {"slot":"UTIL","elig":["C","LW","RW","D","F"]},
    {"slot":"G","elig":["G"]}]'::jsonb,
  3,
  'NHL Standard Points'
)
ON CONFLICT (sport) DO NOTHING;
