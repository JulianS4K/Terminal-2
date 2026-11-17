-- Migration 20261116220000 · level:data-collection · lane:A1 (data plane — MLB schedule) · writes:mlb_ticket_game(+sg_event_id,sg_match_method,sg_matched_at),mlb_ticket_norm_name(),mlb_ticket_match_sg()(new),mlb_ticket_match(),v_mlb_schedule_feed · reads:sg_events_canonical,aq_event_map,events · pre:20261116210000
--
-- MLB schedule feed: map each game to its SeatGeek event (operator 2026-11-16: "also map to seatgeek"),
-- and make the feed fast.
--
-- SEATGEEK. sg_events_canonical already lists 2,805 MLB 2027 events (category 'mlb'). Each MLB game is
-- matched to one of them directly — the same "<away> at <home>" on the same local date (SeatGeek writes
-- spring games "Spring Training: <away> (Split Squad) at <home>"; prefix and "(Split Squad)" are
-- stripped), and on a day with two, the one whose UTC start equals MLB's to the minute. One SeatGeek
-- event per game, fill-only; a match whose SeatGeek date moves away is dropped and matched again.
-- Read-only dry run on prod 2026-11-16: 2,798 of 2,897 upcoming games matched, each to a distinct event.
--   SeatGeek's own TEvo link (sg_events_canonical.tevo_event_id) is NOT used: on 137 of the matched games
--   it names a different TEvo event than this feed's, and in every sample checked it was SeatGeek's link
--   that was wrong (another day's game, mostly match_method 'tevo_search_autotrack'). Reported to the
--   operator; the shared mapper is not changed here.
-- SPEED. The feed view looked up the hub row per game with a sequential scan of aq_event_map (no index
-- on tevo_event_id): 39 s per call on prod. It now reads the hub once (one row per TEvo event, curated
-- first) and hash-joins it. aq_event_map is only read.
-- The view keeps every column and adds sg_url and sg_match_method at the end. sg_event_id is now the
-- direct SeatGeek match, else the hub's. Nothing upstream is called (RULE 2).

BEGIN;
SET LOCAL lock_timeout = '10s';

ALTER TABLE public.mlb_ticket_game
  ADD COLUMN IF NOT EXISTS sg_event_id     bigint,
  ADD COLUMN IF NOT EXISTS sg_match_method text,
  ADD COLUMN IF NOT EXISTS sg_matched_at   timestamptz;
CREATE INDEX IF NOT EXISTS mlb_ticket_game_sg_idx ON public.mlb_ticket_game (sg_event_id) WHERE sg_event_id IS NOT NULL;

-- "(Split Squad)" can sit after either team (SeatGeek: after the away team; TEvo: at the end)
CREATE OR REPLACE FUNCTION public.mlb_ticket_norm_name(p_name text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT lower(btrim(regexp_replace(regexp_replace(regexp_replace(coalesce(p_name, ''),
           '^\s*spring training\s*[-–:]\s*', '', 'i'), '\s*\((split squad|ss)\)', '', 'gi'), '\s+', ' ', 'g')))
$function$;

CREATE OR REPLACE FUNCTION public.mlb_ticket_match_sg(p_limit integer DEFAULT 5000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  -- a match whose SeatGeek event left the game's date is matched again
  UPDATE public.mlb_ticket_game g
     SET sg_event_id = NULL, sg_match_method = NULL, sg_matched_at = NULL, changed_at = now()
    FROM public.sg_events_canonical c
   WHERE c.sg_event_id = g.sg_event_id AND c.sg_event_date IS DISTINCT FROM g.game_date;

  WITH todo AS (
    SELECT g.schedule_id, g.game_date, g.is_tbd, g.game_time_utc,
           public.mlb_ticket_norm_name(g.away_name || ' at ' || g.home_name) AS nm
      FROM public.mlb_ticket_game g
     WHERE g.sg_event_id IS NULL AND g.game_date >= current_date - 1
       AND g.away_name IS NOT NULL AND g.home_name IS NOT NULL
     ORDER BY g.game_date
     LIMIT greatest(p_limit, 0)),
  cand AS (
    SELECT t.schedule_id, c.sg_event_id,
           count(*) OVER (PARTITION BY t.schedule_id) AS n_day,
           (NOT t.is_tbd AND date_trunc('minute', c.sg_datetime_utc) = date_trunc('minute', t.game_time_utc)) AS same_minute
      FROM todo t
      JOIN public.sg_events_canonical c
        ON c.sg_category = 'mlb' AND c.sg_event_date = t.game_date
       AND public.mlb_ticket_norm_name(c.sg_event_name) = t.nm),
  pick AS (
    SELECT schedule_id, min(sg_event_id) AS sg_event_id, 'name_date' AS method
      FROM cand WHERE n_day = 1 GROUP BY schedule_id
    UNION ALL
    SELECT schedule_id, min(sg_event_id), 'name_date_time'
      FROM cand WHERE n_day > 1 AND same_minute
     GROUP BY schedule_id HAVING count(*) = 1)
  UPDATE public.mlb_ticket_game g
     SET sg_event_id = p.sg_event_id, sg_match_method = p.method, sg_matched_at = now(), changed_at = now()
    FROM pick p
   WHERE g.schedule_id = p.schedule_id AND g.sg_event_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game o
                      WHERE o.sg_event_id = p.sg_event_id AND o.schedule_id <> g.schedule_id);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $function$;

-- the TEvo match (as in 20261116200000) + the SeatGeek match, every time the collector matches
CREATE OR REPLACE FUNCTION public.mlb_ticket_match(p_limit integer DEFAULT 5000)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  UPDATE public.mlb_ticket_game g
     SET tevo_event_id = NULL, tevo_matched_at = NULL, tevo_match_method = NULL, changed_at = now()
    FROM public.events e
   WHERE e.id = g.tevo_event_id
     AND (left(e.occurs_at_local, 10) <> g.game_date::text OR coalesce(e.state, 'shown') = 'ignored');

  WITH todo AS (
    SELECT g.schedule_id, g.game_date, g.is_tbd,
           to_char(g.game_time_local, 'YYYY-MM-DD"T"HH24:MI') AS want_min,
           public.mlb_ticket_norm_name(g.away_name || ' at ' || g.home_name) AS nm
      FROM public.mlb_ticket_game g
     WHERE g.tevo_event_id IS NULL AND g.game_date >= current_date - 1
       AND g.away_name IS NOT NULL AND g.home_name IS NOT NULL
     ORDER BY g.game_date
     LIMIT greatest(p_limit, 0)),
  cand AS (
    SELECT t.schedule_id, e.id,
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
  RETURN v_n + public.mlb_ticket_match_sg(p_limit);
END $function$;

CREATE OR REPLACE VIEW public.v_mlb_schedule_feed
WITH (security_invoker = true) AS
WITH hub AS (   -- one hub row per TEvo event of a feed game, curated first; read once, hash-joined
  SELECT DISTINCT ON (a.tevo_event_id)
         a.tevo_event_id, a.aq_short_event_id, a.sg_event_id, a.sh_event_id, a.vivid_event_id,
         a.tm_event_id, a.gotickets_event_id
    FROM public.aq_event_map a
   WHERE a.tevo_event_id IN (SELECT m.tevo_event_id FROM public.mlb_ticket_game m
                              WHERE m.tevo_event_id IS NOT NULL AND m.game_date >= current_date - 1)
   ORDER BY a.tevo_event_id, (a.aq_source = 'aq_curated') DESC, a.imported_at NULLS LAST)
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
       g.ticket_url,
       CASE WHEN g.ticket_url IS NOT NULL THEN g.on_sale_start END AS on_sale_start_et,
       g.tevo_event_id,
       g.tevo_match_method,
       e.occurs_at_local                                     AS tevo_start_local,
       CASE WHEN g.tevo_event_id IS NULL THEN NULL
            WHEN e.occurs_at_local ~ 'T00:00(:00)?$' THEN 'evo_date_only'
            WHEN g.is_tbd THEN 'mlb_tbd'
            WHEN left(e.occurs_at_local, 16) = to_char(g.game_time_local, 'YYYY-MM-DD"T"HH24:MI') THEN 'same'
            ELSE 'differs' END                               AS tevo_time_check,
       hub.aq_short_event_id,
       coalesce(g.sg_event_id, hub.sg_event_id)              AS sg_event_id,
       hub.sh_event_id, hub.vivid_event_id, hub.tm_event_id, hub.gotickets_event_id,
       CASE WHEN g.tevo_event_id IS NOT NULL THEN '/terminal/event.html?event=' || g.tevo_event_id END AS terminal_path,
       g.changed_at,
       g.last_seen_at,
       sg.sg_url,
       CASE WHEN g.sg_event_id IS NOT NULL THEN g.sg_match_method
            WHEN hub.sg_event_id IS NOT NULL THEN 'hub' END  AS sg_match_method
  FROM public.mlb_ticket_game g
  LEFT JOIN public.events e ON e.id = g.tevo_event_id
  LEFT JOIN hub ON hub.tevo_event_id = g.tevo_event_id
  LEFT JOIN public.sg_events_canonical sg ON sg.sg_event_id = coalesce(g.sg_event_id, hub.sg_event_id)
 WHERE g.game_date >= current_date - 1;

REVOKE ALL ON FUNCTION public.mlb_ticket_match_sg(integer), public.mlb_ticket_match(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mlb_ticket_match_sg(integer), public.mlb_ticket_match(integer) TO service_role;
REVOKE ALL ON public.v_mlb_schedule_feed FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_mlb_schedule_feed TO service_role;

SELECT public.mlb_ticket_match(5000);

COMMIT;

-- VERIFY:
--   SELECT game_type, count(*), count(sg_event_id), count(sg_url), count(tevo_event_id) FROM v_mlb_schedule_feed GROUP BY 1;
--   EXPLAIN ANALYZE SELECT count(*) FROM v_mlb_schedule_feed;     -- well under a second
