-- Fantasy engine (v4): real multi-week seasons.
--
-- v2's fantasy_generate_matchups produced the SAME fixed pairing every week
-- (pair team rn with rn+1), so a multi-week schedule was meaningless. This
-- migration makes weeks first-class:
--   * fantasy_generate_matchups — circle-method round-robin: week w gets a
--     distinct rotation of pairings (fix team 0, rotate the rest; odd team
--     counts get a bye). Over (teams-1) weeks every team plays every other once.
--   * fantasy_create_demo_league — an 8-week season of consecutive 7-day slices
--     ending at the league's latest game log; drafts over the whole season,
--     schedules + scores week 1.
--   * fantasy_advance_week — the "next week" control: schedule + score the next
--     7-day slice, accumulating the H2H standings, until the season's data runs
--     out. This is the write action the FANTASY tab's "Advance week" button calls.
-- All @s4kent.com-gated SECDEF.

-- ---- circle-method round-robin ----------------------------------------------
CREATE OR REPLACE FUNCTION public.fantasy_generate_matchups(
    p_league_id bigint, p_week int, p_start date, p_end date)
 RETURNS int LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_ids bigint[]; v_n int; v_m int; v_r int; v_made int := 0;
        i int; sa int; sb int; ha bigint; aw bigint;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  IF EXISTS (SELECT 1 FROM public.fantasy_matchups WHERE league_id = p_league_id AND week = p_week) THEN
    RETURN 0;
  END IF;

  SELECT array_agg(id ORDER BY id) INTO v_ids FROM public.fantasy_teams WHERE league_id = p_league_id;
  v_n := coalesce(array_length(v_ids, 1), 0);
  IF v_n < 2 THEN RETURN 0; END IF;
  v_m := CASE WHEN v_n % 2 = 0 THEN v_n ELSE v_n + 1 END;   -- pad odd counts with a bye
  v_r := (p_week - 1) % (v_m - 1);                          -- rotation for this week

  FOR i IN 0 .. (v_m / 2 - 1) LOOP
    -- circle position -> team-slot number (slot 0 is fixed, 1..m-1 rotate)
    sa := CASE WHEN i = 0 THEN 0 ELSE ((i - 1 + v_r) % (v_m - 1)) + 1 END;
    sb := CASE WHEN (v_m - 1 - i) = 0 THEN 0 ELSE (((v_m - 1 - i) - 1 + v_r) % (v_m - 1)) + 1 END;
    ha := CASE WHEN sa < v_n THEN v_ids[sa + 1] END;          -- slot >= n is the bye
    aw := CASE WHEN sb < v_n THEN v_ids[sb + 1] END;
    IF ha IS NOT NULL AND aw IS NOT NULL THEN
      INSERT INTO public.fantasy_matchups
        (league_id, week, period_start, period_end, home_team_id, away_team_id, status)
      VALUES (p_league_id, p_week, p_start, p_end, ha, aw, 'scheduled');
      v_made := v_made + 1;
    END IF;
  END LOOP;
  RETURN v_made;
END $function$;

-- ---- next-week control -------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fantasy_advance_week(p_league_id bigint)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_espn text; v_anchor date; v_maxweek int; v_w int;
        v_start date; v_end date; v_gmax date; v_made int; v_scored int;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;

  SELECT espn_league INTO v_espn FROM public.fantasy_leagues WHERE id = p_league_id;
  IF v_espn IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'league_not_found'); END IF;

  SELECT min(period_start), max(week) INTO v_anchor, v_maxweek
  FROM public.fantasy_matchups WHERE league_id = p_league_id;
  IF v_anchor IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no_schedule_yet'); END IF;

  v_w := v_maxweek + 1;
  v_start := v_anchor + (7 * (v_w - 1));
  v_end := v_start + 6;

  SELECT max(game_date::date) INTO v_gmax FROM public.espn_player_gamelog
   WHERE espn_league = v_espn AND espn_event_id <> 'none';
  IF v_gmax IS NULL OR v_start > v_gmax THEN
    RETURN jsonb_build_object('ok', true, 'done', true, 'message', 'season complete',
      'week', v_maxweek);
  END IF;
  IF v_end > v_gmax THEN v_end := v_gmax; END IF;

  v_made := public.fantasy_generate_matchups(p_league_id, v_w, v_start, v_end);
  v_scored := public.fantasy_score_week(p_league_id, v_w);
  RETURN jsonb_build_object('ok', true, 'done', false, 'week', v_w,
    'matchups', v_made, 'scored', v_scored,
    'window', jsonb_build_object('start', v_start, 'end', v_end));
END $function$;

-- ---- demo builder: 8-week season of 7-day slices ----------------------------
CREATE OR REPLACE FUNCTION public.fantasy_create_demo_league(
    p_league text DEFAULT 'NBA', p_teams int DEFAULT 6, p_roster int DEFAULT 8, p_starters int DEFAULT 5)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','pg_temp'
AS $function$
DECLARE v_email text; v_id bigint; v_gmax date; v_anchor date; v_drafted int; v_scored int;
        v_names text[] := ARRAY['Alpha','Bravo','Charlie','Delta','Echo','Foxtrot','Golf','Hotel',
                                'India','Juliet','Kilo','Lima'];
        i int;
BEGIN
  v_email := coalesce(auth.jwt()->>'email','');
  IF v_email NOT LIKE '%@s4kent.com' THEN RAISE EXCEPTION 'forbidden' USING ERRCODE='42501'; END IF;
  p_teams := greatest(2, least(p_teams, array_length(v_names,1)));

  v_id := public.fantasy_create_league('Demo '||upper(p_league)||' League', p_league, p_roster, p_starters);
  FOR i IN 1..p_teams LOOP
    INSERT INTO public.fantasy_teams (league_id, team_name, manager_email)
    VALUES (v_id, 'Team '||v_names[i], lower(v_names[i])||'@s4kent.com');
  END LOOP;

  -- 8 one-week slices ending at the league's most recent game log.
  SELECT max(game_date::date) INTO v_gmax FROM public.espn_player_gamelog
   WHERE espn_league = upper(p_league) AND espn_event_id <> 'none';
  IF v_gmax IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'no_gamelog_for_league', 'league', upper(p_league)); END IF;
  v_anchor := v_gmax - 55;   -- week 1 start; week 8 ends at v_gmax

  -- draft over the whole season window so form-ranking reflects all 8 weeks
  v_drafted := public.fantasy_autodraft_league(v_id, v_anchor, v_gmax);
  PERFORM public.fantasy_generate_matchups(v_id, 1, v_anchor, v_anchor + 6);
  v_scored := public.fantasy_score_week(v_id, 1);

  RETURN jsonb_build_object('ok', true, 'league_id', v_id, 'teams', p_teams,
    'drafted', v_drafted, 'scored_matchups', v_scored, 'weeks_total', 8,
    'window', jsonb_build_object('start', v_anchor, 'end', v_anchor + 6));
END $function$;

COMMENT ON FUNCTION public.fantasy_advance_week IS
  'Schedule + score the next 7-day week for a league (circle-method pairings), until the season data runs out. The FANTASY tab "Advance week" action.';
