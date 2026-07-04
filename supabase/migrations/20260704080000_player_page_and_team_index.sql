-- Player-detail page + players-by-team index RPCs for the terminal.
--
-- Reads the ESPN pipelines: espn_athletes (bio/roster), espn_player_stats
-- (season stats), espn_player_gamelog (per-game lines), espn_teams_canonical
-- (team names). All @s4kent.com-gated SECURITY DEFINER, like the other broker
-- page RPCs.

-- Full player detail: bio + team + season stats (per category) + recent games.
CREATE OR REPLACE FUNCTION public.get_broker_player_page(p_athlete_id text, p_league text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_bio jsonb; v_team jsonb; v_stats jsonb; v_games jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(a) INTO v_bio FROM (
    SELECT espn_athlete_id, full_name, display_name, jersey, position, position_abbr,
           height_inches, weight_lbs, age, birth_date, status, experience_years,
           headshot_url, espn_team_id, espn_league
    FROM public.espn_athletes
    WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league
    LIMIT 1
  ) a;

  IF v_bio IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'athlete_not_found');
  END IF;

  SELECT to_jsonb(t) INTO v_team FROM (
    SELECT display_name, abbreviation
    FROM public.espn_teams_canonical
    WHERE espn_team_id = (v_bio->>'espn_team_id') AND espn_league = p_league LIMIT 1
  ) t;

  SELECT coalesce(jsonb_object_agg(category, jsonb_build_object('season', season, 'stats', stats)), '{}'::jsonb)
  INTO v_stats FROM public.espn_player_stats
  WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league;

  SELECT coalesce(jsonb_agg(to_jsonb(g) ORDER BY g.game_date DESC), '[]'::jsonb)
  INTO v_games FROM (
    SELECT game_date, season_type, home_away, opponent_abbr, result, score, stats
    FROM public.espn_player_gamelog
    WHERE espn_athlete_id = p_athlete_id AND espn_league = p_league AND espn_event_id <> 'none'
    ORDER BY game_date DESC NULLS LAST LIMIT 20
  ) g;

  RETURN jsonb_build_object(
    'bio', v_bio, 'team', v_team, 'season_stats', v_stats,
    'recent_games', v_games, 'hidden', false
  );
END $function$;
comment on function public.get_broker_player_page is
  'Terminal player-detail page: bio + team + season stats + recent game log (ESPN pipelines).';

-- League team index: every team with its active-player count (index navigation).
CREATE OR REPLACE FUNCTION public.get_espn_team_index(p_league text)
 RETURNS TABLE (espn_team_id text, team_name text, abbreviation text, player_count int)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  SELECT c.espn_team_id, c.display_name, c.abbreviation,
         count(a.espn_athlete_id) FILTER (WHERE coalesce(a.status,'') <> 'released')::int
  FROM public.espn_teams_canonical c
  LEFT JOIN public.espn_athletes a
    ON a.espn_team_id = c.espn_team_id AND a.espn_league = c.espn_league
  WHERE c.espn_league = p_league
  GROUP BY c.espn_team_id, c.display_name, c.abbreviation
  HAVING count(a.espn_athlete_id) > 0
  ORDER BY c.display_name;
$function$;
comment on function public.get_espn_team_index is
  'Teams in a league with active-player counts (players-by-team index).';

-- A team's roster (the by-team player index leaf): active athletes + jersey/pos.
CREATE OR REPLACE FUNCTION public.get_espn_team_roster(p_league text, p_team_id text)
 RETURNS TABLE (espn_athlete_id text, full_name text, jersey text, "position" text,
                position_abbr text, headshot_url text, status text)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
  SELECT espn_athlete_id, full_name, jersey, position, position_abbr, headshot_url, status
  FROM public.espn_athletes
  WHERE espn_league = p_league AND espn_team_id = p_team_id
    AND coalesce(status,'') <> 'released'
  ORDER BY full_name;
$function$;
comment on function public.get_espn_team_roster is
  'Active roster for a team (leaf of the players-by-team index).';

-- Performer (team) roster for the terminal performer ROSTER tab: resolves the
-- tevo performer -> ESPN team, returns its active athletes (each links to the
-- player-detail page). Returns {applicable:false} for non-team performers.
CREATE OR REPLACE FUNCTION public.get_broker_performer_roster(p_performer_id integer)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_team_id text; v_league text; v_players jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT espn_team_id, espn_league INTO v_team_id, v_league
  FROM public.performer_espn_team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1;
  IF v_team_id IS NULL THEN
    RETURN jsonb_build_object('applicable', false);
  END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.full_name), '[]'::jsonb) INTO v_players FROM (
    SELECT espn_athlete_id, full_name, jersey, position, position_abbr, headshot_url, status
    FROM public.espn_athletes
    WHERE espn_league = v_league AND espn_team_id = v_team_id AND coalesce(status,'') <> 'released'
    ORDER BY full_name
  ) p;

  RETURN jsonb_build_object('applicable', true, 'espn_league', v_league,
                            'espn_team_id', v_team_id, 'players', v_players);
END $function$;
comment on function public.get_broker_performer_roster is
  'Active roster for a performer (team) — the performer ROSTER tab; links to player.html.';
