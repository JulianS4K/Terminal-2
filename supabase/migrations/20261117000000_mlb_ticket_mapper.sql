-- Migration 20261117000000 · level:data-collection · lane:A1 (data plane — MLB schedule) · writes:mlb_ticket_team(+tevo_performer_id),mlb_ticket_game(+tevo_venue_id,primary_seller,primary_event_id),mlb_venue_xref(new),mlb_map_audit(new),aq_event_map(+mlb_schedule_id; rows for mapped games; sg_event_id fill),sg_events_canonical(tevo_event_id for MLB games the schedule proves),mlb_ticket_event_fits()(new),mlb_ticket_map()(new),cron:mlb_ticket_map_hourly · reads:events,team_xref,entity_performer_map,venue_timezone (via tevo_event_utc) · pre:20261116230000
--
-- THE MLB MAPPER (operator 2026-11-16: "look at api pipeline for mlb and tickets.com and build mapper").
--
-- WHAT THE SCHEDULE IS. mlb_ticket_game is a primary source: MLB's own ticketing back end names both clubs,
-- the venue, the local start and the seller's page for every game of every club (mig 20261116190000). That
-- makes it the one feed in this database whose rows cannot be a wrong match — so it is used here as the
-- authority for which EVO (TEvo `events`) and SeatGeek rows ARE a given game, and the hub (aq_event_map,
-- PROJECT_BIBLE §0) learns the game from it. Nothing upstream is called (RULE 2): `events`,
-- team_xref, entity_performer_map and venue_timezone are only read.
--
-- WHAT mlb_ticket_match() (migs 20261116200000/230000) ALREADY DOES, AND WHERE IT STOPS. It fills
-- tevo_event_id when exactly one EVO event has the normalised name "<away> at <home>" on the game's local
-- date (a second candidate only by MLB's start minute). Measured on prod 2026-11-16, 2,901 upcoming MLB
-- games: 2,483 matched; of the 418 left, 355 have no EVO event at all yet (EVO lists no 2027 games for
-- six clubs' parks and for most spring venues), 63 have one that the name rule cannot see:
--   · a suffix or prefix EVO adds: "(Home Opener)", "(Opening Day)", "Spring Breakout - …", "A vs. B";
--   · a date-only placeholder (T00:00) AND the real timed listing for the same game, both on the day
--     (50 games): two candidates, neither on MLB's minute, so the rule declines both.
-- It also trusts SeatGeek's and the hub's own EVO links nowhere — rightly: sg_events_canonical.tevo_event_id
-- named a different EVO event than the game's on 137 matched games and was wrong on 134 of them
-- (tevo_search_autotrack 127, matcher_v3_pm24h 7: another day's game at a shared spring park). And the hub
-- knew nothing of these games: 1,564 of the 2,483 mapped EVO events had no aq_event_map row at all.
--
-- WHAT THIS ADDS — mlb_ticket_map(p_apply), one pass, hourly at :35 (after mlb_ticket_tick's :30 full pass):
--   0. clubs → TEvo performers (mlb_ticket_team.tevo_performer_id), from team_xref (MLB, 30/30) and
--      entity_performer_map (minor leagues, by exact name, 69/120). An EVO event carries both clubs'
--      performer ids on 2,477 of 2,483 matched games — a second axis that needs no name at all.
--   1. VERIFY every existing EVO match against the game: same local day and both clubs named (or both
--      performer ids present), the event not ignored. One that no longer fits (moved day, renamed,
--      ignored, another game's) is dropped and its hub link removed. mlb_ticket_match only re-checks the
--      day.
--   2. MATCH the rest: every EVO event on the game's local day that names both clubs (anywhere in the name,
--      so every suffix/prefix/"vs." form) or carries both performer ids, parking/tailgate/package rows
--      excluded, one game per EVO event. One candidate → teams_date. Several, exactly one of them timed
--      (the others T00:00 placeholders) → teams_date_timed: the listing with a time is the real one.
--      Several timed (a doubleheader) → the one whose start equals MLB's to the minute, compared on the
--      UTC axis with tevo_event_utc() (venue zone) → teams_date_time. Anything else is left unmatched —
--      never a guess. Dry run 2026-11-16 on the 418: +49 (teams_date 9, teams_date_timed 40), 10 still
--      ambiguous (two timed listings, neither on MLB's minute), 359 with nothing to match yet.
--   3. PRIMARY SELLER IDS from the direct ticket URL: primary_seller ∈ {ticketmaster, provenue, glitnir}
--      and primary_event_id — Ticketmaster's event id, ProVenue's pid= (MLB, mlb.tickets.com) or eventId=
--      (minor leagues), Glitnir's event_id=. 940 of 940 direct URLs parse (111 TM, 688 pid, 141 eventId).
--      tickets.com's own ProVenue event id is the key a listing feed would need; it lives here, and the hub
--      carries the game by schedule id (below), not by seller id (tm_event_id is bigint; TM's ids are hex).
--   4. VENUES: mlb_venue_xref (MLB venue id → tevo_venue_id), the mode of the matched games' EVO venues,
--      re-derived every run (a 'manual' row is kept as set); mlb_ticket_game.tevo_venue_id follows it.
--      cross_source_venue_resolve() is deliberately NOT used: on 2026-11-16 it answered Target Field for
--      "Field of Dreams, Dyersville". A venue is only learned from a game both sides name.
--   5. SEATGEEK: for a game with a verified EVO match and a SeatGeek match (mlb_ticket_match_sg),
--      sg_events_canonical.tevo_event_id is filled when NULL and REPOINTED when it names an EVO event that
--      does not fit the game (another day, other clubs, ignored) — match_method 'mlb_schedule', confidence
--      1.0. A link that also fits the game (a doubleheader twin) is left as it is. 134 rows corrected on
--      the first run; every change is in mlb_map_audit with the old id.
--   6. HUB: every mapped game gets a hub row — the existing aq_event_map row of its EVO event (curated
--      first), else a new system_seed row (create_system_aq_event, source 'mlb', tevo + venue + primary
--      'tevo' set) — and the row carries the game: aq_event_map.mlb_schedule_id (new column, one game per
--      row and one row per game, both ways), and sg_event_id filled from the game's SeatGeek match when the
--      row had none and no other hub row holds that SeatGeek id for another EVO event. A hub row whose game
--      was re-matched elsewhere loses the link. Nothing already set in the hub is overwritten.
--   Every write is a row in mlb_map_audit (run_id, action, target, old/new ids). p_apply=false reports the
--   same counts and writes nothing.
-- Also: an index on aq_event_map(tevo_event_id) — the hub is looked up by EVO event everywhere
-- (event_mapper_apply, the feed view, this) and had no index for it (the feed view took 39 s before
-- 20261116220000 worked around it).
-- mlb_ticket_match() / mlb_ticket_match_sg() / mlb_ticket_tick() are not changed: they keep running per
-- club read; this pass is a superset that runs after them. A later migration may fold them.
-- Rollback (reversible by data): UPDATE from mlb_map_audit by run_id (old_tevo / old_sg per target);
--   cron.unschedule('mlb_ticket_map_hourly'); the new columns and tables may stay.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ---------------------------------------------------------------------------------------------------------
-- schema
-- ---------------------------------------------------------------------------------------------------------
ALTER TABLE public.mlb_ticket_team ADD COLUMN IF NOT EXISTS tevo_performer_id bigint;
COMMENT ON COLUMN public.mlb_ticket_team.tevo_performer_id IS
  'TEvo performer of the club (team_xref for MLB, entity_performer_map by exact name for minor leagues); filled by mlb_ticket_map(), fill-only.';

ALTER TABLE public.mlb_ticket_game
  ADD COLUMN IF NOT EXISTS tevo_venue_id    bigint,
  ADD COLUMN IF NOT EXISTS primary_seller   text CHECK (primary_seller IN ('ticketmaster', 'provenue', 'glitnir')),
  ADD COLUMN IF NOT EXISTS primary_event_id text;
COMMENT ON COLUMN public.mlb_ticket_game.primary_seller IS
  'Seller behind the direct ticket_url: ticketmaster (www.ticketmaster.com/event/<id>), provenue (tickets.com — mlb.tickets.com pid= for MLB, eventId= for minor leagues), glitnir (event_id=). NULL when ticket_url is NULL.';
COMMENT ON COLUMN public.mlb_ticket_game.primary_event_id IS
  'The seller''s own event id parsed from ticket_url (Ticketmaster hex id; ProVenue / Glitnir numeric). The key a primary-market listing feed would be polled by.';
COMMENT ON COLUMN public.mlb_ticket_game.tevo_venue_id IS 'TEvo venue of the park, from mlb_venue_xref (mlb_ticket_map()).';

CREATE TABLE IF NOT EXISTS public.mlb_venue_xref (
  mlb_venue_id    integer PRIMARY KEY,         -- MLB ticketing venue id (mlb_ticket_game.venue_id)
  venue_name      text,
  venue_city      text,
  tevo_venue_id   bigint,
  tevo_venue_name text,
  games           integer,                      -- matched games behind the derivation
  method          text NOT NULL DEFAULT 'matched_games',   -- matched_games | manual
  derived_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.mlb_venue_xref IS
  'MLB venue id -> TEvo venue, the mode of the EVO venues of the games mapped to that park; re-derived by every mlb_ticket_map() run. A row with method=manual is kept as set.';

CREATE TABLE IF NOT EXISTS public.mlb_map_audit (
  id          bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  run_id      uuid NOT NULL,
  schedule_id bigint,
  action      text NOT NULL,     -- drop | match | sg_fill | sg_repoint | hub_row | hub_link | hub_unlink | hub_sg
  target      text NOT NULL,     -- mlb_ticket_game | sg_events_canonical | aq_event_map
  target_key  text,
  old_tevo    bigint,
  new_tevo    bigint,
  old_sg      bigint,
  new_sg      bigint,
  note        text
);
CREATE INDEX IF NOT EXISTS mlb_map_audit_run_idx ON public.mlb_map_audit (run_id);
CREATE INDEX IF NOT EXISTS mlb_map_audit_game_idx ON public.mlb_map_audit (schedule_id);

ALTER TABLE public.aq_event_map ADD COLUMN IF NOT EXISTS mlb_schedule_id bigint;
COMMENT ON COLUMN public.aq_event_map.mlb_schedule_id IS
  'The MLB ticketing schedule id (mlb_ticket_game.schedule_id) of the game this hub row is; set by mlb_ticket_map(), one row per game and one game per row.';
CREATE INDEX IF NOT EXISTS aq_event_map_mlb_schedule_idx ON public.aq_event_map (mlb_schedule_id) WHERE mlb_schedule_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS aq_event_map_tevo_event_idx ON public.aq_event_map (tevo_event_id) WHERE tevo_event_id IS NOT NULL;

ALTER TABLE public.mlb_venue_xref ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mlb_map_audit  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mlb_venue_xref, public.mlb_map_audit FROM anon, authenticated;
GRANT SELECT ON public.mlb_venue_xref, public.mlb_map_audit TO service_role;

-- ---------------------------------------------------------------------------------------------------------
-- does this EVO event fit this game? same local day, and both clubs named (anywhere) or both performer ids
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mlb_ticket_event_fits(
  p_event_name text, p_event_local text, p_performer_ids bigint[], p_game_date date,
  p_away text, p_home text, p_away_pid bigint, p_home_pid bigint)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT p_game_date IS NOT NULL AND left(p_event_local, 10) = p_game_date::text
     AND ( (p_away IS NOT NULL AND p_home IS NOT NULL
            AND lower(coalesce(p_event_name, '')) LIKE '%' || lower(p_away) || '%'
            AND lower(coalesce(p_event_name, '')) LIKE '%' || lower(p_home) || '%')
        OR (p_away_pid IS NOT NULL AND p_home_pid IS NOT NULL AND p_performer_ids @> ARRAY[p_away_pid, p_home_pid]) )
$function$;

-- ---------------------------------------------------------------------------------------------------------
-- the mapper
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mlb_ticket_map(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run  uuid := gen_random_uuid();
  v_out  jsonb := '{}'::jsonb;
  v_by   jsonb;
  v_n    integer;
  v_hub_rows integer := 0;
  r      record;
  v_aq   text;
BEGIN
  -- 0. clubs -> TEvo performers: team_xref (MLB), else entity_performer_map by a name it carries exactly once
  DROP TABLE IF EXISTS _mm_team;
  CREATE TEMP TABLE _mm_team ON COMMIT DROP AS
  SELECT t.team_id,
         coalesce(t.tevo_performer_id,
                  (SELECT x.tevo_performer_id FROM public.team_xref x
                    WHERE t.sport_id = 1 AND x.espn_league = 'MLB' AND lower(x.tevo_name) = lower(t.full_name) LIMIT 1),
                  (SELECT min(e.tevo_performer_id) FROM public.entity_performer_map e
                    WHERE lower(e.tevo_performer_name) = lower(t.full_name) HAVING count(*) = 1)) AS pid
    FROM public.mlb_ticket_team t;
  IF p_apply THEN
    UPDATE public.mlb_ticket_team t SET tevo_performer_id = m.pid FROM _mm_team m
     WHERE m.team_id = t.team_id AND t.tevo_performer_id IS NULL AND m.pid IS NOT NULL;
  END IF;

  -- 1. verify every EVO match: still that game?
  DROP TABLE IF EXISTS _mm_drop;
  CREATE TEMP TABLE _mm_drop ON COMMIT DROP AS
  SELECT g.schedule_id, g.tevo_event_id,
         CASE WHEN e.id IS NULL THEN 'event_gone'
              WHEN coalesce(e.state, 'shown') = 'ignored' THEN 'event_ignored'
              WHEN left(e.occurs_at_local, 10) <> g.game_date::text THEN 'date_moved'
              ELSE 'clubs_differ' END AS reason
    FROM public.mlb_ticket_game g
    LEFT JOIN public.events e ON e.id = g.tevo_event_id
    LEFT JOIN _mm_team th ON th.team_id = g.home_team_id
    LEFT JOIN _mm_team ta ON ta.team_id = g.away_team_id
   WHERE g.tevo_event_id IS NOT NULL AND g.game_date >= current_date - 1
     AND NOT (e.id IS NOT NULL AND coalesce(e.state, 'shown') <> 'ignored'
              AND public.mlb_ticket_event_fits(e.name, e.occurs_at_local, e.performer_ids, g.game_date,
                                               g.away_name, g.home_name, ta.pid, th.pid));
  IF p_apply THEN
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.schedule_id, 'drop', 'mlb_ticket_game', d.schedule_id::text, d.tevo_event_id, d.reason FROM _mm_drop d;
    UPDATE public.aq_event_map a SET mlb_schedule_id = NULL FROM _mm_drop d WHERE a.mlb_schedule_id = d.schedule_id;
    UPDATE public.mlb_ticket_game g
       SET tevo_event_id = NULL, tevo_matched_at = NULL, tevo_match_method = NULL, changed_at = now()
      FROM _mm_drop d WHERE d.schedule_id = g.schedule_id;
  END IF;
  SELECT count(*) INTO v_n FROM _mm_drop;
  v_out := v_out || jsonb_build_object('dropped', v_n);

  -- 2. match the unmatched: both clubs on the game's local day, one game per EVO event
  DROP TABLE IF EXISTS _mm_cand;
  CREATE TEMP TABLE _mm_cand ON COMMIT DROP AS
  WITH todo AS (
    SELECT g.schedule_id, g.game_date, g.is_tbd, g.game_time_utc, g.away_name, g.home_name,
           ta.pid AS away_pid, th.pid AS home_pid
      FROM public.mlb_ticket_game g
      LEFT JOIN _mm_team th ON th.team_id = g.home_team_id
      LEFT JOIN _mm_team ta ON ta.team_id = g.away_team_id
     WHERE g.tevo_event_id IS NULL AND g.game_date >= current_date - 1
       AND g.away_name IS NOT NULL AND g.home_name IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM _mm_drop d WHERE d.schedule_id = g.schedule_id))   -- a dropped match is not re-matched in the same pass
  SELECT t.schedule_id, t.is_tbd, t.game_time_utc, e.id AS tevo_event_id,
         (e.occurs_at_local ~ 'T00:00(:00)?') AS placeholder,
         public.tevo_event_utc(e.occurs_at_local, e.venue_id) AS tevo_utc
    FROM todo t
    JOIN public.events e
      ON left(e.occurs_at_local, 10) = t.game_date::text
     AND coalesce(e.state, 'shown') <> 'ignored'
     AND lower(e.name) !~ '(parking|tailgate|package)'
     AND public.mlb_ticket_event_fits(e.name, e.occurs_at_local, e.performer_ids, t.game_date,
                                      t.away_name, t.home_name, t.away_pid, t.home_pid)
   WHERE NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game o WHERE o.tevo_event_id = e.id
                        AND NOT EXISTS (SELECT 1 FROM _mm_drop d WHERE d.schedule_id = o.schedule_id));

  DROP TABLE IF EXISTS _mm_pick;
  CREATE TEMP TABLE _mm_pick ON COMMIT DROP AS
  WITH c AS (
    SELECT c.*,
           count(*) OVER (PARTITION BY c.schedule_id) AS n_all,
           count(*) FILTER (WHERE NOT c.placeholder) OVER (PARTITION BY c.schedule_id) AS n_timed,
           (NOT c.is_tbd AND NOT c.placeholder AND c.tevo_utc IS NOT NULL AND c.game_time_utc IS NOT NULL
            AND abs(extract(epoch FROM c.tevo_utc - c.game_time_utc)) <= 60) AS same_minute
      FROM _mm_cand c),
  p AS (
    SELECT schedule_id, min(tevo_event_id) AS tevo_event_id, 'teams_date'::text AS method
      FROM c WHERE n_all = 1 GROUP BY 1
    UNION ALL
    SELECT schedule_id, min(tevo_event_id), 'teams_date_timed'
      FROM c WHERE n_all > 1 AND n_timed = 1 AND NOT placeholder GROUP BY 1
    UNION ALL
    SELECT schedule_id, min(tevo_event_id), 'teams_date_time'
      FROM c WHERE n_timed > 1 AND same_minute GROUP BY 1 HAVING count(*) = 1)
  SELECT p.* FROM p
   WHERE NOT EXISTS (SELECT 1 FROM p o WHERE o.tevo_event_id = p.tevo_event_id AND o.schedule_id <> p.schedule_id);  -- two games, one listing: neither

  IF p_apply THEN
    UPDATE public.mlb_ticket_game g
       SET tevo_event_id = p.tevo_event_id, tevo_matched_at = now(), tevo_match_method = p.method, changed_at = now()
      FROM _mm_pick p
     WHERE g.schedule_id = p.schedule_id AND g.tevo_event_id IS NULL
       AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game o WHERE o.tevo_event_id = p.tevo_event_id AND o.schedule_id <> g.schedule_id);
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.schedule_id, 'match', 'mlb_ticket_game', p.schedule_id::text, p.tevo_event_id, p.method FROM _mm_pick p;
  END IF;

  -- the game -> EVO event picture as this pass leaves it (the same in a dry run)
  DROP TABLE IF EXISTS _mm_eff;
  CREATE TEMP TABLE _mm_eff ON COMMIT DROP AS
  SELECT g.schedule_id, CASE WHEN d.schedule_id IS NOT NULL THEN NULL ELSE coalesce(p.tevo_event_id, g.tevo_event_id) END AS tevo_event_id
    FROM public.mlb_ticket_game g
    LEFT JOIN _mm_drop d ON d.schedule_id = g.schedule_id
    LEFT JOIN _mm_pick p ON p.schedule_id = g.schedule_id
   WHERE g.game_date >= current_date - 1;

  SELECT coalesce(jsonb_object_agg(x.method, x.n), '{}'::jsonb) INTO v_by FROM (SELECT method, count(*) AS n FROM _mm_pick GROUP BY 1) x;
  SELECT count(*) INTO v_n FROM _mm_pick;
  v_out := v_out || jsonb_build_object('matched', v_n, 'matched_by', v_by,
             'ambiguous', (SELECT count(DISTINCT c.schedule_id) FROM _mm_cand c WHERE NOT EXISTS (SELECT 1 FROM _mm_pick p WHERE p.schedule_id = c.schedule_id)),
             'unmatched', (SELECT count(*) FROM _mm_eff x WHERE x.tevo_event_id IS NULL));

  -- 3. the seller's own event id from the direct ticket URL
  IF p_apply THEN
    WITH p AS (
      SELECT g.schedule_id,
             CASE WHEN g.ticket_url ~  '^https://www\.ticketmaster\.com/event/' THEN 'ticketmaster'
                  WHEN g.ticket_url ~* 'glitnir'                                  THEN 'glitnir'
                  WHEN g.ticket_url ~* '[?&](pid|eventid)=[0-9]+'                 THEN 'provenue' END AS seller,
             coalesce(substring(g.ticket_url from '^https://www\.ticketmaster\.com/event/([0-9A-Za-z]+)'),
                      substring(g.ticket_url from '(?i)[?&]pid=([0-9]+)'),
                      substring(g.ticket_url from '(?i)[?&]eventid=([0-9]+)'),
                      substring(g.ticket_url from '(?i)[?&]event_id=([0-9]+)')) AS eid
        FROM public.mlb_ticket_game g
       WHERE g.ticket_url IS NOT NULL OR g.primary_event_id IS NOT NULL)
    UPDATE public.mlb_ticket_game g
       SET primary_seller = p.seller, primary_event_id = CASE WHEN p.seller IS NULL THEN NULL ELSE p.eid END
      FROM p
     WHERE p.schedule_id = g.schedule_id
       AND (g.primary_seller, g.primary_event_id) IS DISTINCT FROM (p.seller, CASE WHEN p.seller IS NULL THEN NULL ELSE p.eid END);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('primary_ids_set', v_n);
  END IF;

  -- 4. parks: the EVO venue the matched games point at
  IF p_apply THEN
    INSERT INTO public.mlb_venue_xref (mlb_venue_id, venue_name, venue_city, tevo_venue_id, tevo_venue_name, games, method, derived_at)
    SELECT DISTINCT ON (s.venue_id) s.venue_id, s.venue_name, s.venue_city, s.tv, s.tvn, s.n, 'matched_games', now()
      FROM (SELECT g.venue_id, max(g.venue_name) AS venue_name, max(g.venue_city) AS venue_city,
                   e.venue_id AS tv, max(e.venue_name) AS tvn, count(*) AS n
              FROM public.mlb_ticket_game g JOIN public.events e ON e.id = g.tevo_event_id
             WHERE g.venue_id IS NOT NULL AND e.venue_id IS NOT NULL
             GROUP BY g.venue_id, e.venue_id) s
     ORDER BY s.venue_id, s.n DESC, s.tv
    ON CONFLICT (mlb_venue_id) DO UPDATE
       SET venue_name = EXCLUDED.venue_name, venue_city = EXCLUDED.venue_city, tevo_venue_id = EXCLUDED.tevo_venue_id,
           tevo_venue_name = EXCLUDED.tevo_venue_name, games = EXCLUDED.games, derived_at = now()
     WHERE public.mlb_venue_xref.method = 'matched_games';
    UPDATE public.mlb_ticket_game g SET tevo_venue_id = x.tevo_venue_id
      FROM public.mlb_venue_xref x
     WHERE x.mlb_venue_id = g.venue_id AND g.tevo_venue_id IS DISTINCT FROM x.tevo_venue_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('venues_known', (SELECT count(*) FROM public.mlb_venue_xref WHERE tevo_venue_id IS NOT NULL), 'games_venue_set', v_n);
  END IF;

  -- 5. SeatGeek's EVO link for a game the schedule proves
  DROP TABLE IF EXISTS _mm_sg;
  CREATE TEMP TABLE _mm_sg ON COMMIT DROP AS
  SELECT c.sg_event_id, g.schedule_id, c.tevo_event_id AS old_tevo, x.tevo_event_id AS new_tevo,
         CASE WHEN c.tevo_event_id IS NULL THEN 'sg_fill' ELSE 'sg_repoint' END AS action,
         c.match_method AS old_method
    FROM public.mlb_ticket_game g
    JOIN _mm_eff x ON x.schedule_id = g.schedule_id AND x.tevo_event_id IS NOT NULL
    JOIN public.sg_events_canonical c ON c.sg_event_id = g.sg_event_id
    LEFT JOIN public.events e2 ON e2.id = c.tevo_event_id
    LEFT JOIN _mm_team th ON th.team_id = g.home_team_id
    LEFT JOIN _mm_team ta ON ta.team_id = g.away_team_id
   WHERE c.tevo_event_id IS DISTINCT FROM x.tevo_event_id
     AND NOT (e2.id IS NOT NULL AND coalesce(e2.state, 'shown') <> 'ignored'
              AND public.mlb_ticket_event_fits(e2.name, e2.occurs_at_local, e2.performer_ids, g.game_date,
                                               g.away_name, g.home_name, ta.pid, th.pid));
  IF p_apply THEN
    UPDATE public.sg_events_canonical c
       SET tevo_event_id = s.new_tevo, match_method = 'mlb_schedule', match_confidence = 1.0, matched_at = now(), updated_at = now()
      FROM _mm_sg s WHERE c.sg_event_id = s.sg_event_id;
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, new_tevo, old_sg, new_sg, note)
    SELECT v_run, s.schedule_id, s.action, 'sg_events_canonical', s.sg_event_id::text, s.old_tevo, s.new_tevo, s.sg_event_id, s.sg_event_id, s.old_method FROM _mm_sg s;
  END IF;
  SELECT coalesce(jsonb_object_agg(x.action, x.n), '{}'::jsonb) INTO v_by FROM (SELECT action, count(*) AS n FROM _mm_sg GROUP BY 1) x;
  v_out := v_out || jsonb_build_object('seatgeek', v_by);

  -- 6. the hub knows the game
  DROP TABLE IF EXISTS _mm_hub;
  CREATE TEMP TABLE _mm_hub ON COMMIT DROP AS
  SELECT g.schedule_id, x.tevo_event_id, g.sg_event_id, g.away_name || ' at ' || g.home_name AS nm, g.venue_name,
         coalesce(g.game_time_local, g.game_date::timestamp) AS starts, e.venue_id AS tevo_venue_id,
         (SELECT a.aq_short_event_id FROM public.aq_event_map a WHERE a.tevo_event_id = x.tevo_event_id
           ORDER BY (a.mlb_schedule_id = g.schedule_id) DESC NULLS LAST, (a.aq_source = 'aq_curated') DESC, a.imported_at NULLS LAST, a.aq_short_event_id
           LIMIT 1) AS aq,
         false AS created
    FROM public.mlb_ticket_game g
    JOIN _mm_eff x ON x.schedule_id = g.schedule_id AND x.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = x.tevo_event_id;
  v_out := v_out || jsonb_build_object('hub_rows_missing', (SELECT count(*) FROM _mm_hub WHERE aq IS NULL));
  IF p_apply THEN
    FOR r IN SELECT * FROM _mm_hub h WHERE h.aq IS NULL ORDER BY h.schedule_id LOOP
      v_aq := public.create_system_aq_event('mlb', r.nm, r.venue_name, r.starts::timestamptz, r.schedule_id);
      UPDATE public.aq_event_map
         SET tevo_event_id = r.tevo_event_id, tevo_venue_id = coalesce(tevo_venue_id, r.tevo_venue_id),
             primary_source = coalesce(primary_source, 'tevo')
       WHERE aq_short_event_id = v_aq AND tevo_event_id IS NULL;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN
        UPDATE _mm_hub SET aq = v_aq, created = true WHERE schedule_id = r.schedule_id;
        v_hub_rows := v_hub_rows + 1;
      END IF;   -- else: the SYS id already belongs to another EVO event (same name, park and start) -- the game stays without a hub row
    END LOOP;
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo)
    SELECT v_run, h.schedule_id, 'hub_row', 'aq_event_map', h.aq, h.tevo_event_id FROM _mm_hub h WHERE h.created;

    -- a hub row that names a game now matched to another EVO event lets go of it
    WITH u AS (
      UPDATE public.aq_event_map a SET mlb_schedule_id = NULL
        FROM public.mlb_ticket_game g
       WHERE g.schedule_id = a.mlb_schedule_id AND a.tevo_event_id IS DISTINCT FROM g.tevo_event_id
       RETURNING a.aq_short_event_id, g.schedule_id, a.tevo_event_id)
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo)
    SELECT v_run, u.schedule_id, 'hub_unlink', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;

    WITH u AS (
      UPDATE public.aq_event_map a SET mlb_schedule_id = h.schedule_id
        FROM _mm_hub h
       WHERE a.aq_short_event_id = h.aq AND a.mlb_schedule_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.mlb_schedule_id = h.schedule_id)
       RETURNING a.aq_short_event_id, h.schedule_id, h.tevo_event_id)
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo)
    SELECT v_run, u.schedule_id, 'hub_link', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_rows_created', v_hub_rows, 'hub_linked', v_n);

    WITH u AS (
      UPDATE public.aq_event_map a SET sg_event_id = h.sg_event_id
        FROM _mm_hub h
       WHERE a.aq_short_event_id = h.aq AND a.sg_event_id IS NULL AND h.sg_event_id IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM public.aq_event_map o WHERE o.sg_event_id = h.sg_event_id AND o.tevo_event_id IS DISTINCT FROM h.tevo_event_id)
       RETURNING a.aq_short_event_id, h.schedule_id, h.tevo_event_id, h.sg_event_id)
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo, new_sg)
    SELECT v_run, u.schedule_id, 'hub_sg', 'aq_event_map', u.aq_short_event_id, u.tevo_event_id, u.sg_event_id FROM u;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('hub_sg_filled', v_n);
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply) || v_out;
END $function$;

REVOKE ALL ON FUNCTION public.mlb_ticket_map(boolean),
               public.mlb_ticket_event_fits(text, text, bigint[], date, text, text, bigint, bigint)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mlb_ticket_map(boolean),
                          public.mlb_ticket_event_fits(text, text, bigint[], date, text, text, bigint, bigint)
  TO service_role;

-- hourly, five minutes after mlb_ticket_tick's full pass at :30
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mlb_ticket_map_hourly') THEN
    PERFORM cron.unschedule('mlb_ticket_map_hourly');
  END IF;
  PERFORM cron.schedule('mlb_ticket_map_hourly', '35 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '120s'; SELECT public.mlb_ticket_map(true); COMMIT;$j$);
END
$cron$;

SELECT public.mlb_ticket_map(true);

COMMIT;

-- VERIFY:
--   SELECT action, target, count(*) FROM mlb_map_audit WHERE run_id = (SELECT run_id FROM mlb_map_audit ORDER BY at DESC LIMIT 1) GROUP BY 1,2;
--   SELECT tevo_match_method, count(*) FROM mlb_ticket_game WHERE game_date >= current_date GROUP BY 1;
--   SELECT count(*) FILTER (WHERE mlb_schedule_id IS NOT NULL) FROM aq_event_map;      -- one per mapped game
--   SELECT primary_seller, count(*) FROM mlb_ticket_game WHERE ticket_url IS NOT NULL GROUP BY 1;
-- ROLLBACK (data): for one run, UPDATE sg_events_canonical SET tevo_event_id = a.old_tevo FROM mlb_map_audit a
--   WHERE a.run_id = $1 AND a.target = 'sg_events_canonical' AND sg_event_id = a.target_key::bigint; the same shape for
--   mlb_ticket_game (old_tevo) and aq_event_map (mlb_schedule_id / sg_event_id -> NULL for hub_link / hub_sg rows;
--   DELETE the hub_row rows); SELECT cron.unschedule('mlb_ticket_map_hourly').
