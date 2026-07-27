-- ============================================================================
-- Migration 20260509480000 — Tournament event backfill (tennis / golf / F1)
--
-- Per directive: pull tournament events into the events table for sports
-- whose schedule is multi-day, single-tournament rather than the team-vs-team
-- weekly cadence (NBA/NFL/MLB/NHL/MLS/WNBA already handled by existing
-- crons). Scoped to **continental North America** only — US, Canada, Mexico.
--
-- Coverage:
--   Tennis (US):  US Open, Indian Wells, Miami Open, Cincinnati Open,
--                 Charleston Open, Atlanta Open, Hall of Fame Open
--   Golf (US):    Masters, US Open Golf, PGA Championship, Players,
--                 Memorial, WM Phoenix Open, Genesis Invitational,
--                 BMW Championship, Tour Championship
--   F1 (N.A.):    Miami GP, US GP (Austin), Las Vegas GP,
--                 Canadian GP, Mexico City GP
--
-- Approach: TEvo /v9/events?name=<query>&occurs_at.gte=<today> text search
-- per query, async pattern (queue + pending + process), weekly cron.
--
-- These events are not handled by existing v_mlb_game_series since the
-- shape is different (multi-day single tournament, not 3-game team series).
-- See docs/tournament-event-detection.md for the design rationale + a
-- future companion view (v_tournament_grouping) sketched out.
-- ============================================================================

-- ============================================================================
-- (1) Reference table of searches to run
-- ============================================================================

CREATE TABLE IF NOT EXISTS tournament_search_queries (
  query           text PRIMARY KEY,
  genre           text NOT NULL,         -- 'tennis' | 'golf' | 'f1'
  region          text NOT NULL,         -- 'US' | 'Canada' | 'Mexico'
  notes           text,
  enabled         boolean DEFAULT true,
  added_at        timestamptz DEFAULT now()
);

INSERT INTO tournament_search_queries(query, genre, region, notes) VALUES
  -- US tennis
  ('US Open Tennis',     'tennis', 'US', 'Aug-Sep, USTA Billie Jean King NTC, NYC'),
  ('Indian Wells',       'tennis', 'US', 'BNP Paribas Open, March, CA'),
  ('Miami Open',         'tennis', 'US', 'March-April, Hard Rock Stadium, FL'),
  ('Cincinnati Open',    'tennis', 'US', 'August, Lindner Family Tennis Center, OH'),
  ('Charleston Open',    'tennis', 'US', 'April, SC'),
  ('Atlanta Open',       'tennis', 'US', 'July, GA'),
  ('Hall of Fame Open',  'tennis', 'US', 'July, Newport, RI'),
  -- US golf
  ('Masters Tournament', 'golf',   'US', 'April, Augusta National, GA'),
  ('US Open Golf',       'golf',   'US', 'June, US-rotating venues'),
  ('PGA Championship',   'golf',   'US', 'May, US-rotating'),
  ('Players Championship','golf',  'US', 'March, TPC Sawgrass, FL'),
  ('Memorial Tournament','golf',   'US', 'June, Muirfield Village, OH'),
  ('WM Phoenix Open',    'golf',   'US', 'February, TPC Scottsdale, AZ'),
  ('Genesis Invitational','golf',  'US', 'February, Riviera Country Club, CA'),
  ('BMW Championship',   'golf',   'US', 'August, FedEx Cup playoff'),
  ('Tour Championship',  'golf',   'US', 'September, East Lake Golf Club, GA'),
  -- F1 (continental North America only)
  ('Miami Grand Prix',   'f1',     'US',     'May, Miami International Autodrome'),
  ('US Grand Prix',      'f1',     'US',     'October, Circuit of the Americas, Austin'),
  ('Las Vegas Grand Prix','f1',    'US',     'November, Las Vegas Strip Circuit'),
  ('Canadian Grand Prix','f1',     'Canada', 'June, Circuit Gilles Villeneuve, Montreal'),
  ('Mexico City Grand Prix','f1',  'Mexico', 'October-November, Autodromo Hermanos Rodriguez')
ON CONFLICT (query) DO NOTHING;

COMMENT ON TABLE tournament_search_queries IS
  'Per-tournament TEvo search queries, scoped to continental North America. '
  'Driven by tournament_search_queue() / _process(); weekly cron. '
  'Hand-maintained — add new tournaments via INSERT.';

-- ============================================================================
-- (2) Pending queue (async pattern, same as evo_event_backfill_pending)
-- ============================================================================

CREATE TABLE IF NOT EXISTS tournament_search_pending (
  id              bigserial PRIMARY KEY,
  query           text NOT NULL,
  request_id      bigint NOT NULL,
  fired_at        timestamptz DEFAULT now(),
  resolved_at     timestamptz,
  events_persisted int,
  status          text                    -- 'success' | 'http_404' | 'http_other' | 'json_err'
);

CREATE INDEX IF NOT EXISTS tournament_search_pending_unresolved_idx
  ON tournament_search_pending(fired_at) WHERE resolved_at IS NULL;

-- ============================================================================
-- (3) tournament_search_queue — fire one signed search per enabled query
-- ============================================================================

CREATE OR REPLACE FUNCTION tournament_search_queue(p_limit int DEFAULT 25)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_token  text := get_app_secret('TEVO_API_TOKEN');
  v_secret text := get_app_secret('TEVO_SECRET');
  v_query_str text;
  v_sig    text;
  v_req_id bigint;
  v_count  int := 0;
  r RECORD;
BEGIN
  -- Only run queries that haven't been fired in the last 24 hours
  FOR r IN
    SELECT q.query
    FROM tournament_search_queries q
    LEFT JOIN tournament_search_pending p
      ON p.query = q.query AND p.fired_at > now() - interval '24 hours'
    WHERE q.enabled
      AND p.id IS NULL
    ORDER BY q.added_at
    LIMIT p_limit
  LOOP
    -- TEvo /v9/events?name=<query>&per_page=100&occurs_at.gte=<today>
    -- TEvo HMAC requires alphabetically-sorted querystring keys.
    v_query_str := 'name=' || replace(r.query, ' ', '%20')
                 || '&occurs_at.gte=' || to_char(current_date, 'YYYY-MM-DD')
                 || '&per_page=100';
    v_sig := tevo_sign_get('/v9/events', v_query_str, v_secret);
    SELECT net.http_get(
      url := 'https://api.ticketevolution.com/v9/events?' || v_query_str,
      headers := jsonb_build_object(
        'X-Token', v_token,
        'X-Signature', v_sig,
        'Accept', 'application/vnd.ticketevolution.api+json; version=9'
      ),
      timeout_milliseconds := 25000
    ) INTO v_req_id;

    INSERT INTO tournament_search_pending(query, request_id, fired_at)
    VALUES (r.query, v_req_id, now());
    v_count := v_count + 1;
    PERFORM pg_sleep(0.4);  -- be kind to TEvo
  END LOOP;
  RETURN v_count;
END;
$$;

-- ============================================================================
-- (4) tournament_search_process — UPSERT events into our events table
-- ============================================================================

CREATE OR REPLACE FUNCTION tournament_search_process()
RETURNS TABLE(processed int, events_persisted int)
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  v_body jsonb;
  v_events jsonb;
  v_processed int := 0;
  v_total_persisted int := 0;
  v_count int;
  v_status text;
BEGIN
  FOR r IN
    SELECT p.id, p.query, p.request_id, h.content, h.status_code
    FROM tournament_search_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;

    IF r.status_code = 200 THEN
      BEGIN
        v_body := r.content::jsonb;
        v_status := 'success';
      EXCEPTION WHEN OTHERS THEN
        v_body := NULL;
        v_status := 'json_err';
      END;

      IF v_body IS NOT NULL THEN
        v_events := COALESCE(v_body->'events', '[]'::jsonb);
        WITH src AS (SELECT e FROM jsonb_array_elements(v_events) AS e),
        ins AS (
          INSERT INTO events (
            id, name, occurs_at_local, state,
            venue_id, venue_name, venue_location,
            primary_performer_id, primary_performer_name, performer_ids,
            configuration_id, configuration_name,
            seating_chart_medium, seating_chart_large,
            popularity_score, long_term_popularity_score,
            event_type, last_seen
          )
          SELECT
            (e->>'id')::bigint,
            e->>'name', e->>'occurs_at_local', e->>'state',
            NULLIF(e->'venue'->>'id','')::bigint,
            e->'venue'->>'name', e->'venue'->>'location',
            NULLIF(e->'performances'->0->'performer'->>'id','')::bigint,
            e->'performances'->0->'performer'->>'name',
            ARRAY(SELECT (perf->'performer'->>'id')::bigint
                    FROM jsonb_array_elements(COALESCE(e->'performances','[]'::jsonb)) AS perf
                   WHERE perf->'performer'->>'id' IS NOT NULL),
            NULLIF(e->'configuration'->>'id','')::int,
            e->'configuration'->>'name',
            e->'configuration'->>'seating_chart_medium',
            e->'configuration'->>'seating_chart_large',
            NULLIF(e->>'popularity_score','')::numeric,
            NULLIF(e->>'long_term_popularity_score','')::numeric,
            e->>'category_id_text',
            now()
          FROM src
          WHERE (e->>'id') IS NOT NULL
          ON CONFLICT (id) DO UPDATE SET
            name           = COALESCE(EXCLUDED.name, events.name),
            occurs_at_local= COALESCE(EXCLUDED.occurs_at_local, events.occurs_at_local),
            state          = COALESCE(EXCLUDED.state, events.state),
            venue_id       = COALESCE(EXCLUDED.venue_id, events.venue_id),
            venue_name     = COALESCE(EXCLUDED.venue_name, events.venue_name),
            venue_location = COALESCE(EXCLUDED.venue_location, events.venue_location),
            primary_performer_id   = COALESCE(EXCLUDED.primary_performer_id, events.primary_performer_id),
            primary_performer_name = COALESCE(EXCLUDED.primary_performer_name, events.primary_performer_name),
            last_seen      = now()
          RETURNING 1
        )
        SELECT count(*) INTO v_count FROM ins;
        v_total_persisted := v_total_persisted + v_count;

        UPDATE tournament_search_pending
           SET resolved_at = now(), events_persisted = v_count, status = v_status
         WHERE id = r.id;
      ELSE
        UPDATE tournament_search_pending
           SET resolved_at = now(), events_persisted = 0, status = v_status
         WHERE id = r.id;
      END IF;
    ELSIF r.status_code = 404 THEN
      v_status := 'http_404';
      UPDATE tournament_search_pending SET resolved_at = now(), status = v_status WHERE id = r.id;
    ELSE
      v_status := 'http_other';
      UPDATE tournament_search_pending SET resolved_at = now(), status = v_status WHERE id = r.id;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_total_persisted;
END;
$$;

-- ============================================================================
-- (5) Sweep — keep tournament_search_pending lean (resolved >7d gone)
-- ============================================================================

CREATE OR REPLACE FUNCTION tournament_search_pending_sweep()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM tournament_search_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '7 days';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

-- ============================================================================
-- (6) Crons — weekly is plenty (tournaments rarely add inventory daily)
-- ============================================================================

SELECT cron.schedule(
  'tournament_search_queue_weekly',
  '0 4 * * 0',                          -- Sundays 04:00 UTC
  $$ SELECT tournament_search_queue(25); $$
);

SELECT cron.schedule(
  'tournament_search_process_weekly',
  '5 4 * * 0',                          -- Sundays 04:05 UTC
  $$ SELECT * FROM tournament_search_process(); $$
);

SELECT cron.schedule(
  'tournament_search_pending_sweep_weekly',
  '10 4 * * 0',                         -- Sundays 04:10 UTC
  $$ SELECT tournament_search_pending_sweep(); $$
);
