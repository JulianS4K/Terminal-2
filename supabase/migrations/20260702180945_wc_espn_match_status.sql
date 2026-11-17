-- Migration 20260702180945 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "wc_espn_match_status" (version 20260702180945) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

-- Migration · lane:D0 -> A1 · writes(DDL):get_wc_espn · reads:world_cup_2026, espn_event_date_lookup, espn_event_snapshots, performer_external_ids · auth:operator 2026-07-02 ("wire it all into terminal ... ESPN tab")
--
-- ## Applied to prod 2026-07-02 via MCP apply_migration (operator-directed). Idempotent.
--
-- ESPN match score/status for a World Cup match, for the terminal SG-mode ESPN tab.
-- WC matches are SG-native (no TEvo/ESPN id of their own) and their knockout rows
-- are still "TBD", so we bridge to ESPN by SCHEDULE: same calendar day in the
-- FIFA_WC scoreboard feed, closest kickoff time (10/21 upcoming days carry a single
-- WC game -> unambiguous; the rest disambiguate by nearest time). Best-effort — the
-- link firms up as our schedule/teams settle. Returns the latest snapshot (state,
-- status, score) + resolved team names. Email-gated, anon revoked.
CREATE OR REPLACE FUNCTION public.get_wc_espn(p_sg_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_email text := coalesce(auth.jwt()->>'email', '');
  v_date date; v_dt timestamptz; v_espn text;
  v_home text; v_away text; v_snap record;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;

  SELECT event_date, event_datetime INTO v_date, v_dt
  FROM public.world_cup_2026 WHERE sg_event_id = p_sg_event_id LIMIT 1;
  IF v_date IS NULL THEN
    RETURN jsonb_build_object('has_data', false, 'note', 'match not in world_cup_2026');
  END IF;

  SELECT l.espn_event_id INTO v_espn
  FROM public.espn_event_date_lookup l
  WHERE l.espn_league = 'FIFA_WC'
    AND (l.game_at_utc AT TIME ZONE 'UTC')::date = v_date
  ORDER BY abs(extract(epoch FROM l.game_at_utc - coalesce(v_dt, v_date::timestamptz)))
  LIMIT 1;
  IF v_espn IS NULL THEN
    RETURN jsonb_build_object('has_data', false, 'note', 'no ESPN FIFA World Cup game found on this date');
  END IF;

  SELECT state, status_short, home_team_id, away_team_id, home_score, away_score, captured_at
    INTO v_snap
  FROM public.espn_event_snapshots
  WHERE espn_league = 'FIFA_WC' AND espn_event_id = v_espn
  ORDER BY captured_at DESC LIMIT 1;

  SELECT external_name INTO v_home FROM public.performer_external_ids
   WHERE source='espn' AND external_id = coalesce(v_snap.home_team_id,'') LIMIT 1;
  SELECT external_name INTO v_away FROM public.performer_external_ids
   WHERE source='espn' AND external_id = coalesce(v_snap.away_team_id,'') LIMIT 1;

  RETURN jsonb_build_object(
    'has_data', v_snap.status_short IS NOT NULL,
    'espn_event_id', v_espn,
    'state', v_snap.state,
    'status_short', v_snap.status_short,
    'home_team_id', v_snap.home_team_id, 'away_team_id', v_snap.away_team_id,
    'home_team', v_home, 'away_team', v_away,
    'home_score', v_snap.home_score, 'away_score', v_snap.away_score,
    'last_capture', v_snap.captured_at,
    'note', CASE WHEN v_snap.status_short IS NULL
                 THEN 'ESPN event linked; no score snapshot yet (captures once the match is near/live)' END);
END $func$;

REVOKE ALL ON FUNCTION public.get_wc_espn(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_wc_espn(bigint) TO authenticated;
;
