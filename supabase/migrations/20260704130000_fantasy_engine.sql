-- Fantasy engine (v2): roster ops + competition (Layers 3-4 of the plan).
-- Builds on 20260704070000 (domain + scoring). All @s4kent.com-gated SECDEF —
-- single-tenant internal tool (any @s4kent.com user manages; per-manager
-- ownership is a later phase).

-- ---- READ: leagues list + league detail ------------------------------------
CREATE OR REPLACE FUNCTION public.get_fantasy_leagues()
 RETURNS TABLE (id bigint, name text, espn_league text, roster_size int,
                starters int, team_count int, ruleset_name text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  SELECT l.id, l.name, l.espn_league, l.roster_size, l.starters,
         count(t.id)::int, rs.name
  FROM public.fantasy_leagues l
  LEFT JOIN public.fantasy_teams t ON t.league_id = l.id
  LEFT JOIN public.fantasy_scoring_rulesets rs ON rs.id = l.ruleset_id
  GROUP BY l.id, l.name, l.espn_league, l.roster_size, l.starters, rs.name
  ORDER BY l.name;
$function$;

-- League detail: config + teams (with roster + last-window points) + standings.
CREATE OR REPLACE FUNCTION public.get_fantasy_league_detail(p_league_id bigint,
    p_start date DEFAULT (now() - interval '30 days')::date,
    p_end date DEFAULT now()::date)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE v_email text; v_league jsonb; v_teams jsonb; v_standings jsonb;
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

  SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.window_points DESC), '[]'::jsonb) INTO v_teams FROM (
    SELECT tm.id, tm.team_name, tm.manager_email,
      (SELECT coalesce(jsonb_agg(jsonb_build_object(
          'espn_athlete_id', r.espn_athlete_id, 'slot', r.slot,
          'name', a.full_name, 'position', a.position_abbr) ORDER BY r.slot, a.full_name), '[]'::jsonb)
       FROM public.fantasy_rosters r
       LEFT JOIN public.espn_athletes a ON a.espn_athlete_id = r.espn_athlete_id AND a.espn_league = r.espn_league
       WHERE r.fantasy_team_id = tm.id) AS roster,
      coalesce((SELECT sum(points) FROM public.fantasy_team_score(tm.id, p_start, p_end)), 0)::numeric AS window_points
    FROM public.fantasy_teams tm WHERE tm.league_id = p_league_id
  ) t;

  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.wins DESC, s.points_for DESC), '[]'::jsonb) INTO v_standings
  FROM public.get_fantasy_standings(p_league_id) s;

  RETURN jsonb_build_object('league', v_league, 'teams', v_teams,
                            'standings', v_standings, 'window', jsonb_build_object('start', p_start, 'end', p_end),
                            'hidden', false);
END $function$;

-- ---- READ: free agents (sport-matching athletes not rostered in the league) --
CREATE OR REPLACE FUNCTION public.get_fantasy_free_agents(p_league_id bigint,
    p_search text DEFAULT NULL, p_limit int DEFAULT 50)
 RETURNS TABLE (espn_athlete_id text, full_name text, "position" text, team_abbr text, espn_league text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  WITH lg AS (SELECT espn_league FROM public.fantasy_leagues WHERE id = p_league_id)
  SELECT a.espn_athlete_id, a.full_name, a.position_abbr, a.espn_team_id, a.espn_league
  FROM public.espn_athletes a, lg
  WHERE a.espn_league = lg.espn_league
    AND coalesce(a.status,'') <> 'released'
    AND NOT EXISTS (
      SELECT 1 FROM public.fantasy_rosters r
      JOIN public.fantasy_teams t ON t.id = r.fantasy_team_id
      WHERE t.league_id = p_league_id AND r.espn_athlete_id = a.espn_athlete_id)
    AND (p_search IS NULL OR a.full_name ILIKE '%'||p_search||'%')
  ORDER BY a.full_name
  LIMIT greatest(1, least(coalesce(p_limit,50), 200));
$function$;

-- ---- WRITE: roster move (add | drop | set_slot) -----------------------------
CREATE OR REPLACE FUNCTION public.fantasy_roster_move(
    p_team_id bigint, p_athlete_id text, p_action text, p_slot text DEFAULT 'bench')
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE v_email text; v_league text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;

  SELECT l.espn_league INTO v_league
  FROM public.fantasy_teams t JOIN public.fantasy_leagues l ON l.id = t.league_id
  WHERE t.id = p_team_id;
  IF v_league IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'team_not_found'); END IF;

  IF p_action = 'drop' THEN
    DELETE FROM public.fantasy_rosters WHERE fantasy_team_id = p_team_id AND espn_athlete_id = p_athlete_id;
  ELSIF p_action = 'set_slot' THEN
    UPDATE public.fantasy_rosters SET slot = p_slot
    WHERE fantasy_team_id = p_team_id AND espn_athlete_id = p_athlete_id;
  ELSIF p_action = 'add' THEN
    INSERT INTO public.fantasy_rosters (fantasy_team_id, espn_athlete_id, espn_league, slot)
    VALUES (p_team_id, p_athlete_id, v_league, coalesce(p_slot,'bench'))
    ON CONFLICT (fantasy_team_id, espn_athlete_id) DO UPDATE SET slot = EXCLUDED.slot;
  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'bad_action');
  END IF;
  RETURN jsonb_build_object('ok', true);
END $function$;

-- ---- COMPETITION: round-robin matchups, score a week, standings -------------
-- Generate a single round-robin round of H2H matchups for a period (skips if any
-- matchup already exists for that week).
CREATE OR REPLACE FUNCTION public.fantasy_generate_matchups(
    p_league_id bigint, p_week int, p_start date, p_end date)
 RETURNS int LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_n int; v_made int := 0;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  IF EXISTS (SELECT 1 FROM public.fantasy_matchups WHERE league_id = p_league_id AND week = p_week) THEN
    RETURN 0;
  END IF;
  WITH ids AS (
    SELECT id, row_number() OVER (ORDER BY id) AS rn FROM public.fantasy_teams WHERE league_id = p_league_id
  ), paired AS (
    SELECT a.id AS home, b.id AS away FROM ids a JOIN ids b ON b.rn = a.rn + 1 WHERE a.rn % 2 = 1
  )
  INSERT INTO public.fantasy_matchups (league_id, week, period_start, period_end, home_team_id, away_team_id, status)
  SELECT p_league_id, p_week, p_start, p_end, home, away, 'scheduled' FROM paired;
  GET DIAGNOSTICS v_made = ROW_COUNT;
  RETURN v_made;
END $function$;

-- Score every non-final matchup for a league+week from the game logs, finalize.
CREATE OR REPLACE FUNCTION public.fantasy_score_week(p_league_id bigint, p_week int)
 RETURNS int LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; m record; v_h numeric; v_a numeric; v_done int := 0;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  FOR m IN SELECT * FROM public.fantasy_matchups WHERE league_id = p_league_id AND week = p_week LOOP
    SELECT coalesce(sum(points),0) INTO v_h FROM public.fantasy_team_score(m.home_team_id, m.period_start, m.period_end);
    SELECT coalesce(sum(points),0) INTO v_a FROM public.fantasy_team_score(m.away_team_id, m.period_start, m.period_end);
    UPDATE public.fantasy_matchups SET home_points = v_h, away_points = v_a, status = 'final' WHERE id = m.id;
    v_done := v_done + 1;
  END LOOP;
  RETURN v_done;
END $function$;

-- League standings from final matchups: W-L-T + points for/against.
CREATE OR REPLACE FUNCTION public.get_fantasy_standings(p_league_id bigint)
 RETURNS TABLE (team_id bigint, team_name text, wins int, losses int, ties int,
                points_for numeric, points_against numeric)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  WITH sides AS (
    SELECT home_team_id AS team_id, home_points AS pf, away_points AS pa FROM public.fantasy_matchups
      WHERE league_id = p_league_id AND status = 'final' AND home_team_id IS NOT NULL
    UNION ALL
    SELECT away_team_id, away_points, home_points FROM public.fantasy_matchups
      WHERE league_id = p_league_id AND status = 'final' AND away_team_id IS NOT NULL
  )
  SELECT t.id, t.team_name,
    count(*) FILTER (WHERE s.pf > s.pa)::int,
    count(*) FILTER (WHERE s.pf < s.pa)::int,
    count(*) FILTER (WHERE s.pf = s.pa)::int,
    coalesce(sum(s.pf),0)::numeric, coalesce(sum(s.pa),0)::numeric
  FROM public.fantasy_teams t
  LEFT JOIN sides s ON s.team_id = t.id
  WHERE t.league_id = p_league_id
  GROUP BY t.id, t.team_name
  ORDER BY count(*) FILTER (WHERE s.pf > s.pa) DESC, coalesce(sum(s.pf),0) DESC;
$function$;
