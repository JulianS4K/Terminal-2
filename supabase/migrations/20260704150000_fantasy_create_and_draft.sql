-- Fantasy engine (v3): league creation + snake auto-draft + one-click demo.
--
-- Completes the write surface so a working league can be spun up end-to-end
-- (create -> add teams -> auto-draft from real athletes -> matchups -> score)
-- without hand-seeding rows. All @s4kent.com-gated SECDEF; the demo builder is
-- what the FANTASY terminal tab calls to populate an empty league table.
--
-- Auto-draft ranks free agents by their trailing-window fantasy points (using
-- the league's ruleset over espn_player_gamelog), then distributes them in
-- snake order across the teams; the first `starters` picks per team are set to
-- 'starter' (the slots that actually score), the rest to 'bench'. Because
-- ranking is computed only over athletes with in-window games, every drafted
-- starter can score.

-- ---- sport mapping + ruleset pick -------------------------------------------
CREATE OR REPLACE FUNCTION public._fantasy_sport_for_league(p_league text)
 RETURNS text LANGUAGE sql IMMUTABLE AS $function$
  SELECT CASE upper(p_league)
    WHEN 'NBA' THEN 'basketball' WHEN 'WNBA' THEN 'basketball'
    WHEN 'MLB' THEN 'baseball'   WHEN 'NFL'  THEN 'football'
    ELSE lower(p_league) END;
$function$;

-- ---- create a league (uses the default ruleset for the sport) ---------------
CREATE OR REPLACE FUNCTION public.fantasy_create_league(
    p_name text, p_league text, p_roster_size int DEFAULT 10, p_starters int DEFAULT 5)
 RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_sport text; v_ruleset bigint; v_id bigint;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  v_sport := public._fantasy_sport_for_league(p_league);
  SELECT id INTO v_ruleset FROM public.fantasy_scoring_rulesets
   WHERE sport = v_sport ORDER BY is_default DESC, id LIMIT 1;
  INSERT INTO public.fantasy_leagues (name, espn_league, ruleset_id, roster_size, starters, owner_email)
  VALUES (p_name, upper(p_league), v_ruleset, greatest(1, p_roster_size), greatest(1, p_starters), v_email)
  RETURNING id INTO v_id;
  RETURN v_id;
END $function$;

-- ---- snake auto-draft over the league's existing teams -----------------------
CREATE OR REPLACE FUNCTION public.fantasy_autodraft_league(
    p_league_id bigint, p_window_start date, p_window_end date)
 RETURNS int LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_league text; v_rules jsonb; v_roster int; v_starters int;
        v_nteams int; v_made int := 0;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;

  SELECT l.espn_league, rs.rules, l.roster_size, l.starters
    INTO v_league, v_rules, v_roster, v_starters
  FROM public.fantasy_leagues l
  LEFT JOIN public.fantasy_scoring_rulesets rs ON rs.id = l.ruleset_id
  WHERE l.id = p_league_id;
  IF v_league IS NULL THEN RETURN 0; END IF;

  SELECT count(*) INTO v_nteams FROM public.fantasy_teams WHERE league_id = p_league_id;
  IF v_nteams = 0 THEN RETURN 0; END IF;

  WITH cand AS (
    SELECT g.espn_athlete_id, g.espn_league,
           sum(public.fantasy_gamelog_points(g.stats, v_rules)) AS pts,
           row_number() OVER (ORDER BY sum(public.fantasy_gamelog_points(g.stats, v_rules)) DESC,
                                       g.espn_athlete_id) AS rn
    FROM public.espn_player_gamelog g
    WHERE g.espn_league = v_league
      AND g.espn_event_id <> 'none'
      AND g.game_date::date BETWEEN p_window_start AND p_window_end
      AND NOT EXISTS (
        SELECT 1 FROM public.fantasy_rosters r JOIN public.fantasy_teams t ON t.id = r.fantasy_team_id
        WHERE t.league_id = p_league_id AND r.espn_athlete_id = g.espn_athlete_id)
    GROUP BY g.espn_athlete_id, g.espn_league
    LIMIT v_nteams * v_roster
  ),
  teams AS (
    SELECT id AS team_id, row_number() OVER (ORDER BY id) - 1 AS idx
    FROM public.fantasy_teams WHERE league_id = p_league_id
  ),
  assigned AS (
    SELECT c.espn_athlete_id, c.espn_league, c.pts,
           CASE WHEN ((c.rn-1) / v_nteams) % 2 = 0
                THEN ((c.rn-1) % v_nteams)
                ELSE v_nteams - 1 - ((c.rn-1) % v_nteams) END AS team_idx
    FROM cand c
  ),
  teamed AS (
    SELECT a.espn_athlete_id, a.espn_league, t.team_id,
           row_number() OVER (PARTITION BY t.team_id ORDER BY a.pts DESC) AS pick_in_team
    FROM assigned a JOIN teams t ON t.idx = a.team_idx
  )
  INSERT INTO public.fantasy_rosters (fantasy_team_id, espn_athlete_id, espn_league, slot)
  SELECT team_id, espn_athlete_id, espn_league,
         CASE WHEN pick_in_team <= v_starters THEN 'starter' ELSE 'bench' END
  FROM teamed
  ON CONFLICT (fantasy_team_id, espn_athlete_id) DO NOTHING;
  GET DIAGNOSTICS v_made = ROW_COUNT;
  RETURN v_made;
END $function$;

-- ---- one-click demo: create + fill + draft + schedule + score ---------------
CREATE OR REPLACE FUNCTION public.fantasy_create_demo_league(
    p_league text DEFAULT 'NBA', p_teams int DEFAULT 6, p_roster int DEFAULT 8, p_starters int DEFAULT 5)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_id bigint; v_end date; v_start date; v_drafted int; v_scored int;
        v_names text[] := ARRAY['Alpha','Bravo','Charlie','Delta','Echo','Foxtrot','Golf','Hotel',
                                'India','Juliet','Kilo','Lima'];
        i int;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  p_teams := greatest(2, least(p_teams, array_length(v_names,1)));

  v_id := public.fantasy_create_league(
    'Demo '||upper(p_league)||' League', p_league, p_roster, p_starters);

  FOR i IN 1..p_teams LOOP
    INSERT INTO public.fantasy_teams (league_id, team_name, manager_email)
    VALUES (v_id, 'Team '||v_names[i], lower(v_names[i])||'@s4kent.com');
  END LOOP;

  -- window: trailing 60 days from the league's most recent game log.
  SELECT max(game_date::date) INTO v_end FROM public.espn_player_gamelog
   WHERE espn_league = upper(p_league) AND espn_event_id <> 'none';
  IF v_end IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no_gamelog_for_league', 'league', upper(p_league)); END IF;
  v_start := v_end - 60;

  v_drafted := public.fantasy_autodraft_league(v_id, v_start, v_end);
  PERFORM public.fantasy_generate_matchups(v_id, 1, v_start, v_end);
  v_scored := public.fantasy_score_week(v_id, 1);

  RETURN jsonb_build_object('ok', true, 'league_id', v_id, 'teams', p_teams,
    'drafted', v_drafted, 'scored_matchups', v_scored,
    'window', jsonb_build_object('start', v_start, 'end', v_end));
END $function$;

COMMENT ON FUNCTION public.fantasy_create_demo_league IS
  'One-click demo league: create + N teams + snake auto-draft (real athletes) + week-1 matchups + score, over the trailing 60d of game logs.';
