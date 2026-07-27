-- ============================================================================
-- Migration 20260708131000 — Wire NWSL / CFL / NCAAF into the event matcher
--
-- Lane:     data plane (A1)
-- Touches:  espn_scoreboard_queue()      (add 3 scoreboard pulls)
--           match_events_to_espn_tick()  (add 3 slug-CASE arms)
--
-- Companion to 20260708130000 (which seeds the teams + performer xref). Those
-- xref rows let the matcher resolve home/away teams; these two functions feed it:
--   * espn_scoreboard_queue populates espn_event_date_lookup (the (home,away,date)
--     table the strict matcher joins against) — a league absent from its VALUES
--     list never gets pulled, so games never match.
--   * match_events_to_espn_tick's espn_slug CASE returned NULL for any league not
--     listed; event_xref.espn_slug is written from it, so a missing arm would
--     break the insert. Both are extended for NWSL, CFL, NCAAF.
--
-- Only the two functions are CREATE OR REPLACE'd; the cron schedules from
-- 20260510120000 are untouched (they call these functions by name).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Scoreboard queue — add NWSL, CFL, NCAAF pulls
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION espn_scoreboard_queue(p_lookahead_days int DEFAULT 90)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  cfg RECORD; v_req bigint; v_count int := 0;
  v_back text := to_char(current_date - 30, 'YYYYMMDD');
  v_mid  text := to_char(current_date + 30, 'YYYYMMDD');
  v_far  text := to_char(current_date + p_lookahead_days, 'YYYYMMDD');
BEGIN
  FOR cfg IN
    SELECT * FROM (VALUES
      ('basketball','nba','NBA',   v_back || '-' || v_far),
      ('football','nfl','NFL',     v_back || '-' || v_far),
      ('baseball','mlb','MLB',     v_back || '-' || v_mid),
      ('baseball','mlb','MLB',     v_mid  || '-' || v_far),
      ('hockey','nhl','NHL',       v_back || '-' || v_far),
      ('basketball','wnba','WNBA', v_back || '-' || v_far),
      ('soccer','usa.1','MLS',     v_back || '-' || v_far),
      -- new leagues (2026-07-08)
      ('soccer','usa.nwsl','NWSL',            v_back || '-' || v_far),
      ('football','cfl','CFL',                v_back || '-' || v_far),
      ('football','college-football','NCAAF', v_back || '-' || v_far)
    ) AS x(sport, league_path, league_label, date_range)
  LOOP
    SELECT net.http_get(
      url := 'https://site.api.espn.com/apis/site/v2/sports/' || cfg.sport || '/' || cfg.league_path || '/scoreboard',
      params := jsonb_build_object('dates', cfg.date_range, 'limit', '1000'),
      headers := jsonb_build_object('Accept','application/json','User-Agent','terminal-2-broker (julian@s4kent.com)'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO espn_scoreboard_pending(espn_league, request_id) VALUES (cfg.league_label, v_req);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END $$;

COMMENT ON FUNCTION espn_scoreboard_queue(integer) IS
  '10 ESPN scoreboard pulls per tick (MLB chunked; NWSL/CFL/NCAAF added '
  '2026-07-08). NCAAF is seasonal — its window is empty out of season and '
  'well under the 1000-event cap during the Aug-Jan season.';

-- ----------------------------------------------------------------------------
-- (2) Strict matcher — add NWSL / CFL / NCAAF to the espn_slug CASE
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION match_events_to_espn_tick(p_limit int DEFAULT 10)
RETURNS TABLE(considered int, matched int, no_data int, skipped int)
LANGUAGE plpgsql AS $$
DECLARE
  e RECORD; m RECORD;
  v_considered int := 0; v_matched int := 0; v_no_data int := 0; v_skipped int := 0;
  v_home_team text; v_home_league text; v_away_perf_id bigint; v_away_team text; v_away_league text;
BEGIN
  FOR e IN
    SELECT ev.id, ev.name, ev.occurs_at_local, ev.primary_performer_id,
           trim(split_part(ev.name, ' at ', 1)) AS away_name_raw,
           ev.occurs_at_local::date AS event_date
    FROM events ev
    WHERE ev.event_type = 'game'
      AND ev.primary_performer_id IS NOT NULL
      AND ev.name ILIKE '% at %'
      AND ev.occurs_at_local::timestamptz BETWEEN now() - interval '7 days'
                                              AND now() + interval '90 days'
      AND NOT EXISTS (SELECT 1 FROM event_xref ex
                       WHERE ex.tevo_event_id = ev.id
                         AND ex.match_method LIKE 'in_db_strict_v%')
    ORDER BY ev.occurs_at_local
    LIMIT p_limit
  LOOP
    v_considered := v_considered + 1;

    SELECT espn_team_id, espn_league INTO v_home_team, v_home_league
    FROM performer_espn_team_xref WHERE tevo_performer_id = e.primary_performer_id LIMIT 1;
    IF v_home_team IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT pm.performer_id INTO v_away_perf_id FROM performer_metadata pm
    WHERE lower(trim(pm.name)) = lower(trim(e.away_name_raw)) LIMIT 1;
    IF v_away_perf_id IS NULL THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT espn_team_id, espn_league INTO v_away_team, v_away_league
    FROM performer_espn_team_xref WHERE tevo_performer_id = v_away_perf_id AND espn_league = v_home_league LIMIT 1;
    IF v_away_team IS NULL OR v_away_league <> v_home_league THEN v_skipped := v_skipped + 1; CONTINUE; END IF;

    SELECT * INTO m FROM espn_event_date_lookup edl
    WHERE edl.espn_league = v_home_league
      AND edl.home_team_id = v_home_team
      AND edl.away_team_id = v_away_team
      AND (edl.game_at_utc AT TIME ZONE 'America/Los_Angeles')::date = e.event_date
    LIMIT 1;
    IF NOT FOUND THEN v_no_data := v_no_data + 1; CONTINUE; END IF;

    INSERT INTO event_xref(tevo_event_id, espn_event_id, espn_league, espn_slug,
                           match_method, meta, matched_at)
    VALUES (e.id, m.espn_event_id, m.espn_league,
      CASE m.espn_league
        WHEN 'NBA' THEN 'basketball/nba' WHEN 'NFL' THEN 'football/nfl'
        WHEN 'MLB' THEN 'baseball/mlb'   WHEN 'NHL' THEN 'hockey/nhl'
        WHEN 'WNBA' THEN 'basketball/wnba' WHEN 'MLS' THEN 'soccer/usa.1'
        WHEN 'NWSL' THEN 'soccer/usa.nwsl' WHEN 'CFL' THEN 'football/cfl'
        WHEN 'NCAAF' THEN 'football/college-football' END,
      'in_db_strict_v1',
      jsonb_build_object('home_team_id', v_home_team, 'away_team_id', v_away_team,
                         'event_date', e.event_date, 'tevo_name', e.name,
                         'matched_via', 'in_db_strict_v1_pt_date'),
      now())
    ON CONFLICT (tevo_event_id) DO UPDATE SET
      espn_event_id = EXCLUDED.espn_event_id, espn_league = EXCLUDED.espn_league,
      espn_slug = EXCLUDED.espn_slug, match_method = EXCLUDED.match_method,
      meta = EXCLUDED.meta, matched_at = now();
    v_matched := v_matched + 1;
  END LOOP;
  RETURN QUERY SELECT v_considered, v_matched, v_no_data, v_skipped;
END $$;
