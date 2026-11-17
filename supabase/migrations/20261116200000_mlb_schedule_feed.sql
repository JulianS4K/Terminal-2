-- Migration 20261116200000 · level:data-collection · lane:A1 (data plane — MLB schedule) · writes:mlb_ticket_game(+ticket_link_raw,ticket_url_kind,changed_at,tevo_match_method),mlb_ticket_direct_url(),mlb_ticket_tick(),mlb_ticket_match(),v_mlb_schedule_feed(new) · reads:events,aq_event_map,net._http_response · pre:20261116190000
--
-- The MLB schedule as an outbound feed (operator 2026-11-16: "create an outbound feed that auto fills
-- missing data once schedules are released, that also maps to evo and terminal events"; earlier the same
-- day: "remove ones that are redirects", "fills wrong ones").
--
-- WHAT CHANGES on top of 20261116190000 (collector live since 2026-11-16 18:50 UTC):
--   · Only DIRECT seller links are served. ticket_link_raw keeps what MLB gave; ticket_url keeps it only
--     when it is a page for that one game on the seller's own site (www.ticketmaster.com/event/<id>,
--     mlb.tickets.com/?…&pid=<event id>). mlb.com pages (/app/ballpark/…, which forward to the seller,
--     and club landing pages such as /reds/tickets/opening-day) are redirects: ticket_url_kind =
--     'redirect', ticket_url NULL. 2027 list, 2026-11-16: 799 direct, 98 redirects (all Yankees + 1 Reds).
--   · Fills itself in: every club × season is re-read every 11 hours (was 22), so a start time, a link or
--     a date change appears within half a day of the club releasing it. MLB's TBD placeholder time
--     (03:33) is never served as a time. changed_at moves only when something a reader uses changed, so a
--     consumer can poll with ?since=.
--   · Only seasons that still have games: from 1 November the season just played is no longer read.
--   · Matching to EVO (TEvo `events`), fill-only, now also:
--       - spring training: TEvo names them "Spring Training - <away> at <home>", sometimes
--         "(Split Squad)" on the end; both are stripped before comparing;
--       - doubleheaders / two candidates the same day: the one whose start minute equals MLB's;
--       - a match whose TEvo event moved to another day or was ignored is dropped and matched again.
--   · v_mlb_schedule_feed: one row per game from yesterday on — MLB's teams, venue, local + UTC start,
--     direct ticket URL, on-sale time — plus the EVO event (tevo_event_id, its own start and whether it is
--     a date-only placeholder or disagrees with MLB) and the terminal's hub row (aq_short_event_id with the
--     SeatGeek / StubHub / Vivid / Ticketmaster / GoTickets ids it carries) and the terminal page path.
--     Served by GET /api/v1/mlb/schedule (routers/mlb_feed.py).
-- Nothing upstream is written (RULE 2); `events` and `aq_event_map` are only read.

BEGIN;
SET LOCAL lock_timeout = '10s';

ALTER TABLE public.mlb_ticket_game
  ADD COLUMN IF NOT EXISTS ticket_link_raw   text,
  ADD COLUMN IF NOT EXISTS ticket_url_kind   text CHECK (ticket_url_kind IN ('direct', 'redirect')),
  ADD COLUMN IF NOT EXISTS changed_at        timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN IF NOT EXISTS tevo_match_method text;
CREATE INDEX IF NOT EXISTS mlb_ticket_game_changed_idx ON public.mlb_ticket_game (changed_at);

-- the link itself when it is the seller's page for that one game, else NULL
CREATE OR REPLACE FUNCTION public.mlb_ticket_direct_url(p_url text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_url ~ '^https://www\.ticketmaster\.com/event/[0-9A-Za-z]+/?$' THEN p_url
    WHEN p_url ~* '^https://mlb\.tickets\.com/?\?(.*&)?pid=[0-9]+' THEN p_url
  END
$function$;

UPDATE public.mlb_ticket_game
   SET ticket_link_raw = coalesce(ticket_link_raw, ticket_url),
       ticket_url_kind = CASE WHEN coalesce(ticket_link_raw, ticket_url) IS NULL THEN NULL
                              WHEN public.mlb_ticket_direct_url(coalesce(ticket_link_raw, ticket_url)) IS NOT NULL THEN 'direct'
                              ELSE 'redirect' END,
       ticket_url = public.mlb_ticket_direct_url(coalesce(ticket_link_raw, ticket_url));
UPDATE public.mlb_ticket_game SET tevo_match_method = 'name_date' WHERE tevo_event_id IS NOT NULL AND tevo_match_method IS NULL;

-- "<away> at <home>" as TEvo spells an MLB game, normalised
CREATE OR REPLACE FUNCTION public.mlb_ticket_norm_name(p_name text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT lower(btrim(regexp_replace(regexp_replace(coalesce(p_name, ''),
           '^\s*spring training\s*[-–:]\s*', '', 'i'), '\s*\((split squad|ss)\)\s*$', '', 'i')))
$function$;

CREATE OR REPLACE FUNCTION public.mlb_ticket_match(p_limit integer DEFAULT 5000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer; v_drop integer;
BEGIN
  -- a match whose EVO event left the game's date (or was ignored) is matched again
  UPDATE public.mlb_ticket_game g
     SET tevo_event_id = NULL, tevo_matched_at = NULL, tevo_match_method = NULL, changed_at = now()
    FROM public.events e
   WHERE e.id = g.tevo_event_id
     AND (left(e.occurs_at_local, 10) <> g.game_date::text OR coalesce(e.state, 'shown') = 'ignored');
  GET DIAGNOSTICS v_drop = ROW_COUNT;

  WITH todo AS (
    SELECT g.schedule_id, g.game_date, g.is_tbd,
           to_char(g.game_time_local, 'YYYY-MM-DD"T"HH24:MI') AS want_min,
           lower(g.away_name || ' at ' || g.home_name) AS nm
      FROM public.mlb_ticket_game g
     WHERE g.tevo_event_id IS NULL AND g.game_date >= current_date - 1
       AND g.away_name IS NOT NULL AND g.home_name IS NOT NULL
     ORDER BY g.game_date
     LIMIT greatest(p_limit, 0)),
  cand AS (
    SELECT t.schedule_id, e.id, e.occurs_at_local,
           count(*) OVER (PARTITION BY t.schedule_id) AS n_day,
           (NOT t.is_tbd AND left(e.occurs_at_local, 16) = t.want_min) AS same_minute
      FROM todo t
      JOIN public.events e ON left(e.occurs_at_local, 10) = t.game_date::text
                          AND public.mlb_ticket_norm_name(e.name) = t.nm
                          AND coalesce(e.state, 'shown') <> 'ignored'),
  pick AS (
    SELECT schedule_id, min(id) AS tevo_event_id, 'name_date' AS method
      FROM cand WHERE n_day = 1 GROUP BY schedule_id
    UNION ALL
    SELECT schedule_id, min(id), 'name_date_time'
      FROM cand WHERE n_day > 1 AND same_minute
     GROUP BY schedule_id HAVING count(*) = 1)
  UPDATE public.mlb_ticket_game g
     SET tevo_event_id = p.tevo_event_id, tevo_matched_at = now(), tevo_match_method = p.method, changed_at = now()
    FROM pick p
   WHERE g.schedule_id = p.schedule_id AND g.tevo_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game o
                      WHERE o.tevo_event_id = p.tevo_event_id AND o.schedule_id <> g.schedule_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

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
  v_now  timestamp := now() AT TIME ZONE 'America/New_York';
  v_year int := extract(year FROM v_now)::int;
  v_seasons int[];
BEGIN
  -- seasons that still have games: this one until 31 October, and the next
  v_seasons := CASE WHEN extract(month FROM v_now) >= 11 THEN ARRAY[v_year + 1] ELSE ARRAY[v_year, v_year + 1] END;
  INSERT INTO public.mlb_ticket_sync (team_id, season)
  SELECT t.team_id, y FROM public.mlb_ticket_team t CROSS JOIN unnest(v_seasons) y
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
    links AS (
      SELECT i.g,
             (SELECT tl FROM jsonb_array_elements(CASE jsonb_typeof(i.g->'ticket_link') WHEN 'array' THEN i.g->'ticket_link'
                                               WHEN 'object' THEN jsonb_build_array(i.g->'ticket_link') ELSE '[]'::jsonb END) tl
               WHERE coalesce(tl->>'tlink', '') <> ''
               ORDER BY (public.mlb_ticket_direct_url(tl->>'tlink') IS NOT NULL) DESC,   -- a direct link first
                        (upper(coalesce(tl->>'ticket_category', '')) = 'TICKETS') DESC LIMIT 1) AS tl
        FROM items i),
    parsed AS (
      SELECT l.g, l.tl, l.tl->>'tlink' AS raw_link,
             (l.g->>'tbd_flag') = 'Y' AS tbd,
             CASE WHEN l.g->>'game_date' ~ '^\d{4}-\d\d-\d\d$' THEN (l.g->>'game_date')::date END AS gdate,
             CASE WHEN l.g->>'game_time_local' ~ '^\d{4}-\d\d-\d\dT\d\d:\d\d' THEN (l.g->>'game_time_local')::timestamp END AS tlocal,
             CASE WHEN l.g->>'game_time' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                  THEN to_timestamp(l.g->>'game_time', 'YYYYMMDD HH12:MI:SS AM')::timestamp AT TIME ZONE 'UTC' END AS tutc
        FROM links l)
    INSERT INTO public.mlb_ticket_game AS t (
      schedule_id, mlb_game_id, season, game_type, game_type_name, game_date, game_time_local, time_zone_local,
      game_time_utc, is_tbd, game_number, if_necessary, status, descr, home_team_id, home_name, home_abbrev,
      away_team_id, away_name, away_abbrev, venue_id, venue_name, venue_city, venue_postal_code,
      ticket_link_raw, ticket_url, ticket_url_kind, on_sale_start, on_sale_end, raw, last_seen_at, changed_at)
    SELECT (p.g->>'schedule_id')::bigint, p.g->>'game_id',
           coalesce(extract(year FROM p.gdate)::int, s.season),
           p.g->>'game_type', p.g->>'gt_name_short',
           p.gdate, p.tlocal, p.g->>'time_zone_local', p.tutc, p.tbd,
           CASE WHEN p.g->>'game_number' ~ '^\d+$' THEN (p.g->>'game_number')::int END,
           (p.g->>'if_necessary') = 'Y', p.g->>'status', nullif(p.g->>'descr', ''),
           CASE WHEN p.g->>'home_team_id' ~ '^\d+$' THEN (p.g->>'home_team_id')::int END,
           p.g->>'home_name_full', p.g->>'home_name_abbrev',
           CASE WHEN p.g->>'away_team_id' ~ '^\d+$' THEN (p.g->>'away_team_id')::int END,
           p.g->>'away_name_full', p.g->>'away_name_abbrev',
           CASE WHEN p.g->>'venue_id' ~ '^\d+$' THEN (p.g->>'venue_id')::int END,
           p.g->>'venue_name', p.g->>'venue_city', p.g->>'venue_postal_code',
           p.raw_link, public.mlb_ticket_direct_url(p.raw_link),
           CASE WHEN p.raw_link IS NULL THEN NULL
                WHEN public.mlb_ticket_direct_url(p.raw_link) IS NOT NULL THEN 'direct' ELSE 'redirect' END,
           CASE WHEN p.tl->>'on_sale_start_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                THEN to_timestamp(p.tl->>'on_sale_start_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
           CASE WHEN p.tl->>'on_sale_end_date' ~ '^\d{8} \d\d:\d\d:\d\d [AP]M$'
                THEN to_timestamp(p.tl->>'on_sale_end_date', 'YYYYMMDD HH12:MI:SS AM')::timestamp END,
           p.g - 'promotion', now(), now()
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
      venue_postal_code = EXCLUDED.venue_postal_code,
      ticket_link_raw = EXCLUDED.ticket_link_raw, ticket_url = EXCLUDED.ticket_url, ticket_url_kind = EXCLUDED.ticket_url_kind,
      on_sale_start = EXCLUDED.on_sale_start, on_sale_end = EXCLUDED.on_sale_end, raw = EXCLUDED.raw,
      last_seen_at = now(),
      changed_at = CASE WHEN (t.game_date, t.game_time_local, t.game_time_utc, t.is_tbd, t.game_number, t.status,
                              t.home_team_id, t.away_team_id, t.venue_id, t.ticket_url, t.on_sale_start, t.game_type)
                             IS DISTINCT FROM
                             (EXCLUDED.game_date, EXCLUDED.game_time_local, EXCLUDED.game_time_utc, EXCLUDED.is_tbd,
                              EXCLUDED.game_number, EXCLUDED.status, EXCLUDED.home_team_id, EXCLUDED.away_team_id,
                              EXCLUDED.venue_id, EXCLUDED.ticket_url, EXCLUDED.on_sale_start, EXCLUDED.game_type)
                        THEN now() ELSE t.changed_at END,
      -- a game whose date moved is matched again
      tevo_event_id     = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_event_id END,
      tevo_matched_at   = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_matched_at END,
      tevo_match_method = CASE WHEN t.game_date IS DISTINCT FROM EXCLUDED.game_date THEN NULL ELSE t.tevo_match_method END;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    UPDATE public.mlb_ticket_sync
       SET pending_request_id = NULL, tries = 0, last_ok_at = now(), last_games = v_rows, last_error = NULL
     WHERE team_id = s.team_id AND season = s.season;
    PERFORM public.mlb_ticket_match(1000);
    RETURN jsonb_build_object('state', 'landed', 'team', s.team_id, 'season', s.season, 'games', v_rows);
  END IF;

  -- 2. idle: the club × season least recently read, once it is 11 hours old (errors retry after 30 min)
  SELECT * INTO s FROM public.mlb_ticket_sync
   WHERE season = ANY (v_seasons)
     AND (last_ok_at IS NULL OR last_ok_at < now() - interval '11 hours')
     AND (last_error_at IS NULL OR last_error_at < now() - interval '30 minutes' OR last_ok_at > last_error_at)
   ORDER BY last_ok_at NULLS FIRST, team_id, season
   LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN
    -- nothing to read: a matching pass for EVO events created since
    PERFORM public.mlb_ticket_match(1000);
    RETURN jsonb_build_object('state', 'idle');
  END IF;
  PERFORM public.mlb_ticket_fire(s.team_id, s.season);
  RETURN jsonb_build_object('state', 'fired', 'team', s.team_id, 'season', s.season);
END $function$;

-- the feed: one row per game from yesterday on
CREATE OR REPLACE VIEW public.v_mlb_schedule_feed
WITH (security_invoker = true) AS
SELECT g.schedule_id                                         AS mlb_schedule_id,
       g.mlb_game_id,
       g.season,
       CASE g.game_type WHEN 'R' THEN 'regular' WHEN 'S' THEN 'spring' WHEN 'E' THEN 'exhibition'
                        WHEN 'F' THEN 'wild_card' WHEN 'D' THEN 'division_series'
                        WHEN 'L' THEN 'league_championship' WHEN 'W' THEN 'world_series'
                        ELSE lower(coalesce(g.game_type_name, g.game_type)) END AS game_type,
       g.game_date,
       CASE WHEN g.is_tbd THEN NULL ELSE g.game_time_local END AS start_local,
       g.time_zone_local                                     AS time_zone,
       CASE WHEN g.is_tbd THEN NULL ELSE g.game_time_utc END AS start_utc,
       g.is_tbd                                              AS time_tbd,
       g.game_number                                         AS doubleheader_game,
       g.if_necessary,
       g.status,
       g.descr                                               AS description,
       g.home_team_id, g.home_name, g.home_abbrev,
       g.away_team_id, g.away_name, g.away_abbrev,
       g.venue_id, g.venue_name, g.venue_city, g.venue_postal_code,
       g.ticket_url,                                          -- direct seller page for this game, else NULL
       CASE WHEN g.ticket_url IS NOT NULL THEN g.on_sale_start END AS on_sale_start_et,
       g.tevo_event_id,                                       -- EVO (Ticket Evolution) event
       g.tevo_match_method,
       e.occurs_at_local                                     AS tevo_start_local,
       CASE WHEN g.tevo_event_id IS NULL THEN NULL
            WHEN e.occurs_at_local ~ 'T00:00(:00)?$' THEN 'evo_date_only'
            WHEN g.is_tbd THEN 'mlb_tbd'
            WHEN left(e.occurs_at_local, 16) = to_char(g.game_time_local, 'YYYY-MM-DD"T"HH24:MI') THEN 'same'
            ELSE 'differs' END                               AS tevo_time_check,
       hub.aq_short_event_id,                                -- the terminal's hub event
       hub.sg_event_id, hub.sh_event_id, hub.vivid_event_id, hub.tm_event_id, hub.gotickets_event_id,
       CASE WHEN g.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || g.tevo_event_id END AS terminal_path,
       g.changed_at,
       g.last_seen_at
  FROM public.mlb_ticket_game g
  LEFT JOIN public.events e ON e.id = g.tevo_event_id
  LEFT JOIN LATERAL (
    SELECT a.aq_short_event_id, a.sg_event_id, a.sh_event_id, a.vivid_event_id, a.tm_event_id, a.gotickets_event_id
      FROM public.aq_event_map a
     WHERE a.tevo_event_id = g.tevo_event_id
     ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at NULLS LAST
     LIMIT 1) hub ON g.tevo_event_id IS NOT NULL
 WHERE g.game_date >= current_date - 1;

REVOKE ALL ON FUNCTION public.mlb_ticket_match(integer), public.mlb_ticket_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mlb_ticket_match(integer), public.mlb_ticket_tick() TO service_role;
REVOKE ALL ON public.v_mlb_schedule_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_mlb_schedule_feed TO service_role;

-- the season just played is no longer read; its rows stay for history
DELETE FROM public.mlb_ticket_sync s
 WHERE s.season < extract(year FROM now() AT TIME ZONE 'America/New_York')::int + 1
   AND extract(month FROM now() AT TIME ZONE 'America/New_York') >= 11
   AND s.pending_request_id IS NULL;

SELECT public.mlb_ticket_match(5000);

COMMIT;

-- VERIFY:
--   SELECT game_type, count(*), count(ticket_url), count(tevo_event_id), count(aq_short_event_id)
--     FROM v_mlb_schedule_feed GROUP BY 1;
--   SELECT ticket_url_kind, count(*) FROM mlb_ticket_game GROUP BY 1;        -- redirects kept only in ticket_link_raw
