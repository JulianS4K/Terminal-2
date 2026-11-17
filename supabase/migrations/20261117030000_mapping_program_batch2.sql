-- Migration 20261117030000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:espn_scoreboard_queue() fn (host), _ingest_espn_scoreboard() fn (host) · reads:net._http_response · pre:20261117020000
--
-- MAPPING PROGRAM, BATCH 2 (KANBAN "Mapping program" MAP-9 = A1-DB-21). Whole definitions (MIGRATION_CONVENTIONS §6a).
--
-- MAP-9 · the game -> ESPN matcher has been starving since 2026-08-05. espn_scoreboard_queue() (cron 156, daily
--   04:00) and _ingest_espn_scoreboard() still fetch https://site.api.espn.com/..., which has answered every
--   request from the database with an Akamai 403 since 08-05 (750 of 750); espn_event_date_lookup was last fed
--   on 2026-08-04, so match_events_to_espn_tick (cron 168) finds nothing to join and the event_xref-keyed
--   features (gameday snapshots, odds, injuries-on-event, prediction-market links) reach only the games the
--   edge-function backfill catches. The edge functions moved to https://site.web.api.espn.com/... on
--   2026-09-11 (supabase/functions/espn-collect, espn-league-collect) and have fetched from it since; both
--   hosts serve the same scoreboard document (probed 2026-11-17: 200, identical size). Two changes in the two
--   functions: the host, and the User-Agent is the plain product string 'terminal-2-broker' on both (the queue
--   function carried a personal mailbox in it). Same path, parameters and parsing.
-- Nothing upstream is written (RULE 2): both are GETs of a public API.
-- Rollback: put 'site.api.espn.com' back in both functions (the current prod definitions).

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public._ingest_espn_scoreboard(p_sport text, p_league_path text, p_league_label text, p_lookahead_days integer DEFAULT 90)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_req bigint; v_body jsonb; v_status int; v_count int := 0; feat jsonb;
  v_start text := to_char(current_date - 30, 'YYYYMMDD');
  v_end   text := to_char(current_date + p_lookahead_days, 'YYYYMMDD');
  v_tries int := 0;
BEGIN
  SELECT net.http_get(
    url := 'https://site.web.api.espn.com/apis/site/v2/sports/' || p_sport || '/' || p_league_path || '/scoreboard',
    params := jsonb_build_object('dates', v_start || '-' || v_end, 'limit', '1000'),
    headers := jsonb_build_object('Accept','application/json','User-Agent','terminal-2-broker'),
    timeout_milliseconds := 60000
  ) INTO v_req;

  -- Up to 60s of polling
  WHILE v_tries < 60 LOOP
    PERFORM pg_sleep(1);
    SELECT status_code INTO v_status FROM net._http_response WHERE id = v_req;
    EXIT WHEN v_status IS NOT NULL;
    v_tries := v_tries + 1;
  END LOOP;

  IF v_status IS NULL THEN RETURN -1; END IF;
  IF v_status <> 200 THEN RETURN -2; END IF;

  SELECT content::jsonb INTO v_body FROM net._http_response WHERE id = v_req;

  FOR feat IN SELECT jsonb_array_elements(v_body -> 'events') LOOP
    IF (feat ->> 'id') IS NOT NULL THEN
      INSERT INTO espn_event_date_lookup(espn_event_id, espn_league, game_at_utc,
                                          home_team_id, away_team_id, status_short)
      SELECT feat ->> 'id', p_league_label, (feat ->> 'date')::timestamptz,
        (SELECT (c->'team'->>'id') FROM jsonb_array_elements(feat->'competitions'->0->'competitors') c WHERE c->>'homeAway' = 'home' LIMIT 1),
        (SELECT (c->'team'->>'id') FROM jsonb_array_elements(feat->'competitions'->0->'competitors') c WHERE c->>'homeAway' = 'away' LIMIT 1),
        feat -> 'status' -> 'type' ->> 'shortDetail'
      ON CONFLICT (espn_event_id, espn_league) DO UPDATE SET
        game_at_utc=EXCLUDED.game_at_utc, home_team_id=EXCLUDED.home_team_id,
        away_team_id=EXCLUDED.away_team_id, status_short=EXCLUDED.status_short, ingested_at=now();
      v_count := v_count + 1;
    END IF;
  END LOOP;
  RETURN v_count;
END $function$;

CREATE OR REPLACE FUNCTION public.espn_scoreboard_queue(p_lookahead_days integer DEFAULT 90)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
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
      ('soccer','usa.nwsl','NWSL',            v_back || '-' || v_far),
      ('football','cfl','CFL',                v_back || '-' || v_far),
      ('football','college-football','NCAAF', v_back || '-' || v_far)
    ) AS x(sport, league_path, league_label, date_range)
  LOOP
    SELECT net.http_get(
      url := 'https://site.web.api.espn.com/apis/site/v2/sports/' || cfg.sport || '/' || cfg.league_path || '/scoreboard',
      params := jsonb_build_object('dates', cfg.date_range, 'limit', '1000'),
      headers := jsonb_build_object('Accept','application/json','User-Agent','terminal-2-broker'),
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO espn_scoreboard_pending(espn_league, request_id) VALUES (cfg.league_label, v_req);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END $function$;

COMMIT;

-- VERIFY (after the 04:00 run, or SELECT public.espn_scoreboard_queue(90) by hand):
--   SELECT espn_league, status_code FROM espn_scoreboard_pending p JOIN net._http_response r ON r.id = p.request_id ORDER BY p.request_id DESC LIMIT 10;   -- 200s
--   SELECT espn_league, max(ingested_at) FROM espn_event_date_lookup GROUP BY 1;                                                                           -- today
