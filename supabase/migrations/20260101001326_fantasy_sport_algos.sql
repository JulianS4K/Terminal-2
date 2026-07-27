-- Fantasy engine (v5): per-sport algorithms.
--
-- Until now every sport used a flat label->points map and a generic snake draft.
-- ESPN fantasy differs per sport in TWO ways this migration encodes:
--   1. SCORING — baseball needs batter-vs-pitcher branching (a pitching line's
--      H/R/BB/HR are *allowed*, not earned), so the ruleset gains a split mode.
--      Basketball/football stay flat but move to ESPN-style weights.
--   2. ROSTER SHAPE — each sport has its own starting lineup of position slots
--      (basketball G/F/C+UTIL, baseball C/1B/…/OF/SP/RP, football QB/RB/WR/TE/
--      FLEX/K). A new fantasy_sport_profiles table holds each sport's slot
--      template + bench + default ruleset, and the auto-draft is now
--      POSITION-AWARE: it fills each team's open slots with the best eligible
--      player, overflowing to the bench.
--
-- Positions come from espn_athletes.position_abbr; the observed vocab per league
-- (2026-07-04) drives the eligibility lists: NBA/WNBA are coarse G/F/C; MLB has
-- C/1B/2B/3B/SS/LF/CF/RF/OF/DH + SP/RP/P; NFL offense is QB/RB/WR/TE/PK.

-- ---- sport profiles ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.fantasy_sport_profiles (
  sport               text PRIMARY KEY,           -- basketball | baseball | football
  scoring_mode        text NOT NULL DEFAULT 'points',
  roster_slots        jsonb NOT NULL,             -- [{slot, elig:[pos|'ANY']}] (starters, in order)
  bench               int  NOT NULL DEFAULT 3,
  default_ruleset_name text NOT NULL,
  updated_at          timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.fantasy_sport_profiles ENABLE ROW LEVEL SECURITY;

INSERT INTO public.fantasy_sport_profiles (sport, roster_slots, bench, default_ruleset_name) VALUES
 ('basketball',
  '[{"slot":"G","elig":["G"]},{"slot":"G","elig":["G"]},{"slot":"F","elig":["F"]},{"slot":"F","elig":["F"]},{"slot":"C","elig":["C"]},{"slot":"UTIL","elig":["ANY"]},{"slot":"UTIL","elig":["ANY"]}]'::jsonb,
  3, 'NBA Standard Points'),
 ('baseball',
  '[{"slot":"C","elig":["C"]},{"slot":"1B","elig":["1B"]},{"slot":"2B","elig":["2B"]},{"slot":"3B","elig":["3B"]},{"slot":"SS","elig":["SS"]},{"slot":"OF","elig":["LF","CF","RF","OF"]},{"slot":"OF","elig":["LF","CF","RF","OF"]},{"slot":"OF","elig":["LF","CF","RF","OF"]},{"slot":"UTIL","elig":["C","1B","2B","3B","SS","LF","CF","RF","OF","DH"]},{"slot":"SP","elig":["SP","P"]},{"slot":"SP","elig":["SP","P"]},{"slot":"RP","elig":["RP","P"]}]'::jsonb,
  4, 'MLB Standard Points'),
 ('football',
  '[{"slot":"QB","elig":["QB"]},{"slot":"RB","elig":["RB","FB"]},{"slot":"RB","elig":["RB","FB"]},{"slot":"WR","elig":["WR"]},{"slot":"WR","elig":["WR"]},{"slot":"TE","elig":["TE"]},{"slot":"FLEX","elig":["RB","WR","TE","FB"]},{"slot":"K","elig":["PK"]}]'::jsonb,
  5, 'NFL Standard Points')
ON CONFLICT (sport) DO UPDATE SET
  roster_slots = EXCLUDED.roster_slots, bench = EXCLUDED.bench,
  default_ruleset_name = EXCLUDED.default_ruleset_name, updated_at = now();

-- ---- ESPN-style scoring rulesets (mapped to our game-log keys) --------------
-- Basketball: STL/BLK premium, TO penalty (FG/FT/3PT are "made-att" strings so
--   the numeric guard skips them — points come from the countable stats).
UPDATE public.fantasy_scoring_rulesets
   SET rules = '{"PTS":1,"REB":1,"AST":2,"STL":4,"BLK":4,"TO":-2}'::jsonb
 WHERE name = 'NBA Standard Points';

-- Baseball: SPLIT mode — a line with IP scores as pitching, else as batting.
UPDATE public.fantasy_scoring_rulesets
   SET rules = '{"__mode__":"split","pitch_when":"IP","bat":{"H":1,"2B":1,"3B":2,"HR":3,"R":2,"RBI":2,"BB":1,"SB":2,"HBP":1,"SO":-1},"pitch":{"IP":3,"K":1,"ER":-2,"H":-1,"BB":-1}}'::jsonb
 WHERE name = 'MLB Standard Points';

-- Football: PPR offense + kicking (defenders get no slot, so aren't drafted).
UPDATE public.fantasy_scoring_rulesets
   SET rules = '{"TD":6,"YDS":0.05,"REC":1,"CAR":0.2,"FG":3,"XP":1,"LST":-2}'::jsonb
 WHERE name = 'NFL Standard Points';

-- ---- scoring engine: split-aware --------------------------------------------
-- A ruleset is either a flat {label:pts} map, or a split map
-- {__mode__:split, pitch_when:<key>, bat:{…}, pitch:{…}} that selects a submap
-- by whether the line contains pitch_when. Backward-compatible with flat maps.
CREATE OR REPLACE FUNCTION public.fantasy_gamelog_points(p_stats jsonb, p_rules jsonb)
 RETURNS numeric LANGUAGE sql IMMUTABLE AS $function$
  WITH m AS (
    SELECT CASE
      WHEN p_rules ? '__mode__' AND (p_rules->>'__mode__') = 'split' THEN
        CASE WHEN p_stats ? coalesce(p_rules->>'pitch_when','IP')
             THEN p_rules->'pitch' ELSE p_rules->'bat' END
      ELSE p_rules END AS map
  )
  SELECT coalesce(sum(
    (m.map->>k)::numeric
    * CASE WHEN (p_stats->>k) ~ '^-?[0-9]+(\.[0-9]+)?$' THEN (p_stats->>k)::numeric ELSE 0 END
  ), 0)::numeric
  FROM m, LATERAL jsonb_object_keys(m.map) k
  WHERE m.map IS NOT NULL AND p_stats ? k;
$function$;
COMMENT ON FUNCTION public.fantasy_gamelog_points IS
  'Fantasy points for one game-log line. Ruleset is a flat {label:pts} map, or a split {__mode__:split,pitch_when,bat,pitch} map (baseball) selected by line type.';

-- A team scores its NON-bench slots (any positional starter slot). (was slot='starter')
CREATE OR REPLACE FUNCTION public.fantasy_team_score(p_team_id bigint, p_start date, p_end date)
 RETURNS TABLE(espn_athlete_id text, athlete_name text, games int, points numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp' AS $function$
  WITH lg AS (
    SELECT l.espn_league, rs.rules
    FROM fantasy_teams t
    JOIN fantasy_leagues l ON l.id = t.league_id
    LEFT JOIN fantasy_scoring_rulesets rs ON rs.id = l.ruleset_id
    WHERE t.id = p_team_id
  ),
  starters AS (
    SELECT r.espn_athlete_id, r.espn_league
    FROM fantasy_rosters r
    WHERE r.fantasy_team_id = p_team_id AND r.slot <> 'bench'
  )
  SELECT g.espn_athlete_id, max(g.athlete_name) AS athlete_name, count(*)::int AS games,
         coalesce(sum(fantasy_gamelog_points(g.stats, (SELECT rules FROM lg))), 0)::numeric AS points
  FROM starters s
  JOIN lg ON true
  JOIN espn_player_gamelog g
    ON g.espn_athlete_id = s.espn_athlete_id AND g.espn_league = lg.espn_league
   AND g.espn_event_id <> 'none' AND g.game_date::date BETWEEN p_start AND p_end
  GROUP BY g.espn_athlete_id
  ORDER BY points DESC;
$function$;

-- ---- league creation: derive roster shape + ruleset from the sport profile --
CREATE OR REPLACE FUNCTION public.fantasy_create_league(
    p_name text, p_league text, p_roster_size int DEFAULT 10, p_starters int DEFAULT 5)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_sport text; v_ruleset bigint; v_id bigint;
        v_starters int := p_starters; v_roster int := p_roster_size; v_prof record;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  v_sport := public._fantasy_sport_for_league(p_league);
  SELECT * INTO v_prof FROM public.fantasy_sport_profiles WHERE sport = v_sport;
  IF FOUND THEN
    v_starters := jsonb_array_length(v_prof.roster_slots);
    v_roster   := v_starters + v_prof.bench;
    SELECT id INTO v_ruleset FROM public.fantasy_scoring_rulesets WHERE name = v_prof.default_ruleset_name LIMIT 1;
  ELSE
    SELECT id INTO v_ruleset FROM public.fantasy_scoring_rulesets
     WHERE sport = v_sport ORDER BY is_default DESC, id LIMIT 1;
  END IF;
  INSERT INTO public.fantasy_leagues (name, espn_league, ruleset_id, roster_size, starters, owner_email)
  VALUES (p_name, upper(p_league), v_ruleset, greatest(1, v_roster), greatest(1, v_starters), v_email)
  RETURNING id INTO v_id;
  RETURN v_id;
END $function$;

-- ---- position-aware snake auto-draft ----------------------------------------
CREATE OR REPLACE FUNCTION public.fantasy_autodraft_league(
    p_league_id bigint, p_window_start date, p_window_end date)
 RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_league text; v_sport text; v_rules jsonb;
        v_roster int; v_starters int; v_bench int; v_nteams int; v_slots jsonb;
        v_ids bigint[]; v_made int := 0; v_total int;
        k int; v_round int; v_ti int; v_team bigint; v_ath text; v_pos text; v_slot text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;

  SELECT l.espn_league, rs.rules, l.roster_size, l.starters
    INTO v_league, v_rules, v_roster, v_starters
  FROM public.fantasy_leagues l LEFT JOIN public.fantasy_scoring_rulesets rs ON rs.id = l.ruleset_id
  WHERE l.id = p_league_id;
  IF v_league IS NULL THEN RETURN 0; END IF;
  v_sport := public._fantasy_sport_for_league(v_league);
  SELECT roster_slots INTO v_slots FROM public.fantasy_sport_profiles WHERE sport = v_sport;
  IF v_slots IS NULL THEN
    v_slots := (SELECT jsonb_agg(jsonb_build_object('slot','UTIL','elig',jsonb_build_array('ANY')))
                FROM generate_series(1, v_starters));  -- fallback: all-UTIL
  END IF;
  SELECT array_agg(id ORDER BY id) INTO v_ids FROM public.fantasy_teams WHERE league_id = p_league_id;
  v_nteams := coalesce(array_length(v_ids,1),0);
  IF v_nteams = 0 THEN RETURN 0; END IF;
  v_bench := greatest(0, v_roster - v_starters);
  v_total := v_nteams * v_roster;

  DROP TABLE IF EXISTS _cand;  DROP TABLE IF EXISTS _slots;  DROP TABLE IF EXISTS _assign;
  CREATE TEMP TABLE _cand (athlete_id text PRIMARY KEY, pos text, pts numeric, taken boolean DEFAULT false) ON COMMIT DROP;
  INSERT INTO _cand(athlete_id, pos, pts)
    SELECT g.espn_athlete_id, max(a.position_abbr),
           sum(public.fantasy_gamelog_points(g.stats, v_rules))
    FROM public.espn_player_gamelog g
    JOIN public.espn_athletes a ON a.espn_athlete_id = g.espn_athlete_id AND a.espn_league = g.espn_league
    WHERE g.espn_league = v_league AND g.espn_event_id <> 'none'
      AND g.game_date::date BETWEEN p_window_start AND p_window_end
      AND NOT EXISTS (SELECT 1 FROM public.fantasy_rosters r JOIN public.fantasy_teams t ON t.id = r.fantasy_team_id
                       WHERE t.league_id = p_league_id AND r.espn_athlete_id = g.espn_athlete_id)
    GROUP BY g.espn_athlete_id;

  CREATE TEMP TABLE _slots (team_id bigint, ord int, slot_code text, elig text[], any_flag boolean, filled boolean DEFAULT false) ON COMMIT DROP;
  INSERT INTO _slots(team_id, ord, slot_code, elig, any_flag)
    SELECT t.id, s.ord, s.code, s.elig, s.any_flag
    FROM unnest(v_ids) AS t(id)
    CROSS JOIN LATERAL (
      SELECT (row_number() OVER ())::int AS ord, (e->>'slot') AS code,
             CASE WHEN e->'elig'->>0 = 'ANY' THEN ARRAY[]::text[]
                  ELSE ARRAY(SELECT jsonb_array_elements_text(e->'elig')) END AS elig,
             (e->'elig'->>0 = 'ANY') AS any_flag
      FROM jsonb_array_elements(v_slots) e
    ) s;

  CREATE TEMP TABLE _assign (team_id bigint, athlete_id text, slot text) ON COMMIT DROP;

  FOR k IN 0 .. (v_total - 1) LOOP
    v_round := k / v_nteams;
    v_ti := CASE WHEN v_round % 2 = 0 THEN k % v_nteams ELSE v_nteams - 1 - (k % v_nteams) END;
    v_team := v_ids[v_ti + 1];
    -- best remaining candidate that fits an OPEN starter slot on this team
    SELECT c.athlete_id, c.pos INTO v_ath, v_pos
    FROM _cand c
    WHERE NOT c.taken AND EXISTS (
      SELECT 1 FROM _slots s WHERE s.team_id = v_team AND NOT s.filled
        AND (s.any_flag OR c.pos = ANY (s.elig)))
    ORDER BY c.pts DESC NULLS LAST LIMIT 1;

    IF v_ath IS NOT NULL THEN
      UPDATE _slots s SET filled = true
      WHERE s.ctid = (SELECT s2.ctid FROM _slots s2
                      WHERE s2.team_id = v_team AND NOT s2.filled
                        AND (s2.any_flag OR v_pos = ANY (s2.elig))
                      ORDER BY s2.ord LIMIT 1)
      RETURNING slot_code INTO v_slot;
      UPDATE _cand SET taken = true WHERE athlete_id = v_ath;
      INSERT INTO _assign VALUES (v_team, v_ath, v_slot);
    ELSIF (SELECT count(*) FROM _assign WHERE team_id = v_team AND slot = 'bench') < v_bench THEN
      SELECT athlete_id INTO v_ath FROM _cand WHERE NOT taken ORDER BY pts DESC NULLS LAST LIMIT 1;
      IF v_ath IS NOT NULL THEN
        UPDATE _cand SET taken = true WHERE athlete_id = v_ath;
        INSERT INTO _assign VALUES (v_team, v_ath, 'bench');
      END IF;
    END IF;
  END LOOP;

  INSERT INTO public.fantasy_rosters (fantasy_team_id, espn_athlete_id, espn_league, slot)
    SELECT team_id, athlete_id, v_league, slot FROM _assign
    ON CONFLICT (fantasy_team_id, espn_athlete_id) DO NOTHING;
  GET DIAGNOSTICS v_made = ROW_COUNT;
  RETURN v_made;
END $function$;
