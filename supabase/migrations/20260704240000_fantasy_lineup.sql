-- Fantasy lineup editing: move a player between the bench and a starting slot.
--
-- Auto-draft and add-free-agent leave a player on the bench; only NON-bench
-- (positional) slots score (fantasy_team_score). These two RPCs let the manager
-- set the lineup:
--   * fantasy_bench_player  — demote a starter to the bench (frees its slot).
--   * fantasy_start_player  — promote a bench player into the FIRST open starter
--     slot they are eligible for, per the sport profile's roster template. If no
--     eligible slot is open, it returns {ok:false, error:'no_open_slot'} so the
--     UI can prompt the manager to bench someone first.
-- Eligibility = the player's position_abbr is in the slot's elig list (or the
-- slot is ANY/UTIL/FLEX). Both @s4kent.com-gated SECDEF.

CREATE OR REPLACE FUNCTION public.fantasy_bench_player(p_team_id bigint, p_athlete_id text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_n int;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  UPDATE public.fantasy_rosters SET slot = 'bench'
   WHERE fantasy_team_id = p_team_id AND espn_athlete_id = p_athlete_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RETURN jsonb_build_object('ok', false, 'error', 'not_on_roster'); END IF;
  RETURN jsonb_build_object('ok', true, 'slot', 'bench');
END $function$;

CREATE OR REPLACE FUNCTION public.fantasy_start_player(p_team_id bigint, p_athlete_id text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_league text; v_sport text; v_slots jsonb; v_pos text; v_code text; v_n int;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;

  SELECT l.espn_league INTO v_league
  FROM public.fantasy_teams t JOIN public.fantasy_leagues l ON l.id = t.league_id
  WHERE t.id = p_team_id;
  IF v_league IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'team_not_found'); END IF;

  SELECT a.position_abbr INTO v_pos FROM public.fantasy_rosters r
    JOIN public.espn_athletes a ON a.espn_athlete_id = r.espn_athlete_id AND a.espn_league = r.espn_league
   WHERE r.fantasy_team_id = p_team_id AND r.espn_athlete_id = p_athlete_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'not_on_roster'); END IF;

  v_sport := public._fantasy_sport_for_league(v_league);
  SELECT roster_slots INTO v_slots FROM public.fantasy_sport_profiles WHERE sport = v_sport;
  IF v_slots IS NULL THEN
    -- no profile → single generic starter pool; start if under the league's starters count
    UPDATE public.fantasy_rosters SET slot = 'ST'
     WHERE fantasy_team_id = p_team_id AND espn_athlete_id = p_athlete_id;
    RETURN jsonb_build_object('ok', true, 'slot', 'ST');
  END IF;

  WITH tmpl AS (
    SELECT (row_number() OVER ())::int AS ord, e->>'slot' AS code,
           CASE WHEN e->'elig'->>0 = 'ANY' THEN ARRAY[]::text[]
                ELSE ARRAY(SELECT jsonb_array_elements_text(e->'elig')) END AS elig,
           (e->'elig'->>0 = 'ANY') AS any_flag
    FROM jsonb_array_elements(v_slots) e
  )
  SELECT t.code INTO v_code
  FROM tmpl t
  WHERE (t.any_flag OR v_pos = ANY (t.elig))
    AND (SELECT count(*) FROM tmpl t2 WHERE t2.code = t.code)
        > coalesce((SELECT count(*) FROM public.fantasy_rosters r
                    WHERE r.fantasy_team_id = p_team_id AND r.slot = t.code), 0)
  ORDER BY t.ord
  LIMIT 1;

  IF v_code IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_open_slot', 'position', v_pos);
  END IF;

  UPDATE public.fantasy_rosters SET slot = v_code
   WHERE fantasy_team_id = p_team_id AND espn_athlete_id = p_athlete_id;
  RETURN jsonb_build_object('ok', true, 'slot', v_code);
END $function$;

COMMENT ON FUNCTION public.fantasy_start_player IS
  'Promote a bench player into the first open eligible starter slot (per the sport roster template); {ok:false,error:no_open_slot} if the lineup is full at their position.';
