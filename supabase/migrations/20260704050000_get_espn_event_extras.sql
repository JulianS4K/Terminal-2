-- Event-level ESPN extras: both teams' recent transactions + stat leaders, for
-- the terminal event page's ESPN panel. A standalone lazy-loaded RPC so the
-- large get_broker_event_page_v2 RPC stays untouched.
--
-- Team resolution: event_xref -> latest espn_event_snapshots (home/away team id)
-- + espn_league. Leaders use the league-primary stat (MLB home runs, NBA/WNBA
-- points; NFL has no stats pipeline -> empty). Joined by canonical abbreviation.

-- Per-team helper: { transactions:[...5], leaders:[...5], stat_label }.
CREATE OR REPLACE FUNCTION public._espn_team_extras(p_team_id text, p_league text)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_abbr text; v_txns jsonb; v_leaders jsonb;
  v_cat text; v_key text; v_label text;
BEGIN
  IF p_team_id IS NULL THEN RETURN NULL; END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.txn_date DESC), '[]'::jsonb)
  INTO v_txns FROM (
    SELECT txn_date, description, team_abbr, team_display_name
    FROM public.espn_transactions
    WHERE espn_team_id = p_team_id AND espn_league = p_league
    ORDER BY txn_date DESC NULLS LAST LIMIT 5
  ) t;

  SELECT abbreviation INTO v_abbr
  FROM public.espn_teams_canonical WHERE espn_team_id = p_team_id AND espn_league = p_league LIMIT 1;
  v_cat   := CASE WHEN p_league = 'MLB' THEN 'batting' ELSE 'general' END;
  v_key   := CASE WHEN p_league = 'MLB' THEN 'homeRuns' ELSE 'avgPoints' END;
  v_label := CASE WHEN p_league = 'MLB' THEN 'HR' ELSE 'PPG' END;

  IF v_abbr IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.val DESC), '[]'::jsonb) INTO v_leaders FROM (
      SELECT athlete_name, position,
        coalesce(nullif(nullif(stats->>v_key, '-'), '--'), stats_num->>v_key) AS stat_display,
        (stats_num->>v_key)::numeric AS val
      FROM public.espn_player_stats
      WHERE espn_league = p_league AND category = v_cat AND lower(team_abbr) = lower(v_abbr)
        AND stats_num ? v_key AND (stats_num->>v_key) ~ '^-?[0-9.]+$'
      ORDER BY (stats_num->>v_key)::numeric DESC LIMIT 5
    ) x;
  ELSE
    v_leaders := '[]'::jsonb;
  END IF;

  RETURN jsonb_build_object('espn_team_id', p_team_id, 'stat_label', v_label,
                            'transactions', coalesce(v_txns, '[]'::jsonb),
                            'leaders', coalesce(v_leaders, '[]'::jsonb));
END $function$;

CREATE OR REPLACE FUNCTION public.get_espn_event_extras(p_event_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_league text; v_home text; v_away text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT ex.espn_league, s.home_team_id, s.away_team_id INTO v_league, v_home, v_away
  FROM public.event_xref ex
  JOIN LATERAL (
    SELECT home_team_id, away_team_id FROM public.espn_event_snapshots s
    WHERE s.espn_event_id = ex.espn_event_id ORDER BY captured_at DESC LIMIT 1
  ) s ON true
  WHERE ex.tevo_event_id = p_event_id LIMIT 1;

  IF v_league IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'no_espn_event_xref');
  END IF;

  RETURN jsonb_build_object(
    'espn_league', v_league,
    'home', public._espn_team_extras(v_home, v_league),
    'away', public._espn_team_extras(v_away, v_league),
    'hidden', false
  );
END $function$;

comment on function public.get_espn_event_extras is
  'Event-level ESPN extras (both teams: recent transactions + stat leaders) for the terminal event ESPN panel.';
