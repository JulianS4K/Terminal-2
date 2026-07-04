-- Extend get_espn_event_extras to surface the new racing + MMA pipelines at the
-- EVENT level, branching by the event's ESPN league:
--   * racing (F1 races today; NASCAR maps if events appear) -> series standings
--     (espn_racing_standings, top 15 by rank).
--   * MMA/UFC -> the stored fight card (espn_mma_events by espn_event_id); the
--     `espn` edge fn still renders it on-demand, this makes it part of the panel.
--   * team sports -> the existing home/away transactions + stat leaders.
-- The event page (event.js) renders by the returned `kind`.

CREATE OR REPLACE FUNCTION public.get_espn_event_extras(p_event_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_email text; v_league text; v_espn_event_id text; v_home text; v_away text; v_series text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT espn_league, espn_event_id INTO v_league, v_espn_event_id
  FROM public.event_xref WHERE tevo_event_id = p_event_id LIMIT 1;
  IF v_league IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'no_espn_event_xref');
  END IF;

  v_series := CASE lower(v_league)
    WHEN 'f1' THEN 'f1'
    WHEN 'nascar' THEN 'nascar-cup'
    WHEN 'nascar-cup' THEN 'nascar-cup'
    WHEN 'nascar-xfinity' THEN 'nascar-xfinity'
    WHEN 'nascar-truck' THEN 'nascar-truck'
    ELSE NULL END;
  IF v_series IS NOT NULL THEN
    RETURN jsonb_build_object('kind', 'racing', 'series', v_series, 'espn_league', v_league, 'hidden', false,
      'standings', coalesce((
        SELECT jsonb_agg(to_jsonb(s) ORDER BY s.rank)
        FROM (SELECT rank, driver_name, driver_abbr, country, points, wins
              FROM public.espn_racing_standings WHERE series = v_series ORDER BY rank LIMIT 15) s), '[]'::jsonb));
  END IF;

  IF lower(v_league) IN ('ufc', 'mma') THEN
    RETURN jsonb_build_object('kind', 'mma', 'espn_league', v_league, 'hidden', false,
      'card', (SELECT to_jsonb(m) FROM (
        SELECT name, event_date, venue, fights, fight_count
        FROM public.espn_mma_events WHERE espn_event_id = v_espn_event_id) m));
  END IF;

  SELECT s.home_team_id, s.away_team_id INTO v_home, v_away
  FROM public.espn_event_snapshots s
  WHERE s.espn_event_id = v_espn_event_id ORDER BY s.captured_at DESC LIMIT 1;
  RETURN jsonb_build_object('kind', 'team', 'espn_league', v_league, 'hidden', false,
    'home', public._espn_team_extras(v_home, v_league),
    'away', public._espn_team_extras(v_away, v_league));
END $function$;
