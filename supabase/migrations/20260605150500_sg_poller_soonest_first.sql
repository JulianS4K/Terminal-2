-- ============================================================
-- Migration 20260601130000 — SG listings poller: soonest-event-first priority
--
-- Lane:     A1 (collector) — drafted by D0 at operator request, A1 to review + apply
-- Touches:  sg_listings_poll_tick (W, CREATE OR REPLACE) — reads sg_event_priority_state,
--           collector_cadence (via collector_band), net._http_response, sg_broker_pending (W)
-- Pre-reqs: 20260531160000 (band-driven poller this revises), collector_band(), collector_cadence
--
-- Problem (diagnosed by D0 2026-06-01, bot_chat 995, PR #394):
-- the band poller's selection orders ONLY by `last_polled_listings_at ASC NULLS FIRST`.
-- That re-qualifies 429-stranded events (the intent in MIG-D) but carries NO
-- hours-to-event urgency, so when the eligible set exceeds the per-tick budget
-- (observed: 1,614 eligible vs ~150 polls/hr at p_max=5 x 30 ticks), stale far-out
-- events rank ahead of imminent games. Live evidence: Cleveland Guardians @ NY
-- Yankees sg 17691547/48/49 at 28/52/70h to event (le7d band = 60min) had NOT
-- polled in ~22h (last_fired NULL, listings_polls_today=0); 1,275 stale far-out
-- events ranked ahead of them, only 61 eligible events were within 72h.
--
-- Fix: make event urgency the PRIMARY sort key — soonest sg_datetime_utc first —
-- then keep `last_polled ASC NULLS FIRST` as the tiebreak (preserves the 429
-- re-qualification behaviour within an urgency tier). Eligibility is unchanged
-- (per-band required_min still gates WHO is due); this only reorders WHO goes
-- first when the tick budget is scarce. Far-out events still drain on remaining
-- capacity — their bands are long (d15_30=720min, d31p=1440min) so they tolerate
-- waiting behind the ~61 near-term events, which comfortably fit under the
-- 150-poll/hr ceiling.
--
-- Only the ORDER BY changes; token guard, rate-aware backoff, band join, WHERE,
-- fire/insert/stamp loop, and the last_polled-only-on-200 contract (in
-- sg_broker_listings_process) are all preserved verbatim from 20260531160000.
--
-- Follow-on levers (NOT done here — left to A1's judgement): raising p_max or
-- adding a dedicated near-term fast lane if the far-out backlog still lags; and
-- the occasional deadlock on the `UPDATE sg_event_priority_state` from concurrent
-- ticks (3/24h observed) — could serialize via FOR UPDATE SKIP LOCKED on select.
-- ============================================================
--
-- ## Pending operator apply via apply_migration

CREATE OR REPLACE FUNCTION public.sg_listings_poll_tick(p_max int DEFAULT 20, p_min_remaining int DEFAULT 3)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  v_token     text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_remaining int;
  r           RECORD;
  v_req       bigint;
  v_now       timestamptz := clock_timestamp();
  v_count     int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;

  -- Rate-aware backoff: only on a FRESH low reading (~10s window). Stale/none => fire.
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
  FROM public.sg_broker_pending p
  JOIN net._http_response h ON h.id = p.request_id
  WHERE h.headers ? 'ratelimit-remaining' AND h.created > v_now - interval '10 seconds'
  ORDER BY h.id DESC LIMIT 1;
  IF v_remaining IS NOT NULL AND v_remaining < p_min_remaining THEN RETURN 0; END IF;

  FOR r IN
    SELECT s.sg_event_id
    FROM public.sg_event_priority_state s
    JOIN LATERAL public.collector_band('SG','listings',
           EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0) c ON true
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      AND ( s.last_polled_listings_at IS NULL
            OR s.last_polled_listings_at < v_now - make_interval(mins => c.required_min) )
      AND ( s.last_fired_listings_at IS NULL
            OR s.last_fired_listings_at < v_now - interval '90 seconds' )   -- don't re-fire a pending request
    -- CHANGED (mig 20260601130000): urgency first so imminent games never starve
    -- behind stale far-out events; last_polled ASC kept as the 429 re-qualify tiebreak.
    ORDER BY s.sg_datetime_utc ASC, s.last_polled_listings_at ASC NULLS FIRST, s.sg_event_id
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'listings', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_fired_listings_at = v_now, listings_polls_today = listings_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $function$;
REVOKE ALL ON FUNCTION public.sg_listings_poll_tick(int,int) FROM anon, PUBLIC;
