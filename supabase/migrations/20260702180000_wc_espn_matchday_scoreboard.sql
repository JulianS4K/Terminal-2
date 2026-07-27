-- Migration 20260702180000 · lane:D0 (author) → A1 (apply) · writes(DDL):get_wc_espn · reads:world_cup_2026, espn_event_date_lookup, espn_event_snapshots, performer_external_ids · pre:20260702170000_wc_seatdata_comps_full_curve · auth:operator-requested 2026-07-02 ("wire it all into terminal ... ESPN tab")
--
-- ## Applied to prod 2026-07-02 via MCP apply_migration (operator-directed). Idempotent.
--
-- ESPN match/scoreboard data for a World Cup match, for the terminal SG-mode ESPN
-- tab. WC matches are SG-native (no ESPN id of their own) and our knockout rows are
-- still "TBD" with placeholder kickoff times, so a closest-time pin COLLIDES on
-- multi-game days (two of our matches resolve to the same ESPN game). Instead this
-- returns the match's whole MATCHDAY scoreboard — every FIFA_WC game on that
-- calendar date, each with its latest score/status — which is correct and useful
-- without ever pinning the wrong game. Single-game days naturally return one row.
-- Score/state comes from the latest espn_event_snapshots row per event (populated by
-- espn-live-score-poll during/near matches); the schedule + team ids come from the
-- espn_event_date_lookup the scoreboard cron maintains. Email-gated, anon revoked.
CREATE OR REPLACE FUNCTION public.get_wc_espn(p_sg_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_email text := coalesce(auth.jwt()->>'email', '');
  v_date date; v_result jsonb;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;

  SELECT event_date INTO v_date FROM public.world_cup_2026 WHERE sg_event_id = p_sg_event_id LIMIT 1;
  IF v_date IS NULL THEN
    RETURN jsonb_build_object('has_data', false, 'note', 'match not in world_cup_2026');
  END IF;

  WITH day_games AS (
    SELECT l.espn_event_id, l.game_at_utc, l.home_team_id, l.away_team_id, l.status_short
    FROM public.espn_event_date_lookup l
    WHERE l.espn_league = 'FIFA_WC' AND (l.game_at_utc AT TIME ZONE 'UTC')::date = v_date
  ),
  snap AS (
    SELECT DISTINCT ON (espn_event_id) espn_event_id, state, status_short, home_score, away_score, captured_at
    FROM public.espn_event_snapshots
    WHERE espn_league = 'FIFA_WC' AND espn_event_id IN (SELECT espn_event_id FROM day_games)
    ORDER BY espn_event_id, captured_at DESC
  )
  SELECT jsonb_build_object(
    'has_data', (SELECT count(*) > 0 FROM day_games),
    'match_date', v_date,
    'game_count', (SELECT count(*) FROM day_games),
    'games', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'espn_event_id', g.espn_event_id,
        'kickoff', g.game_at_utc,
        'home_team', coalesce(hp.external_name, g.home_team_id),
        'away_team', coalesce(ap.external_name, g.away_team_id),
        'state', s.state,
        'status_short', coalesce(s.status_short, g.status_short),
        'home_score', s.home_score, 'away_score', s.away_score,
        'last_capture', s.captured_at) ORDER BY g.game_at_utc), '[]'::jsonb)
      FROM day_games g
      LEFT JOIN snap s ON s.espn_event_id = g.espn_event_id
      LEFT JOIN public.performer_external_ids hp ON hp.source='espn' AND hp.external_id = g.home_team_id
      LEFT JOIN public.performer_external_ids ap ON ap.source='espn' AND ap.external_id = g.away_team_id)
  ) INTO v_result;

  RETURN v_result;
END $func$;

REVOKE ALL ON FUNCTION public.get_wc_espn(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_wc_espn(bigint) TO authenticated;
