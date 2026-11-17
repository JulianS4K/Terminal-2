-- Migration 20261117070000 · level:data-collection · lane:A1 (data plane — ESPN) · writes:espn_event_tickets(new),espn_event_ticket_history(new),espn_scoreboard_queue(),espn_scoreboard_process(),v_espn_event_tickets(new) · reads:net._http_response,event_xref · pre:20261117061000
--
-- Operator 2026-11-17: "Save the vivid link for espn" — keep the ticket block ESPN's scoreboard
-- carries on every upcoming game, which our collector dropped:
--   competitions[0].tickets[0] = { summary: "Tickets as low as $76", numberAvailable: 221,
--     links: [ vividseats.com/…/production/7432945, vividseats.com/…/venue/24 ] }
--
-- WHY THE SWEEP HAS BEEN EMPTY SINCE 2026-08-04: espn_scoreboard_queue asks for a date range
-- (?dates=YYYYMMDD-YYYYMMDD&limit=1000). ESPN stopped serving that form: every request since at
-- least 2026-10-19 came back 403 from the database (400 from elsewhere), 0 events. So
-- espn_event_date_lookup — read by match_events_to_espn_tick, the broker event page, the event
-- chart and the lifecycle — has not been refreshed since 2026-08-04 (135 future rows left).
-- A month (?dates=YYYYMM&limit=1000) still answers 200 from the database: December NBA, 178
-- games, 172 with tickets (checked 2026-11-17).
--
-- CHANGE
--   * espn_scoreboard_queue(p_lookahead_days DEFAULT 180): one request per league per month, from
--     the month 30 days back through the month p_lookahead_days ahead (180 reaches the 2027 MLB
--     opener). Same leagues, same pending table, same daily cron. The User-Agent no longer carries
--     a personal e-mail address.
--   * espn_scoreboard_process(): unchanged date-lookup upsert, plus the ticket block into
--     espn_event_tickets — the "as low as" price parsed to min_price, numberAvailable, the Vivid
--     production URL + id, the Vivid venue URL + id, and the ESPN game page. A trigger appends a
--     row to espn_event_ticket_history whenever the price or count changes.
--   * v_espn_event_tickets: the ticket rows with the TEvo event each ESPN game is matched to
--     (event_xref), for the terminal / API to read.
-- The price is ESPN's (Vivid's) public "as low as" figure — read-only, RULE 2 (GET only).

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.espn_event_tickets (
  espn_event_id        text NOT NULL,
  espn_league          text NOT NULL,
  game_at_utc          timestamptz,
  summary              text,
  min_price            numeric(10,2),
  number_available     integer,
  vivid_url            text,
  vivid_production_id  bigint,
  vivid_venue_url      text,
  vivid_venue_id       integer,
  espn_url             text,
  first_seen_at        timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  price_changed_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (espn_event_id, espn_league)
);
CREATE INDEX IF NOT EXISTS espn_event_tickets_vivid_idx ON public.espn_event_tickets (vivid_production_id);
CREATE INDEX IF NOT EXISTS espn_event_tickets_game_idx ON public.espn_event_tickets (game_at_utc);

CREATE TABLE IF NOT EXISTS public.espn_event_ticket_history (
  id                bigserial PRIMARY KEY,
  espn_event_id     text NOT NULL,
  espn_league       text NOT NULL,
  observed_at       timestamptz NOT NULL DEFAULT now(),
  min_price         numeric(10,2),
  number_available  integer
);
CREATE INDEX IF NOT EXISTS espn_event_ticket_history_ev_idx
  ON public.espn_event_ticket_history (espn_event_id, espn_league, observed_at);

ALTER TABLE public.espn_event_tickets        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.espn_event_ticket_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.espn_event_tickets, public.espn_event_ticket_history FROM anon, authenticated;
GRANT SELECT ON public.espn_event_tickets, public.espn_event_ticket_history TO service_role;

CREATE OR REPLACE FUNCTION public.espn_event_tickets_log()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF TG_OP = 'INSERT'
     OR (OLD.min_price, OLD.number_available) IS DISTINCT FROM (NEW.min_price, NEW.number_available) THEN
    INSERT INTO espn_event_ticket_history (espn_event_id, espn_league, min_price, number_available)
    VALUES (NEW.espn_event_id, NEW.espn_league, NEW.min_price, NEW.number_available);
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS espn_event_tickets_log ON public.espn_event_tickets;
CREATE TRIGGER espn_event_tickets_log AFTER INSERT OR UPDATE ON public.espn_event_tickets
  FOR EACH ROW EXECUTE FUNCTION public.espn_event_tickets_log();

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

CREATE OR REPLACE FUNCTION public.espn_scoreboard_process()
RETURNS TABLE(processed integer, events_upserted integer)
LANGUAGE plpgsql SET search_path TO 'public', 'pg_temp' AS $function$
DECLARE
  r RECORD; v_body jsonb; feat jsonb; tk jsonb; v_viv text; v_ven text; v_price text;
  v_processed int := 0; v_upserted int := 0;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.espn_league, h.content, h.status_code
    FROM espn_scoreboard_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    v_body := NULL;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;

      IF v_body IS NOT NULL THEN
        FOR feat IN SELECT jsonb_array_elements(coalesce(v_body -> 'events', '[]'::jsonb))
        LOOP
          IF (feat ->> 'id') IS NOT NULL AND (feat ->> 'date') IS NOT NULL THEN
            INSERT INTO espn_event_date_lookup(espn_event_id, espn_league, game_at_utc,
                                                home_team_id, away_team_id, status_short)
            SELECT
              feat ->> 'id', r.espn_league,
              (feat ->> 'date')::timestamptz,
              (SELECT (c->'team'->>'id') FROM jsonb_array_elements(feat->'competitions'->0->'competitors') c WHERE c->>'homeAway' = 'home' LIMIT 1),
              (SELECT (c->'team'->>'id') FROM jsonb_array_elements(feat->'competitions'->0->'competitors') c WHERE c->>'homeAway' = 'away' LIMIT 1),
              feat -> 'status' -> 'type' ->> 'shortDetail'
            ON CONFLICT (espn_event_id, espn_league) DO UPDATE SET
              game_at_utc=EXCLUDED.game_at_utc, home_team_id=EXCLUDED.home_team_id,
              away_team_id=EXCLUDED.away_team_id, status_short=EXCLUDED.status_short, ingested_at=now();
            v_upserted := v_upserted + 1;

            -- the ticket block (upcoming games only; ESPN drops it once a game starts)
            tk := CASE jsonb_typeof(feat->'competitions'->0->'tickets')
                    WHEN 'array' THEN feat->'competitions'->0->'tickets'->0 END;
            IF tk IS NOT NULL AND jsonb_typeof(tk) = 'object' THEN
              SELECT l->>'href' INTO v_viv FROM jsonb_array_elements(coalesce(tk->'links', '[]'::jsonb)) l
               WHERE l->>'href' ~ '/production/\d+' LIMIT 1;
              SELECT l->>'href' INTO v_ven FROM jsonb_array_elements(coalesce(tk->'links', '[]'::jsonb)) l
               WHERE l->>'href' ~ '/venue/\d+' LIMIT 1;
              v_price := replace((regexp_match(coalesce(tk->>'summary', ''), '\$\s*([0-9][0-9,]*(\.[0-9]+)?)'))[1], ',', '');
              INSERT INTO espn_event_tickets AS t (
                espn_event_id, espn_league, game_at_utc, summary, min_price, number_available,
                vivid_url, vivid_production_id, vivid_venue_url, vivid_venue_id, espn_url)
              VALUES (
                feat ->> 'id', r.espn_league, (feat ->> 'date')::timestamptz, nullif(tk->>'summary', ''),
                CASE WHEN v_price ~ '^\d{1,8}(\.\d+)?$' THEN v_price::numeric END,
                CASE WHEN tk->>'numberAvailable' ~ '^\d{1,9}$' THEN (tk->>'numberAvailable')::int END,
                regexp_replace(v_viv, '\?.*$', ''),
                (regexp_match(v_viv, '/production/(\d{1,18})'))[1]::bigint,
                regexp_replace(v_ven, '\?.*$', ''),
                (regexp_match(v_ven, '/venue/(\d{1,9})'))[1]::int,
                (SELECT l->>'href' FROM jsonb_array_elements(coalesce(feat->'links', '[]'::jsonb)) l
                  WHERE l->>'href' LIKE '%/game/%' LIMIT 1))
              ON CONFLICT (espn_event_id, espn_league) DO UPDATE SET
                game_at_utc = EXCLUDED.game_at_utc, summary = EXCLUDED.summary,
                min_price = EXCLUDED.min_price, number_available = EXCLUDED.number_available,
                vivid_url = coalesce(EXCLUDED.vivid_url, t.vivid_url),
                vivid_production_id = coalesce(EXCLUDED.vivid_production_id, t.vivid_production_id),
                vivid_venue_url = coalesce(EXCLUDED.vivid_venue_url, t.vivid_venue_url),
                vivid_venue_id = coalesce(EXCLUDED.vivid_venue_id, t.vivid_venue_id),
                espn_url = coalesce(EXCLUDED.espn_url, t.espn_url),
                updated_at = now(),
                price_changed_at = CASE WHEN t.min_price IS DISTINCT FROM EXCLUDED.min_price
                                        THEN now() ELSE t.price_changed_at END;
            END IF;
          END IF;
        END LOOP;
      END IF;
    END IF;
    UPDATE espn_scoreboard_pending
       SET resolved_at = now(),
           http_status = r.status_code,
           events_count = jsonb_array_length(COALESCE(v_body -> 'events','[]'::jsonb))
     WHERE id = r.pending_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_upserted;
END $function$;

CREATE OR REPLACE VIEW public.v_espn_event_tickets
WITH (security_invoker = true) AS
SELECT t.espn_event_id, t.espn_league, t.game_at_utc, t.summary, t.min_price, t.number_available,
       t.vivid_url, t.vivid_production_id, t.vivid_venue_url, t.vivid_venue_id, t.espn_url,
       x.tevo_event_id, e.name AS tevo_event_name,
       t.first_seen_at, t.updated_at, t.price_changed_at
  FROM public.espn_event_tickets t
  LEFT JOIN LATERAL (SELECT ex.tevo_event_id FROM public.event_xref ex
                      WHERE ex.espn_event_id = t.espn_event_id AND ex.espn_league = t.espn_league
                      ORDER BY ex.matched_at DESC NULLS LAST LIMIT 1) x ON true
  LEFT JOIN public.events e ON e.id = x.tevo_event_id
 WHERE t.game_at_utc >= now() - interval '1 day';

REVOKE ALL ON FUNCTION public.espn_event_tickets_log() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.espn_scoreboard_queue(integer), public.espn_scoreboard_process()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.espn_scoreboard_queue(integer), public.espn_scoreboard_process() TO service_role;
REVOKE ALL ON public.v_espn_event_tickets FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_espn_event_tickets TO service_role;

COMMIT;

-- VERIFY (after the 04:00 UTC queue + 04:07 process, or a manual SELECT espn_scoreboard_queue()):
--   SELECT espn_league, http_status, count(*), sum(events_count) FROM espn_scoreboard_pending
--    WHERE fired_at > now() - interval '1 hour' GROUP BY 1,2;          -- 200s, events > 0
--   SELECT max(ingested_at), count(*) FILTER (WHERE game_at_utc > now()) FROM espn_event_date_lookup;
--   SELECT espn_league, count(*), count(vivid_production_id), avg(min_price) FROM espn_event_tickets GROUP BY 1;
-- ROLLBACK: re-create espn_scoreboard_queue / espn_scoreboard_process from prod's previous bodies
--   (range form — note it returns nothing); DROP VIEW v_espn_event_tickets; DROP TABLE
--   espn_event_ticket_history, espn_event_tickets; DROP FUNCTION espn_event_tickets_log().
