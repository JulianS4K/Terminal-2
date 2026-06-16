-- Migration 20260616181000 · lane:D0 (author) → A1 (apply) · writes:sg_force_track_listings_tick, cron(sg_wc_listings_catchup) · reads:sg_event_priority_state · pre:20260616180000_wc_all_platforms · auth:operator-requested 2026-06-16 ("track them all" — keep World Cup SeatGeek data fresh)
--
-- D0 — dedicated, paced SeatGeek catch-up poller for the force-tracked World Cup
-- events. WHY: the owned poller (sg_listings_poll_owned_1min) orders by tightest
-- cadence-band first, so far-horizon WC events sort last and never get reached
-- before p_max is hit — they sat ~2 weeks stale despite force_track=true. This
-- tick is SCOPED to force_track=true events only (the operator-requested WC set),
-- so it does NOT reverse the June-8 owned-focus directive globally; it just keeps
-- the explicitly-tracked set fresh. Rate-aware (honors the live ratelimit-remaining
-- header, same guard as sg_listings_poll_tick) and bounded (p_max), so it shares
-- the SG token politely; the clock advances only on a fired request and the
-- pipeline is strand-safe (a 429 leaves last_fired old → retried next tick).

CREATE OR REPLACE FUNCTION public.sg_force_track_listings_tick(
  p_max integer DEFAULT 6,
  p_min_remaining integer DEFAULT 4,
  p_repoll_min integer DEFAULT 30)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_remaining int; r RECORD; v_req bigint; v_now timestamptz := clock_timestamp(); v_count int := 0;
BEGIN
  IF NOT public.cron_should_fire('sg_wc_listings_catchup') THEN RETURN 0; END IF;
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;

  -- Rate-aware: back off if the freshest budget reading is low (same guard as the
  -- main poller). A stale reading (>10s) is ignored so we don't deadlock.
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
  FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
  WHERE h.headers ? 'ratelimit-remaining' AND h.created > v_now - interval '10 seconds'
  ORDER BY h.id DESC LIMIT 1;
  IF v_remaining IS NOT NULL AND v_remaining < p_min_remaining THEN RETURN 0; END IF;

  FOR r IN
    SELECT s.sg_event_id
    FROM public.sg_event_priority_state s
    WHERE s.force_track = true
      AND s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      AND ( s.last_fired_listings_at IS NULL
            OR s.last_fired_listings_at < v_now - make_interval(mins => p_repoll_min) )
    ORDER BY s.last_fired_listings_at ASC NULLS FIRST, s.sg_datetime_utc ASC
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'listings', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_fired_listings_at = v_now, listings_polls_today = listings_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END;
$func$;

REVOKE ALL ON FUNCTION public.sg_force_track_listings_tick(integer, integer, integer) FROM PUBLIC, anon;

-- Cron: every 2 min, ≤6 events/tick → the ~87 force-tracked WC events refresh on a
-- ~30-min rolling cadence (existing sg_priority_listings_process_5min drains the
-- responses into seatgeek_listings_snapshots).
DO $$ BEGIN PERFORM cron.unschedule('sg_wc_listings_catchup'); EXCEPTION WHEN OTHERS THEN NULL; END $$;
SELECT cron.schedule('sg_wc_listings_catchup', '*/2 * * * *',
  $cron$ SELECT public.sg_force_track_listings_tick(6, 4, 30); $cron$);
