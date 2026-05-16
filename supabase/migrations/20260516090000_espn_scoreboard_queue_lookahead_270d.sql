-- Migration 20260516090000 · admin · bump espn_scoreboard_queue default 90d → 270d · pre:20260516080000
--
-- This session surfaced: the espn_scoreboard_queue_4h cron passes no args, so
-- defaults to 90d lookahead. That captured NFL preseason (Aug) but missed the
-- full regular season Oct-Jan when the NFL released the 2026 schedule.
--
-- Bumping the default to 270d means the daily cron auto-captures the full NFL
-- season (~22 weeks) + MLB Aug-Apr + NBA Oct-June without future operator
-- intervention each fall.
--
-- Cost impact: minimal. Each league makes 1 HTTP call per cron firing regardless
-- of lookahead (the ESPN scoreboard endpoint accepts a date range param). 7 leagues
-- × 1 call/day = 7 ESPN calls/day, unchanged. The processed payload is bigger
-- (more events per call) but ESPN's limit=1000 cap handles it.
--
-- Verified manually 2026-05-16: espn_scoreboard_queue(270) returned 322 NFL games
-- in single call (compared to 8 with 90d). 1,403 future MLB games, 308 WNBA, 323 MLS.
--
-- MLB still uses two-call split (past 30 + next 30, then next 30 to far) per
-- existing logic — that split is unchanged because MLB events span the full year
-- and ESPN's limit=1000 needs 2 fetches to cover.
--
-- ## Already applied to prod  Applied via MCP 2026-05-16.

CREATE OR REPLACE FUNCTION public.espn_scoreboard_queue(p_lookahead_days integer DEFAULT 270)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  cfg RECORD; v_req bigint; v_count int := 0;
  v_back text   := to_char(current_date - 30, 'YYYYMMDD');
  v_mid  text   := to_char(current_date + 30, 'YYYYMMDD');
  v_far  text   := to_char(current_date + p_lookahead_days, 'YYYYMMDD');
BEGIN
  FOR cfg IN
    SELECT * FROM (VALUES
      ('basketball','nba','NBA',          v_back || '-' || v_far),
      ('football','nfl','NFL',            v_back || '-' || v_far),
      ('baseball','mlb','MLB',            v_back || '-' || v_mid),  -- past 30 + next 30
      ('baseball','mlb','MLB',            v_mid  || '-' || v_far),  -- next 30 to far
      ('hockey','nhl','NHL',              v_back || '-' || v_far),
      ('basketball','wnba','WNBA',        v_back || '-' || v_far),
      ('soccer','usa.1','MLS',            v_back || '-' || v_far)
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
END $function$;
