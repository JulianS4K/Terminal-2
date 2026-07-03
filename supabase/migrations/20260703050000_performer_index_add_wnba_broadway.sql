-- Migration 20260703050000 · level:standard · lane:broadway (D3)/D0 · writes:get_broker_performer_index · reads:performer_espn_team_xref,broadway_show_ref,events · pre:20260703013000
--
-- Performer-space directory: add two categories alongside the sports leagues.
--   (1) WNBA — the 15 WNBA teams already live in performer_espn_team_xref but
--       were excluded by the league filter (NFL/NBA/MLB/MLS only). Add 'WNBA'.
--   (2) Broadway — a NEW pseudo-league whose "teams" are Broadway SHOWS
--       (broadway_show_ref), the show being the team-analogue and the leads the
--       roster (v_broadway_performer_getin / the Cast tab). Each show entry
--       carries a sample_event_id (most-recent performance) so the directory can
--       link it to the event page's Cast tab; tevo_performer_id is NULL (a show
--       is not a performer), which the frontend uses to pick the link target.
--
-- Only additive: the ESPN team branch is byte-identical to 20260524130000 except
-- the +'WNBA' filter; Broadway is a UNIONed pseudo-league. Email gate unchanged.
-- (Operator-directed, crosses into A1's RPC lane like the 20260524130000 fix.)

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
    WHERE xt.espn_league IN ('NFL','NBA','MLB','MLS','WNBA') AND xt.tevo_performer_id IS NOT NULL
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
  -- Broadway pseudo-league: each broadway_show_ref show is a directory entry.
  bway AS (
    SELECT 'Broadway'::text AS espn_league,
           jsonb_build_object(
             'show_slug', r.show_slug,
             'display_name', r.title,
             'performer_name', r.title,
             'tevo_performer_id', NULL::bigint,
             'sample_event_id', (
               SELECT e.id FROM public.events e
               WHERE e.venue_name ILIKE r.venue_name_pattern
                 AND (r.event_name_pattern IS NULL OR e.name ILIKE r.event_name_pattern)
               ORDER BY e.occurs_at_local DESC LIMIT 1),
             'events_count_next_90d', (
               SELECT count(*) FROM public.events e
               WHERE e.venue_name ILIKE r.venue_name_pattern
                 AND (r.event_name_pattern IS NULL OR e.name ILIKE r.event_name_pattern)
                 AND e.occurs_at_local ~ '^\d{4}'
                 AND e.occurs_at_local::timestamptz >= now()
                 AND e.occurs_at_local::timestamptz < now() + interval '90 days')
           ) AS team_obj,
           r.title AS sort_key
    FROM public.broadway_show_ref r
  ),
  rows_all AS (
    SELECT espn_league, team_obj, sort_key FROM rows0
    UNION ALL
    SELECT espn_league, team_obj, sort_key FROM bway
  ),
  per_league AS (
    SELECT espn_league, jsonb_agg(team_obj ORDER BY sort_key) AS teams, COUNT(*) AS team_count
    FROM rows_all GROUP BY espn_league
  )
  SELECT jsonb_build_object(
    'counts',  jsonb_object_agg(espn_league, team_count) ||
               jsonb_build_object('total', (SELECT sum(team_count) FROM per_league)),
    'leagues', jsonb_object_agg(espn_league, teams)
  ) INTO v_result FROM per_league;

  RETURN coalesce(v_result, jsonb_build_object('counts', '{}'::jsonb, 'leagues', '{}'::jsonb));
END $function$;
