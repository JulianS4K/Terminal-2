-- Migration 20261117100000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:event_mapper_identity() fn (MLB schedule identity for SeatGeek ids),mlb_hub_link(+entity; PK entity+schedule_id),mlb_stadium_title_fits()(new),mlb_ticket_map() fn (removed games, doubleheader twins, time flags, stadium events),mlb_ticket_event(tevo_event_id fill-only — DML),aq_event_map(rows for mapped stadium events — DML only, no DDL),cron:mlb_ticket_map_hourly(ceiling) · reads:mlb_ticket_game,mlb_ticket_event,mlb_venue_xref,events,aq_event_map,sg_events_canonical · pre:20261117090000
--
-- MAPPING PROGRAM — THE MLB TICKETING SCHEDULE INSIDE THE EVENT MAPPER.
--
-- Asked by the Terminal hub session at the operator's request (2026-11-17, "incorporate it into event mapper"): the
-- MLB/MiLB ticketing schedule (mlb_ticket_game, 150 clubs; mlb_ticket_event, the clubs' non-game dates — mig
-- 20261117060000) is a primary source and should anchor the shared resolver and catch mislinks. Four things, all
-- read-only on the schedule's own tick and crons (mlb_ticket_tick / mlb_ticket_match* / mlb_ticket_alert_tick are
-- not touched; they are the hub session's):
--
--   1. IDENTITY. event_mapper_identity('seatgeek', <sg id>) — stage 0 of every surface the resolver maps — now asks
--      the schedule first: a game the schedule ties to that SeatGeek id (mlb_ticket_match_sg) and to an EVO event
--      (mlb_ticket_map, verified hourly) answers 'identity_mlb_schedule'; sg_events_canonical's own link second, the
--      hub third. The other sources (GoTickets, TickPick, Vivid, StubHub, Ticketmaster) reach the games through the
--      hub rows mlb_ticket_map() keeps for every mapped game (mig 20261117000000 step 6).
--   2. MISLINKS. v_mlb_schedule_feed.tevo_time_check says 'differs' on 808 upcoming games (2026-11-17), but 758 of
--      them are EVO's "time to be announced" hours — T12:00, T23:59, T03:30 — on 2027 games, not wrong events.
--      The mapper already drops a match whose day or clubs no longer fit; it now also drops a DOUBLEHEADER TWIN (a
--      timed EVO listing on the other game's minute — the one way the clubs and the day can agree on the wrong game;
--      0 on prod today, 4 games in doubleheaders) and flags, once per game and time, a timed listing more than ten
--      minutes off MLB's start (mlb_map_audit 'time_differs': informational — the day and both clubs agree, so it is
--      the game at a different listed hour; ~110 today). Never a repoint on time alone.
--   3. CHANGES. mlb_ticket_tick clears tevo_event_id when a game's date moves; the mapper re-matches such a game on
--      its next pass and lets the stale hub link go (unchanged since mig 20261117000000). A REMOVED game (or event)
--      now also leaves the hub: its mlb_hub_link row goes (audit 'hub_unlink … removed'); its EVO id is kept, as
--      the tick keeps it, so a restored row is whole again. A time change is re-verified every hour by rule 2.
--   4. STADIUM EVENTS. mlb_ticket_event rows (175 upcoming: concerts such as Fall Out Boy at Fenway / Globe Life,
--      but also "Pre-Game Party", "Kids Club ID Pickup", "Suites: …") are matched by mlb_ticket_match_events() on
--      venue name + day (19 so far). The mapper adds a stricter second rule that uses what it knows: the park's
--      EVO venue from mlb_venue_xref (learned from the games both sides name), a day with no game at that park, a
--      title sharing a word of four letters or more with the EVO listing (mlb_stadium_title_fits), exactly one
--      candidate not held by any game or event — fill-only ('venue_xref_title'). Every mapped stadium event gets a
--      hub row like a game does; mlb_hub_link gains `entity` ('game' | 'event') and is keyed by (entity,
--      schedule_id) — the two id spaces are both MLB schedule ids and must not collide in the link.
--
-- Bodies: event_mapper_identity from mig 20261117080000 and mlb_ticket_map from mig 20261117000000 (both on this
-- branch, not yet applied), regenerated with only the marked blocks changed. Nothing upstream is called (RULE 2).
-- Step order inside mlb_ticket_map is now 0, 1, 1b, 1c, 2, 3, 4, 7, 5, 6 (the stadium events need step 4's parks).

BEGIN;
SET LOCAL lock_timeout = '10s';

-- ───────────────────────── 1. the resolver's identity stage asks the schedule first ─────────────────────────
CREATE OR REPLACE FUNCTION public.event_mapper_identity(p_source text, p_source_event_id bigint)
 RETURNS TABLE(tevo_event_id bigint, method text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_src text := lower(trim(coalesce(p_source, ''))); v_tevo bigint; v_meth text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_source_event_id IS NULL THEN RETURN; END IF;

  IF v_src IN ('tevo', 'evo') THEN
    tevo_event_id := p_source_event_id; method := 'identity_tevo'; RETURN NEXT; RETURN;
  ELSIF v_src IN ('gotickets', 'gt') THEN
    SELECT g.tevo_event_id INTO v_tevo FROM public.gotickets_event g
     WHERE g.gt_event_id = p_source_event_id AND g.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_gotickets_event'; END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.gotickets_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('seatgeek', 'sg') THEN
    -- mig 20261117100000: the MLB ticketing schedule first — a game the schedule ties to this SeatGeek id names
    -- the EVO event with the authority of the league's own back end (mlb_ticket_map() verifies it every hour);
    -- SeatGeek's own link named another EVO event on 137 games and was wrong on 134 of them (mig 20261117000000)
    SELECT g.tevo_event_id INTO v_tevo FROM public.mlb_ticket_game g
     WHERE g.sg_event_id = p_source_event_id AND g.tevo_event_id IS NOT NULL AND g.removed_at IS NULL
     ORDER BY g.tevo_matched_at DESC NULLS LAST LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_mlb_schedule'; END IF;
    IF v_tevo IS NULL THEN
      SELECT c.tevo_event_id INTO v_tevo FROM public.sg_events_canonical c
       WHERE c.sg_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_sg_canonical'; END IF;
    END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.sg_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('tickpick', 'tp') THEN
    -- mig 20261117080000: the TickPick catalogue's verified match first, the hub second
    SELECT c.tevo_event_id INTO v_tevo FROM public.tickpick_catalog_event c
     WHERE c.tp_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_tickpick_catalog'; END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.tp_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('vivid', 'vividseats', 'vivid seats') THEN
    -- mig 20261117080000: the Vivid catalogue (its eventId = the productionId on our orders) first, the hub second
    SELECT c.tevo_event_id INTO v_tevo FROM public.vivid_catalog_event c
     WHERE c.vivid_event_id = p_source_event_id AND c.tevo_event_id IS NOT NULL LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_vivid_catalog'; END IF;
    IF v_tevo IS NULL THEN
      SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
       WHERE a.vivid_event_id = p_source_event_id AND a.tevo_event_id IS NOT NULL
       ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
      IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
    END IF;
  ELSIF v_src IN ('stubhub', 'sh', 'ticketmaster', 'tm', 'seatdata', 'sd') THEN
    SELECT a.tevo_event_id INTO v_tevo FROM public.aq_event_map a
     WHERE a.tevo_event_id IS NOT NULL
       AND ((v_src IN ('stubhub', 'sh')                      AND a.sh_event_id    = p_source_event_id)
         OR (v_src IN ('ticketmaster', 'tm')                 AND a.tm_event_id    = p_source_event_id)
         OR (v_src IN ('seatdata', 'sd')                     AND a.sd_event_id    = p_source_event_id))
     ORDER BY (a.aq_source = 'aq_curated') DESC, a.imported_at DESC LIMIT 1;
    IF v_tevo IS NOT NULL THEN v_meth := 'identity_hub'; END IF;
  END IF;

  IF v_tevo IS NOT NULL THEN
    tevo_event_id := v_tevo; method := v_meth; RETURN NEXT;
  END IF;
  RETURN;
END $function$;

-- ───────────────────────── 2. the hub link carries games and stadium events apart ─────────────────────────
ALTER TABLE public.mlb_hub_link ADD COLUMN IF NOT EXISTS entity text NOT NULL DEFAULT 'game' CHECK (entity IN ('game', 'event'));
DO $pk$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
     WHERE c.conrelid = 'public.mlb_hub_link'::regclass AND c.contype = 'p'
       AND c.conkey = ARRAY[(SELECT a.attnum FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attname = 'entity'),
                            (SELECT a.attnum FROM pg_attribute a WHERE a.attrelid = c.conrelid AND a.attname = 'schedule_id')]) THEN
    ALTER TABLE public.mlb_hub_link DROP CONSTRAINT IF EXISTS mlb_hub_link_pkey;
    ALTER TABLE public.mlb_hub_link ADD PRIMARY KEY (entity, schedule_id);
  END IF;
END
$pk$;
COMMENT ON TABLE public.mlb_hub_link IS
  'MLB ticketing game (entity=game, mlb_ticket_game.schedule_id) or stadium event (entity=event, mlb_ticket_event.schedule_id) -> its hub row (aq_event_map.aq_short_event_id); one row per hub row and one hub row per game/event; kept by mlb_ticket_map(). Join the hub through this, never by name or date.';

-- does a stadium event's title name the EVO listing? a shared word of four letters or more that is not filler
CREATE OR REPLACE FUNCTION public.mlb_stadium_title_fits(p_title text, p_event_name text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT EXISTS (
    SELECT 1
      FROM regexp_split_to_table(lower(coalesce(p_title, '')), '[^a-z0-9]+') t
     WHERE length(t) >= 4
       AND t NOT IN ('with', 'from', 'live', 'tour', 'show', 'night', 'game', 'party', 'event', 'events', 'suite', 'suites',
                     'club', 'stadium', 'park', 'field', 'ballpark', 'presents', 'presented', 'featuring', 'special', 'guest',
                     'tickets', 'ticket', 'concert', 'series', 'experience', 'premium', 'pregame', 'postgame', 'members',
                     'membership', 'pickup')
       AND t = ANY (regexp_split_to_array(lower(coalesce(p_event_name, '')), '[^a-z0-9]+')))
$function$;
REVOKE ALL ON FUNCTION public.mlb_stadium_title_fits(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mlb_stadium_title_fits(text, text) TO service_role;

-- ───────────────────────── 3. the mapper ─────────────────────────
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

  -- 1. verify every EVO match: still that game? (mig 20261117100000: a removed game is left as it is — its hub
  --    link goes in 1b; a doubleheader twin — a timed EVO listing on the OTHER game's minute that day — is dropped,
  --    so step 2 can hand it to the game it is, by MLB's minute, on the next pass)
  DROP TABLE IF EXISTS _mm_drop;
  CREATE TEMP TABLE _mm_drop ON COMMIT DROP AS
  SELECT g.schedule_id, g.tevo_event_id,
         CASE WHEN e.id IS NULL THEN 'event_gone'
              WHEN coalesce(e.state, 'shown') = 'ignored' THEN 'event_ignored'
              WHEN left(e.occurs_at_local, 10) <> g.game_date::text THEN 'date_moved'
              WHEN coalesce(dh.twin, false) THEN 'doubleheader_twin'
              ELSE 'clubs_differ' END AS reason
    FROM public.mlb_ticket_game g
    LEFT JOIN public.events e ON e.id = g.tevo_event_id
    LEFT JOIN _mm_team th ON th.team_id = g.home_team_id
    LEFT JOIN _mm_team ta ON ta.team_id = g.away_team_id
    LEFT JOIN LATERAL (
      SELECT true AS twin
        FROM public.mlb_ticket_game s
       WHERE e.id IS NOT NULL AND NOT coalesce(g.is_tbd, false) AND g.game_time_utc IS NOT NULL AND e.occurs_at_local !~ 'T00:00(:00)?'
         AND s.game_date = g.game_date AND s.home_team_id = g.home_team_id AND s.away_team_id = g.away_team_id
         AND s.schedule_id <> g.schedule_id AND s.removed_at IS NULL AND NOT coalesce(s.is_tbd, false) AND s.game_time_utc IS NOT NULL
         AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - s.game_time_utc)) <= 60
         AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - g.game_time_utc)) > 60
       LIMIT 1) dh ON true
   WHERE g.tevo_event_id IS NOT NULL AND g.game_date >= current_date - 1 AND g.removed_at IS NULL
     AND (coalesce(dh.twin, false)
          OR NOT (e.id IS NOT NULL AND coalesce(e.state, 'shown') <> 'ignored'
                  AND public.mlb_ticket_event_fits(e.name, e.occurs_at_local, e.performer_ids, g.game_date,
                                                   g.away_name, g.home_name, ta.pid, th.pid)));
  IF p_apply THEN
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
    SELECT v_run, d.schedule_id, 'drop', 'mlb_ticket_game', d.schedule_id::text, d.tevo_event_id, d.reason FROM _mm_drop d;
    DELETE FROM public.mlb_hub_link l USING _mm_drop d WHERE l.schedule_id = d.schedule_id;
    UPDATE public.mlb_ticket_game g
       SET tevo_event_id = NULL, tevo_matched_at = NULL, tevo_match_method = NULL, changed_at = now()
      FROM _mm_drop d WHERE d.schedule_id = g.schedule_id;
  END IF;
  SELECT count(*) INTO v_n FROM _mm_drop;
  v_out := v_out || jsonb_build_object('dropped', v_n);

  -- 1b. a removed game or stadium event (mlb_ticket_tick: no longer on the club's schedule) keeps its EVO id — the
  --     tick restores it when the row comes back — but leaves the hub (mig 20261117100000)
  DROP TABLE IF EXISTS _mm_removed;
  CREATE TEMP TABLE _mm_removed ON COMMIT DROP AS
  SELECT l.entity, l.schedule_id, l.aq_short_event_id, l.tevo_event_id
    FROM public.mlb_hub_link l
   WHERE (l.entity = 'game'  AND EXISTS (SELECT 1 FROM public.mlb_ticket_game  g WHERE g.schedule_id = l.schedule_id AND g.removed_at IS NOT NULL))
      OR (l.entity = 'event' AND EXISTS (SELECT 1 FROM public.mlb_ticket_event v WHERE v.schedule_id = l.schedule_id AND v.removed_at IS NOT NULL));
  IF p_apply THEN
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
    SELECT v_run, rm.schedule_id, 'hub_unlink', 'mlb_hub_link', rm.aq_short_event_id, rm.tevo_event_id, rm.entity || ' removed' FROM _mm_removed rm;
    DELETE FROM public.mlb_hub_link l USING _mm_removed rm WHERE l.entity = rm.entity AND l.schedule_id = rm.schedule_id;
  END IF;
  v_out := v_out || jsonb_build_object('removed_unlinked', (SELECT count(*) FROM _mm_removed));

  -- 1c. MLB's start against the EVO listing's: a timed listing more than ten minutes off is flagged once
  --     (mlb_map_audit 'time_differs'), never dropped — the clubs are named and the day agrees, so it is the game,
  --     listed at a different hour. EVO's T12:00 / T23:59 / T03:30 (and T00:00) stand for "time to be announced":
  --     on 2026-11-17 they made 758 of the 808 games the feed view (v_mlb_schedule_feed.tevo_time_check) called
  --     'differs', so they are read as unknown here (mig 20261117100000)
  DROP TABLE IF EXISTS _mm_tdiff;
  CREATE TEMP TABLE _mm_tdiff ON COMMIT DROP AS
  SELECT g.schedule_id, g.tevo_event_id,
         format('evo %s vs mlb %s (%s min)', left(e.occurs_at_local, 16), to_char(g.game_time_local, 'YYYY-MM-DD"T"HH24:MI'),
                round(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - g.game_time_utc) / 60)) AS note
    FROM public.mlb_ticket_game g
    JOIN public.events e ON e.id = g.tevo_event_id
   WHERE g.game_date >= current_date AND g.removed_at IS NULL AND NOT coalesce(g.is_tbd, false) AND g.game_time_utc IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM _mm_drop d WHERE d.schedule_id = g.schedule_id)
     AND e.occurs_at_local !~ 'T(00:00|12:00|23:59|03:30)'
     AND abs(extract(epoch FROM public.tevo_event_utc(e.occurs_at_local, e.venue_id) - g.game_time_utc)) > 600;
  IF p_apply THEN
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
    SELECT v_run, t.schedule_id, 'time_differs', 'mlb_ticket_game', t.schedule_id::text, t.tevo_event_id, t.note FROM _mm_tdiff t
     WHERE NOT EXISTS (SELECT 1 FROM public.mlb_map_audit a
                        WHERE a.action = 'time_differs' AND a.schedule_id = t.schedule_id AND a.old_tevo = t.tevo_event_id AND a.note = t.note);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_out := v_out || jsonb_build_object('time_differs_new', v_n);
  END IF;
  v_out := v_out || jsonb_build_object('time_differs', (SELECT count(*) FROM _mm_tdiff));

  -- 2. match the unmatched: both clubs on the game's local day, one game per EVO event
  DROP TABLE IF EXISTS _mm_cand;
  CREATE TEMP TABLE _mm_cand ON COMMIT DROP AS
  WITH todo AS (
    SELECT g.schedule_id, g.game_date, g.is_tbd, g.game_time_utc, g.away_name, g.home_name,
           ta.pid AS away_pid, th.pid AS home_pid
      FROM public.mlb_ticket_game g
      LEFT JOIN _mm_team th ON th.team_id = g.home_team_id
      LEFT JOIN _mm_team ta ON ta.team_id = g.away_team_id
     WHERE g.tevo_event_id IS NULL AND g.game_date >= current_date - 1 AND g.removed_at IS NULL
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

  -- the game -> EVO event picture as this pass leaves it (the same in a dry run); the stadium events join it in step 7
  DROP TABLE IF EXISTS _mm_eff;
  CREATE TEMP TABLE _mm_eff ON COMMIT DROP AS
  SELECT 'game'::text AS entity, g.schedule_id,
         CASE WHEN d.schedule_id IS NOT NULL THEN NULL ELSE coalesce(p.tevo_event_id, g.tevo_event_id) END AS tevo_event_id
    FROM public.mlb_ticket_game g
    LEFT JOIN _mm_drop d ON d.schedule_id = g.schedule_id
    LEFT JOIN _mm_pick p ON p.schedule_id = g.schedule_id
   WHERE g.game_date >= current_date - 1 AND g.removed_at IS NULL;

  SELECT coalesce(jsonb_object_agg(x.method, x.n), '{}'::jsonb) INTO v_by FROM (SELECT method, count(*) AS n FROM _mm_pick GROUP BY 1) x;
  SELECT count(*) INTO v_n FROM _mm_pick;
  v_out := v_out || jsonb_build_object('matched', v_n, 'matched_by', v_by,
             'ambiguous', (SELECT count(DISTINCT c.schedule_id) FROM _mm_cand c WHERE NOT EXISTS (SELECT 1 FROM _mm_pick p WHERE p.schedule_id = c.schedule_id)),
             'unmatched', (SELECT count(*) FROM _mm_eff x WHERE x.entity = 'game' AND x.tevo_event_id IS NULL));

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

  -- 7. stadium events (mlb_ticket_event, mig 20261117060000: the concerts and other non-game dates the clubs sell).
  --    mlb_ticket_match_events() pairs them by venue name + day; this adds the park's known EVO venue (mlb_venue_xref,
  --    step 4), a title that shares a word with the EVO listing, a day with no game at the park, one candidate —
  --    fill-only, so the tick's own match stands where it has one (mig 20261117100000)
  DROP TABLE IF EXISTS _mm_evpick;
  CREATE TEMP TABLE _mm_evpick ON COMMIT DROP AS
  WITH todo AS (
    SELECT v.schedule_id, v.event_date, v.title, x.tevo_venue_id
      FROM public.mlb_ticket_event v
      JOIN public.mlb_venue_xref x ON x.mlb_venue_id = v.venue_id AND x.tevo_venue_id IS NOT NULL
     WHERE v.tevo_event_id IS NULL AND v.removed_at IS NULL AND v.event_date >= current_date AND NOT coalesce(v.is_tbd, false)
       AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game g WHERE g.venue_id = v.venue_id AND g.game_date = v.event_date AND g.removed_at IS NULL)),
  cand AS (
    SELECT t.schedule_id, e.id, count(*) OVER (PARTITION BY t.schedule_id) AS n
      FROM todo t
      JOIN public.events e ON left(e.occurs_at_local, 10) = t.event_date::text AND e.venue_id = t.tevo_venue_id
                          AND coalesce(e.state, 'shown') <> 'ignored' AND lower(e.name) !~ '(parking|tailgate|package)'
                          AND public.mlb_stadium_title_fits(t.title, e.name))
  SELECT c.schedule_id, c.id AS tevo_event_id
    FROM cand c
   WHERE c.n = 1
     AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_game  g WHERE g.tevo_event_id = c.id)
     AND NOT EXISTS (SELECT 1 FROM public.mlb_ticket_event o WHERE o.tevo_event_id = c.id)
     AND NOT EXISTS (SELECT 1 FROM cand o WHERE o.id = c.id AND o.schedule_id <> c.schedule_id);
  IF p_apply THEN
    UPDATE public.mlb_ticket_event v
       SET tevo_event_id = p.tevo_event_id, tevo_match_method = 'venue_xref_title', tevo_matched_at = now(), changed_at = now()
      FROM _mm_evpick p WHERE p.schedule_id = v.schedule_id AND v.tevo_event_id IS NULL;
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo, note)
    SELECT v_run, p.schedule_id, 'event_match', 'mlb_ticket_event', p.schedule_id::text, p.tevo_event_id, 'venue_xref_title' FROM _mm_evpick p;
  END IF;
  INSERT INTO _mm_eff (entity, schedule_id, tevo_event_id)
  SELECT 'event', v.schedule_id, coalesce(p.tevo_event_id, v.tevo_event_id)
    FROM public.mlb_ticket_event v
    LEFT JOIN _mm_evpick p ON p.schedule_id = v.schedule_id
   WHERE v.event_date >= current_date - 1 AND v.removed_at IS NULL;
  v_out := v_out || jsonb_build_object('events_matched', (SELECT count(*) FROM _mm_evpick),
             'events_unmatched', (SELECT count(*) FROM _mm_eff x WHERE x.entity = 'event' AND x.tevo_event_id IS NULL));

  -- 5. SeatGeek's EVO link for a game the schedule proves
  DROP TABLE IF EXISTS _mm_sg;
  CREATE TEMP TABLE _mm_sg ON COMMIT DROP AS
  SELECT c.sg_event_id, g.schedule_id, c.tevo_event_id AS old_tevo, x.tevo_event_id AS new_tevo,
         CASE WHEN c.tevo_event_id IS NULL THEN 'sg_fill' ELSE 'sg_repoint' END AS action,
         c.match_method AS old_method
    FROM public.mlb_ticket_game g
    JOIN _mm_eff x ON x.entity = 'game' AND x.schedule_id = g.schedule_id AND x.tevo_event_id IS NOT NULL
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

  -- 6. the hub knows the game (and, mig 20261117100000, the stadium event)
  DROP TABLE IF EXISTS _mm_hubrow;
  CREATE TEMP TABLE _mm_hubrow ON COMMIT DROP AS      -- one hub row per EVO event of a mapped game: one scan of the hub, hash-joined
  SELECT DISTINCT ON (a.tevo_event_id) a.tevo_event_id, a.aq_short_event_id
    FROM public.aq_event_map a
    JOIN (SELECT DISTINCT x.tevo_event_id FROM _mm_eff x WHERE x.tevo_event_id IS NOT NULL) x ON x.tevo_event_id = a.tevo_event_id
   ORDER BY a.tevo_event_id,
            EXISTS (SELECT 1 FROM public.mlb_hub_link l WHERE l.aq_short_event_id = a.aq_short_event_id) DESC,   -- the row already tied to a game
            (a.aq_source = 'aq_curated') DESC, a.imported_at NULLS LAST, a.aq_short_event_id;
  DROP TABLE IF EXISTS _mm_hub;
  CREATE TEMP TABLE _mm_hub ON COMMIT DROP AS
  SELECT 'game'::text AS entity, g.schedule_id, x.tevo_event_id, g.sg_event_id, g.away_name || ' at ' || g.home_name AS nm, g.venue_name,
         coalesce(g.game_time_local, g.game_date::timestamp) AS starts, e.venue_id AS tevo_venue_id,
         h.aq_short_event_id AS aq, false AS created
    FROM public.mlb_ticket_game g
    JOIN _mm_eff x ON x.entity = 'game' AND x.schedule_id = g.schedule_id AND x.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = x.tevo_event_id
    LEFT JOIN _mm_hubrow h ON h.tevo_event_id = x.tevo_event_id
  UNION ALL
  SELECT 'event', v.schedule_id, x.tevo_event_id, NULL::bigint, v.title, v.venue_name,
         coalesce(v.event_time_local, v.event_date::timestamp), e.venue_id, h.aq_short_event_id, false
    FROM public.mlb_ticket_event v
    JOIN _mm_eff x ON x.entity = 'event' AND x.schedule_id = v.schedule_id AND x.tevo_event_id IS NOT NULL
    JOIN public.events e ON e.id = x.tevo_event_id
    LEFT JOIN _mm_hubrow h ON h.tevo_event_id = x.tevo_event_id;
  v_out := v_out || jsonb_build_object('hub_rows_missing', (SELECT count(*) FROM _mm_hub WHERE aq IS NULL));
  IF p_apply THEN
    FOR r IN SELECT * FROM _mm_hub h WHERE h.aq IS NULL ORDER BY h.entity, h.schedule_id LOOP
      v_aq := public.create_system_aq_event('mlb', r.nm, r.venue_name, r.starts::timestamptz, r.schedule_id);
      UPDATE public.aq_event_map
         SET tevo_event_id = r.tevo_event_id, tevo_venue_id = coalesce(tevo_venue_id, r.tevo_venue_id),
             primary_source = coalesce(primary_source, 'tevo')
       WHERE aq_short_event_id = v_aq AND tevo_event_id IS NULL;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      IF v_n > 0 THEN
        UPDATE _mm_hub SET aq = v_aq, created = true WHERE entity = r.entity AND schedule_id = r.schedule_id;
        v_hub_rows := v_hub_rows + 1;
      END IF;   -- else: the SYS id already belongs to another EVO event (same name, park and start) -- the game stays without a hub row
    END LOOP;
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo, note)
    SELECT v_run, h.schedule_id, 'hub_row', 'aq_event_map', h.aq, h.tevo_event_id, h.entity FROM _mm_hub h WHERE h.created;

    -- a link whose hub row no longer is the game's EVO event (the game was re-matched, or the row changed) goes
    WITH u AS (
      DELETE FROM public.mlb_hub_link l
       USING _mm_eff x
       WHERE x.entity = l.entity AND x.schedule_id = l.schedule_id
         AND x.tevo_event_id IS DISTINCT FROM (SELECT a.tevo_event_id FROM public.aq_event_map a WHERE a.aq_short_event_id = l.aq_short_event_id)
       RETURNING l.aq_short_event_id, l.schedule_id, l.tevo_event_id, l.entity)
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, old_tevo, note)
    SELECT v_run, u.schedule_id, 'hub_unlink', 'mlb_hub_link', u.aq_short_event_id, u.tevo_event_id, u.entity || ' re-matched' FROM u;

    -- every mapped game tied to its hub row, one game per row
    WITH u AS (
      INSERT INTO public.mlb_hub_link (entity, schedule_id, aq_short_event_id, tevo_event_id)
      SELECT h.entity, h.schedule_id, h.aq, h.tevo_event_id FROM _mm_hub h
       WHERE h.aq IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM public.mlb_hub_link l WHERE (l.entity = h.entity AND l.schedule_id = h.schedule_id) OR l.aq_short_event_id = h.aq)
      RETURNING aq_short_event_id, schedule_id, tevo_event_id)
    INSERT INTO public.mlb_map_audit (run_id, schedule_id, action, target, target_key, new_tevo)
    SELECT v_run, u.schedule_id, 'hub_link', 'mlb_hub_link', u.aq_short_event_id, u.tevo_event_id FROM u;
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

-- hourly at :35 as before; the ceiling grows with the two new steps (120 s -> 180 s)
DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'mlb_ticket_map_hourly') THEN
    PERFORM cron.unschedule('mlb_ticket_map_hourly');
  END IF;
  PERFORM cron.schedule('mlb_ticket_map_hourly', '35 * * * *',
                        $j$BEGIN; SET LOCAL statement_timeout = '180s'; SELECT public.mlb_ticket_map(true); COMMIT;$j$);
END
$cron$;

COMMIT;

-- VERIFY:
--   SELECT * FROM event_mapper_identity('seatgeek', (SELECT sg_event_id FROM mlb_ticket_game WHERE sg_event_id IS NOT NULL AND tevo_event_id IS NOT NULL LIMIT 1));
--   SELECT public.mlb_ticket_map(false);                                       -- dropped / removed_unlinked / time_differs / events_matched
--   SELECT action, note, count(*) FROM mlb_map_audit WHERE action IN ('time_differs', 'event_match', 'hub_unlink') GROUP BY 1, 2 ORDER BY 3 DESC;
--   SELECT entity, count(*) FROM mlb_hub_link GROUP BY 1;
