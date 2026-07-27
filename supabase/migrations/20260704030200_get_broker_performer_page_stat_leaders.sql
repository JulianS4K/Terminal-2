-- Add a `stat_leaders` block to get_broker_performer_page: the performer (team)
-- ESPN Context tab shows the team's top players by a league-primary stat
-- (MLB → home runs, NBA/WNBA → points per game) from espn_player_stats
-- (slice 3 pipeline), joined by the team's canonical abbreviation.
--
-- Only v_leaders + the return key are new vs 20260704010200; the rest is verbatim.

CREATE OR REPLACE FUNCTION public.get_broker_performer_page(p_performer_id integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_email text; v_team_id text; v_league text; v_abbr text;
  v_standings jsonb; v_injuries jsonb; v_recent jsonb; v_txns jsonb; v_att jsonb; v_leaders jsonb;
  v_stat_key text; v_stat_cat text; v_stat_label text;
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

  -- Team stat leaders — league-primary stat, joined by canonical abbreviation.
  SELECT abbreviation INTO v_abbr
  FROM public.espn_teams_canonical WHERE espn_team_id = v_team_id AND espn_league = v_league LIMIT 1;
  v_stat_cat := CASE WHEN v_league = 'MLB' THEN 'batting' ELSE 'general' END;
  v_stat_key := CASE WHEN v_league = 'MLB' THEN 'homeRuns' ELSE 'avgPoints' END;
  v_stat_label := CASE WHEN v_league = 'MLB' THEN 'HR' ELSE 'PPG' END;

  IF v_abbr IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.val DESC), '[]'::jsonb) INTO v_leaders FROM (
      SELECT athlete_name, position,
        v_stat_label AS stat_label,
        coalesce(nullif(nullif(stats->>v_stat_key, '-'), '--'), stats_num->>v_stat_key) AS stat_display,
        (stats_num->>v_stat_key)::numeric AS val
      FROM public.espn_player_stats
      WHERE espn_league = v_league AND category = v_stat_cat
        AND lower(team_abbr) = lower(v_abbr)
        AND stats_num ? v_stat_key AND (stats_num->>v_stat_key) ~ '^-?[0-9.]+$'
      ORDER BY (stats_num->>v_stat_key)::numeric DESC
      LIMIT 5
    ) x;
  ELSE
    v_leaders := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object(
    'espn_team_id', v_team_id, 'espn_league', v_league,
    'standings', v_standings, 'injuries', v_injuries,
    'recent_results', v_recent, 'transactions', v_txns,
    'attendance', v_att, 'stat_leaders', v_leaders, 'hidden', false
  );
END $function$;
