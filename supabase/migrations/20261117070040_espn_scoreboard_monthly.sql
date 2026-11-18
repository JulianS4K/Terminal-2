-- Migration 20261117070040 · level:data-collection · lane:A1 (data plane — ESPN) · writes:espn_scoreboard_queue() · reads:none · pre:20261117061000
--
-- WHY: espn_scoreboard_queue asks ESPN's scoreboard for a date range (?dates=YYYYMMDD-YYYYMMDD&limit=1000). ESPN
-- stopped serving that form: every request since at least 2026-10-19 came back 403 from the database (400 from
-- elsewhere), 0 events. So espn_event_date_lookup — read by match_events_to_espn_tick, the broker event page, the
-- event chart and the lifecycle — has not been refreshed since 2026-08-04. A month (?dates=YYYYMM&limit=1000) still
-- answers 200 from the database (December NBA: 178 games, checked 2026-11-17).
--
-- CHANGE: espn_scoreboard_queue(p_lookahead_days DEFAULT 180) asks one month at a time, from the month 30 days back
-- through the month p_lookahead_days ahead (72 requests, same daily cron, same pending table). espn_scoreboard_process
-- is unchanged — it already reads any scoreboard body. The User-Agent no longer carries a personal e-mail address.
-- ESPN's ticket block (Vivid ids, "as low as", count) is NOT collected here: espn_ticket_game (the mapping program's
-- ESPN ticket collector, crons espn_ticket_tick_1min / espn_ticket_map_hourly) already keeps it.

BEGIN;
SET LOCAL lock_timeout = '10s';

DROP FUNCTION IF EXISTS public.espn_scoreboard_queue(integer);
CREATE FUNCTION public.espn_scoreboard_queue(p_lookahead_days integer DEFAULT 180)
RETURNS integer LANGUAGE plpgsql AS $function$
DECLARE
  cfg RECORD; v_req bigint; v_count int := 0; v_month date;
BEGIN
  FOR cfg IN
    SELECT * FROM (VALUES
      ('basketball','nba','NBA'),
      ('football','nfl','NFL'),
      ('baseball','mlb','MLB'),
      ('hockey','nhl','NHL'),
      ('basketball','wnba','WNBA'),
      ('soccer','usa.1','MLS'),
      ('soccer','usa.nwsl','NWSL'),
      ('football','cfl','CFL'),
      ('football','college-football','NCAAF')
    ) AS x(sport, league_path, league_label)
  LOOP
    -- ESPN serves a month (dates=YYYYMM); the YYYYMMDD-YYYYMMDD range form is refused
    FOR v_month IN
      SELECT generate_series(date_trunc('month', current_date - 30),
                             date_trunc('month', current_date + p_lookahead_days),
                             interval '1 month')::date
    LOOP
      SELECT net.http_get(
        url := 'https://site.api.espn.com/apis/site/v2/sports/' || cfg.sport || '/' || cfg.league_path || '/scoreboard',
        params := jsonb_build_object('dates', to_char(v_month, 'YYYYMM'), 'limit', '1000'),
        headers := jsonb_build_object('Accept', 'application/json', 'User-Agent', 'terminal-2-broker'),
        timeout_milliseconds := 30000
      ) INTO v_req;
      INSERT INTO espn_scoreboard_pending(espn_league, request_id) VALUES (cfg.league_label, v_req);
      v_count := v_count + 1;
      PERFORM pg_sleep(0.3);
    END LOOP;
  END LOOP;
  RETURN v_count;
END $function$;

REVOKE ALL ON FUNCTION public.espn_scoreboard_queue(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.espn_scoreboard_queue(integer) TO service_role;

COMMIT;

-- VERIFY (after the next 04:00 UTC queue, or SELECT espn_scoreboard_queue() by hand, and the next process tick):
--   SELECT espn_league, http_status, count(*), sum(events_count) FROM espn_scoreboard_pending
--    WHERE fired_at > now() - interval '1 hour' GROUP BY 1,2;            -- 200s, events > 0
--   SELECT max(ingested_at), count(*) FILTER (WHERE game_at_utc > now()) FROM espn_event_date_lookup;
-- ROLLBACK: re-create the range-form espn_scoreboard_queue(integer DEFAULT 90) (it returns nothing).
