-- Migration 20260512100210 · level:supervisor · lane:canonical · writes:v_events_pullable,sweep_inactive_event_states,sg_listings_queue_window,cron(sweep_inactive_event_states_daily) · reads:events,derive_event_lifecycle,seatgeek_event_xref,sg_events_canonical · pre:20260509050000,20260509280000

-- v_events_pullable: canonical filter for any cron that pulls per-event data.
-- Returns only events whose lifecycle classifier reports is_active=true
-- (excludes ghost_eliminated, cancelled, postponed, completed).
CREATE OR REPLACE VIEW v_events_pullable AS
SELECT e.id, e.name, e.occurs_at_local, e.venue_id, e.venue_name,
       e.primary_performer_id, e.primary_performer_name, e.state, e.last_seen,
       lc.status AS lifecycle_status, lc.confidence AS lifecycle_confidence,
       lc.hrs_since_seen, lc.hrs_to_event
FROM events e
CROSS JOIN LATERAL derive_event_lifecycle(e.id) lc
WHERE lc.is_active = true;

COMMENT ON VIEW v_events_pullable IS
  'Source-of-truth filter for cron pulls. Excludes ghost_eliminated, cancelled, postponed, completed. Use this view (or NOT IN exclusion) in any listings-queue selection.';

GRANT SELECT ON v_events_pullable TO service_role, coworker_readonly;

-- sweep_inactive_event_states: nightly job that promotes high-confidence
-- ghost_eliminated/cancelled lifecycle into events.state='ignored'.
-- Most downstream consumers (broker UI, public RPCs) already filter on state,
-- and the existing collect-listings edge function filters too. Setting state
-- explicitly gives the cron a hard stop. Min confidence 0.9 prevents
-- accidental flips on still-decidable events.
CREATE OR REPLACE FUNCTION sweep_inactive_event_states()
RETURNS TABLE(events_marked int, by_status jsonb)
LANGUAGE plpgsql AS $f$
DECLARE
  v_count int := 0;
  v_breakdown jsonb;
BEGIN
  WITH targets AS (
    SELECT e.id, lc.status FROM events e
    CROSS JOIN LATERAL derive_event_lifecycle(e.id) lc
    WHERE e.state = 'shown'
      AND lc.status IN ('cancelled', 'ghost_eliminated')
      AND lc.confidence >= 0.9
  ),
  upd AS (
    UPDATE events SET state = 'ignored'
    WHERE id IN (SELECT id FROM targets)
    RETURNING id
  )
  SELECT (SELECT COUNT(*) FROM upd),
         COALESCE((SELECT jsonb_object_agg(status, c) FROM (SELECT t.status, COUNT(*) c FROM targets t GROUP BY t.status) s), '{}'::jsonb)
  INTO v_count, v_breakdown;
  RETURN QUERY SELECT v_count, v_breakdown;
END;
$f$;

COMMENT ON FUNCTION sweep_inactive_event_states() IS
  'Daily sweep that promotes derive_event_lifecycle ghost_eliminated/cancelled (conf >= 0.9) into events.state = ignored, halting further cron pulls.';

-- Modify SG-side cron to filter ghost/cancelled events via xref → events lifecycle.
-- Unmatched SG events (no xref) still get pulled — they may be valid first-seen events.
CREATE OR REPLACE FUNCTION sg_listings_queue_window(
  p_window text, p_min_age_seconds int, p_limit int DEFAULT 30
) RETURNS int AS $f$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  v_min_date date; v_max_date date;
  r RECORD; v_req_id bigint; v_count int := 0;
BEGIN
  CASE p_window
    WHEN '0-24h'  THEN v_min_date := current_date;       v_max_date := current_date + 1;
    WHEN '1-7d'   THEN v_min_date := current_date + 1;   v_max_date := current_date + 7;
    WHEN '7-30d'  THEN v_min_date := current_date + 7;   v_max_date := current_date + 30;
    WHEN '30-60d' THEN v_min_date := current_date + 30;  v_max_date := current_date + 60;
    WHEN '60d+'   THEN v_min_date := current_date + 60;  v_max_date := current_date + 365;
    ELSE RAISE EXCEPTION 'unknown window %', p_window;
  END CASE;
  FOR r IN
    SELECT sgc.sg_event_id FROM sg_events_canonical sgc
    LEFT JOIN sg_listings_pending p ON p.sg_event_id = sgc.sg_event_id
        AND p.fired_at > now() - make_interval(secs => p_min_age_seconds)
    WHERE sgc.sg_event_date BETWEEN v_min_date AND v_max_date
      AND p.id IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM seatgeek_event_xref sex
        JOIN events e ON e.id = sex.tevo_event_id
        CROSS JOIN LATERAL derive_event_lifecycle(e.id) lc
        WHERE sex.sg_event_id = sgc.sg_event_id
          AND lc.status IN ('cancelled', 'ghost_eliminated')
      )
    ORDER BY sgc.sg_event_date LIMIT p_limit
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/v2/listings?event_id=' || r.sg_event_id || '&token=' || v_token,
      timeout_milliseconds := 25000
    ) INTO v_req_id;
    INSERT INTO sg_listings_pending(request_id, sg_event_id, window_label)
    VALUES (v_req_id, r.sg_event_id, p_window);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END;
$f$ LANGUAGE plpgsql;

COMMENT ON FUNCTION sg_listings_queue_window(text, int, int) IS
  'SG-side listings queue. Excludes events linked to TEvo events with lifecycle status cancelled or ghost_eliminated. Unmatched SG events still pulled.';

-- Schedule daily sweep at 01:00 ET = 05:00 UTC (after game outcomes have settled)
SELECT cron.schedule('sweep_inactive_event_states_daily', '0 5 * * *',
  $$ SELECT sweep_inactive_event_states(); $$);
