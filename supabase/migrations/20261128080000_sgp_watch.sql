-- Migration 20261128080000 · level:data-collection · lane:a1 (SeatGeek primary watch) · writes:sgp_watch_config(new),sgp_watch_team(new),sgp_watch_search(new),sgp_watch_game(new),sgp_watch_poll(new),v_sgp_watch_games(new),sgp_capture_event()(new),sgp_watch_game_row()(new),sgp_watch_settle_one()(new),sgp_watch_budget()(new),sgp_watch_tick()(new),cron sgp_watch_tick_30s(new) · reads:provenue_capture_event(),sg_events_canonical,vault tickets.dev,net._http_response
--
-- The SeatGeek primary watch: the box-office seats of the teams that sell through SeatGeek, read through tickets.dev's
-- SeatGeek capture. Operator 2026-11-28: "build the seatgeek primary watch, only poll for and look at primary for sg
-- in ticketsdev polling".
--
-- WHY. Our SeatGeek feed (brokerdata.seatgeek.com) is resale only: SeatGeek's own primary seats are not in it
-- (RESOURCES_BIBLE: "SG primary is unobservable", verified against Austin FC). tickets.dev's capture of a SeatGeek
-- event page marks every listing inventoryType 'primary' or 'resale'. The first read (Lakers at Pelicans, SeatGeek
-- 18412995, 2026-11-28) held 268 primary listings (2,083 tickets, $35 to $1,200 all-in, fee about 0: the price is
-- the total) and 352 resale. This watch keeps the primary listings only and drops the resale ones before anything is
-- stored; the resale count is kept in the ledger, nothing else of it.
--
-- WHICH GAMES. The SeatGeek partner teams (seatgeek.com/enterprise/partners, US and Canada, as the operator pasted
-- it): sgp_watch_team, 43 rows, each with the performer names that mark its home games. tickets.dev's catalogue
-- (GET /v1/events?query=<team>, free) is searched for each team once a search_every (a day), up to
-- search_max_pages pages of search_page_size; an event is the team's home game when the team is its master
-- performer (tickets.dev lists the home side master: the Pelicans are master of Lakers at Pelicans and not of
-- Pelicans at Trail Blazers), it has a SeatGeek page, and it is not a parking event. They are kept in
-- sgp_watch_game; a game no search has seen for 3 days leaves the watch. Every search keeps the master performers
-- it saw (sgp_watch_search.masters), so a team whose home games match nothing can be given the right name.
-- Our own SeatGeek catalogue (sg_events_canonical) holds almost none of these games: it is not the source.
--
-- WHAT IT WRITES. primary_poll_event / primary_poll_listing as source 'seatgeek_primary' through the shared
-- primary_poll_ingest, so the CRM gets them through /api/v1/subs/primary/* like every other box office. The capture
-- is parsed by the ProVenue watch's own parser (provenue_capture_event: the same tickets.dev format, its listing
-- ids, its shared-id tags, its order caps) on the primary listings alone; the event's total, lowest and highest price
-- are worked out from those listings, because the capture's stats count the resale too. The EVO id is
-- sg_events_canonical's, when it has the game (method 'sg_canonical').
--
-- ORDER CAPS. As for ProVenue: the cap a capped block shows, else team_order_max (by team, set by hand from the
-- team's checkout), else none. A block over the cap goes to the CRM in pieces (mig 20261124230030).
--
-- PACING AND SAFETY: the ProVenue watch's, as it stands after mig 20261128040000 — one game every `every` (an hour),
-- soonest first, empty_every (a day) for a game with no primary seats, retry_after after a failed read, the
-- daily/hourly caps (successes and reads in flight; only a success is billed), quota_reserve against the balance
-- tickets.dev returns, an hour's hold after quota_exceeded, one read in flight after upstream errors, a ledger keyed
-- on its own id, reads in flight at a database restart marked lost. The two watches spend ONE tickets.dev plan:
-- their caps are the operator's split of it. This one ships with enabled = false (no captures) and the catalogue
-- search on (discover_enabled; free), so the game list is ready when it is switched on.

BEGIN;

-- ---------------------------------------------------------------- config (one row)
CREATE TABLE IF NOT EXISTS public.sgp_watch_config (
  id                  boolean PRIMARY KEY DEFAULT true CHECK (id),
  enabled             boolean  NOT NULL DEFAULT false,     -- captures (billed)
  discover_enabled    boolean  NOT NULL DEFAULT true,      -- catalogue searches (free)
  every               interval NOT NULL DEFAULT interval '1 hour',
  due_slack           interval NOT NULL DEFAULT interval '2 minutes',
  retry_after         interval NOT NULL DEFAULT interval '10 minutes',
  empty_every         interval NOT NULL DEFAULT interval '1 day',
  horizon_days        integer  CHECK (horizon_days BETWEEN 0 AND 400),
  daily_cap           integer  NOT NULL DEFAULT 10 CHECK (daily_cap >= 0),
  hourly_cap          integer  NOT NULL DEFAULT 50 CHECK (hourly_cap >= 0),
  quota_reserve       integer  NOT NULL DEFAULT 25 CHECK (quota_reserve >= 0),
  max_in_flight       integer  NOT NULL DEFAULT 4 CHECK (max_in_flight BETWEEN 1 AND 50),
  fires_per_tick      integer  NOT NULL DEFAULT 4 CHECK (fires_per_tick BETWEEN 1 AND 50),
  fire_timeout_ms     integer  NOT NULL DEFAULT 180000,    -- the first SeatGeek capture took about two minutes
  stale_after         interval NOT NULL DEFAULT interval '6 minutes',
  upstream_errors_max integer  NOT NULL DEFAULT 3,
  search_every        interval NOT NULL DEFAULT interval '1 day',
  search_page_size    integer  NOT NULL DEFAULT 100 CHECK (search_page_size BETWEEN 1 AND 100),
  search_max_pages    integer  NOT NULL DEFAULT 5 CHECK (search_max_pages BETWEEN 1 AND 50),
  searches_per_tick   integer  NOT NULL DEFAULT 2 CHECK (searches_per_tick BETWEEN 0 AND 20),
  gone_after          interval NOT NULL DEFAULT interval '3 days',   -- a game no search has seen for this long
  team_order_max      jsonb    NOT NULL DEFAULT '{}'::jsonb,         -- {"New Orleans Pelicans": 8}
  note                text
);
INSERT INTO public.sgp_watch_config (id) VALUES (true) ON CONFLICT (id) DO NOTHING;

-- ---------------------------------------------------------------- the partner teams
CREATE TABLE IF NOT EXISTS public.sgp_watch_team (
  team        text PRIMARY KEY,                 -- what the catalogue is searched for
  match_names text[] NOT NULL,                  -- master performer names that make an event this team's home game
  league      text,
  enabled     boolean NOT NULL DEFAULT true,
  searched_at timestamptz,                      -- the last search started (page 1 fired)
  note        text
);
INSERT INTO public.sgp_watch_team (team, match_names, league) VALUES
 ('New Orleans Pelicans', '{"New Orleans Pelicans"}', 'NBA'),
 ('Cleveland Cavaliers', '{"Cleveland Cavaliers"}', 'NBA'),
 ('Utah Jazz', '{"Utah Jazz"}', 'NBA'),
 ('Florida Panthers', '{"Florida Panthers"}', 'NHL'),
 ('Utah Mammoth', '{"Utah Mammoth","Utah Hockey Club"}', 'NHL'),
 ('Baltimore Ravens', '{"Baltimore Ravens"}', 'NFL'),
 ('Dallas Cowboys', '{"Dallas Cowboys"}', 'NFL'),
 ('New Orleans Saints', '{"New Orleans Saints"}', 'NFL'),
 ('Tennessee Titans', '{"Tennessee Titans"}', 'NFL'),
 ('Washington Commanders', '{"Washington Commanders"}', 'NFL'),
 ('Austin FC', '{"Austin FC"}', 'MLS'),
 ('Chicago Fire', '{"Chicago Fire","Chicago Fire FC"}', 'MLS'),
 ('FC Cincinnati', '{"FC Cincinnati"}', 'MLS'),
 ('Minnesota United FC', '{"Minnesota United FC","Minnesota United"}', 'MLS'),
 ('Philadelphia Union', '{"Philadelphia Union"}', 'MLS'),
 ('Portland Timbers', '{"Portland Timbers"}', 'MLS'),
 ('Real Salt Lake', '{"Real Salt Lake"}', 'MLS'),
 ('Sporting Kansas City', '{"Sporting Kansas City","Sporting KC"}', 'MLS'),
 ('St. Louis City SC', '{"St. Louis City SC","St. Louis CITY SC","St Louis City SC"}', 'MLS'),
 ('Kansas City Current', '{"Kansas City Current"}', 'NWSL'),
 ('Portland Thorns FC', '{"Portland Thorns FC","Portland Thorns"}', 'NWSL'),
 ('Racing Louisville FC', '{"Racing Louisville FC","Racing Louisville"}', 'NWSL'),
 ('Utah Royals FC', '{"Utah Royals FC","Utah Royals"}', 'NWSL'),
 ('AV Alta FC', '{"AV Alta FC"}', 'USL'),
 ('Brooklyn FC', '{"Brooklyn FC","Brooklyn FC Women"}', 'USL'),
 ('Charleston Battery', '{"Charleston Battery"}', 'USL'),
 ('Colorado Springs Switchbacks FC', '{"Colorado Springs Switchbacks FC","Colorado Springs Switchbacks"}', 'USL'),
 ('Detroit City FC', '{"Detroit City FC"}', 'USL'),
 ('FC Tulsa', '{"FC Tulsa"}', 'USL'),
 ('Hartford Athletic', '{"Hartford Athletic"}', 'USL'),
 ('Las Vegas Lights FC', '{"Las Vegas Lights FC","Las Vegas Lights"}', 'USL'),
 ('Lexington SC', '{"Lexington SC"}', 'USL'),
 ('Loudoun United FC', '{"Loudoun United FC","Loudoun United"}', 'USL'),
 ('Louisville City FC', '{"Louisville City FC","Louisville City"}', 'USL'),
 ('Monterey Bay FC', '{"Monterey Bay FC"}', 'USL'),
 ('New Mexico United', '{"New Mexico United"}', 'USL'),
 ('Oakland Roots SC', '{"Oakland Roots SC","Oakland Roots"}', 'USL'),
 ('Rhode Island FC', '{"Rhode Island FC"}', 'USL'),
 ('Richmond Kickers', '{"Richmond Kickers"}', 'USL'),
 ('Sacramento Republic FC', '{"Sacramento Republic FC","Sacramento Republic"}', 'USL'),
 ('Sporting Club Jacksonville', '{"Sporting Club Jacksonville","Sporting JAX","Sporting Jacksonville"}', 'USL'),
 ('Tampa Bay Sun FC', '{"Tampa Bay Sun FC","Tampa Bay Sun"}', 'USL'),
 ('Westchester SC', '{"Westchester SC"}', 'USL')
ON CONFLICT (team) DO NOTHING;

-- ---------------------------------------------------------------- catalogue searches (free)
CREATE TABLE IF NOT EXISTS public.sgp_watch_search (
  id          bigserial PRIMARY KEY,
  request_id  bigint NOT NULL,
  team        text NOT NULL,
  page        integer NOT NULL,
  fired_at    timestamptz NOT NULL DEFAULT now(),
  checked_at  timestamptz,
  status_code integer,
  outcome     text,                             -- ok | error | lost
  events      integer,
  home_games  integer,
  has_more    boolean,
  masters     jsonb,                            -- the master performers seen, with counts
  error       text
);
CREATE UNIQUE INDEX IF NOT EXISTS sgp_watch_search_open_request_idx ON public.sgp_watch_search (request_id) WHERE checked_at IS NULL;
CREATE INDEX IF NOT EXISTS sgp_watch_search_team_idx ON public.sgp_watch_search (team, fired_at DESC);

-- ---------------------------------------------------------------- the home games found
CREATE TABLE IF NOT EXISTS public.sgp_watch_game (
  sg_event_id   text PRIMARY KEY,               -- SeatGeek's event id (the capture's eventId)
  team          text NOT NULL REFERENCES public.sgp_watch_team (team),
  name          text,
  event_utc     timestamptz,
  event_local   text,                           -- the catalogue's local time, with its offset
  venue_name    text,
  venue_city    text,
  venue_state   text,
  timezone      text,
  url           text NOT NULL,                  -- the SeatGeek page the capture reads
  tdev_id       text,                           -- tickets.dev's own event id
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS sgp_watch_game_utc_idx ON public.sgp_watch_game (event_utc);

-- ---------------------------------------------------------------- the capture ledger: one row per read
CREATE TABLE IF NOT EXISTS public.sgp_watch_poll (
  id                 bigserial PRIMARY KEY,
  request_id         bigint NOT NULL,
  sg_event_id        text NOT NULL,
  fired_at           timestamptz NOT NULL DEFAULT now(),
  checked_at         timestamptz,
  status_code        integer,
  response_s         numeric,
  outcome            text,     -- ok | empty | not_on_sale | event_not_found | capture_failed | rate_limited | quota_exceeded | auth | lost | bad_body | settle_error | error
  error              text,
  listings           integer,  -- primary listings kept
  tickets            integer,
  resale_listings    integer,  -- resale listings dropped
  captures_remaining bigint
);
CREATE UNIQUE INDEX IF NOT EXISTS sgp_watch_poll_open_request_idx ON public.sgp_watch_poll (request_id) WHERE checked_at IS NULL;
CREATE INDEX IF NOT EXISTS sgp_watch_poll_event_idx ON public.sgp_watch_poll (sg_event_id, fired_at DESC);

ALTER TABLE public.sgp_watch_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sgp_watch_team ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sgp_watch_search ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sgp_watch_game ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sgp_watch_poll ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------- the games we may read
CREATE OR REPLACE VIEW public.v_sgp_watch_games AS
SELECT g.sg_event_id, g.team, g.name, g.event_utc, g.event_local, g.venue_name, g.venue_city, g.venue_state, g.timezone,
       g.url, c.tevo_event_id
  FROM public.sgp_watch_game g
  JOIN public.sgp_watch_team t ON t.team = g.team AND t.enabled
  LEFT JOIN public.sg_events_canonical c ON g.sg_event_id ~ '^[0-9]{1,18}$' AND c.sg_event_id = g.sg_event_id::bigint
 WHERE g.event_utc > now()
   AND g.last_seen_at > now() - (SELECT c2.gone_after FROM public.sgp_watch_config c2);
REVOKE ALL ON public.v_sgp_watch_games FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------- a capture -> one primary_poll_ingest event (primary only)
CREATE OR REPLACE FUNCTION public.sgp_capture_event(p_body jsonb, p_id text, p_game jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH p AS (
    SELECT coalesce(jsonb_agg(x), '[]'::jsonb) AS listings
      FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_body->'listings') = 'array' THEN p_body->'listings' ELSE '[]'::jsonb END) x
     WHERE x->>'inventoryType' = 'primary'
  ), e AS (
    -- the ProVenue parser on the primary listings alone; the capture's stats count the resale too, so they go
    SELECT public.provenue_capture_event((p_body - 'stats') || jsonb_build_object('listings', p.listings), p_id, p_game) AS ev FROM p
  )
  SELECT jsonb_strip_nulls(e.ev || jsonb_build_object(
           'total_available', (SELECT sum((x->>'qty')::int) FROM jsonb_array_elements(e.ev->'listings') x),
           'price_min', (SELECT min((x->>'all_in')::numeric) FROM jsonb_array_elements(e.ev->'listings') x),
           'price_max', (SELECT max((x->>'all_in')::numeric) FROM jsonb_array_elements(e.ev->'listings') x)))
    FROM e
$function$;

-- ---------------------------------------------------------------- the game row, in the shape the parse wants
CREATE OR REPLACE FUNCTION public.sgp_watch_game_row(p_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_strip_nulls(jsonb_build_object(
           'name', g.name,
           'local_date', substring(g.event_local FROM '^\d{4}-\d{2}-\d{2}'),
           'local_time', substring(g.event_local FROM 'T(\d{2}:\d{2})'),
           'start_utc', g.event_utc,
           'timezone', g.timezone,
           'venue', g.venue_name, 'city', g.venue_city, 'url', g.url,
           'tevo_event_id', c.tevo_event_id,
           'order_max', (SELECT cf.team_order_max->>g.team FROM public.sgp_watch_config cf)))
    FROM public.sgp_watch_game g
    LEFT JOIN public.sg_events_canonical c ON g.sg_event_id ~ '^[0-9]{1,18}$' AND c.sg_event_id = g.sg_event_id::bigint
   WHERE g.sg_event_id = p_id
$function$;

-- ---------------------------------------------------------------- settle one capture
CREATE OR REPLACE FUNCTION public.sgp_watch_settle_one(p_id text, p_status integer, p_body jsonb,
                                                       p_timed_out boolean, p_error text, p_headers jsonb DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_game jsonb := coalesce(public.sgp_watch_game_row(p_id), '{}'::jsonb);
  v_code text := p_body#>>'{error,code}';
  v_remaining bigint;
  v_event jsonb; v_outcome text; v_err text; v_listings integer; v_tickets integer; v_resale integer;
  v_band interval;
BEGIN
  SELECT CASE WHEN v ~ '^[0-9]+$' THEN v::bigint END INTO v_remaining
    FROM (SELECT coalesce(p_headers->>'Tickets-Captures-Remaining', p_headers->>'tickets-captures-remaining') AS v) h;

  IF coalesce(p_timed_out, false) OR p_status IS NULL THEN
    v_outcome := 'capture_failed'; v_err := coalesce(p_error, 'timed out');
  ELSIF p_status = 200 AND jsonb_typeof(p_body->'listings') = 'array' THEN
    v_event := public.sgp_capture_event(p_body, p_id, v_game);
    v_listings := jsonb_array_length(v_event->'listings');
    v_tickets := (v_event->>'total_available')::integer;
    v_resale := (SELECT count(*) FROM jsonb_array_elements(p_body->'listings') x WHERE x->>'inventoryType' IS DISTINCT FROM 'primary');
    v_outcome := CASE WHEN v_listings > 0 THEN 'ok' WHEN coalesce(p_body->>'note', '') <> '' THEN 'not_on_sale' ELSE 'empty' END;
    v_err := nullif(p_body->>'note', '');
  ELSIF p_status = 200 THEN
    v_outcome := 'bad_body'; v_err := 'a 200 without a listings array';
  ELSIF v_code IN ('rate_limited', 'quota_exceeded') THEN
    v_outcome := v_code; v_err := p_body#>>'{error,message}';
  ELSIF p_status IN (401, 402) THEN
    v_outcome := 'auth'; v_err := coalesce(v_code, 'http ' || p_status);
  ELSIF v_code = 'event_not_found' OR p_status = 404 THEN
    v_outcome := 'event_not_found'; v_err := coalesce(p_body#>>'{error,message}', 'event_not_found');
  ELSE
    v_outcome := CASE WHEN p_status >= 500 THEN 'capture_failed' ELSE 'error' END;
    v_err := coalesce(v_code, '') || ' http ' || p_status || coalesce(': ' || (p_body#>>'{error,message}'), '');
  END IF;

  IF v_event IS NOT NULL THEN
    PERFORM public.primary_poll_ingest('seatgeek_primary', jsonb_build_array(v_event));
    UPDATE public.primary_poll_listing pl SET notes = x->>'notes'
      FROM jsonb_array_elements(v_event->'listings') x
     WHERE pl.source = 'seatgeek_primary' AND pl.source_event_id = p_id AND pl.listing_id = x->>'id' AND x ? 'notes';
    -- the watch's own band, stored and pinned (as the ProVenue and AXS watches): no primary seats = the long band
    SELECT CASE WHEN v_listings > 0 THEN c.every ELSE c.empty_every END INTO v_band FROM public.sgp_watch_config c;
    UPDATE public.primary_poll_event e
       SET poll_interval = v_band, next_poll_at = coalesce(e.poll_ok_at, now()) + v_band, cadence_pinned = true
     WHERE e.source = 'seatgeek_primary' AND e.source_event_id = p_id;
  ELSIF v_outcome IN ('event_not_found', 'capture_failed', 'bad_body', 'error') AND v_game ? 'name' THEN
    PERFORM public.primary_poll_ingest('seatgeek_primary', jsonb_build_array(
              public.sgp_capture_event('{}'::jsonb, p_id, v_game) - 'listings'
              || jsonb_build_object('ok', false, 'error', left(v_outcome || ': ' || coalesce(v_err, ''), 300), 'listings', '[]'::jsonb)));
  END IF;

  IF v_game ? 'tevo_event_id' THEN
    UPDATE public.primary_poll_event e
       SET tevo_event_id = (v_game->>'tevo_event_id')::bigint, tevo_match_method = 'sg_canonical', tevo_matched_at = now()
     WHERE e.source = 'seatgeek_primary' AND e.source_event_id = p_id
       AND (e.tevo_event_id IS NULL OR e.tevo_match_method = 'sg_canonical')
       AND e.tevo_event_id IS DISTINCT FROM (v_game->>'tevo_event_id')::bigint;
  END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object('outcome', v_outcome, 'error', left(v_err, 300), 'listings', v_listings,
                                              'tickets', v_tickets, 'resale_listings', v_resale, 'captures_remaining', v_remaining));
END $function$;

-- ---------------------------------------------------------------- the budget, readable
CREATE OR REPLACE FUNCTION public.sgp_watch_budget()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT jsonb_build_object(
    'enabled', c.enabled, 'daily_cap', c.daily_cap, 'hourly_cap', c.hourly_cap,
    'billed_today', (SELECT count(*) FROM public.sgp_watch_poll p
                      WHERE p.fired_at >= date_trunc('day', now()) AND (p.checked_at IS NULL OR p.outcome IN ('ok', 'empty', 'not_on_sale', 'settle_error'))),
    'billed_last_hour', (SELECT count(*) FROM public.sgp_watch_poll p
                          WHERE p.fired_at >= now() - interval '1 hour' AND (p.checked_at IS NULL OR p.outcome IN ('ok', 'empty', 'not_on_sale', 'settle_error'))),
    'in_flight', (SELECT count(*) FROM public.sgp_watch_poll p WHERE p.checked_at IS NULL),
    -- the balance is the plan's, shared with the ProVenue watch: the newest either has seen
    'captures_remaining', (SELECT x.r FROM (
                             SELECT p.captures_remaining AS r, p.checked_at FROM public.sgp_watch_poll p WHERE p.captures_remaining IS NOT NULL
                             UNION ALL
                             SELECT p.captures_remaining, p.checked_at FROM public.provenue_watch_poll p WHERE p.captures_remaining IS NOT NULL) x
                            ORDER BY x.checked_at DESC LIMIT 1),
    'quota_exceeded_at', (SELECT max(x.t) FROM (
                            SELECT p.checked_at AS t FROM public.sgp_watch_poll p WHERE p.outcome = 'quota_exceeded'
                            UNION ALL
                            SELECT p.checked_at FROM public.provenue_watch_poll p WHERE p.outcome = 'quota_exceeded') x),
    'games_in_horizon', (SELECT count(*) FROM public.v_sgp_watch_games g
                          WHERE c.horizon_days IS NULL OR g.event_utc < now() + make_interval(days => c.horizon_days)),
    'teams_with_games', (SELECT count(DISTINCT g.team) FROM public.v_sgp_watch_games g),
    'response_p50_s', m.p50, 'response_p90_s', m.p90,
    'per_hour_at_in_flight', CASE WHEN m.p50 > 0 THEN floor(3600 / m.p50 * c.max_in_flight) END)
    FROM public.sgp_watch_config c
    CROSS JOIN LATERAL (
      SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY x.response_s))::numeric, 1) AS p50,
             round((percentile_cont(0.9) WITHIN GROUP (ORDER BY x.response_s))::numeric, 1) AS p90
        FROM (SELECT p.response_s FROM public.sgp_watch_poll p
               WHERE p.response_s IS NOT NULL ORDER BY p.checked_at DESC LIMIT 200) x) m
$function$;

-- ---------------------------------------------------------------- the tick: settle searches and captures, then fire
CREATE OR REPLACE FUNCTION public.sgp_watch_tick()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_cfg public.sgp_watch_config%ROWTYPE;
  v_budget jsonb; v_key text; v_slots integer; v_errors integer; v_room integer;
  v_fired integer := 0; v_settled integer := 0; v_lost integer := 0;
  v_searched integer := 0; v_search_fired integer := 0; v_found integer := 0;
  w record; t record; s record; r jsonb; v_rid bigint; v_body jsonb; v_n integer; v_home integer; v_more boolean;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('sgp_watch_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another sgp_watch_tick is running');
  END IF;
  SELECT * INTO v_cfg FROM public.sgp_watch_config;
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'tickets.dev';

  -- 1. settle the catalogue searches that have answered (a search fired before the database last started lost its
  --    answer in the restart: pg_net's ids start again, so a response with its id now is someone else's)
  FOR s IN SELECT q.id, q.request_id, q.team, q.page, hr.status_code, hr.content
             FROM public.sgp_watch_search q JOIN net._http_response hr ON hr.id = q.request_id
            WHERE q.checked_at IS NULL AND q.fired_at >= pg_postmaster_start_time()
            ORDER BY q.fired_at
  LOOP
    v_body := public.safe_jsonb(s.content);
    IF s.status_code = 200 AND jsonb_typeof(v_body->'events') = 'array' THEN
      WITH ev AS (
        SELECT e, (SELECT so->>'eventId' FROM jsonb_array_elements(coalesce(e->'sources', '[]'::jsonb)) so
                    WHERE so->>'marketplace' = 'seatgeek' AND coalesce(so->>'url', '') <> '' LIMIT 1) AS sg_id,
                  (SELECT so->>'url' FROM jsonb_array_elements(coalesce(e->'sources', '[]'::jsonb)) so
                    WHERE so->>'marketplace' = 'seatgeek' AND coalesce(so->>'url', '') <> '' LIMIT 1) AS sg_url
          FROM jsonb_array_elements(v_body->'events') e
      ), home AS (
        SELECT ev.* FROM ev JOIN public.sgp_watch_team tm ON tm.team = s.team
         WHERE ev.sg_id IS NOT NULL
           AND coalesce(ev.e->>'name', '') !~* 'parking'
           AND coalesce(ev.e#>>'{venue,name}', '') !~* 'parking'
           AND EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(ev.e->'performers', '[]'::jsonb)) pf
                        WHERE coalesce((pf->>'master')::boolean, false) AND lower(pf->>'name') = ANY (SELECT lower(m) FROM unnest(tm.match_names) m))
      ), up AS (
        INSERT INTO public.sgp_watch_game AS g (sg_event_id, team, name, event_utc, event_local, venue_name, venue_city, venue_state,
                                                timezone, url, tdev_id, first_seen_at, last_seen_at)
        SELECT DISTINCT ON (h.sg_id) h.sg_id, s.team, h.e->>'name', nullif(h.e->>'eventDateUtc', '')::timestamptz, h.e->>'eventDateLocal',
               h.e#>>'{venue,name}', h.e#>>'{venue,city}', h.e#>>'{venue,state}', h.e#>>'{venue,timezone}', h.sg_url, h.e->>'id', now(), now()
          FROM home h
        ON CONFLICT (sg_event_id) DO UPDATE
           SET team = EXCLUDED.team, name = EXCLUDED.name, event_utc = EXCLUDED.event_utc, event_local = EXCLUDED.event_local,
               venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city, venue_state = EXCLUDED.venue_state,
               timezone = EXCLUDED.timezone, url = EXCLUDED.url, tdev_id = EXCLUDED.tdev_id, last_seen_at = now()
        RETURNING 1
      )
      SELECT (SELECT count(*) FROM ev), (SELECT count(*) FROM up) INTO v_n, v_home;
      v_more := coalesce((v_body->>'hasMore')::boolean, false);
      UPDATE public.sgp_watch_search q
         SET checked_at = now(), status_code = s.status_code, outcome = 'ok', events = v_n, home_games = v_home, has_more = v_more,
             masters = (SELECT jsonb_object_agg(m.name, m.n) FROM (
                          SELECT pf->>'name' AS name, count(*) AS n
                            FROM jsonb_array_elements(v_body->'events') e, jsonb_array_elements(coalesce(e->'performers', '[]'::jsonb)) pf
                           WHERE coalesce((pf->>'master')::boolean, false) GROUP BY 1 ORDER BY 2 DESC LIMIT 20) m)
       WHERE q.id = s.id;
      v_found := v_found + v_home;
      -- the next page, at once (it is part of this search)
      IF v_more AND s.page < v_cfg.search_max_pages AND coalesce(v_key, '') <> '' THEN
        SELECT net.http_get(url := 'https://api.tickets.dev/v1/events',
                 params := jsonb_build_object('query', s.team, 'pageSize', v_cfg.search_page_size::text, 'page', (s.page + 1)::text),
                 headers := jsonb_build_object('x-api-key', v_key), timeout_milliseconds := 30000) INTO v_rid;
        INSERT INTO public.sgp_watch_search (request_id, team, page) VALUES (v_rid, s.team, s.page + 1);
        v_search_fired := v_search_fired + 1;
      END IF;
    ELSE
      UPDATE public.sgp_watch_search q
         SET checked_at = now(), status_code = s.status_code, outcome = 'error',
             error = left(coalesce(v_body#>>'{error,message}', v_body#>>'{error,code}', 'http ' || s.status_code), 300)
       WHERE q.id = s.id;
    END IF;
    v_searched := v_searched + 1;
  END LOOP;
  UPDATE public.sgp_watch_search q SET checked_at = now(), outcome = 'lost',
         error = CASE WHEN q.fired_at < pg_postmaster_start_time() THEN 'lost in a database restart' ELSE 'no response within stale_after' END
   WHERE q.checked_at IS NULL
     AND (q.fired_at < pg_postmaster_start_time()
          OR (q.fired_at < now() - v_cfg.stale_after AND NOT EXISTS (SELECT 1 FROM net._http_response hr WHERE hr.id = q.request_id)));

  -- 2. settle every capture that has answered
  FOR w IN SELECT p.request_id, p.sg_event_id, hr.status_code, hr.content, hr.timed_out, hr.error_msg, to_jsonb(hr)->'headers' AS headers,
                  round(extract(epoch FROM hr.created - p.fired_at)::numeric, 1) AS response_s
             FROM public.sgp_watch_poll p JOIN net._http_response hr ON hr.id = p.request_id
            WHERE p.checked_at IS NULL AND p.fired_at >= pg_postmaster_start_time()
            ORDER BY p.fired_at
  LOOP
    BEGIN
      r := public.sgp_watch_settle_one(w.sg_event_id, w.status_code, public.safe_jsonb(w.content),
                                       coalesce(w.timed_out, false), w.error_msg, w.headers);
    EXCEPTION WHEN OTHERS THEN
      r := jsonb_build_object('outcome', CASE WHEN w.status_code = 200 THEN 'settle_error' ELSE 'error' END,
                              'error', left('settle: ' || SQLERRM, 300));
    END;
    UPDATE public.sgp_watch_poll p
       SET checked_at = now(), status_code = w.status_code, outcome = r->>'outcome', error = r->>'error', response_s = w.response_s,
           listings = (r->>'listings')::integer, tickets = (r->>'tickets')::integer,
           resale_listings = (r->>'resale_listings')::integer, captures_remaining = (r->>'captures_remaining')::bigint
     WHERE p.request_id = w.request_id AND p.checked_at IS NULL;
    v_settled := v_settled + 1;
  END LOOP;

  -- the feeds show a source's events of its current run: every upcoming game read joins the run when a read settles
  IF v_settled > 0 THEN
    PERFORM public.primary_poll_run_done('seatgeek_primary', 'seatgeek_primary-' || to_char(clock_timestamp(), 'YYYYMMDD"T"HH24MISS.US'),
              coalesce((SELECT jsonb_agg(e.source_event_id) FROM public.primary_poll_event e
                          JOIN public.v_sgp_watch_games g ON g.sg_event_id = e.source_event_id
                         WHERE e.source = 'seatgeek_primary'), '[]'::jsonb));
  END IF;

  UPDATE public.sgp_watch_poll p
     SET checked_at = now(), outcome = 'lost',
         error = CASE WHEN p.fired_at < pg_postmaster_start_time() THEN 'lost in a database restart' ELSE 'no response within stale_after' END
   WHERE p.checked_at IS NULL
     AND (p.fired_at < pg_postmaster_start_time()
          OR (p.fired_at < now() - v_cfg.stale_after AND NOT EXISTS (SELECT 1 FROM net._http_response hr WHERE hr.id = p.request_id)));
  GET DIAGNOSTICS v_lost = ROW_COUNT;

  DELETE FROM public.sgp_watch_poll p WHERE p.fired_at < now() - interval '14 days';
  DELETE FROM public.sgp_watch_search q WHERE q.fired_at < now() - interval '14 days';

  IF coalesce(v_key, '') = '' THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'searches_settled', v_searched, 'fired', 0, 'held', 'vault secret tickets.dev missing');
  END IF;

  -- 3. start the catalogue searches that are due (free): a team not searched within search_every, none open
  IF v_cfg.discover_enabled THEN
    FOR t IN
      SELECT tm.team FROM public.sgp_watch_team tm
       WHERE tm.enabled AND (tm.searched_at IS NULL OR tm.searched_at < now() - v_cfg.search_every)
         AND NOT EXISTS (SELECT 1 FROM public.sgp_watch_search q WHERE q.team = tm.team AND q.checked_at IS NULL)
       ORDER BY tm.searched_at NULLS FIRST, tm.team
       LIMIT v_cfg.searches_per_tick
    LOOP
      SELECT net.http_get(url := 'https://api.tickets.dev/v1/events',
               params := jsonb_build_object('query', t.team, 'pageSize', v_cfg.search_page_size::text, 'page', '1'),
               headers := jsonb_build_object('x-api-key', v_key), timeout_milliseconds := 30000) INTO v_rid;
      INSERT INTO public.sgp_watch_search (request_id, team, page) VALUES (v_rid, t.team, 1);
      UPDATE public.sgp_watch_team SET searched_at = now() WHERE team = t.team;
      v_search_fired := v_search_fired + 1;
    END LOOP;
  END IF;

  IF NOT v_cfg.enabled THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'searches_settled', v_searched, 'searches_fired', v_search_fired,
                              'games_found', v_found, 'fired', 0, 'paused', true);
  END IF;

  -- 4. the room for captures: plan caps, the shared balance, the upstream's health, what is in flight
  v_budget := public.sgp_watch_budget();
  IF (v_budget->>'quota_exceeded_at')::timestamptz > now() - interval '1 hour' THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'searches_fired', v_search_fired, 'fired', 0, 'held', 'quota_exceeded in the last hour');
  END IF;
  IF (v_budget->>'captures_remaining')::bigint <= v_cfg.quota_reserve THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'searches_fired', v_search_fired, 'fired', 0,
                              'held', 'captures_remaining at reserve', 'captures_remaining', v_budget->'captures_remaining');
  END IF;
  v_room := least(v_cfg.daily_cap - (v_budget->>'billed_today')::integer,
                  v_cfg.hourly_cap - (v_budget->>'billed_last_hour')::integer);
  SELECT count(*) FILTER (WHERE x.outcome IN ('rate_limited', 'capture_failed', 'lost')) INTO v_errors
    FROM (SELECT p.outcome FROM public.sgp_watch_poll p WHERE p.checked_at IS NOT NULL ORDER BY p.checked_at DESC LIMIT 10) x;
  v_slots := least(v_cfg.max_in_flight - (v_budget->>'in_flight')::integer, v_cfg.fires_per_tick, v_room);
  IF v_errors >= v_cfg.upstream_errors_max THEN v_slots := least(v_slots, 1 - (v_budget->>'in_flight')::integer); END IF;
  IF v_slots <= 0 THEN
    RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'searches_fired', v_search_fired, 'fired', 0, 'room', v_room,
                              'in_flight', v_budget->'in_flight', 'upstream_errors', v_errors);
  END IF;

  -- 5. fire the captures that are due, soonest game first
  FOR t IN
    SELECT g.sg_event_id, g.url
      FROM public.v_sgp_watch_games g
      LEFT JOIN public.primary_poll_event e ON e.source = 'seatgeek_primary' AND e.source_event_id = g.sg_event_id
      LEFT JOIN LATERAL (
        SELECT max(p.fired_at) FILTER (WHERE p.outcome IN ('ok', 'empty', 'not_on_sale')) AS ok_at,
               max(p.fired_at) AS any_at,
               max(p.fired_at) FILTER (WHERE p.outcome = 'settle_error') AS bad_at,
               bool_or(p.checked_at IS NULL) AS in_flight
          FROM public.sgp_watch_poll p WHERE p.sg_event_id = g.sg_event_id) last ON true
     WHERE (v_cfg.horizon_days IS NULL OR g.event_utc < now() + make_interval(days => v_cfg.horizon_days))
       AND NOT coalesce(last.in_flight, false)
       AND (last.bad_at IS NULL OR last.bad_at <= now() - v_cfg.empty_every)
       AND (e.source_event_id IS NULL OR e.poll_status IS DISTINCT FROM 'ok' OR e.next_poll_at IS NULL
            OR e.next_poll_at <= now() + v_cfg.due_slack)
       AND (last.any_at IS NULL OR last.any_at <= now() - v_cfg.retry_after
            OR (last.ok_at IS NOT NULL AND last.any_at = last.ok_at))
     ORDER BY g.event_utc, g.sg_event_id
     LIMIT v_slots
  LOOP
    SELECT net.http_get(
      url := 'https://api.tickets.dev/v1/capture/seatgeek',
      params := jsonb_build_object('url', t.url, 'includeVenueMaps', 'false'),
      headers := jsonb_build_object('x-api-key', v_key),
      timeout_milliseconds := v_cfg.fire_timeout_ms) INTO v_rid;
    INSERT INTO public.sgp_watch_poll (request_id, sg_event_id) VALUES (v_rid, t.sg_event_id);
    v_fired := v_fired + 1;
  END LOOP;

  RETURN jsonb_build_object('settled', v_settled, 'lost', v_lost, 'searches_settled', v_searched, 'searches_fired', v_search_fired,
                            'games_found', v_found, 'fired', v_fired, 'room', v_room - v_fired, 'upstream_errors', v_errors,
                            'captures_remaining', v_budget->'captures_remaining');
END $function$;

REVOKE ALL ON FUNCTION public.sgp_capture_event(jsonb, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sgp_watch_game_row(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sgp_watch_settle_one(text, integer, jsonb, boolean, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sgp_watch_budget() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sgp_watch_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sgp_watch_budget() TO service_role;
GRANT EXECUTE ON FUNCTION public.sgp_watch_tick() TO service_role;

-- the cron settles and searches every 30 s; it captures only while sgp_watch_config.enabled
SELECT cron.schedule('sgp_watch_tick_30s', '30 seconds', $$SELECT public.sgp_watch_tick()$$);

COMMIT;
