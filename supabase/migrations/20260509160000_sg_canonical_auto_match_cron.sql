-- ============================================================================
-- Migration 20260509160000 — auto-match cron for SG canonical events
--
-- Three helpers + master tick + pg_cron schedule:
--
-- (a) sync_sg_seller_listings_to_canonical() — copies new SG events from
--     seatgeek_seller_listings into sg_events_canonical. Runs first to pick
--     up any SG events the seller cron added since last tick.
--
-- (b) auto_match_sg_canonical() — iterates unmatched canonical rows,
--     re-runs sg_attempt_event_xref. Catches the case where TEvo ingested
--     the event after the prior attempt.
--
-- (c) refresh_sg_canonical_from_xref() — back-syncs match info from
--     seatgeek_event_xref to canonical for rows linked outside this loop
--     (e.g. via the FastAPI /api/seatgeek/event/{id}/link route).
--
-- (d) sg_canonical_auto_match_tick() — master, returns jsonb summary.
-- (e) pg_cron job: every 30 min.
-- ============================================================================

CREATE OR REPLACE FUNCTION sync_sg_seller_listings_to_canonical()
RETURNS TABLE(rows_inserted int, rows_updated int) AS $$
DECLARE
  v_inserted int := 0;
  v_updated int := 0;
BEGIN
  WITH src AS (
    SELECT DISTINCT ON (ssl.sg_event_id)
      ssl.sg_event_id, ssl.sg_event_name, ssl.sg_event_date,
      ssl.sg_venue, ssl.sg_event_time
    FROM seatgeek_seller_listings ssl
    ORDER BY ssl.sg_event_id, ssl.pulled_at DESC
  ),
  upserted AS (
    INSERT INTO sg_events_canonical (
      sg_event_id, sg_event_name, sg_event_date, sg_venue_name,
      has_seller_listings, updated_at
    )
    SELECT s.sg_event_id, s.sg_event_name, s.sg_event_date, s.sg_venue,
           true, now()
    FROM src s
    ON CONFLICT (sg_event_id) DO UPDATE SET
      sg_event_name = COALESCE(sg_events_canonical.sg_event_name, EXCLUDED.sg_event_name),
      sg_event_date = COALESCE(sg_events_canonical.sg_event_date, EXCLUDED.sg_event_date),
      sg_venue_name = COALESCE(sg_events_canonical.sg_venue_name, EXCLUDED.sg_venue_name),
      has_seller_listings = true,
      updated_at = now()
    RETURNING (xmax = 0) AS is_insert
  )
  SELECT
    count(*) FILTER (WHERE is_insert),
    count(*) FILTER (WHERE NOT is_insert)
  INTO v_inserted, v_updated FROM upserted;

  RETURN QUERY SELECT v_inserted, v_updated;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION auto_match_sg_canonical()
RETURNS TABLE(
  attempted int, newly_matched int, still_unmatched int, needs_tevo_search int
) AS $$
DECLARE
  r RECORD;
  v_match bigint;
  v_attempted int := 0;
  v_matched int := 0;
  v_unmatched int := 0;
BEGIN
  FOR r IN
    SELECT sg_event_id, sg_event_name, sg_event_date, sg_venue_name
    FROM sg_events_canonical
    WHERE tevo_event_id IS NULL
      AND (sg_event_date IS NULL OR sg_event_date >= current_date - 30)
  LOOP
    v_attempted := v_attempted + 1;
    v_match := sg_attempt_event_xref(
      r.sg_event_id, r.sg_event_name, r.sg_event_date, r.sg_venue_name
    );
    IF v_match IS NOT NULL THEN
      UPDATE sg_events_canonical SET
        tevo_event_id = v_match,
        match_method = 'auto_canonical_loop',
        match_confidence = 0.9,
        matched_at = now(),
        updated_at = now()
      WHERE sg_event_id = r.sg_event_id;
      v_matched := v_matched + 1;
    ELSE
      v_unmatched := v_unmatched + 1;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_attempted, v_matched, v_unmatched,
    (SELECT count(*)::int FROM sg_events_canonical WHERE tevo_event_id IS NULL);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION refresh_sg_canonical_from_xref()
RETURNS int AS $$
DECLARE v_updated int;
BEGIN
  UPDATE sg_events_canonical sgc SET
    tevo_event_id = sgx.tevo_event_id,
    match_method = COALESCE(sgc.match_method, sgx.match_method),
    match_confidence = COALESCE(sgc.match_confidence, sgx.match_confidence),
    matched_at = COALESCE(sgc.matched_at, sgx.matched_at),
    updated_at = now()
  FROM seatgeek_event_xref sgx
  WHERE sgc.sg_event_id = sgx.sg_event_id
    AND sgc.tevo_event_id IS NULL
    AND sgx.tevo_event_id IS NOT NULL;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sg_canonical_auto_match_tick()
RETURNS jsonb AS $$
DECLARE
  v_sync record; v_match record; v_back int;
BEGIN
  SELECT * INTO v_sync FROM sync_sg_seller_listings_to_canonical();
  v_back := refresh_sg_canonical_from_xref();
  SELECT * INTO v_match FROM auto_match_sg_canonical();
  RETURN jsonb_build_object(
    'sync_inserted', v_sync.rows_inserted,
    'sync_updated', v_sync.rows_updated,
    'backsync_from_xref', v_back,
    'attempted', v_match.attempted,
    'newly_matched', v_match.newly_matched,
    'still_unmatched_in_pass', v_match.still_unmatched,
    'total_unmatched_now', v_match.needs_tevo_search,
    'ran_at', now()
  );
END;
$$ LANGUAGE plpgsql;

-- Schedule: every 30 min
SELECT cron.schedule(
  'sg_canonical_auto_match_30min',
  '*/30 * * * *',
  $$ SELECT sg_canonical_auto_match_tick(); $$
);
