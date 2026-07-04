-- Security hardening from the session audit (get_advisors 2026-07-04).
--
-- 1. Pin search_path on three helper functions that were created without it
--    (function_search_path_mutable WARN) — matches the project's function
--    search-path convention (migs 20260511000100 / 20260514181000). All three
--    are pure (no schema-resolved table refs), so this is convention + defense.
-- 2. Email-gate the three fantasy READ RPCs that shipped ungated
--    (get_fantasy_leagues / _standings / _free_agents). The detail RPC and every
--    fantasy write RPC already gate on @s4kent.com; these three did not, so the
--    anon role could read league/roster data. Converted to plpgsql with the
--    standard gate (the terminal always authenticates, so no functional change).

-- ---- 1. pin search_path on pure helpers --------------------------------------
CREATE OR REPLACE FUNCTION public.fantasy_gamelog_points(p_stats jsonb, p_rules jsonb)
 RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path TO 'public','pg_temp' AS $function$
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

CREATE OR REPLACE FUNCTION public._fantasy_sport_for_league(p_league text)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public','pg_temp' AS $function$
  SELECT CASE upper(p_league)
    WHEN 'NBA' THEN 'basketball' WHEN 'WNBA' THEN 'basketball'
    WHEN 'MLB' THEN 'baseball'   WHEN 'NFL'  THEN 'football'
    ELSE lower(p_league) END;
$function$;

CREATE OR REPLACE FUNCTION public._espn_txn_type(p_description text)
 RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO 'public','pg_temp' AS $function$
  SELECT CASE
    WHEN p_description IS NULL THEN 'MOVE'
    WHEN p_description ILIKE '%re-signed%'                                   THEN 'RE-SIGN'
    WHEN p_description ILIKE '%signed%' OR p_description ILIKE '%agreed to terms%' THEN 'SIGN'
    WHEN p_description ILIKE '%traded%' OR p_description ILIKE '%acquired%'
      OR p_description ILIKE '%in exchange%'                                 THEN 'TRADE'
    WHEN p_description ILIKE '%claimed%'                                     THEN 'CLAIM'
    WHEN p_description ILIKE '%waived%'                                      THEN 'WAIVE'
    WHEN p_description ILIKE '%released%'                                    THEN 'RELEASE'
    WHEN p_description ILIKE '%designated%for assignment%'
      OR p_description ILIKE '%designated%for release%'                      THEN 'DFA'
    WHEN p_description ILIKE '%reinstated%' OR p_description ILIKE '%activated%' THEN 'ACTIVATE'
    WHEN p_description ILIKE '%placed%il%' OR p_description ILIKE '%injured list%'
      OR p_description ILIKE '%day il%'                                      THEN 'IL'
    WHEN p_description ILIKE '%optioned%'                                    THEN 'OPTION'
    WHEN p_description ILIKE '%recalled%' OR p_description ILIKE '%selected the contract%' THEN 'RECALL'
    WHEN p_description ILIKE '%rehab assignment%' OR p_description ILIKE '%assigned%' THEN 'ASSIGN'
    WHEN p_description ILIKE '%promoted%'                                    THEN 'PROMOTE'
    ELSE 'MOVE'
  END;
$function$;

-- ---- 2. email-gate the fantasy read RPCs ------------------------------------
CREATE OR REPLACE FUNCTION public.get_fantasy_leagues()
 RETURNS TABLE (id bigint, name text, espn_league text, roster_size int,
                starters int, team_count int, ruleset_name text)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
BEGIN
  IF coalesce(auth.jwt()->>'email','') NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    SELECT l.id, l.name, l.espn_league, l.roster_size, l.starters,
           count(t.id)::int, rs.name
    FROM public.fantasy_leagues l
    LEFT JOIN public.fantasy_teams t ON t.league_id = l.id
    LEFT JOIN public.fantasy_scoring_rulesets rs ON rs.id = l.ruleset_id
    GROUP BY l.id, l.name, l.espn_league, l.roster_size, l.starters, rs.name
    ORDER BY l.name;
END $function$;

CREATE OR REPLACE FUNCTION public.get_fantasy_standings(p_league_id bigint)
 RETURNS TABLE (team_id bigint, team_name text, wins int, losses int, ties int,
                points_for numeric, points_against numeric)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
BEGIN
  IF coalesce(auth.jwt()->>'email','') NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    WITH sides AS (
      SELECT home_team_id AS tid, home_points AS pf, away_points AS pa FROM public.fantasy_matchups
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
    LEFT JOIN sides s ON s.tid = t.id
    WHERE t.league_id = p_league_id
    GROUP BY t.id, t.team_name
    ORDER BY count(*) FILTER (WHERE s.pf > s.pa) DESC, coalesce(sum(s.pf),0) DESC;
END $function$;

CREATE OR REPLACE FUNCTION public.get_fantasy_free_agents(p_league_id bigint,
    p_search text DEFAULT NULL, p_limit int DEFAULT 50)
 RETURNS TABLE (espn_athlete_id text, full_name text, "position" text, team_abbr text, espn_league text)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
BEGIN
  IF coalesce(auth.jwt()->>'email','') NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE='42501';
  END IF;
  RETURN QUERY
    WITH lg AS (SELECT fl.espn_league AS lgc FROM public.fantasy_leagues fl WHERE fl.id = p_league_id)
    SELECT a.espn_athlete_id, a.full_name, a.position_abbr, a.espn_team_id, a.espn_league
    FROM public.espn_athletes a, lg
    WHERE a.espn_league = lg.lgc
      AND coalesce(a.status,'') <> 'released'
      AND NOT EXISTS (
        SELECT 1 FROM public.fantasy_rosters r
        JOIN public.fantasy_teams t ON t.id = r.fantasy_team_id
        WHERE t.league_id = p_league_id AND r.espn_athlete_id = a.espn_athlete_id)
      AND (p_search IS NULL OR a.full_name ILIKE '%'||p_search||'%')
    ORDER BY a.full_name
    LIMIT greatest(1, least(coalesce(p_limit,50), 200));
END $function$;
