-- ============================================================================
-- Migration 20260911231000 — a sub-finder SeatGeek pull now resets that event's poll clock
--
-- Lane:     A1 (ingest/crons)
-- Touches:  sg_event_priority_state (W), sg_broker_pending (W, unchanged),
--           seatgeek_listings_snapshots (R)
-- Pre-reqs: 20260911010000 (sg_listings_pull_on_demand hub registration)
--
-- "If a sub polls a GoTickets/EVO/SG event, can we skip the next poll or reset
-- the event poll timer?" — for EVO and GoTickets this already happens:
-- n2s_pull_events() stamps evo_listings_poll_state.last_polled_listings_at and
-- gt_listings_poll_state.last_polled_listings_at after each on-demand fire, and
-- evo_listings_poll_tick()/gt_listings_poll_tick() both read those clocks
-- against collector_band(), so the scheduled poller skips an event the sub
-- finder just pulled.
--
-- SeatGeek was the one gap. sg_listings_pull_on_demand() fires the exact same
-- brokerdata.seatgeek.com/listings request as sg_priority_poll_tick(), but it
-- neither read nor wrote sg_event_priority_state, so the scheduled tick had no
-- idea the event had just been polled and fired a duplicate. That is a wasted
-- request on the tightest budget we have: the SG token is ~5 req/10s and is
-- SHARED with an external production program (RESOURCES_BIBLE §5).
--
-- Both directions are closed here:
--   READ  — skip an event whose clock says it was polled inside p_freshness,
--           even if no snapshot has landed yet (the request may still be in
--           flight; the snapshot check alone cannot see that).
--   WRITE — stamp last_polled_listings_at / listings_polls_today exactly as
--           sg_priority_poll_tick does, so the next scheduled poll skips.
--
-- UPDATE-only, never INSERT: an event with no sg_event_priority_state row is
-- not on the scheduled poller's radar at all, so there is no clock to reset.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sg_listings_pull_on_demand(
  p_tevo_event_ids bigint[],
  p_max_events     integer,
  p_freshness      interval)
RETURNS TABLE(queued integer, skipped_fresh integer, unmapped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  r       RECORD;
  v_req   bigint;
  v_q     int := 0;
  v_fresh int := 0;
  v_unmap int := 0;
  v_now   timestamptz := clock_timestamp();
BEGIN
  IF p_tevo_event_ids IS NULL OR cardinality(p_tevo_event_ids) = 0 THEN
    RETURN QUERY SELECT 0, 0, 0; RETURN;
  END IF;
  IF v_token IS NULL OR v_token = '' THEN
    RAISE EXCEPTION 'SEATGEEK_API_TOKEN is not set - cannot pull SeatGeek listings';
  END IF;

  SELECT count(*) INTO v_unmap
    FROM unnest(p_tevo_event_ids) AS t(tevo_event_id)
   WHERE NOT EXISTS (
     SELECT 1 FROM public.sg_events_canonical c WHERE c.tevo_event_id = t.tevo_event_id)
     AND NOT EXISTS (
     SELECT 1 FROM public.aq_event_map a
      WHERE a.tevo_event_id = t.tevo_event_id AND a.sg_event_id IS NOT NULL);

  -- Register hub-resolved events that the canonical table has never seen,
  -- so the FK on seatgeek_listings_snapshots and the xref the drain reads
  -- both exist BEFORE anything is queued (20260911010000). Existing rows
  -- in either table are never touched.
  INSERT INTO public.sg_events_canonical
    (sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_venue_name,
     tevo_event_id, match_method, match_confidence, matched_at, match_status)
  SELECT a.sg_event_id, e.name, left(e.occurs_at_local, 10)::date,
         CASE WHEN e.occurs_at_local ~ '[+-]\d\d:\d\d$' THEN e.occurs_at_local::timestamptz END,
         e.venue_name, e.id, 'aq_hub_n2s', 1.0, now(), 'matched'
    FROM unnest(p_tevo_event_ids) AS t(tevo_event_id)
    JOIN public.events e ON e.id = t.tevo_event_id
    JOIN LATERAL (SELECT a.sg_event_id FROM public.aq_event_map a
                   WHERE a.tevo_event_id = t.tevo_event_id AND a.sg_event_id IS NOT NULL
                   ORDER BY a.sg_event_id LIMIT 1) a ON true
   WHERE e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT'
     AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical c WHERE c.tevo_event_id = t.tevo_event_id)
  ON CONFLICT (sg_event_id) DO NOTHING;

  INSERT INTO public.seatgeek_event_xref
    (tevo_event_id, sg_event_id, sg_event_name, matched_at, match_method, match_confidence)
  SELECT c.tevo_event_id, c.sg_event_id, c.sg_event_name, now(), 'aq_hub_n2s', 1.0
    FROM public.sg_events_canonical c
   WHERE c.tevo_event_id = ANY(p_tevo_event_ids) AND c.match_method = 'aq_hub_n2s'
  ON CONFLICT (tevo_event_id) DO NOTHING;

  FOR r IN
    WITH want AS (SELECT DISTINCT x AS tevo_event_id FROM unnest(p_tevo_event_ids) AS x),
    resolved AS (
      SELECT w.tevo_event_id,
             COALESCE(
               (SELECT c.sg_event_id FROM public.sg_events_canonical c
                 WHERE c.tevo_event_id = w.tevo_event_id
                 ORDER BY c.sg_event_id LIMIT 1),
               (SELECT a.sg_event_id FROM public.aq_event_map a
                 WHERE a.tevo_event_id = w.tevo_event_id AND a.sg_event_id IS NOT NULL
                 ORDER BY a.sg_event_id LIMIT 1)
             ) AS sg_event_id
        FROM want w
    )
    SELECT rs.tevo_event_id, rs.sg_event_id,
           (EXISTS (SELECT 1 FROM public.seatgeek_listings_snapshots s
                     WHERE s.tevo_event_id = rs.tevo_event_id
                       AND s.captured_at >= now() - p_freshness)
            -- Clock check: the scheduled poller may have fired this event
            -- moments ago and the response not landed yet. Without this a
            -- sub-finder pull duplicates an in-flight request.
            OR EXISTS (SELECT 1 FROM public.sg_event_priority_state ps
                        WHERE ps.sg_event_id = rs.sg_event_id
                          AND ps.last_polled_listings_at >= now() - p_freshness)
           ) AS is_fresh
      FROM resolved rs
     WHERE rs.sg_event_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM public.sg_events_canonical c
                    WHERE c.sg_event_id = rs.sg_event_id)
     ORDER BY rs.tevo_event_id
  LOOP
    IF r.is_fresh THEN
      v_fresh := v_fresh + 1;
      CONTINUE;
    END IF;
    EXIT WHEN v_q >= p_max_events;

    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token
             || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;

    INSERT INTO public.sg_broker_pending(request_id, scope, sg_event_id)
    VALUES (v_req, 'listings', r.sg_event_id);

    -- Reset the event's poll timer so the scheduled tick skips it. Mirrors
    -- sg_priority_poll_tick exactly, including the daily counter it budgets
    -- against. UPDATE-only: no priority row means no scheduled poll to skip.
    UPDATE public.sg_event_priority_state
       SET last_polled_listings_at = v_now,
           listings_polls_today    = listings_polls_today + 1
     WHERE sg_event_id = r.sg_event_id;

    v_q := v_q + 1;
  END LOOP;

  RETURN QUERY SELECT v_q, v_fresh, v_unmap;
END
$fn$;

COMMENT ON FUNCTION public.sg_listings_pull_on_demand(bigint[], integer, interval)
  IS 'On-demand SeatGeek listings pull (sub finder / N2S path). Reads AND writes '
     'sg_event_priority_state.last_polled_listings_at so it neither duplicates an '
     'in-flight scheduled poll nor leaves the next one to re-poll what it just '
     'fetched — the SG token is ~5 req/10s and shared with an external program. '
     'EVO/GT get the same treatment inside n2s_pull_events().';
