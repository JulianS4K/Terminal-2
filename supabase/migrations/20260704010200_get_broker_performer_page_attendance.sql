-- Add an `attendance` block to get_broker_performer_page: the performer (team)
-- ESPN Context tab shows the team's latest season attendance (rank, home avg/
-- total, pct) next to standings / injuries / transactions. Pulls the latest
-- change-only snapshot from espn_attendance_latest (slice 2 pipeline).
--
-- Only the v_att SELECT + return key are new vs 20260704000100; the rest is
-- reproduced verbatim.

CREATE OR REPLACE FUNCTION public.get_broker_performer_page(p_performer_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_email text; v_team_id text; v_league text;
  v_standings jsonb; v_injuries jsonb; v_recent jsonb; v_txns jsonb; v_att jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT espn_team_id, espn_league INTO v_team_id, v_league
  FROM public.performer_espn_team_xref WHERE tevo_performer_id = p_performer_id LIMIT 1;

  IF v_team_id IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'no_espn_xref');
  END IF;

  SELECT to_jsonb(s) INTO v_standings FROM (
    SELECT DISTINCT ON (espn_team_id) wins, losses, ties, win_pct, games_back,
      playoff_seed, conference_rank, division_rank, record_summary,
      standing_summary, streak, captured_at
    FROM public.espn_team_snapshots WHERE espn_team_id = v_team_id
    ORDER BY espn_team_id, captured_at DESC
  ) s;

  SELECT coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb) INTO v_injuries FROM (
    SELECT DISTINCT ON (athlete_id) athlete_id, athlete_name, position, status,
      injury_type, short_comment, return_date, captured_at
    FROM public.espn_injuries_snapshots
    WHERE espn_team_id = v_team_id AND lower(status) <> 'active' AND status IS NOT NULL
    ORDER BY athlete_id, captured_at DESC
  ) i;

  SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.captured_at DESC), '[]'::jsonb)
  INTO v_recent FROM (
    SELECT * FROM (
      SELECT DISTINCT ON (espn_event_id) espn_event_id, status_short, captured_at,
        home_team_id, away_team_id, home_score, away_score, attendance,
        (home_team_id = v_team_id) AS is_home,
        CASE WHEN home_team_id = v_team_id THEN away_team_id ELSE home_team_id END AS opponent_team_id
      FROM public.espn_event_snapshots
      WHERE state = 'post' AND (home_team_id = v_team_id OR away_team_id = v_team_id)
      ORDER BY espn_event_id, captured_at DESC
    ) deduped ORDER BY captured_at DESC LIMIT 5
  ) e;

  SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.txn_date DESC), '[]'::jsonb)
  INTO v_txns FROM (
    SELECT txn_date, description, team_abbr, team_display_name
    FROM public.espn_transactions
    WHERE espn_team_id = v_team_id AND espn_league = v_league
    ORDER BY txn_date DESC NULLS LAST
    LIMIT 15
  ) t;

  SELECT to_jsonb(a) INTO v_att FROM (
    SELECT season, rank, team_name, home_games, home_total, home_avg, home_pct,
      road_avg, overall_avg, captured_at
    FROM public.espn_attendance_latest
    WHERE espn_team_id = v_team_id AND espn_league = v_league
    LIMIT 1
  ) a;

  RETURN jsonb_build_object(
    'espn_team_id', v_team_id, 'espn_league', v_league,
    'standings', v_standings, 'injuries', v_injuries,
    'recent_results', v_recent, 'transactions', v_txns,
    'attendance', v_att, 'hidden', false
  );
END $function$;
