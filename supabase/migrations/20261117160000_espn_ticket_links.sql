-- Migration 20261117160000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:espn_ticket_league(new),espn_ticket_sync(new),espn_ticket_game(new),espn_ticket_fire()(new),espn_ticket_tick()(new),espn_ticket_match()(new),espn_ticket_map()(new),v_espn_ticket_link(new view),vivid_catalog_event(tevo_event_id fill-only),vivid_catalog_venue(tevo_venue_id fill-only),vivid_catalog_audit,cron:espn_ticket_tick_1min(new),cron:espn_ticket_map_hourly(new) · reads:site.api.espn.com (GET, pg_net),events,venue_timezone,vivid_catalog_event,vivid_catalog_venue · pre:20261117150000
--
-- MAPPING PROGRAM — ESPN'S TICKET LINKS MAP VIVID TO EVERY GAME ESPN LISTS.
--
-- Operator 2026-11-18: "use the ESPN Vivid ticket URLs to map Vivid automatically to all games within ESPN." ESPN's
-- public scoreboard (site.api.espn.com/apis/site/v2/sports/<sport>/<league>/scoreboard?dates=…) carries, on every
-- game, a Vivid Seats ticket link — ".../production/7419725" — and a Vivid venue link — ".../venue/1327". Checked
-- 2026-11-18: NBA 172 of 178 December games, NHL 213 of 214, NFL 10 of 11, college football 58 of 58, men's college
-- basketball 89 of 122 on one day, MLB 13 of 13 on an April day; and the production id IS our vivid_catalog_event
-- id, the venue id our vivid_catalog_venue id (7419725 = "NBA Cup - Charlotte Hornets at Atlanta Hawks", 1327 =
-- State Farm Arena). So for every game ESPN lists we get, by identity and not by name, the Vivid production —
-- while the catalogue mapper reaches a Vivid game only through a paired venue and a name that fits.
--
-- Three parts, all read-only upstream (RULE 2: a GET of a public feed through pg_net, as the MLB schedule is):
--   espn_ticket_tick (every minute)  one scoreboard page per league × period (a month for the pro leagues, a day for
--                                    college basketball) is in flight at a time, landed into espn_ticket_game: the game,
--                                    its teams, venue, UTC start (timeValid false = time unknown), the Vivid production
--                                    and venue ids, the ticket summary. A page is refreshed daily over the league's
--                                    horizon. Then espn_ticket_match pairs the landed games with TEvo events.
--   espn_ticket_match                ESPN game -> TEvo event: the same start (tevo_event_utc within 90 min) when ESPN
--                                    knows the time, else the same local day; both team nicknames in the EVO name and
--                                    xmap_name_fits on "<away> at <home>"; exactly one candidate (several -> the one
--                                    at the TEvo venue paired with the game's Vivid venue, else none); a TEvo event is
--                                    claimed by one game. event_xref (tevo <-> espn) covers 256 upcoming events today
--                                    and espn_event_date_lookup only NFL, so the match is made here, not read.
--   espn_ticket_map (hourly :38)     writes, fill-only and audited: a Vivid production whose ESPN game is matched to
--                                    a TEvo event takes that id (tevo_match_method 'espn_link', same local day ± 1);
--                                    a Vivid production the catalogue mapper already matched gives its EVO id to an
--                                    unmatched ESPN game ('vivid_link'); an unpaired Vivid venue ESPN ties to a venue
--                                    whose matched games are all at one TEvo venue is paired ('pair_espn' — kept as
--                                    set by the mappers, catalog_venue_kept). v_espn_ticket_link for review.
-- Later (needs DDL on event_xmap, with the internal-key work): ESPN as a seventh source of the cross-source spine.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. tables ─────────────────────────
CREATE TABLE IF NOT EXISTS public.espn_ticket_league (
  espn_league   text PRIMARY KEY,                       -- as event_xref.espn_league spells it
  sport_slug    text NOT NULL,                          -- '<sport>/<league>' in the scoreboard path
  span          text NOT NULL CHECK (span IN ('day', 'month')),
  extra_params  jsonb NOT NULL DEFAULT '{}'::jsonb,     -- e.g. {"groups": "50"} (college: every Division I conference)
  horizon_days  int NOT NULL DEFAULT 365,
  active        boolean NOT NULL DEFAULT true
);
INSERT INTO public.espn_ticket_league (espn_league, sport_slug, span, extra_params, horizon_days) VALUES
  ('NBA',   'basketball/nba',                     'month', '{}', 365),
  ('NHL',   'hockey/nhl',                         'month', '{}', 365),
  ('NFL',   'football/nfl',                       'month', '{}', 365),
  ('MLB',   'baseball/mlb',                       'month', '{}', 365),
  ('WNBA',  'basketball/wnba',                    'month', '{}', 365),
  ('MLS',   'soccer/usa.1',                       'month', '{}', 365),
  ('NCAAF', 'football/college-football',          'month', '{"groups": "80"}', 365),
  ('NCAAB', 'basketball/mens-college-basketball', 'day',   '{"groups": "50"}', 120)
ON CONFLICT (espn_league) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.espn_ticket_sync (
  espn_league        text NOT NULL REFERENCES public.espn_ticket_league (espn_league),
  period             text NOT NULL,                     -- YYYYMM or YYYYMMDD, as the dates= parameter takes it
  pending_request_id bigint,
  pending_since      timestamptz,
  tries              int NOT NULL DEFAULT 0,
  last_ok_at         timestamptz,
  last_games         int,
  last_error         text,
  last_error_at      timestamptz,
  PRIMARY KEY (espn_league, period)
);

CREATE TABLE IF NOT EXISTS public.espn_ticket_game (
  espn_event_id       text PRIMARY KEY,                 -- text, as event_xref.espn_event_id
  espn_league         text NOT NULL,
  season_year         int,
  season_type         int,
  name                text,                             -- "Charlotte Hornets at Atlanta Hawks"
  short_name          text,                             -- "CHA @ ATL"
  game_at_utc         timestamptz,
  time_valid          boolean,                          -- false: ESPN has the day, not the time
  status              text,                             -- STATUS_SCHEDULED | STATUS_FINAL | STATUS_POSTPONED | …
  neutral_site        boolean,
  home_team_id        text,
  home_name           text,
  away_team_id        text,
  away_name           text,
  espn_venue_id       text,
  venue_name          text,
  venue_city          text,
  venue_state         text,
  vivid_production_id bigint,                           -- = vivid_catalog_event.vivid_event_id
  vivid_venue_id      bigint,                           -- = vivid_catalog_venue.vivid_venue_id
  tickets_summary     text,
  tickets_available   int,
  raw                 jsonb,
  first_seen_at       timestamptz NOT NULL DEFAULT now(),
  last_seen_at        timestamptz NOT NULL DEFAULT now(),
  tevo_event_id       bigint,
  tevo_match_method   text,
  tevo_matched_at     timestamptz
);
CREATE INDEX IF NOT EXISTS espn_ticket_game_at_idx ON public.espn_ticket_game (game_at_utc);
CREATE INDEX IF NOT EXISTS espn_ticket_game_vivid_idx ON public.espn_ticket_game (vivid_production_id) WHERE vivid_production_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS espn_ticket_game_tevo_idx ON public.espn_ticket_game (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS espn_ticket_game_vvenue_idx ON public.espn_ticket_game (vivid_venue_id) WHERE vivid_venue_id IS NOT NULL;
COMMENT ON TABLE public.espn_ticket_game IS
  'Every game on ESPN''s scoreboards for the leagues in espn_ticket_league, with the Vivid Seats production and venue ids ESPN links to and our TEvo match (espn_ticket_match). Kept by espn_ticket_tick (pg_net, GET). Mig 20261117160000.';

DO $rls$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['espn_ticket_league', 'espn_ticket_sync', 'espn_ticket_game'] LOOP
    IF NOT (SELECT c.relrowsecurity FROM pg_class c WHERE c.oid = ('public.' || t)::regclass) THEN
      EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    END IF;
    IF has_table_privilege('anon', 'public.' || t, 'SELECT, INSERT, UPDATE, DELETE') OR has_table_privilege('authenticated', 'public.' || t, 'SELECT, INSERT, UPDATE, DELETE') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    END IF;
    IF NOT has_table_privilege('service_role', 'public.' || t, 'SELECT') THEN
      EXECUTE format('GRANT SELECT ON public.%I TO service_role', t);
    END IF;
  END LOOP;
END
$rls$;

-- ───────────────────────── 2. the collector ─────────────────────────
-- one GET: a league's scoreboard for one period
CREATE OR REPLACE FUNCTION public.espn_ticket_fire(p_league text, p_period text)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  l     public.espn_ticket_league;
  v_req bigint;
BEGIN
  SELECT * INTO l FROM public.espn_ticket_league WHERE espn_league = p_league;
  IF NOT FOUND THEN RAISE EXCEPTION 'espn_ticket_fire: unknown league %', p_league; END IF;
  SELECT net.http_get(
           url := 'https://site.api.espn.com/apis/site/v2/sports/' || l.sport_slug || '/scoreboard',
           params := jsonb_build_object('dates', p_period, 'limit', '1000') || l.extra_params,
           timeout_milliseconds := 60000) INTO v_req;
  INSERT INTO public.espn_ticket_sync (espn_league, period, pending_request_id, pending_since)
  VALUES (p_league, p_period, v_req, now())
  ON CONFLICT (espn_league, period) DO UPDATE SET pending_request_id = v_req, pending_since = now();
  RETURN v_req;
END $function$;

-- ESPN game -> TEvo event, for the games not yet matched
CREATE OR REPLACE FUNCTION public.espn_ticket_match(p_limit integer DEFAULT 2000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE v_n integer;
BEGIN
  DROP TABLE IF EXISTS _em_todo;
  CREATE TEMP TABLE _em_todo ON COMMIT DROP AS
  SELECT g.espn_event_id, g.name, g.home_name, g.away_name, g.game_at_utc, coalesce(g.time_valid, true) AS time_valid,
         lower(regexp_replace(g.home_name, '^.*\s', '')) AS home_nick,     -- the last word: Hawks, Blazers, Sox, 76ers
         lower(regexp_replace(g.away_name, '^.*\s', '')) AS away_nick,
         v.tevo_venue_id AS paired_tevo_venue,
         -- the game's local day: the paired TEvo venue's zone, else the state's usual zone
         (g.game_at_utc AT TIME ZONE coalesce(tz.iana_tz, public.xmap_state_tz(g.venue_state, 'US')))::date AS local_day
    FROM public.espn_ticket_game g
    LEFT JOIN public.vivid_catalog_venue v ON v.vivid_venue_id = g.vivid_venue_id AND v.tevo_venue_id IS NOT NULL
    LEFT JOIN public.venue_timezone tz ON tz.tevo_venue_id = v.tevo_venue_id
   WHERE g.tevo_event_id IS NULL AND g.game_at_utc IS NOT NULL
     AND g.game_at_utc BETWEEN now() - interval '1 day' AND now() + interval '400 days'
     AND coalesce(g.home_name, '') <> '' AND coalesce(g.away_name, '') <> '' AND coalesce(g.name, '') <> ''
     AND coalesce(g.status, '') NOT IN ('STATUS_FINAL', 'STATUS_CANCELED', 'STATUS_POSTPONED')
     AND coalesce(g.home_team_id, '0') <> '-1' AND coalesce(g.away_team_id, '0') <> '-1'   -- TBD sides (brackets) are not a game yet
   ORDER BY g.game_at_utc
   LIMIT greatest(p_limit, 0);
  IF (SELECT count(*) FROM _em_todo) = 0 THEN RETURN 0; END IF;

  -- the EVO games on those days (± 1), with their UTC start
  DROP TABLE IF EXISTS _em_days;
  CREATE TEMP TABLE _em_days ON COMMIT DROP AS
  SELECT DISTINCT (t.local_day + o)::text AS day FROM _em_todo t CROSS JOIN (VALUES (-1), (0), (1)) v(o);
  DROP TABLE IF EXISTS _em_ev;
  CREATE TEMP TABLE _em_ev ON COMMIT DROP AS
  SELECT e.id, e.name, lower(e.name) AS ln, e.venue_id, e.primary_performer_name, left(e.occurs_at_local, 10) AS day,
         public.tevo_event_utc(e.occurs_at_local, e.venue_id) AS utc
    FROM public.events e
    JOIN _em_days d ON d.day = left(e.occurs_at_local, 10)
   WHERE e.state IS DISTINCT FROM 'ignored'
     AND e.name ~* '\m(at|vs\.?|v)\M'
     AND e.name !~* '(parking|tailgate|package|shuttle|hospitality|\mvip\M|suites?\M|pre-?game|post-?game)'
     AND NOT EXISTS (SELECT 1 FROM public.espn_ticket_game o WHERE o.tevo_event_id = e.id);
  CREATE INDEX ON _em_ev (day);
  ANALYZE _em_ev;

  WITH cand AS (
    SELECT t.espn_event_id, e.id AS tevo_event_id, e.venue_id,
           (t.time_valid AND e.utc IS NOT NULL) AS by_time
      FROM _em_todo t
      JOIN _em_ev e ON e.day BETWEEN (t.local_day - 1)::text AND (t.local_day + 1)::text
     WHERE length(t.home_nick) >= 3 AND length(t.away_nick) >= 3
       AND position(t.home_nick IN e.ln) > 0 AND position(t.away_nick IN e.ln) > 0
       AND CASE WHEN t.time_valid AND e.utc IS NOT NULL THEN abs(extract(epoch FROM e.utc - t.game_at_utc)) <= 5400
                ELSE e.day = t.local_day::text END
       AND public.xmap_name_fits(t.name, ARRAY[t.away_name, t.home_name], e.name,
                                 CASE WHEN coalesce(e.primary_performer_name, '') <> '' THEN ARRAY[e.primary_performer_name] END)),
  per AS (
    SELECT c.espn_event_id, count(*) AS n, min(c.tevo_event_id) AS one, bool_and(c.by_time) AS by_time,
           count(*) FILTER (WHERE c.venue_id = t.paired_tevo_venue) AS n_venue,
           min(c.tevo_event_id) FILTER (WHERE c.venue_id = t.paired_tevo_venue) AS one_venue
      FROM cand c JOIN _em_todo t ON t.espn_event_id = c.espn_event_id
     GROUP BY c.espn_event_id),
  pick AS (
    SELECT p.espn_event_id,
           CASE WHEN p.n = 1 THEN p.one WHEN p.n_venue = 1 THEN p.one_venue END AS tevo_event_id,
           CASE WHEN p.n = 1 AND p.by_time THEN 'espn_time_name' WHEN p.n = 1 THEN 'espn_day_name'
                WHEN p.n_venue = 1 THEN 'espn_venue_time_name' END AS method
      FROM per p),
  ok AS (
    SELECT * FROM pick p WHERE p.tevo_event_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pick q WHERE q.tevo_event_id = p.tevo_event_id AND q.espn_event_id <> p.espn_event_id))   -- one TEvo event, one game
  UPDATE public.espn_ticket_game g
     SET tevo_event_id = ok.tevo_event_id, tevo_match_method = ok.method, tevo_matched_at = now()
    FROM ok WHERE g.espn_event_id = ok.espn_event_id AND g.tevo_event_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

-- one step per call: land the pages in flight (up to ten), fire the pages due (up to five), match what landed
CREATE OR REPLACE FUNCTION public.espn_ticket_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  s        record;
  r        record;
  j        jsonb;
  v_rows   int;
  v_err    text;
  v_landed int := 0;
  v_errors int := 0;
  v_fired  int := 0;
  v_games  int := 0;
  v_match  int := 0;
BEGIN
  -- the periods each league needs: from today to its horizon
  INSERT INTO public.espn_ticket_sync (espn_league, period)
  SELECT DISTINCT l.espn_league,
         CASE l.span WHEN 'month' THEN to_char(d, 'YYYYMM') ELSE to_char(d, 'YYYYMMDD') END
    FROM public.espn_ticket_league l
    CROSS JOIN LATERAL generate_series(current_date, current_date + l.horizon_days, interval '1 day') d
   WHERE l.active
  ON CONFLICT DO NOTHING;
  -- periods that fell behind today are not refreshed any more
  DELETE FROM public.espn_ticket_sync y
   WHERE y.pending_request_id IS NULL
     AND CASE WHEN length(y.period) = 6 THEN to_date(y.period || '01', 'YYYYMMDD') + interval '1 month' <= date_trunc('month', current_date)
              ELSE to_date(y.period, 'YYYYMMDD') < current_date - 1 END;

  -- 1. the pages in flight
  FOR s IN SELECT * FROM public.espn_ticket_sync WHERE pending_request_id IS NOT NULL ORDER BY pending_since LIMIT 10 FOR UPDATE SKIP LOCKED LOOP
    SELECT x.status_code, x.content INTO r FROM net._http_response x WHERE x.id = s.pending_request_id;
    IF NOT FOUND THEN
      IF s.pending_since > now() - interval '3 minutes' THEN CONTINUE; END IF;   -- still travelling
      r := NULL;
    END IF;
    j := CASE WHEN r IS NOT NULL THEN public.safe_jsonb(r.content) END;
    IF r IS NULL OR r.status_code IS DISTINCT FROM 200 OR j IS NULL OR jsonb_typeof(j->'events') IS DISTINCT FROM 'array' THEN
      v_err := format('http %s %s', coalesce(r.status_code::text, 'lost'), left(coalesce(r.content, ''), 200));
      UPDATE public.espn_ticket_sync
         SET pending_request_id = NULL, tries = tries + 1, last_error = v_err, last_error_at = now()
       WHERE espn_league = s.espn_league AND period = s.period;
      v_errors := v_errors + 1;
      CONTINUE;
    END IF;

    WITH ev AS (
      SELECT e, e->'competitions'->0 AS c FROM jsonb_array_elements(j->'events') e WHERE (e->>'id') ~ '^\d+$'),
    x AS (
      SELECT ev.e, ev.c,
             (SELECT l->>'href' FROM jsonb_array_elements(coalesce(ev.c->'tickets', '[]'::jsonb)) tk, jsonb_array_elements(coalesce(tk->'links', '[]'::jsonb)) l
               WHERE l->>'href' ~ 'vividseats\.com/.*/production/\d+' LIMIT 1) AS prod_href,
             (SELECT l->>'href' FROM jsonb_array_elements(coalesce(ev.c->'tickets', '[]'::jsonb)) tk, jsonb_array_elements(coalesce(tk->'links', '[]'::jsonb)) l
               WHERE l->>'href' ~ 'vividseats\.com/.*/venue/\d+' LIMIT 1) AS venue_href,
             (SELECT cp FROM jsonb_array_elements(coalesce(ev.c->'competitors', '[]'::jsonb)) cp WHERE cp->>'homeAway' = 'home' LIMIT 1) AS home,
             (SELECT cp FROM jsonb_array_elements(coalesce(ev.c->'competitors', '[]'::jsonb)) cp WHERE cp->>'homeAway' = 'away' LIMIT 1) AS away
        FROM ev)
    INSERT INTO public.espn_ticket_game AS g (
      espn_event_id, espn_league, season_year, season_type, name, short_name, game_at_utc, time_valid, status, neutral_site,
      home_team_id, home_name, away_team_id, away_name, espn_venue_id, venue_name, venue_city, venue_state,
      vivid_production_id, vivid_venue_id, tickets_summary, tickets_available, raw, last_seen_at)
    SELECT x.e->>'id', s.espn_league,
           CASE WHEN x.e->'season'->>'year' ~ '^\d+$' THEN (x.e->'season'->>'year')::int END,
           CASE WHEN x.e->'season'->>'type' ~ '^\d+$' THEN (x.e->'season'->>'type')::int END,
           x.e->>'name', x.e->>'shortName',
           CASE WHEN x.e->>'date' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (x.e->>'date')::timestamptz END,
           CASE WHEN jsonb_typeof(x.c->'timeValid') = 'boolean' THEN (x.c->>'timeValid')::boolean ELSE true END,
           x.c->'status'->'type'->>'name',
           CASE WHEN jsonb_typeof(x.c->'neutralSite') = 'boolean' THEN (x.c->>'neutralSite')::boolean END,
           x.home->>'id', x.home->'team'->>'displayName', x.away->>'id', x.away->'team'->>'displayName',
           x.c->'venue'->>'id', x.c->'venue'->>'fullName', x.c->'venue'->'address'->>'city', x.c->'venue'->'address'->>'state',
           substring(x.prod_href FROM '/production/(\d+)')::bigint, substring(x.venue_href FROM '/venue/(\d+)')::bigint,
           x.c->'tickets'->0->>'summary',
           CASE WHEN x.c->'tickets'->0->>'numberAvailable' ~ '^\d+$' THEN (x.c->'tickets'->0->>'numberAvailable')::int END,
           (x.e - 'competitions' - 'links' - 'weather') || jsonb_build_object('competition', x.c - 'highlights' - 'recent' - 'broadcasts' - 'geoBroadcasts' - 'format' - 'notes' - 'situation' - 'leaders' - 'odds'),
           now()
      FROM x
    ON CONFLICT (espn_event_id) DO UPDATE SET
      espn_league = EXCLUDED.espn_league, season_year = EXCLUDED.season_year, season_type = EXCLUDED.season_type,
      name = EXCLUDED.name, short_name = EXCLUDED.short_name, game_at_utc = EXCLUDED.game_at_utc, time_valid = EXCLUDED.time_valid,
      status = EXCLUDED.status, neutral_site = EXCLUDED.neutral_site,
      home_team_id = EXCLUDED.home_team_id, home_name = EXCLUDED.home_name, away_team_id = EXCLUDED.away_team_id, away_name = EXCLUDED.away_name,
      espn_venue_id = EXCLUDED.espn_venue_id, venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city, venue_state = EXCLUDED.venue_state,
      vivid_production_id = coalesce(EXCLUDED.vivid_production_id, g.vivid_production_id),
      vivid_venue_id = coalesce(EXCLUDED.vivid_venue_id, g.vivid_venue_id),
      tickets_summary = EXCLUDED.tickets_summary, tickets_available = EXCLUDED.tickets_available, raw = EXCLUDED.raw, last_seen_at = now(),
      -- a game that moved by more than an hour is matched again
      tevo_event_id     = CASE WHEN g.game_at_utc IS DISTINCT FROM EXCLUDED.game_at_utc AND abs(extract(epoch FROM coalesce(g.game_at_utc, EXCLUDED.game_at_utc) - EXCLUDED.game_at_utc)) > 3600 THEN NULL ELSE g.tevo_event_id END,
      tevo_match_method = CASE WHEN g.game_at_utc IS DISTINCT FROM EXCLUDED.game_at_utc AND abs(extract(epoch FROM coalesce(g.game_at_utc, EXCLUDED.game_at_utc) - EXCLUDED.game_at_utc)) > 3600 THEN NULL ELSE g.tevo_match_method END,
      tevo_matched_at   = CASE WHEN g.game_at_utc IS DISTINCT FROM EXCLUDED.game_at_utc AND abs(extract(epoch FROM coalesce(g.game_at_utc, EXCLUDED.game_at_utc) - EXCLUDED.game_at_utc)) > 3600 THEN NULL ELSE g.tevo_matched_at END;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    UPDATE public.espn_ticket_sync
       SET pending_request_id = NULL, tries = 0, last_ok_at = now(), last_games = v_rows, last_error = NULL
     WHERE espn_league = s.espn_league AND period = s.period;
    v_landed := v_landed + 1; v_games := v_games + v_rows;
  END LOOP;

  -- 2. the pages due: not refreshed for 22 hours (errors retry after 30 minutes), oldest first
  FOR s IN
    SELECT y.espn_league, y.period FROM public.espn_ticket_sync y
     WHERE y.pending_request_id IS NULL
       AND (y.last_ok_at IS NULL OR y.last_ok_at < now() - interval '22 hours')
       AND (y.last_error_at IS NULL OR y.last_error_at < now() - interval '30 minutes')
       AND y.tries < 20
     ORDER BY y.last_ok_at NULLS FIRST, y.period
     LIMIT 5
  LOOP
    PERFORM public.espn_ticket_fire(s.espn_league, s.period);
    v_fired := v_fired + 1;
  END LOOP;

  -- 3. what landed is matched
  IF v_landed > 0 THEN v_match := public.espn_ticket_match(2000); END IF;
  RETURN jsonb_build_object('landed', v_landed, 'games', v_games, 'errors', v_errors, 'fired', v_fired, 'matched', v_match);
END $function$;

-- ───────────────────────── 3. the map: Vivid takes the link ─────────────────────────
CREATE OR REPLACE FUNCTION public.espn_ticket_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_out jsonb := '{}'::jsonb;
  v_n   int;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('espn_ticket_map')) THEN
    RETURN jsonb_build_object('skipped', 'another espn_ticket_map is running');
  END IF;
  v_out := jsonb_build_object('run_id', v_run, 'applied', p_apply,
    'games', (SELECT count(*) FROM public.espn_ticket_game WHERE game_at_utc >= now()),
    'games_with_vivid', (SELECT count(*) FROM public.espn_ticket_game WHERE game_at_utc >= now() AND vivid_production_id IS NOT NULL),
    'games_with_tevo', (SELECT count(*) FROM public.espn_ticket_game WHERE game_at_utc >= now() AND tevo_event_id IS NOT NULL));

  -- A. a Vivid production whose ESPN game is matched to a TEvo event takes that id (same local day ± 1; one production per EVO event)
  DROP TABLE IF EXISTS _ex_fill;
  CREATE TEMP TABLE _ex_fill ON COMMIT DROP AS
  SELECT c.vivid_event_id, g.tevo_event_id, g.espn_event_id, g.name AS game, c.name AS vivid_name, e.name AS evo_name
    FROM public.espn_ticket_game g
    JOIN public.vivid_catalog_event c ON c.vivid_event_id = g.vivid_production_id
    JOIN public.events e ON e.id = g.tevo_event_id AND e.state IS DISTINCT FROM 'ignored'
   WHERE g.tevo_event_id IS NOT NULL AND c.tevo_event_id IS NULL
     AND c.event_date IS NOT NULL AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\d'
     AND abs(c.event_date - left(e.occurs_at_local, 10)::date) <= 1
     AND NOT EXISTS (SELECT 1 FROM public.vivid_catalog_event o WHERE o.tevo_event_id = g.tevo_event_id AND o.vivid_event_id <> c.vivid_event_id);
  IF p_apply THEN
    WITH upd AS (
      UPDATE public.vivid_catalog_event c SET tevo_event_id = f.tevo_event_id, tevo_match_method = 'espn_link', tevo_matched_at = now()
        FROM _ex_fill f WHERE c.vivid_event_id = f.vivid_event_id AND c.tevo_event_id IS NULL
      RETURNING c.vivid_event_id, c.tevo_event_id)
    INSERT INTO public.vivid_catalog_audit (run_id, vivid_event_id, action, target, target_key, new_tevo, note)
    SELECT v_run, u.vivid_event_id, 'match', 'vivid_catalog_event', u.vivid_event_id::text, u.tevo_event_id,
           'espn_link: ESPN game ' || f.espn_event_id || ' "' || f.game || '"'
      FROM upd u JOIN _ex_fill f ON f.vivid_event_id = u.vivid_event_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('vivid_filled', v_n);
  END IF;
  v_out := v_out || jsonb_build_object('vivid_fill_candidates', (SELECT count(*) FROM _ex_fill),
             'vivid_sample', (SELECT coalesce(jsonb_agg(f.vivid_name || '  =>  ' || f.evo_name), '[]'::jsonb) FROM (SELECT * FROM _ex_fill ORDER BY vivid_event_id LIMIT 8) f));

  -- B. the other way: a Vivid production the catalogue mapper matched gives its EVO id to an unmatched ESPN game
  DROP TABLE IF EXISTS _ex_back;
  CREATE TEMP TABLE _ex_back ON COMMIT DROP AS
  SELECT g.espn_event_id, c.tevo_event_id
    FROM public.espn_ticket_game g
    JOIN public.vivid_catalog_event c ON c.vivid_event_id = g.vivid_production_id AND c.tevo_event_id IS NOT NULL
   WHERE g.tevo_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.espn_ticket_game o WHERE o.tevo_event_id = c.tevo_event_id);
  IF p_apply THEN
    UPDATE public.espn_ticket_game g SET tevo_event_id = b.tevo_event_id, tevo_match_method = 'vivid_link', tevo_matched_at = now()
      FROM _ex_back b WHERE g.espn_event_id = b.espn_event_id AND g.tevo_event_id IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('games_filled_from_vivid', v_n);
  END IF;
  v_out := v_out || jsonb_build_object('games_fill_candidates', (SELECT count(*) FROM _ex_back));

  -- C. an unpaired Vivid venue ESPN ties to a venue whose matched games are all at one TEvo venue
  DROP TABLE IF EXISTS _ex_venue;
  CREATE TEMP TABLE _ex_venue ON COMMIT DROP AS
  SELECT v.vivid_venue_id, min(e.venue_id) AS tevo_venue_id, count(*) AS games, min(e.venue_name) AS tevo_name
    FROM public.vivid_catalog_venue v
    JOIN public.espn_ticket_game g ON g.vivid_venue_id = v.vivid_venue_id AND g.tevo_event_id IS NOT NULL AND coalesce(g.neutral_site, false) = false
    JOIN public.events e ON e.id = g.tevo_event_id AND e.venue_id IS NOT NULL
   WHERE v.tevo_venue_id IS NULL
   GROUP BY v.vivid_venue_id HAVING count(DISTINCT e.venue_id) = 1 AND count(*) >= 2;
  IF p_apply THEN
    WITH upd AS (
      UPDATE public.vivid_catalog_venue v SET tevo_venue_id = x.tevo_venue_id, method = 'pair_espn', derived_at = now()
        FROM _ex_venue x WHERE v.vivid_venue_id = x.vivid_venue_id AND v.tevo_venue_id IS NULL
      RETURNING v.vivid_venue_id, v.tevo_venue_id)
    INSERT INTO public.vivid_catalog_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'vivid_catalog_venue', u.vivid_venue_id::text,
           format('tevo_venue %s via pair_espn: %s (%s ESPN games)', u.tevo_venue_id, x.tevo_name, x.games)
      FROM upd u JOIN _ex_venue x ON x.vivid_venue_id = u.vivid_venue_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_paired', v_n);
  END IF;
  v_out := v_out || jsonb_build_object('venue_pair_candidates', (SELECT count(*) FROM _ex_venue));
  RETURN v_out;
END $function$;
COMMENT ON FUNCTION public.espn_ticket_map(boolean) IS
  'Vivid takes ESPN''s ticket links: a Vivid production whose ESPN game is matched to a TEvo event is mapped to it (espn_link), a matched Vivid production gives its EVO id to its unmatched ESPN game (vivid_link), an unpaired Vivid venue whose ESPN games sit at one TEvo venue is paired (pair_espn). Fill-only, audited in vivid_catalog_audit. Mig 20261117160000.';

REVOKE ALL ON FUNCTION public.espn_ticket_fire(text, text), public.espn_ticket_tick(), public.espn_ticket_match(integer), public.espn_ticket_map(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.espn_ticket_fire(text, text), public.espn_ticket_tick(), public.espn_ticket_match(integer), public.espn_ticket_map(boolean) TO service_role;

-- ───────────────────────── 4. review view ─────────────────────────
CREATE OR REPLACE VIEW public.v_espn_ticket_link AS
SELECT g.espn_league, g.espn_event_id, g.name AS game, g.game_at_utc, g.time_valid, g.venue_name, g.venue_city, g.venue_state,
       g.vivid_production_id, c.name AS vivid_name, c.event_date AS vivid_day, c.tevo_event_id AS vivid_tevo, c.tevo_match_method AS vivid_method,
       g.tevo_event_id AS game_tevo, g.tevo_match_method AS game_method, e.name AS evo_name, e.occurs_at_local AS evo_start,
       g.vivid_venue_id, v.tevo_venue_id AS vivid_tevo_venue, v.method AS vivid_venue_method, g.tickets_summary, g.tickets_available
  FROM public.espn_ticket_game g
  LEFT JOIN public.vivid_catalog_event c ON c.vivid_event_id = g.vivid_production_id
  LEFT JOIN public.vivid_catalog_venue v ON v.vivid_venue_id = g.vivid_venue_id
  LEFT JOIN public.events e ON e.id = g.tevo_event_id;
COMMENT ON VIEW public.v_espn_ticket_link IS 'ESPN game, the Vivid production ESPN links to, and both sides'' TEvo match, for review. Mig 20261117160000.';
REVOKE ALL ON public.v_espn_ticket_link FROM anon, authenticated;
GRANT SELECT ON public.v_espn_ticket_link TO service_role;

-- ───────────────────────── 5. crons ─────────────────────────
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn_ticket_tick_1min') THEN PERFORM cron.unschedule('espn_ticket_tick_1min'); END IF;
  PERFORM cron.schedule('espn_ticket_tick_1min', '* * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '55s'; SELECT public.espn_ticket_tick(); COMMIT;$j$);
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'espn_ticket_map_hourly') THEN PERFORM cron.unschedule('espn_ticket_map_hourly'); END IF;
  PERFORM cron.schedule('espn_ticket_map_hourly', '38 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '300s'; SELECT public.espn_ticket_match(20000); SELECT public.espn_ticket_map(true); COMMIT;$j$);
END
$cron$;

COMMIT;

-- VERIFY (the tick fires five pages a minute and lands them the next; the pro leagues' year is ~90 pages, college basketball 120 days):
--   SELECT espn_league, count(*) AS pages, count(*) FILTER (WHERE last_ok_at IS NOT NULL) AS landed, sum(last_games) AS games, max(last_error) FROM espn_ticket_sync GROUP BY 1 ORDER BY 1;
--   SELECT espn_league, count(*) AS games, count(vivid_production_id) AS with_vivid, count(tevo_event_id) AS with_tevo FROM espn_ticket_game WHERE game_at_utc >= now() GROUP BY 1 ORDER BY 1;
--   SELECT public.espn_ticket_map(false);                          -- dry run: what the :38 cron will write
--   SELECT * FROM v_espn_ticket_link WHERE vivid_method = 'espn_link' ORDER BY random() LIMIT 20;
--   SELECT game_method, count(*) FROM espn_ticket_game WHERE tevo_event_id IS NOT NULL GROUP BY 1;
