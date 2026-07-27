-- Migration 20260518010000 · lane:D0 (author) → A1 (apply) · writes:get_broker_performer_index + get_broker_performer_page · reads:performer_espn_team_xref,aq_performer_map,espn_teams_canonical,espn_team_snapshots,espn_injuries_snapshots,espn_event_snapshots,events · pre:none · auth:operator-approved 2026-05-17
--
-- D0 Phase 2b — two SECDEF RPCs powering the new performer page:
--   1. get_broker_performer_index()   — 4-league directory (NFL/NBA/MLB/MLS) for the INDEX mode
--   2. get_broker_performer_page(p)   — ESPN context (standings + injuries + recent results) for the DETAIL ESPN tab
--
-- Per A1 pre-flight audit (bot_chat #299):
--   #1 League filter sourced from performer_espn_team_xref (canonical 32/30/30/30, UPPERCASE codes)
--      — NOT from aq_performer_map.category (only Sports/Concerts/Comedy/NULL — zero league granularity)
--   #2 Injury filter: `lower(status) <> 'active' AND status IS NOT NULL`
--      — values are mixed-case (Out/Day-To-Day/Questionable/*-Day-IL/Active); no 'doubtful'
--   #3 espn_event_snapshots ORDER BY captured_at (occurs_at_utc doesn't exist); state='post' filter
--   #4 events.occurs_at_local is TEXT — guard with regex + cast to timestamptz
--   #6 espn_team_snapshots has 8K dupes for 32×6 teams — DISTINCT ON (espn_team_id) mandatory
--
-- Both follow canonical v3 SECDEF: @s4kent.com gate, REVOKE PUBLIC + GRANT anon/auth.

-- ============================================================
-- 1. Performer Index (4-league directory)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_broker_performer_index()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH base AS (
    SELECT
      xt.tevo_performer_id,
      xt.espn_team_id,
      xt.espn_league,
      ap.performer_name,
      etc.display_name,
      etc.abbreviation
    FROM public.performer_espn_team_xref xt
    LEFT JOIN public.aq_performer_map ap ON ap.tevo_performer_id = xt.tevo_performer_id
    LEFT JOIN public.espn_teams_canonical etc ON etc.espn_team_id = xt.espn_team_id
    WHERE xt.espn_league IN ('NFL','NBA','MLB','MLS')
      AND xt.tevo_performer_id IS NOT NULL
  ),
  counts AS (
    SELECT b.tevo_performer_id,
           COUNT(*) AS events_count_next_90d
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
             'tevo_performer_id', b.tevo_performer_id,
             'performer_name',    b.performer_name,
             'espn_team_id',      b.espn_team_id,
             'abbreviation',      b.abbreviation,
             'display_name',      b.display_name,
             'events_count_next_90d', coalesce(c.events_count_next_90d, 0)
           ) AS team_obj,
           coalesce(b.display_name, b.performer_name, '') AS sort_key
    FROM base b
    LEFT JOIN counts c ON c.tevo_performer_id = b.tevo_performer_id
  ),
  per_league AS (
    SELECT espn_league,
           jsonb_agg(team_obj ORDER BY sort_key) AS teams,
           COUNT(*) AS team_count
    FROM rows0
    GROUP BY espn_league
  )
  SELECT jsonb_build_object(
    'counts',  jsonb_object_agg(espn_league, team_count) ||
               jsonb_build_object('total', (SELECT sum(team_count) FROM per_league)),
    'leagues', jsonb_object_agg(espn_league, teams)
  )
  INTO v_result
  FROM per_league;

  RETURN coalesce(v_result, jsonb_build_object('counts', '{}'::jsonb, 'leagues', '{}'::jsonb));
END $func$;

REVOKE ALL ON FUNCTION public.get_broker_performer_index() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_performer_index() TO anon, authenticated;

COMMENT ON FUNCTION public.get_broker_performer_index() IS
  'D0 performer page INDEX mode — NFL/NBA/MLB/MLS teams grouped by league. UPPERCASE codes per performer_espn_team_xref. Email-gated.';

-- ============================================================
-- 2. Performer Page (ESPN context for DETAIL tab)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_broker_performer_page(p_performer_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email     text;
  v_team_id   text;
  v_league    text;
  v_standings jsonb;
  v_injuries  jsonb;
  v_recent    jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Resolve ESPN xref for this performer
  SELECT espn_team_id, espn_league INTO v_team_id, v_league
  FROM public.performer_espn_team_xref
  WHERE tevo_performer_id = p_performer_id
  LIMIT 1;

  IF v_team_id IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'no_espn_xref');
  END IF;

  -- Standings: latest snap per team via DISTINCT ON (audit fix #6)
  SELECT to_jsonb(s) INTO v_standings
  FROM (
    SELECT DISTINCT ON (espn_team_id)
      wins, losses, ties, win_pct, games_back,
      playoff_seed, conference_rank, division_rank,
      record_summary, standing_summary, streak, captured_at
    FROM public.espn_team_snapshots
    WHERE espn_team_id = v_team_id
    ORDER BY espn_team_id, captured_at DESC
  ) s;

  -- Injuries: latest per athlete, exclude active (audit fix #2)
  SELECT coalesce(jsonb_agg(to_jsonb(i)), '[]'::jsonb)
  INTO v_injuries
  FROM (
    SELECT DISTINCT ON (athlete_id)
      athlete_id, athlete_name, position, status, injury_type,
      short_comment, return_date, captured_at
    FROM public.espn_injuries_snapshots
    WHERE espn_team_id = v_team_id
      AND lower(status) <> 'active'
      AND status IS NOT NULL
    ORDER BY athlete_id, captured_at DESC
  ) i;

  -- Recent results: state='post', latest 5 distinct games (audit fix #3)
  SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.captured_at DESC), '[]'::jsonb)
  INTO v_recent
  FROM (
    SELECT * FROM (
      SELECT DISTINCT ON (espn_event_id)
        espn_event_id, status_short, captured_at,
        home_team_id, away_team_id, home_score, away_score, attendance,
        (home_team_id = v_team_id) AS is_home,
        CASE WHEN home_team_id = v_team_id THEN away_team_id ELSE home_team_id END AS opponent_team_id
      FROM public.espn_event_snapshots
      WHERE state = 'post'
        AND (home_team_id = v_team_id OR away_team_id = v_team_id)
      ORDER BY espn_event_id, captured_at DESC
    ) deduped
    ORDER BY captured_at DESC
    LIMIT 5
  ) e;

  RETURN jsonb_build_object(
    'espn_team_id',   v_team_id,
    'espn_league',    v_league,
    'standings',      v_standings,
    'injuries',       v_injuries,
    'recent_results', v_recent,
    'hidden',         false
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_broker_performer_page(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_broker_performer_page(integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_broker_performer_page(integer) IS
  'D0 performer page ESPN tab — standings (DISTINCT ON espn_team_id) + injuries (lower(status) != active) + recent_results (state=post, last 5 games). Email-gated. Returns {hidden:true, reason:no_espn_xref} for unlinked performers.';
