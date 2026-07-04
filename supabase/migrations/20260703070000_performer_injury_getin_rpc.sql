-- Migration 20260703070000 · level:standard · lane:D0/A1 · writes:get_performer_injury_getin · reads:performer_espn_team_xref,espn_injuries_snapshots,events,event_listing_snapshot_daily · pre:20260703060000
--
-- ESPN injury price-impact — the sports analogue of the Broadway cast-run panel.
-- For a TEAM performer, returns its currently-out players and the team's avg
-- game get-in during each player's out-window: "does a star's absence move
-- ticket prices" (the sports mirror of "does stunt casting move the needle").
--
-- Returns the SAME generic participant contract as the broadway-cast routes —
-- {performer_id, kind:'espn', metric:'get_in_usd', subject, participants[]} —
-- so the terminal reuses window.CastPanel unchanged. A player whose out-window
-- overlaps no priced games comes back measured=false (ghost), like an
-- awaiting-coverage Broadway lead.
--
-- Called server-side by /api/broker/performer/{id}/injury-getin (service_role);
-- the route's require_auth is the gate, so this RPC is NOT email-gated (unlike
-- the frontend-called get_broker_performer_index). Degrades to applicable=false
-- for a non-team performer / no current injuries.
--
-- Notes on the metric (honest, like the Broadway coverage counts):
--   * "out" = status matching out / *-IL / injured reserve / suspension.
--   * one row per athlete_name (the injuries source carries duplicate
--     athlete_ids for the same player); most-recent snapshot wins.
--   * only players seen out in the last 21 days (current), capped at 14.
--   * out-window = first out-capture in the last 120d → return_date (or +14d if
--     ongoing); avg_getin = team games in that window we actually priced.

CREATE OR REPLACE FUNCTION public.get_performer_injury_getin(p_performer_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_team text; v_league text; v_name text; v_result jsonb;
BEGIN
  SELECT espn_team_id, espn_league INTO v_team, v_league
  FROM public.performer_espn_team_xref
  WHERE tevo_performer_id = p_performer_id
  LIMIT 1;

  IF v_team IS NULL THEN
    RETURN jsonb_build_object('performer_id', p_performer_id, 'applicable', false,
      'kind', 'espn', 'metric', 'get_in_usd', 'subject', NULL, 'participants', '[]'::jsonb);
  END IF;

  SELECT primary_performer_name INTO v_name
  FROM public.events WHERE primary_performer_id = p_performer_id LIMIT 1;

  WITH latest AS (
    SELECT DISTINCT ON (athlete_name)
           athlete_name, position, status, injury_type, return_date, captured_at
    FROM public.espn_injuries_snapshots
    WHERE espn_team_id = v_team AND espn_league = v_league
    ORDER BY athlete_name, captured_at DESC
  ),
  out_now AS (
    SELECT * FROM latest
    WHERE status ~* '(out|IL|injured reserve|suspension)'
      AND captured_at >= now() - interval '21 days'
  ),
  win AS (
    SELECT o.athlete_name, o.position, o.status, o.injury_type, o.return_date,
      (SELECT min(i2.captured_at)::date FROM public.espn_injuries_snapshots i2
         WHERE i2.athlete_name = o.athlete_name AND i2.espn_team_id = v_team
           AND i2.status ~* '(out|IL|injured reserve|suspension)'
           AND i2.captured_at >= now() - interval '120 days') AS win_start,
      COALESCE(o.return_date::date, (now() + interval '14 days')::date) AS win_end
    FROM out_now o
  ),
  priced AS (
    SELECT w.athlete_name, w.position, w.status, w.injury_type, w.return_date,
           w.win_start, w.win_end,
           count(DISTINCT s.event_id)      AS games_priced,
           round(avg(s.amalgam_getin), 2)  AS avg_getin,
           round(min(s.amalgam_getin), 2)  AS min_getin,
           round(max(s.amalgam_getin), 2)  AS max_getin
    FROM win w
    LEFT JOIN public.events e
      ON e.primary_performer_id = p_performer_id
     AND e.occurs_at_local ~ '^\d{4}'
     AND e.occurs_at_local::date BETWEEN w.win_start AND w.win_end
    LEFT JOIN public.event_listing_snapshot_daily s
      ON s.event_id = e.id AND s.amalgam_getin IS NOT NULL
    GROUP BY w.athlete_name, w.position, w.status, w.injury_type, w.return_date, w.win_start, w.win_end
  ),
  top AS (SELECT * FROM priced ORDER BY win_start DESC LIMIT 14)
  SELECT jsonb_build_object(
    'performer_id', p_performer_id, 'kind', 'espn', 'metric', 'get_in_usd',
    'subject', jsonb_build_object('slug', v_team, 'title', COALESCE(v_name, 'Team')),
    'applicable', (SELECT count(*) > 0 FROM top),
    'participants', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'name', athlete_name, 'role', position, 'status', status,
        'window_start', win_start, 'window_end', win_end,
        'sub', 'OUT · ' || COALESCE(position, '—')
               || COALESCE(' · ' || injury_type, '')
               || COALESCE(' · back ' || to_char(return_date, 'Mon FMDD'), ' · ongoing'),
        'measured', games_priced > 0,
        'avg_getin', avg_getin, 'min_getin', min_getin, 'max_getin', max_getin,
        'perfs_priced', games_priced, 'snapshot_rows', games_priced
      ) ORDER BY win_start DESC)
      FROM top
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN COALESCE(v_result, jsonb_build_object('performer_id', p_performer_id,
    'applicable', false, 'kind', 'espn', 'metric', 'get_in_usd',
    'subject', NULL, 'participants', '[]'::jsonb));
END $function$;

REVOKE ALL ON FUNCTION public.get_performer_injury_getin(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_performer_injury_getin(bigint) TO service_role;
