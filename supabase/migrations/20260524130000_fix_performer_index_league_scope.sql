-- 20260524130000_fix_performer_index_league_scope.sql
--
-- ## Already applied to prod — applied via MCP apply_migration 2026-05-24.
--
-- D0 (operator-directed QA fix; crosses into A1's migration lane via the
-- "begin fixing and testing" directive, 2026-05-24).
--
-- BUG (found live on the Performer index page): get_broker_performer_index
--   joins espn_teams_canonical on espn_team_id ALONE. espn_team_id collides
--   across leagues (PROJECT_BIBLE §3 landmine — id reused per league), so each
--   of the 122 clean performer_espn_team_xref rows fans out to every same-id
--   team across leagues. Result: 122 → 425 output rows, and the NFL/NBA/MLB
--   columns each show a cross-league mix (e.g. NHL "Anaheim Ducks", MLB
--   "Diamondbacks", WNBA "Atlanta Dream" all rendered under NFL). MLS happened
--   to look right only because few ids collide into it.
--
-- FIX: scope the canonical join by league too (AND etc.espn_league =
--   xt.espn_league). Verified pre-apply: corrected per-league counts =
--   NFL 32, NBA 30, MLB 30, MLS 30 (= 122, matching the xref). Only change
--   vs the prior definition is that one extra join predicate.
--
-- ROLLBACK: re-create the function with the espn_teams_canonical join keyed on
--   espn_team_id alone.

CREATE OR REPLACE FUNCTION public.get_broker_performer_index()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH base AS (
    SELECT xt.tevo_performer_id, xt.espn_team_id, xt.espn_league,
           ap.performer_name, etc.display_name, etc.abbreviation
    FROM public.performer_espn_team_xref xt
    LEFT JOIN public.aq_performer_map ap ON ap.tevo_performer_id = xt.tevo_performer_id
    LEFT JOIN public.espn_teams_canonical etc
      ON etc.espn_team_id = xt.espn_team_id AND etc.espn_league = xt.espn_league
    WHERE xt.espn_league IN ('NFL','NBA','MLB','MLS') AND xt.tevo_performer_id IS NOT NULL
  ),
  counts AS (
    SELECT b.tevo_performer_id, COUNT(*) AS events_count_next_90d
    FROM base b
    JOIN public.events ev ON ev.primary_performer_id = b.tevo_performer_id
    WHERE ev.occurs_at_local ~ '^\d{4}'
      AND ev.occurs_at_local::timestamptz >= now()
      AND ev.occurs_at_local::timestamptz < now() + interval '90 days'
    GROUP BY b.tevo_performer_id
  ),
  rows0 AS (
    SELECT b.espn_league,
           jsonb_build_object(
             'tevo_performer_id', b.tevo_performer_id, 'performer_name', b.performer_name,
             'espn_team_id', b.espn_team_id, 'abbreviation', b.abbreviation,
             'display_name', b.display_name,
             'events_count_next_90d', coalesce(c.events_count_next_90d, 0)
           ) AS team_obj,
           coalesce(b.display_name, b.performer_name, '') AS sort_key
    FROM base b LEFT JOIN counts c ON c.tevo_performer_id = b.tevo_performer_id
  ),
  per_league AS (
    SELECT espn_league, jsonb_agg(team_obj ORDER BY sort_key) AS teams, COUNT(*) AS team_count
    FROM rows0 GROUP BY espn_league
  )
  SELECT jsonb_build_object(
    'counts',  jsonb_object_agg(espn_league, team_count) ||
               jsonb_build_object('total', (SELECT sum(team_count) FROM per_league)),
    'leagues', jsonb_object_agg(espn_league, teams)
  ) INTO v_result FROM per_league;

  RETURN coalesce(v_result, jsonb_build_object('counts', '{}'::jsonb, 'leagues', '{}'::jsonb));
END $function$;
