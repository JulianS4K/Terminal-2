-- ============================================================================
-- Migration 20260509360000 — Auto-backfill events from TEvo / SG orders
--
-- Product directive: "have a chron run where in ticket evo or seatgeek order
-- comes in that isnt in system have the cron start collecting data for our
-- event cron policies."
--
-- TODAY'S BEHAVIOR:
--   When a new TEvo or SG order arrives for an event we don't have in our
--   `events` table (TEvo) or `sg_events_canonical` (SG), the order itself
--   lands but no listing pulls fire — because all our listing crons iterate
--   over `events` / `sg_events_canonical`. Result: orphan event sits in
--   v_unmatched_events with no price-history collection.
--
-- NEW BEHAVIOR (this migration):
--   1. Detect orphan event_ids on the orders side.
--   2. Fire signed GET to TEvo /v9/events/:id (or SG /v2/events?id=:id) to
--      fetch full event metadata.
--   3. Persist into `events` / `sg_events_canonical`.
--   4. The existing listing crons (collect-listings-0-24h through 60d+,
--      sg_listings_*) automatically pick up the new event on their next
--      tick — no further wiring needed.
--
-- RULE 2 compliance: all calls are GET. Audit script extended to plpgsql.
-- ============================================================================

-- ============================================================================
-- (1) Pending tables — track in-flight backfill requests
-- ============================================================================

CREATE TABLE IF NOT EXISTS evo_event_backfill_pending (
  tevo_event_id  bigint PRIMARY KEY,
  request_id     bigint NOT NULL,
  reason         text,                 -- 'order_orphan' | 'listing_orphan' | 'manual'
  fired_at       timestamptz DEFAULT now(),
  resolved_at    timestamptz,
  status         text                  -- 'success' | 'http_404' | 'http_other' | 'json_err'
);

CREATE INDEX IF NOT EXISTS evo_event_backfill_pending_unresolved_idx
  ON evo_event_backfill_pending(fired_at) WHERE resolved_at IS NULL;

CREATE TABLE IF NOT EXISTS sg_event_backfill_pending (
  sg_event_id    bigint PRIMARY KEY,
  request_id     bigint NOT NULL,
  reason         text,                 -- 'order_orphan' | 'listing_orphan' | 'seller_orphan'
  fired_at       timestamptz DEFAULT now(),
  resolved_at    timestamptz,
  status         text
);

CREATE INDEX IF NOT EXISTS sg_event_backfill_pending_unresolved_idx
  ON sg_event_backfill_pending(fired_at) WHERE resolved_at IS NULL;

COMMENT ON TABLE evo_event_backfill_pending IS
  'In-flight TEvo /v9/events/:id requests. Populated when an order references '
  'an event_id not in the events table. Resolved by evo_event_backfill_process.';

COMMENT ON TABLE sg_event_backfill_pending IS
  'In-flight SG /v2/events?id=:id requests. Populated when an SG order or '
  'listing references an sg_event_id not in sg_events_canonical.';

-- ============================================================================
-- (2) TEvo orphan event backfill — queue
-- ============================================================================

CREATE OR REPLACE FUNCTION evo_event_backfill_queue(p_limit int DEFAULT 20)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_token  text := get_app_secret('TEVO_API_TOKEN');
  v_secret text := get_app_secret('TEVO_SECRET');
  v_query  text;
  v_sig    text;
  v_req_id bigint;
  v_count  int := 0;
  r        RECORD;
BEGIN
  -- Find unique TEvo event_ids referenced by orders/order_items but
  -- NOT in events table AND NOT in flight.
  FOR r IN
    WITH orphans AS (
      SELECT DISTINCT it.event_id AS tevo_event_id, 'order_orphan' AS reason
      FROM evo_order_items it
      WHERE it.event_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM events e WHERE e.id = it.event_id)
    )
    SELECT o.tevo_event_id, o.reason
    FROM orphans o
    LEFT JOIN evo_event_backfill_pending p ON p.tevo_event_id = o.tevo_event_id
        AND p.fired_at > now() - interval '6 hours'
    WHERE p.tevo_event_id IS NULL
    LIMIT p_limit
  LOOP
    -- TEvo /v9/events/:id — empty query string for path-only endpoint
    v_query := '';
    v_sig := tevo_sign_get('/v9/events/' || r.tevo_event_id, v_query, v_secret);
    SELECT net.http_get(
      url := 'https://api.ticketevolution.com/v9/events/' || r.tevo_event_id,
      headers := jsonb_build_object(
        'X-Token', v_token,
        'X-Signature', v_sig,
        'Accept', 'application/vnd.ticketevolution.api+json; version=9'
      ),
      timeout_milliseconds := 20000
    ) INTO v_req_id;

    INSERT INTO evo_event_backfill_pending(tevo_event_id, request_id, reason, fired_at)
    VALUES (r.tevo_event_id, v_req_id, r.reason, now())
    ON CONFLICT (tevo_event_id) DO UPDATE SET
      request_id = EXCLUDED.request_id, fired_at = now(),
      resolved_at = NULL, status = NULL, reason = EXCLUDED.reason;
    v_count := v_count + 1;
    PERFORM pg_sleep(0.3);
  END LOOP;
  RETURN v_count;
END;
$$;

-- ============================================================================
-- (3) TEvo orphan event backfill — process
-- ============================================================================

CREATE OR REPLACE FUNCTION evo_event_backfill_process()
RETURNS TABLE(processed int, persisted int)
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  v_body jsonb;
  v_processed int := 0;
  v_persisted int := 0;
  v_status text;
BEGIN
  FOR r IN
    SELECT p.tevo_event_id, p.request_id, h.content, h.status_code
    FROM evo_event_backfill_pending p
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
        -- TEvo /v9/events/:id returns the event object directly (not nested).
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
          (v_body->>'id')::bigint,
          v_body->>'name',
          v_body->>'occurs_at_local',
          v_body->>'state',
          NULLIF(v_body->'venue'->>'id','')::bigint,
          v_body->'venue'->>'name',
          v_body->'venue'->>'location',
          NULLIF(v_body->'performances'->0->'performer'->>'id','')::bigint,
          v_body->'performances'->0->'performer'->>'name',
          ARRAY(SELECT (perf->'performer'->>'id')::bigint
                  FROM jsonb_array_elements(COALESCE(v_body->'performances','[]'::jsonb)) AS perf
                 WHERE perf->'performer'->>'id' IS NOT NULL),
          NULLIF(v_body->'configuration'->>'id','')::int,
          v_body->'configuration'->>'name',
          v_body->'configuration'->>'seating_chart_medium',
          v_body->'configuration'->>'seating_chart_large',
          NULLIF(v_body->>'popularity_score','')::numeric,
          NULLIF(v_body->>'long_term_popularity_score','')::numeric,
          v_body->>'category_id_text',
          now()
        ON CONFLICT (id) DO UPDATE SET
          name = COALESCE(EXCLUDED.name, events.name),
          occurs_at_local = COALESCE(EXCLUDED.occurs_at_local, events.occurs_at_local),
          state = COALESCE(EXCLUDED.state, events.state),
          venue_id = COALESCE(EXCLUDED.venue_id, events.venue_id),
          venue_name = COALESCE(EXCLUDED.venue_name, events.venue_name),
          venue_location = COALESCE(EXCLUDED.venue_location, events.venue_location),
          primary_performer_id = COALESCE(EXCLUDED.primary_performer_id, events.primary_performer_id),
          primary_performer_name = COALESCE(EXCLUDED.primary_performer_name, events.primary_performer_name),
          last_seen = now();
        v_persisted := v_persisted + 1;
      END IF;
    ELSIF r.status_code = 404 THEN
      v_status := 'http_404';
    ELSE
      v_status := 'http_other';
    END IF;

    UPDATE evo_event_backfill_pending
       SET resolved_at = now(), status = v_status
     WHERE tevo_event_id = r.tevo_event_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END;
$$;

-- ============================================================================
-- (4) SG orphan event backfill — queue
-- ============================================================================

CREATE OR REPLACE FUNCTION sg_event_backfill_queue(p_limit int DEFAULT 20)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  r RECORD;
  v_req_id bigint;
  v_count  int := 0;
BEGIN
  FOR r IN
    WITH orphans AS (
      -- SG order references with no canonical row
      SELECT DISTINCT sg_event_id, 'order_orphan' AS reason
      FROM seatgeek_orders
      WHERE sg_event_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM sg_events_canonical c WHERE c.sg_event_id = seatgeek_orders.sg_event_id)
      UNION
      SELECT DISTINCT sg_event_id, 'seller_orphan'
      FROM seatgeek_seller_listings
      WHERE sg_event_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM sg_events_canonical c WHERE c.sg_event_id = seatgeek_seller_listings.sg_event_id)
      UNION
      SELECT DISTINCT sg_event_id, 'listing_orphan'
      FROM seatgeek_listings_snapshots
      WHERE sg_event_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM sg_events_canonical c WHERE c.sg_event_id = seatgeek_listings_snapshots.sg_event_id)
    )
    SELECT o.sg_event_id, o.reason
    FROM orphans o
    LEFT JOIN sg_event_backfill_pending p ON p.sg_event_id = o.sg_event_id
        AND p.fired_at > now() - interval '6 hours'
    WHERE p.sg_event_id IS NULL
    LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/v2/events?id=' || r.sg_event_id || '&token=' || v_token,
      timeout_milliseconds := 20000
    ) INTO v_req_id;

    INSERT INTO sg_event_backfill_pending(sg_event_id, request_id, reason, fired_at)
    VALUES (r.sg_event_id, v_req_id, r.reason, now())
    ON CONFLICT (sg_event_id) DO UPDATE SET
      request_id = EXCLUDED.request_id, fired_at = now(),
      resolved_at = NULL, status = NULL, reason = EXCLUDED.reason;
    v_count := v_count + 1;
    PERFORM pg_sleep(0.4);
  END LOOP;
  RETURN v_count;
END;
$$;

-- ============================================================================
-- (5) SG orphan event backfill — process
-- ============================================================================

CREATE OR REPLACE FUNCTION sg_event_backfill_process()
RETURNS TABLE(processed int, persisted int)
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  v_body jsonb;
  v_evt jsonb;
  v_processed int := 0;
  v_persisted int := 0;
  v_status text;
BEGIN
  FOR r IN
    SELECT p.sg_event_id, p.request_id, h.content, h.status_code
    FROM sg_event_backfill_pending p
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
        -- brokerdata /v2/events returns { events: [...] } or single object
        v_evt := COALESCE(v_body->'events'->0, v_body);
        IF v_evt ? 'id' THEN
          INSERT INTO sg_events_canonical (
            sg_event_id, sg_event_name, sg_event_date, sg_venue_name, sg_category,
            has_seller_listings, has_orders, has_v2_listings_pulled,
            updated_at
          )
          SELECT
            (v_evt->>'id')::bigint,
            COALESCE(NULLIF(v_evt->>'title',''), 'sg_' || (v_evt->>'id')),
            NULLIF(left(v_evt->>'datetime_local',10), '')::date,
            v_evt->'venue'->>'name',
            v_evt->'taxonomies'->0->>'name',
            false, false, false,
            now()
          ON CONFLICT (sg_event_id) DO UPDATE SET
            sg_event_name = COALESCE(EXCLUDED.sg_event_name, sg_events_canonical.sg_event_name),
            sg_event_date = COALESCE(EXCLUDED.sg_event_date, sg_events_canonical.sg_event_date),
            sg_venue_name = COALESCE(EXCLUDED.sg_venue_name, sg_events_canonical.sg_venue_name),
            sg_category   = COALESCE(EXCLUDED.sg_category, sg_events_canonical.sg_category),
            updated_at    = now();
          v_persisted := v_persisted + 1;
        END IF;
      END IF;
    ELSIF r.status_code = 404 THEN
      v_status := 'http_404';
    ELSE
      v_status := 'http_other';
    END IF;

    UPDATE sg_event_backfill_pending
       SET resolved_at = now(), status = v_status
     WHERE sg_event_id = r.sg_event_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END;
$$;

-- ============================================================================
-- (6) Sweep — keep backfill_pending lean (resolved >7d gone)
-- ============================================================================

CREATE OR REPLACE FUNCTION orphan_backfill_sweep()
RETURNS TABLE(evo_deleted int, sg_deleted int)
LANGUAGE plpgsql
AS $$
DECLARE v_e int; v_s int;
BEGIN
  DELETE FROM evo_event_backfill_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '7 days';
  GET DIAGNOSTICS v_e = ROW_COUNT;
  DELETE FROM sg_event_backfill_pending
  WHERE resolved_at IS NOT NULL AND resolved_at < now() - interval '7 days';
  GET DIAGNOSTICS v_s = ROW_COUNT;
  RETURN QUERY SELECT v_e, v_s;
END;
$$;

-- ============================================================================
-- (7) Wire crons
-- ============================================================================

-- Backfill queue + process — every 15 min, offset by 2m to let queue settle.
SELECT cron.schedule(
  'orphan_event_backfill_queue_15min',
  '*/15 * * * *',
  $$ SELECT evo_event_backfill_queue(20), sg_event_backfill_queue(20); $$
);

SELECT cron.schedule(
  'orphan_event_backfill_process_15min',
  '2-59/15 * * * *',
  $$ SELECT * FROM evo_event_backfill_process(); SELECT * FROM sg_event_backfill_process(); $$
);

-- Daily sweep at 03:35 UTC (just after wiki sweep)
SELECT cron.schedule(
  'orphan_backfill_sweep_daily',
  '35 3 * * *',
  $$ SELECT orphan_backfill_sweep(); $$
);
