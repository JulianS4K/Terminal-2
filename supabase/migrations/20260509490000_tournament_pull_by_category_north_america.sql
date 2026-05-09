-- ============================================================================
-- Migration 20260509490000 — Tournament event pull by category, North America
--
-- Supersedes the name-based search in mig 20260509480000. TEvo's `name=`
-- requires exact match and `q=` does fuzzy performer-name search that
-- doesn't surface tournament events. The reliable path is `category_id=`.
--
-- Approach (live-probed):
--   - Tennis = TEvo category_id 25  (351 future events as of 2026-05-09)
--   - Golf   = TEvo category_id 24  (48 future events)
--   - F1     = TEvo category_id 29  (90 future events)
--
-- Pull paginated, filter to continental North America at INSERT time using
-- venue_location regex (US state codes / Canadian provinces / Mexico).
--
-- Replaces:
--   tournament_search_queue / tournament_search_process / their crons.
-- These are dropped (no rows depend on them); the schema-search reference
-- table tournament_search_queries stays as historical record (rows
-- disabled).
-- ============================================================================

-- ============================================================================
-- (1) Tear down the broken name-search approach
-- ============================================================================

DO $$
BEGIN
  PERFORM cron.unschedule('tournament_search_queue_weekly');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
DO $$
BEGIN
  PERFORM cron.unschedule('tournament_search_process_weekly');
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DROP FUNCTION IF EXISTS tournament_search_queue(int);
DROP FUNCTION IF EXISTS tournament_search_process();

-- Disable rows in the old reference table; keep table for history
UPDATE tournament_search_queries SET enabled = false;
COMMENT ON TABLE tournament_search_queries IS
  'DEPRECATED — text search via `name=` does not work on TEvo /v9/events. '
  'Replaced by tournament_categories + tournament_pull_queue (mig 490000). '
  'Rows kept as historical seed reference; enabled=false on all.';

-- ============================================================================
-- (2) Helper: is_north_america_venue(text)
--     Matches "City, [Borough,] STATE" with US/CA codes, plus Mexico
-- ============================================================================

CREATE OR REPLACE FUNCTION is_north_america_venue(p_location text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT
    p_location IS NOT NULL AND (
      -- US state code at end
      p_location ~* ',\s*(AL|AK|AZ|AR|CA|CO|CT|DE|FL|GA|HI|ID|IL|IN|IA|KS|KY|LA|ME|MD|MA|MI|MN|MS|MO|MT|NE|NV|NH|NJ|NM|NY|NC|ND|OH|OK|OR|PA|RI|SC|SD|TN|TX|UT|VT|VA|WA|WV|WI|WY|DC|PR)\s*$'
      -- Canadian province code at end
      OR p_location ~* ',\s*(AB|BC|MB|NB|NL|NS|NT|NU|ON|PE|QC|SK|YT)\s*$'
      -- Explicit country mentions
      OR p_location ILIKE '%, Mexico%'
      OR p_location ILIKE '%, Canada%'
      OR p_location ILIKE '%, United States%'
      OR p_location ILIKE '%, USA%'
    );
$$;

COMMENT ON FUNCTION is_north_america_venue IS
  'Returns true if venue_location string ends with a US state code, Canadian '
  'province code, or contains Mexico/USA/Canada/United States. Used to filter '
  'tournament_pull_process to continental North America only.';

-- ============================================================================
-- (3) Categories to pull
-- ============================================================================

CREATE TABLE IF NOT EXISTS tournament_categories (
  category_id   int PRIMARY KEY,
  tevo_label    text NOT NULL,            -- 'Tennis' | 'Golf' | 'Formula 1'
  genre         text NOT NULL,            -- canonical 'tennis' | 'golf' | 'f1'
  pages_to_pull int DEFAULT 5,            -- 5 * 100 = 500 events per pull
  enabled       boolean DEFAULT true,
  notes         text,
  added_at      timestamptz DEFAULT now()
);

INSERT INTO tournament_categories(category_id, tevo_label, genre, pages_to_pull, notes) VALUES
  (24, 'Golf',      'golf',   3, 'PGA + LIV + The Open + Masters etc.'),
  (25, 'Tennis',    'tennis', 5, 'ATP + WTA + Grand Slams; high volume'),
  (29, 'Formula 1', 'f1',     2, 'Global F1 calendar; we filter to N.A. only')
ON CONFLICT (category_id) DO NOTHING;

COMMENT ON TABLE tournament_categories IS
  'TEvo category_ids to pull tournament events from. pages_to_pull controls '
  'how many 100-event pages we fetch per category per cycle.';

-- ============================================================================
-- (4) tournament_category_pending — async queue (per category, per page)
-- ============================================================================

CREATE TABLE IF NOT EXISTS tournament_category_pending (
  id                bigserial PRIMARY KEY,
  category_id       int NOT NULL,
  page              int NOT NULL,
  request_id        bigint NOT NULL,
  fired_at          timestamptz DEFAULT now(),
  resolved_at       timestamptz,
  events_returned   int,
  events_persisted  int,
  events_filtered   int,                  -- non-NA, dropped
  status            text
);

CREATE INDEX IF NOT EXISTS tournament_category_pending_unresolved_idx
  ON tournament_category_pending(fired_at) WHERE resolved_at IS NULL;

-- ============================================================================
-- (5) tournament_pull_queue — fire all enabled categories, all pages
-- ============================================================================

CREATE OR REPLACE FUNCTION tournament_pull_queue(p_max_pages int DEFAULT 25)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_token  text := get_app_secret('TEVO_API_TOKEN');
  v_secret text := get_app_secret('TEVO_SECRET');
  r RECORD; v_query text; v_sig text; v_req bigint; v_count int := 0;
BEGIN
  FOR r IN
    SELECT tc.category_id, tc.pages_to_pull, gs.page
    FROM tournament_categories tc
    JOIN LATERAL generate_series(1, tc.pages_to_pull) AS gs(page) ON true
    WHERE tc.enabled
      AND NOT EXISTS (
        SELECT 1 FROM tournament_category_pending p
        WHERE p.category_id = tc.category_id
          AND p.page = gs.page
          AND p.fired_at > now() - interval '24 hours'
      )
    ORDER BY tc.category_id, gs.page
    LIMIT p_max_pages
  LOOP
    -- TEvo HMAC needs alphabetically-sorted querystring keys.
    v_query := 'category_id=' || r.category_id
            || '&occurs_at.gte=' || to_char(current_date, 'YYYY-MM-DD')
            || '&page=' || r.page
            || '&per_page=100';
    v_sig := tevo_sign_get('/v9/events', v_query, v_secret);
    SELECT net.http_get(
      url := 'https://api.ticketevolution.com/v9/events?' || v_query,
      headers := jsonb_build_object(
        'X-Token', v_token, 'X-Signature', v_sig,
        'Accept', 'application/vnd.ticketevolution.api+json; version=9'),
      timeout_milliseconds := 25000
    ) INTO v_req;
    INSERT INTO tournament_category_pending(category_id, page, request_id, fired_at)
    VALUES (r.category_id, r.page, v_req, now());
    v_count := v_count + 1;
    PERFORM pg_sleep(0.4);
  END LOOP;
  RETURN v_count;
END;
$$;

-- ============================================================================
-- (6) tournament_pull_process — UPSERT into events with N.America filter
-- ============================================================================

CREATE OR REPLACE FUNCTION tournament_pull_process()
RETURNS TABLE(processed int, persisted int, filtered_non_na int) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_body jsonb; v_events jsonb;
  v_processed int := 0; v_total_persisted int := 0; v_total_filtered int := 0;
  v_count int; v_filtered int; v_returned int; v_status text;
BEGIN
  FOR r IN
    SELECT p.id, p.category_id, p.page, p.request_id, h.content, h.status_code
    FROM tournament_category_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb; v_status := 'success';
      EXCEPTION WHEN OTHERS THEN v_body := NULL; v_status := 'json_err'; END;

      IF v_body IS NOT NULL THEN
        v_events := COALESCE(v_body->'events', '[]'::jsonb);
        v_returned := jsonb_array_length(v_events);
        SELECT count(*) INTO v_filtered
        FROM jsonb_array_elements(v_events) AS e
        WHERE NOT is_north_america_venue(e->'venue'->>'location');

        WITH src AS (
          SELECT e FROM jsonb_array_elements(v_events) AS e
          WHERE is_north_america_venue(e->'venue'->>'location')
        ),
        ins AS (
          INSERT INTO events (
            id, name, occurs_at_local, state, venue_id, venue_name, venue_location,
            primary_performer_id, primary_performer_name, performer_ids,
            configuration_id, configuration_name,
            seating_chart_medium, seating_chart_large,
            popularity_score, long_term_popularity_score, event_type, last_seen
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
            e->>'category_id_text', now()
          FROM src WHERE (e->>'id') IS NOT NULL
          ON CONFLICT (id) DO UPDATE SET
            name           = COALESCE(EXCLUDED.name, events.name),
            occurs_at_local= COALESCE(EXCLUDED.occurs_at_local, events.occurs_at_local),
            state          = COALESCE(EXCLUDED.state, events.state),
            venue_id       = COALESCE(EXCLUDED.venue_id, events.venue_id),
            venue_name     = COALESCE(EXCLUDED.venue_name, events.venue_name),
            venue_location = COALESCE(EXCLUDED.venue_location, events.venue_location),
            last_seen      = now()
          RETURNING 1
        )
        SELECT count(*) INTO v_count FROM ins;
        v_total_persisted := v_total_persisted + v_count;
        v_total_filtered  := v_total_filtered + v_filtered;

        UPDATE tournament_category_pending
           SET resolved_at = now(), events_returned = v_returned,
               events_persisted = v_count, events_filtered = v_filtered, status = v_status
         WHERE id = r.id;
      ELSE
        UPDATE tournament_category_pending SET resolved_at = now(), status = v_status WHERE id = r.id;
      END IF;
    ELSIF r.status_code = 404 THEN
      UPDATE tournament_category_pending SET resolved_at = now(), status = 'http_404' WHERE id = r.id;
    ELSE
      UPDATE tournament_category_pending SET resolved_at = now(), status = 'http_other' WHERE id = r.id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_total_persisted, v_total_filtered;
END;
$$;

-- ============================================================================
-- (7) Sweep helper + cron
-- ============================================================================

CREATE OR REPLACE FUNCTION tournament_category_pending_sweep()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
  DELETE FROM tournament_category_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '14 days';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END; $$;

SELECT cron.schedule('tournament_pull_queue_weekly',   '0 4 * * 0',  $$ SELECT tournament_pull_queue(25); $$);
SELECT cron.schedule('tournament_pull_process_weekly', '5 4 * * 0',  $$ SELECT * FROM tournament_pull_process(); $$);

-- (Reuse the existing sweep cron from mig 480000 if it's still scheduled;
--  otherwise no-op the create. The sweep handles both old + new pending tables.)
