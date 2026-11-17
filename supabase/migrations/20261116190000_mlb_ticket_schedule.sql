-- Migration 20261116190000 · level:data-collection · lane:A1 (data plane — MLB schedule) · writes:mlb_ticket_team(new),mlb_ticket_sync(new),mlb_ticket_game(new),mlb_ticket_fire(),mlb_ticket_tick(),mlb_ticket_match(),cron:mlb_ticket_tick_1min · reads:net._http_response,events · pre:20261116030000
--
-- MLB schedule + official ticket links, from MLB's own ticketing back end (operator 2026-11-16: "use this
-- to get link, to get mlb schedule and team, venues and date and url, https://www.mlb.com/tickets").
--
-- SOURCE. mlb.com/tickets and each club's schedule page read
--   GET https://www.ticketing-client.com/ticketing-client/json/EventTicketPromotionPrice.tiksrv
--       ?team_id=<id>&home_team_id=<id>&sport_id=1&display_in=singlegame&ticket_category=Tickets
--       &site_section=Default&sub_category=Default&leave_empty_games=true&event_type=T
--       &begin_date=<yyyy>0101&end_date=<yyyy>1231&year=<yyyy>
-- which returns every home game of one club for a season (2027 Yankees: 81 regular + 16 spring) with
-- teams (MLB ids, full names), venue (id, name, city, postal code), local start time + time zone, UTC
-- start, TBD flag, game type, doubleheader number, and ticket_link.tlink — the club's official
-- single-game ticket page, e.g. https://www.mlb.com/app/ballpark/yankees/tickets/single-game-tickets/2027/home-game-01,
-- which hands off to the club's ticket seller once single games are on sale (on_sale_start_date).
-- Public, no key. Without a team id the endpoint limits a request to 31 days, so it is read per club
-- per season: 30 clubs × (this season, next season) = 60 GETs, each refreshed once a day, one at a time.
-- statsapi.mlb.com's schedule carries no ticket links (hydrate=tickets returns nothing), so it is not used.
--
-- TABLES. mlb_ticket_team (the 30 clubs, statsapi ids), mlb_ticket_sync (one row per club × season:
-- in-flight request, last success, last error), mlb_ticket_game (one row per game, schedule_id).
-- MATCH. mlb_ticket_match() fills mlb_ticket_game.tevo_event_id when exactly one TEvo event has the same
-- "<away full name> at <home full name>" on the same local date (fill-only; doubleheaders and ties are
-- left for review). TEvo carries many MLB games as date-only (00:00) placeholders; MLB's start time is
-- kept here, not written into events.
-- GET only, no upstream write (RULE 2).

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.mlb_ticket_team (
  team_id   integer PRIMARY KEY,           -- statsapi.mlb.com team id
  abbrev    text NOT NULL,
  full_name text NOT NULL,
  active    boolean NOT NULL DEFAULT true
);

INSERT INTO public.mlb_ticket_team (team_id, abbrev, full_name) VALUES
  (108, 'LAA', 'Los Angeles Angels'),
  (109, 'AZ', 'Arizona Diamondbacks'),
  (110, 'BAL', 'Baltimore Orioles'),
  (111, 'BOS', 'Boston Red Sox'),
  (112, 'CHC', 'Chicago Cubs'),
  (113, 'CIN', 'Cincinnati Reds'),
  (114, 'CLE', 'Cleveland Guardians'),
  (115, 'COL', 'Colorado Rockies'),
  (116, 'DET', 'Detroit Tigers'),
  (117, 'HOU', 'Houston Astros'),
  (118, 'KC', 'Kansas City Royals'),
  (119, 'LAD', 'Los Angeles Dodgers'),
  (120, 'WSH', 'Washington Nationals'),
  (121, 'NYM', 'New York Mets'),
  (133, 'ATH', 'Athletics'),
  (134, 'PIT', 'Pittsburgh Pirates'),
  (135, 'SD', 'San Diego Padres'),
  (136, 'SEA', 'Seattle Mariners'),
  (137, 'SF', 'San Francisco Giants'),
  (138, 'STL', 'St. Louis Cardinals'),
  (139, 'TB', 'Tampa Bay Rays'),
  (140, 'TEX', 'Texas Rangers'),
  (141, 'TOR', 'Toronto Blue Jays'),
  (142, 'MIN', 'Minnesota Twins'),
  (143, 'PHI', 'Philadelphia Phillies'),
  (144, 'ATL', 'Atlanta Braves'),
  (145, 'CWS', 'Chicago White Sox'),
  (146, 'MIA', 'Miami Marlins'),
  (147, 'NYY', 'New York Yankees'),
  (158, 'MIL', 'Milwaukee Brewers')
ON CONFLICT (team_id) DO UPDATE SET abbrev = EXCLUDED.abbrev, full_name = EXCLUDED.full_name;

CREATE TABLE IF NOT EXISTS public.mlb_ticket_sync (
  team_id            integer NOT NULL REFERENCES public.mlb_ticket_team (team_id),
  season             integer NOT NULL,
  pending_request_id bigint,
  pending_since      timestamptz,
  tries              integer NOT NULL DEFAULT 0,
  last_ok_at         timestamptz,
  last_games         integer,
  last_error         text,
  last_error_at      timestamptz,
  PRIMARY KEY (team_id, season)
);

CREATE TABLE IF NOT EXISTS public.mlb_ticket_game (
  schedule_id       bigint PRIMARY KEY,     -- MLB ticketing schedule id (one per game)
  mlb_game_id       text,                   -- e.g. 2027/03/25/tormlb-nyamlb-1
  season            integer NOT NULL,
  game_type         text,                   -- R regular, S spring, E exhibition, F/D/L/W postseason
  game_type_name    text,                   -- Season / Spring / ...
  game_date         date,
  game_time_local   timestamp,              -- venue wall clock
  time_zone_local   text,                   -- EDT, CST, ...
  game_time_utc     timestamptz,
  is_tbd            boolean,
  game_number       integer,                -- 2 = second game of a doubleheader
  if_necessary      boolean,
  status            text,
  descr             text,
  home_team_id      integer,
  home_name         text,
  home_abbrev       text,
  away_team_id      integer,
  away_name         text,
  away_abbrev       text,
  venue_id          integer,
  venue_name        text,
  venue_city        text,
  venue_postal_code text,
  ticket_url        text,                   -- the club's official single-game ticket page
  on_sale_start     timestamp,              -- as MLB gives it (Eastern)
  on_sale_end       timestamp,
  raw               jsonb,
  first_seen_at     timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  tevo_event_id     bigint,
  tevo_matched_at   timestamptz
);
CREATE INDEX IF NOT EXISTS mlb_ticket_game_date_idx ON public.mlb_ticket_game (game_date);
CREATE INDEX IF NOT EXISTS mlb_ticket_game_home_idx ON public.mlb_ticket_game (home_team_id, season);
CREATE INDEX IF NOT EXISTS mlb_ticket_game_tevo_idx ON public.mlb_ticket_game (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

ALTER TABLE public.mlb_ticket_team ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mlb_ticket_sync ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mlb_ticket_game ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mlb_ticket_team, public.mlb_ticket_sync, public.mlb_ticket_game FROM anon, authenticated;
GRANT SELECT ON public.mlb_ticket_team, public.mlb_ticket_sync, public.mlb_ticket_game TO service_role;

-- one GET for one club × season
CREATE OR REPLACE FUNCTION public.mlb_ticket_fire(p_team integer, p_season integer)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_req bigint;
BEGIN
  SELECT net.http_get(
           url := 'https://www.ticketing-client.com/ticketing-client/json/EventTicketPromotionPrice.tiksrv',
           params := jsonb_build_object(
             'team_id', p_team::text, 'home_team_id', p_team::text, 'sport_id', '1',
             'display_in', 'singlegame', 'ticket_category', 'Tickets', 'site_section', 'Default',
             'sub_category', 'Default', 'leave_empty_games', 'true', 'event_type', 'T',
             'begin_date', p_season || '0101', 'end_date', p_season || '1231', 'year', p_season::text),
           timeout_milliseconds := 60000) INTO v_req;
  UPDATE public.mlb_ticket_sync SET pending_request_id = v_req, pending_since = now()
   WHERE team_id = p_team AND season = p_season;
  RETURN v_req;
END $function$;

-- fill tevo_event_id where exactly one TEvo event is "<away> at <home>" on the same local date
CREATE OR REPLACE FUNCTION public.mlb_ticket_match(p_limit integer DEFAULT 5000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  WITH todo AS (
    SELECT g.schedule_id, g.game_date, g.away_name || ' at ' || g.home_name AS nm
      FROM public.mlb_ticket_game g
     WHERE g.tevo_event_id IS NULL AND g.game_date >= current_date - 1
       AND g.away_name IS NOT NULL AND g.home_name IS NOT NULL
     ORDER BY g.game_date
     LIMIT greatest(p_limit, 0)),
  cand AS (
    SELECT t.schedule_id, min(e.id) AS tevo_event_id, count(*) AS n
      FROM todo t
      JOIN public.events e ON left(e.occurs_at_local, 10) = t.game_date::text
                          AND lower(e.name) = lower(t.nm)
                          AND coalesce(e.state, 'shown') <> 'ignored'
     GROUP BY t.schedule_id)
  UPDATE public.mlb_ticket_game g
     SET tevo_event_id = c.tevo_event_id, tevo_matched_at = now()
    FROM cand c
   WHERE g.schedule_id = c.schedule_id AND c.n = 1 AND g.tevo_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game o
                      WHERE o.tevo_event_id = c.tevo_event_id AND o.schedule_id <> g.schedule_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

-- one step per call: land the in-flight page, else fire the next club × season that is due
CREATE OR REPLACE FUNCTION public.mlb_ticket_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  s      public.mlb_ticket_sync;
  r      record;
  j      jsonb;
  v_rows int := 0;
  v_err  text;
  v_year int := extract(year FROM now() AT TIME ZONE 'America/New_York')::int;
BEGIN
  -- this season and next, for every active club
  INSERT INTO public.mlb_ticket_sync (team_id, season)
  SELECT t.team_id, y FROM public.mlb_ticket_team t CROSS JOIN (VALUES (v_year), (v_year + 1)) v(y)
   WHERE t.active
  ON CONFLICT DO NOTHING;

  -- 1. a page in flight
  SELECT * INTO s FROM public.mlb_ticket_sync WHERE pending_request_id IS NOT NULL
   ORDER BY pending_since LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF FOUND THEN
    SELECT x.status_code, x.content INTO r FROM net._http_response x WHERE x.id = s.pending_request_id;
    IF NOT FOUND THEN
      IF s.pending_since > now() - interval '3 minutes' THEN
        RETURN jsonb_build_object('state', 'waiting', 'team', s.team_id, 'season', s.season);
      END IF;
      r := NULL;
    END IF;
    j := CASE WHEN r IS NOT NULL THEN public.safe_jsonb(r.content) END;
    IF r IS NULL OR r.status_code IS DISTINCT FROM 200 OR j->'events' IS NULL OR j->'events' ? 'error' THEN
      v_err := format('http %s %s', coalesce(r.status_code::text, 'lost'), left(coalesce(r.content, ''), 200));
      UPDATE public.mlb_ticket_sync
         SET pending_request_id = NULL, tries = tries + 1, last_error = v_err, last_error_at = now()
       WHERE team_id = s.team_id AND season = s.season;
      RETURN jsonb_build_object('state', 'error', 'team', s.team_id, 'season', s.season, 'error', v_err);
    END IF;

    WITH items AS (
      SELECT g FROM jsonb_array_elements(
               CASE jsonb_typeof(j->'events'->'game') WHEN 'array' THEN j->'events'->'game'
                    WHEN 'object' THEN jsonb_build_array(j->'events'->'game') ELSE '[]'::jsonb END) g
       WHERE (g->>'schedule_id') ~ '^\d+$'),
    parsed AS (
      SELECT i.g,
             (SELECT tl->>'tlink'
                FROM jsonb_array_elements(CASE jsonb_typeof(i.g->'ticket_link') WHEN 'array' THEN i.g->'ticket_link'
                                               WHEN 'object' THEN jsonb_build_array(i.g->'ticket_link') ELSE '[]'::jsonb END) tl
               WHERE coalesce(tl->>'tlink', '') <> ''
               ORDER BY (upper(coalesce(tl->>'ticket_category', '')) = 'TICKETS') DESC LIMIT 1) AS tlink,
             (SELECT tl FROM jsonb_array_elements(CASE jsonb_typeof(i.g->'ticket_link') WHEN 'array' THEN i.g->'ticket_link'
                                               WHEN 'object' THEN jsonb_build_array(i.g->'ticket_link') ELSE '[]'::jsonb END) tl
               WHERE coalesce(tl->>'tlink', '') <> ''
               ORDER BY (upper(coalesce(tl->>'ticket_category', '')) = 'TICKETS') DESC LIMIT 1) AS tl
        FROM items i)
    INSERT INTO public.mlb_ticket_game AS t (
      schedule_id, mlb_game_id, season, game_type, game_type_name, game_date, game_time_local, time_zone_local,
      game_time_utc, is_tbd, game_number, if_necessary, status, descr, home_team_id, home_name, home_abbrev,
      away_team_id, away_name, away_abbrev, venue_id, venue_name, venue_city, venue_postal_code,
      ticket_url, on_sale_start, on_sale_end, raw, last_seen_at)
    SELECT (p.g->>'schedule_id')::bigint, p.g->>'game_id',
           coalesce(CASE WHEN p.g->>'game_date' ~ '^\d{4}-' THEN left(p.g->>'game_date', 4)::int END, s.season),
           p.g->>'game_type', p.g->>'gt_name_short',
           CASE WHEN p.g->>'game_date' ~ '^\d{4}-\d\d-\d\d$' THEN (p.g->>'game_date')::date END,
           CASE WHEN p.g->>'game_time_local' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (p.g->>'game_time_local')::timestamp END,
           p.g->>'time_zone_local',
           CASE WHEN p.g->>'game_time' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                THEN to_timestamp(p.g->>'game_time', 'YYYYMMDD HH12:MI:SS AM')::timestamp AT TIME ZONE 'UTC' END,
           (p.g->>'tbd_flag') = 'Y',
           CASE WHEN p.g->>'game_number' ~ '^\d+$' THEN (p.g->>'game_number')::int END,
           (p.g->>'if_necessary') = 'Y', p.g->>'status', nullif(p.g->>'descr', ''),
           CASE WHEN p.g->>'home_team_id' ~ '^\d+$' THEN (p.g->>'home_team_id')::int END,
           p.g->>'home_name_full', p.g->>'home_name_abbrev',
           CASE WHEN p.g->>'away_team_id' ~ '^\d+$' THEN (p.g->>'away_team_id')::int END,
           p.g->>'away_name_full', p.g->>'away_name_abbrev',
           CASE WHEN p.g->>'venue_id' ~ '^\d+$' THEN (p.g->>'venue_id')::int END,
           p.g->>'venue_name', p.g->>'venue_city', p.g->>'venue_postal_code',
           p.tlink,
           CASE WHEN p.tl->>'on_sale_start_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                THEN to_timestamp(p.tl->>'on_sale_start_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
           CASE WHEN p.tl->>'on_sale_end_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                THEN to_timestamp(p.tl->>'on_sale_end_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
           p.g - 'promotion', now()
      FROM parsed p
    ON CONFLICT (schedule_id) DO UPDATE SET
      mlb_game_id = EXCLUDED.mlb_game_id, season = EXCLUDED.season, game_type = EXCLUDED.game_type,
      game_type_name = EXCLUDED.game_type_name, game_date = EXCLUDED.game_date,
      game_time_local = EXCLUDED.game_time_local, time_zone_local = EXCLUDED.time_zone_local,
      game_time_utc = EXCLUDED.game_time_utc, is_tbd = EXCLUDED.is_tbd, game_number = EXCLUDED.game_number,
      if_necessary = EXCLUDED.if_necessary, status = EXCLUDED.status, descr = EXCLUDED.descr,
      home_team_id = EXCLUDED.home_team_id, home_name = EXCLUDED.home_name, home_abbrev = EXCLUDED.home_abbrev,
      away_team_id = EXCLUDED.away_team_id, away_name = EXCLUDED.away_name, away_abbrev = EXCLUDED.away_abbrev,
      venue_id = EXCLUDED.venue_id, venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city,
      venue_postal_code = EXCLUDED.venue_postal_code, ticket_url = EXCLUDED.ticket_url,
      on_sale_start = EXCLUDED.on_sale_start, on_sale_end = EXCLUDED.on_sale_end, raw = EXCLUDED.raw,
      last_seen_at = now(),
      -- a game whose date moved is matched again
      tevo_event_id = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_event_id END,
      tevo_matched_at = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_matched_at END;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    UPDATE public.mlb_ticket_sync
       SET pending_request_id = NULL, tries = 0, last_ok_at = now(), last_games = v_rows, last_error = NULL
     WHERE team_id = s.team_id AND season = s.season;
    PERFORM public.mlb_ticket_match(500);
    RETURN jsonb_build_object('state', 'landed', 'team', s.team_id, 'season', s.season, 'games', v_rows);
  END IF;

  -- 2. idle: the club × season least recently refreshed, if older than a day (errors retry after 30 min)
  SELECT * INTO s FROM public.mlb_ticket_sync
   WHERE season IN (v_year, v_year + 1)
     AND (last_ok_at IS NULL OR last_ok_at < now() - interval '22 hours')
     AND (last_error_at IS NULL OR last_error_at < now() - interval '30 minutes' OR last_ok_at > last_error_at)
   ORDER BY last_ok_at NULLS FIRST, team_id, season
   LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'idle');
  END IF;
  PERFORM public.mlb_ticket_fire(s.team_id, s.season);
  RETURN jsonb_build_object('state', 'fired', 'team', s.team_id, 'season', s.season);
END $function$;

REVOKE ALL ON FUNCTION public.mlb_ticket_fire(integer, integer), public.mlb_ticket_match(integer),
                       public.mlb_ticket_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mlb_ticket_match(integer), public.mlb_ticket_tick() TO service_role;

-- every minute except the saturated :02/:05/:07 marks; 60 club-seasons refresh in about two hours a day
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mlb_ticket_tick_1min') THEN
    PERFORM cron.unschedule('mlb_ticket_tick_1min');
  END IF;
  PERFORM cron.schedule('mlb_ticket_tick_1min', '0,1,3,4,6,8-59 * * * *',
                        'SELECT public.mlb_ticket_tick();');
END
$cron$;

COMMIT;

-- VERIFY (after ~2 hours):
--   SELECT season, count(*), count(ticket_url), count(tevo_event_id) FROM mlb_ticket_game GROUP BY 1;
--   SELECT team_id, season, last_ok_at, last_games, last_error FROM mlb_ticket_sync ORDER BY last_ok_at NULLS FIRST;
-- ROLLBACK: SELECT cron.unschedule('mlb_ticket_tick_1min'); DROP FUNCTION mlb_ticket_tick(), mlb_ticket_match(integer),
--           mlb_ticket_fire(integer, integer); DROP TABLE mlb_ticket_game, mlb_ticket_sync, mlb_ticket_team;
