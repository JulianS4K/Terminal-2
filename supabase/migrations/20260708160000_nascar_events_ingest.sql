-- ============================================================================
-- Migration 20260708160000 — NASCAR ticket-inventory ingest (TEvo → events)
--
-- Lane:     A1 data plane (ingest pipeline; consumed by the D0 Leagues hub
--           racing view via the get_nascar_schedule matcher, mig 20260708161000).
-- Touches:  nascar_ingest_pending (W/table), nascar_ingest_fire (W/fn),
--           nascar_ingest_process (W/fn), events (W/upsert), cron.* (W/schedule)
-- Reads:    net._http_response, get_app_secret(), tevo_sign_get()
-- Pre-reqs: 20260509480000 (tournament_search — the async-pull pattern this mirrors)
--
-- WHY. Unlike tennis/golf/F1 (each a distinct TEvo performer → already ingested
-- by tournament_search_process), every NASCAR national race hangs off ONE
-- generic TEvo performer, "NASCAR" (id 25363). So a per-performer name search
-- can't discover the individual races — they're distinguished by venue + date.
-- This ingest pulls performer 25363's upcoming events (the Cup / Xfinity /
-- Truck national races, each carrying its real speedway venue + date) into the
-- events table so the racing view can attach live get-in / market / owned
-- metrics per race. The D0 matcher (mig 20260708161000) then aligns each
-- ingested event to the ESPN schedule (espn_racing_events) by date + series.
--
-- Scope guards:
--   * performer_id=25363 only — the canonical NASCAR performer. Category-28
--     noise (monster-truck shows, local weekly racing) lives under OTHER
--     performers and is never pulled.
--   * name NOT ILIKE '%Fan Zone%' — "… - Fan Zone Only" listings are a
--     secondary, same-date duplicate of the real grandstand event; excluding
--     them keeps the date+series match key unique.
--
-- Async pattern = tournament_search (mig 20260509480000): _fire() signs + fires
-- one net.http_get and records a pending row; _process() upserts from the
-- landed response and resolves it. Weekly cron (the season only shifts race to
-- race); crons avoid the :02/:05/:07 saturated minute clusters.
--
-- ROLLBACK: DELETE FROM events WHERE event_type='nascar';
--           DROP FUNCTION nascar_ingest_fire, nascar_ingest_process;
--           DROP TABLE nascar_ingest_pending;
--           SELECT cron.unschedule('nascar_ingest_fire_weekly'),
--                  cron.unschedule('nascar_ingest_process_weekly').
-- ============================================================================

CREATE TABLE IF NOT EXISTS nascar_ingest_pending (
  id               bigserial PRIMARY KEY,
  request_id       bigint NOT NULL,
  fired_at         timestamptz DEFAULT now(),
  resolved_at      timestamptz,
  events_persisted int,
  status           text            -- 'success' | 'http_other' | 'json_err'
);
CREATE INDEX IF NOT EXISTS nascar_ingest_pending_unresolved_idx
  ON nascar_ingest_pending(fired_at) WHERE resolved_at IS NULL;

-- ----------------------------------------------------------------------------
-- _fire — sign + fire one TEvo /v9/events pull for performer 25363 (NASCAR).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nascar_ingest_fire()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_token  text := get_app_secret('TEVO_API_TOKEN');
  v_secret text := get_app_secret('TEVO_SECRET');
  v_qs     text;
  v_sig    text;
  v_req_id bigint;
BEGIN
  -- HMAC requires alphabetically-sorted querystring keys:
  -- occurs_at.gte < per_page < performer_id.
  v_qs := 'occurs_at.gte=' || to_char(current_date, 'YYYY-MM-DD')
        || '&per_page=100&performer_id=25363';
  v_sig := tevo_sign_get('/v9/events', v_qs, v_secret);
  SELECT net.http_get(
    url := 'https://api.ticketevolution.com/v9/events?' || v_qs,
    headers := jsonb_build_object(
      'X-Token', v_token,
      'X-Signature', v_sig,
      'Accept', 'application/vnd.ticketevolution.api+json; version=9'
    ),
    timeout_milliseconds := 25000
  ) INTO v_req_id;

  INSERT INTO nascar_ingest_pending(request_id, fired_at) VALUES (v_req_id, now());
  RETURN v_req_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- _process — upsert the landed NASCAR events into `events` (event_type='nascar',
-- Fan-Zone-only listings excluded), resolve the pending row.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION nascar_ingest_process()
RETURNS TABLE(processed int, events_persisted int)
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  v_body jsonb;
  v_events jsonb;
  v_processed int := 0;
  v_total int := 0;
  v_count int;
  v_status text;
BEGIN
  FOR r IN
    SELECT p.id, p.request_id, h.content, h.status_code
    FROM nascar_ingest_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;

    IF r.status_code = 200 THEN
      BEGIN
        v_body := r.content::jsonb;
        v_status := 'success';
      EXCEPTION WHEN OTHERS THEN
        v_body := NULL; v_status := 'json_err';
      END;

      IF v_body IS NOT NULL THEN
        v_events := COALESCE(v_body->'events', '[]'::jsonb);
        WITH src AS (
          SELECT e FROM jsonb_array_elements(v_events) AS e
          WHERE (e->>'id') IS NOT NULL
            AND (e->>'name') NOT ILIKE '%Fan Zone%'   -- drop same-date duplicate listings
        ),
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
            'nascar',
            now()
          FROM src
          ON CONFLICT (id) DO UPDATE SET
            name            = COALESCE(EXCLUDED.name, events.name),
            occurs_at_local = COALESCE(EXCLUDED.occurs_at_local, events.occurs_at_local),
            state           = COALESCE(EXCLUDED.state, events.state),
            venue_id        = COALESCE(EXCLUDED.venue_id, events.venue_id),
            venue_name      = COALESCE(EXCLUDED.venue_name, events.venue_name),
            venue_location  = COALESCE(EXCLUDED.venue_location, events.venue_location),
            primary_performer_id   = COALESCE(EXCLUDED.primary_performer_id, events.primary_performer_id),
            primary_performer_name = COALESCE(EXCLUDED.primary_performer_name, events.primary_performer_name),
            event_type      = 'nascar',
            last_seen       = now()
          RETURNING 1
        )
        SELECT count(*) INTO v_count FROM ins;
        v_total := v_total + v_count;
        UPDATE nascar_ingest_pending
           SET resolved_at = now(), events_persisted = v_count, status = v_status
         WHERE id = r.id;
      ELSE
        UPDATE nascar_ingest_pending
           SET resolved_at = now(), events_persisted = 0, status = v_status WHERE id = r.id;
      END IF;
    ELSE
      UPDATE nascar_ingest_pending
         SET resolved_at = now(), events_persisted = 0, status = 'http_other' WHERE id = r.id;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_total;
END;
$$;

-- ----------------------------------------------------------------------------
-- Crons — weekly is plenty (a race weekend at a time). Fire, then process 5m
-- later; a monthly sweep keeps the pending log lean. Minutes avoid :02/:05/:07.
-- ----------------------------------------------------------------------------
SELECT cron.schedule('nascar_ingest_fire_weekly',    '20 4 * * 1', $$ SELECT nascar_ingest_fire(); $$);
SELECT cron.schedule('nascar_ingest_process_weekly', '25 4 * * 1', $$ SELECT * FROM nascar_ingest_process(); $$);
SELECT cron.schedule('nascar_ingest_pending_sweep',  '30 4 * * 1',
  $$ DELETE FROM nascar_ingest_pending WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '30 days'; $$);
