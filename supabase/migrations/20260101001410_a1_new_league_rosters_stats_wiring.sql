-- ============================================================================
-- Migration 20260708160000 — Wire NWSL/CFL/NCAAF into roster + stats collection
--
-- Lane:     data plane (A1)
-- Touches:  performer_external_ids (W: enroll CFL canonical teams),
--           fantasy_points() (add CFL -> football),
--           cron.job (new daily roster cron for the new leagues)
--
-- Operator directive (2026-07-08): "wire them in and finish connecting, also
--   pull their stats." Rosters for NWSL + NCAAF were collected via espn-rosters
--   (they were already enrolled in performer_external_ids from the standings
--   work). CFL had zero Tevo inventory so it was never enrolled — this migration
--   enrolls its 9 ESPN canonical teams with synthetic performer_ids (900000000 +
--   espn_team_id; well clear of the ~136k real Tevo id range, no FK on the
--   column) so CFL flows through every existing pipeline (standings, rosters,
--   stats) like every other league.
--
-- Companion edge change: espn-league-collect GAMELOG_LEAGUES/STATS_CONFIG extended
-- for CFL + NCAAF (+ NWSL season stats). fantasy_points() gains CFL below so CFL
-- gamelogs score on the football ruleset (NCAAF already mapped).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Enroll CFL canonical teams so roster/standings/stats collectors see them
-- ----------------------------------------------------------------------------
INSERT INTO performer_external_ids (performer_id, source, external_id, external_name, league, meta)
SELECT 900000000 + etc.espn_team_id::int, 'espn', etc.espn_team_id, etc.display_name, 'CFL',
       jsonb_build_object('espn_slug', 'football/cfl',
                          'backfilled_from', 'cfl_canonical_enroll_20260708',
                          'synthetic_performer', true)
FROM espn_teams_canonical etc
WHERE etc.espn_league = 'CFL'
ON CONFLICT (performer_id, source) DO NOTHING;

-- ----------------------------------------------------------------------------
-- (2) fantasy_points: CFL scores on the football ruleset
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fantasy_points(p_league text, p_stats jsonb)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_sport text; v_rules jsonb; v_sub jsonb; v_pts numeric := 0; k text; v text;
BEGIN
  IF p_stats IS NULL THEN RETURN NULL; END IF;
  v_sport := CASE p_league
    WHEN 'MLB'  THEN 'baseball'
    WHEN 'NBA'  THEN 'basketball'
    WHEN 'WNBA' THEN 'basketball'
    WHEN 'NFL'  THEN 'football'
    WHEN 'NCAAF' THEN 'football'
    WHEN 'CFL'  THEN 'football'
    ELSE NULL END;
  IF v_sport IS NULL THEN RETURN NULL; END IF;
  SELECT rules INTO v_rules FROM fantasy_scoring_rulesets WHERE sport = v_sport AND is_default LIMIT 1;
  IF v_rules IS NULL THEN RETURN NULL; END IF;
  IF v_rules->>'__mode__' = 'split' THEN
    IF p_stats ? (v_rules->>'pitch_when') THEN v_sub := v_rules->'pitch'; ELSE v_sub := v_rules->'bat'; END IF;
  ELSE v_sub := v_rules; END IF;
  FOR k, v IN SELECT key, value FROM jsonb_each_text(v_sub) LOOP
    CONTINUE WHEN k LIKE '\_\_%' OR v !~ '^-?[0-9]+(\.[0-9]+)?$';
    v_pts := v_pts + coalesce((p_stats->>k)::numeric, 0) * v::numeric;
  END LOOP;
  RETURN round(v_pts, 2);
END $$;

-- ----------------------------------------------------------------------------
-- (3) Daily roster refresh for the new leagues.
--     NWSL + CFL are one league-call each; NCAAF is fired per-team (66) because
--     all-66-in-one-call exceeds the edge wall-clock. pg_sleep spreads the burst.
-- ----------------------------------------------------------------------------
SELECT cron.schedule('espn-rosters-new-leagues-daily', '15 9 * * *', $CRON$
DO $body$
DECLARE t record;
  u text := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/espn-rosters';
BEGIN
  PERFORM public._cron_invoke_edge_fn(u, '{"league":"NWSL"}'::jsonb);
  PERFORM public._cron_invoke_edge_fn(u, '{"league":"CFL"}'::jsonb);
  PERFORM pg_sleep(2);
  FOR t IN SELECT DISTINCT external_id FROM public.performer_external_ids
           WHERE source='espn' AND league='NCAAF' LOOP
    PERFORM public._cron_invoke_edge_fn(u, jsonb_build_object('team_id', t.external_id));
    PERFORM pg_sleep(0.5);
  END LOOP;
END $body$;
$CRON$);
