-- Fantasy scoring rulesets for baseball (MLB) + football (NFL), so leagues in
-- those sports score instead of returning 0 for want of a ruleset. WNBA already
-- works — _fantasy_sport_for_league maps it to 'basketball', reusing the seeded
-- 'NBA Standard Points' ruleset (WNBA game-log stat labels are identical to NBA).
--
-- Rules are stat-LABEL -> points-per-unit maps whose keys MUST match the
-- espn_player_gamelog.stats keys for that sport (fantasy_gamelog_points only
-- counts keys present + numeric in a line).
--
-- MLB is a mixed batting/pitching game log — a player's row is EITHER a batting
-- line (AB…) OR a pitching line (IP…). Verified 2026-07-04 which keys are
-- two-sided so we never reward a pitcher for offense allowed:
--   * batter-only: RBI, 2B, 3B, SB, HBP, SO (batter strikeouts)
--   * pitcher-only: K (pitcher strikeouts), ER, IP
--   * SHARED (excluded): H, R, BB, HR — present in BOTH batting and pitching
--     lines (hits/runs/walks/HR *allowed* on the pitching side), so scoring them
--     would credit pitchers for offense they gave up. RBI stands in for power.

INSERT INTO public.fantasy_scoring_rulesets (name, sport, rules, is_default)
SELECT 'MLB Standard Points', 'baseball',
  '{"RBI":2,"2B":2,"3B":3,"SB":3,"HBP":1,"SO":-0.5,"K":1,"ER":-2,"IP":2}'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM public.fantasy_scoring_rulesets WHERE name = 'MLB Standard Points');

-- NFL: each row is a player's own offensive OR defensive/kicking line, so most
-- keys are single-sided "good". TD/YDS/REC/CAR = offense; SACK/FF/FR/SOLO/AST/PD
-- = defense; FG/XP = kicking; LST (fumbles lost) is the shared negative. INT is
-- deliberately omitted — it's two-sided (thrown by a QB vs caught by a DB).
INSERT INTO public.fantasy_scoring_rulesets (name, sport, rules, is_default)
SELECT 'NFL Standard Points', 'football',
  '{"TD":6,"YDS":0.05,"REC":1,"CAR":0.2,"SACK":2,"FF":3,"FR":3,"SOLO":1,"AST":0.5,"PD":1,"FG":3,"XP":1,"LST":-2}'::jsonb, true
WHERE NOT EXISTS (SELECT 1 FROM public.fantasy_scoring_rulesets WHERE name = 'NFL Standard Points');
