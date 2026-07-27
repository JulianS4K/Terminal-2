-- Fix get_fantasy_league_detail's default scoring window so the roster
-- "window_points" line up with the standings.
--
-- Problem: the v2 detail RPC defaulted its window to now()-30d. But a league's
-- matchups are scored over whatever window they were generated for (for the NBA
-- demo, the trailing 60d of game logs, ending mid-June). In July that default
-- window is empty for NBA, so every team's window_points showed ~0 even though
-- the standings (computed from the scored matchups) showed real W-L. The two
-- panels disagreed.
--
-- Fix: when the caller passes no explicit dates, derive the window from the
-- league's most recent matchup period (period_start..period_end). Fall back to
-- the trailing 30d of the league's own game logs, then to now()-30d. Explicit
-- p_start/p_end still override. Same return shape.

CREATE OR REPLACE FUNCTION public.get_fantasy_league_detail(p_league_id bigint,
    p_start date DEFAULT NULL, p_end date DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE v_email text; v_league jsonb; v_teams jsonb; v_standings jsonb;
        v_espn text; v_start date; v_end date;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';
  END IF;

  SELECT to_jsonb(l) INTO v_league FROM (
    SELECT l.id, l.name, l.espn_league, l.roster_size, l.starters, rs.name AS ruleset, rs.rules
    FROM public.fantasy_leagues l LEFT JOIN public.fantasy_scoring_rulesets rs ON rs.id = l.ruleset_id
    WHERE l.id = p_league_id
  ) l;
  IF v_league IS NULL THEN RETURN jsonb_build_object('hidden', true); END IF;
  v_espn := v_league->>'espn_league';

  -- Resolve the scoring window when the caller left it open.
  v_start := p_start; v_end := p_end;
  IF v_start IS NULL OR v_end IS NULL THEN
    SELECT m.period_start, m.period_end INTO v_start, v_end
    FROM public.fantasy_matchups m
    WHERE m.league_id = p_league_id
    ORDER BY m.period_end DESC NULLS LAST, m.week DESC NULLS LAST LIMIT 1;
  END IF;
  IF v_start IS NULL OR v_end IS NULL THEN
    SELECT (max(game_date::date) - 30), max(game_date::date) INTO v_start, v_end
    FROM public.espn_player_gamelog
    WHERE espn_league = v_espn AND espn_event_id <> 'none';
  END IF;
  IF v_start IS NULL OR v_end IS NULL THEN
    v_start := (now() - interval '30 days')::date; v_end := now()::date;
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.window_points DESC), '[]'::jsonb) INTO v_teams FROM (
    SELECT tm.id, tm.team_name, tm.manager_email,
      (SELECT coalesce(jsonb_agg(jsonb_build_object(
          'espn_athlete_id', r.espn_athlete_id, 'slot', r.slot,
          'name', a.full_name, 'position', a.position_abbr) ORDER BY r.slot, a.full_name), '[]'::jsonb)
       FROM public.fantasy_rosters r
       LEFT JOIN public.espn_athletes a ON a.espn_athlete_id = r.espn_athlete_id AND a.espn_league = r.espn_league
       WHERE r.fantasy_team_id = tm.id) AS roster,
      coalesce((SELECT sum(points) FROM public.fantasy_team_score(tm.id, v_start, v_end)), 0)::numeric AS window_points
    FROM public.fantasy_teams tm WHERE tm.league_id = p_league_id
  ) t;

  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.wins DESC, s.points_for DESC), '[]'::jsonb) INTO v_standings
  FROM public.get_fantasy_standings(p_league_id) s;

  RETURN jsonb_build_object('league', v_league, 'teams', v_teams,
                            'standings', v_standings,
                            'window', jsonb_build_object('start', v_start, 'end', v_end),
                            'hidden', false);
END $function$;
