-- Robustness: decouple the SG owned-listings FIRING rotation from PROCESSOR
-- success, so a future processor stall can't starve the rotation.
--
-- Context (incident 2026-06-09): sg_broker_listings_process jammed on a dup-key
-- (fixed in 20260609170000). While it was down it never advanced
-- last_polled_listings_at — and sg_listings_poll_tick's "due" gate keys on
-- exactly that column. So the same handful of events stayed perpetually "due"
-- and monopolized the 4 fire slots every run, starving every other owned event
-- (incl. the NBA Finals games) of listings polls. The cadence was correct; the
-- coupling was the problem: FIRING (which we control) depended on PROCESSING
-- (downstream, fallible) to advance the rotation.
--
-- Fix: gate AND order on GREATEST(last_polled_listings_at, last_fired_listings_at)
-- — i.e. "last attempt", fire or poll, whichever is later. An event we just
-- FIRED is treated as recently attempted and won't re-fire until its tier
-- interval elapses, even if its response hasn't been processed yet. The rotation
-- now advances on fire-time, so a processing backlog can never re-lock firing
-- onto a fixed set. (GREATEST ignores NULLs; both-NULL → never attempted → due.)
--
-- Cadence semantics: effectively measured from fire-time instead of poll-time,
-- which is the more correct interval anyway (don't re-fire an event just because
-- its previous pull is still being processed). The existing 90s anti-double-fire
-- gate is kept (now largely subsumed, harmless). GET-only upstream unchanged;
-- no broker-write path touched (CLAUDE.md §1/§2). No signature change.

CREATE OR REPLACE FUNCTION public.sg_listings_poll_tick(p_max integer DEFAULT 20, p_min_remaining integer DEFAULT 3, p_owned_kind text DEFAULT NULL::text, p_rate_mult numeric DEFAULT 1)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_remaining int; r RECORD; v_req bigint; v_now timestamptz := clock_timestamp(); v_count int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
  FROM public.sg_broker_pending p JOIN net._http_response h ON h.id = p.request_id
  WHERE h.headers ? 'ratelimit-remaining' AND h.created > v_now - interval '10 seconds'
  ORDER BY h.id DESC LIMIT 1;
  IF v_remaining IS NOT NULL AND v_remaining < p_min_remaining THEN RETURN 0; END IF;

  FOR r IN
    SELECT s.sg_event_id
    FROM public.sg_event_priority_state s
    JOIN LATERAL public.collector_band('SG','listings',
           EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0,
           (coalesce(s.owned_count_last_7d,0) > 0)) c ON true
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      AND ( p_owned_kind IS NULL
            OR (coalesce(s.owned_count_last_7d,0) > 0) = (p_owned_kind = 'owned') )
      -- "due" = last ATTEMPT (fire or poll, whichever later) older than the tier
      -- interval. Keying on last_fired too means firing rotates even if the
      -- downstream processor stalls and never advances last_polled.
      AND ( GREATEST(s.last_polled_listings_at, s.last_fired_listings_at) IS NULL
            OR GREATEST(s.last_polled_listings_at, s.last_fired_listings_at)
               < v_now - make_interval(mins => round(c.required_min * p_rate_mult)::int) )
      AND ( s.last_fired_listings_at IS NULL
            OR s.last_fired_listings_at < v_now - interval '90 seconds' )
    ORDER BY c.required_min ASC,
             GREATEST(s.last_polled_listings_at, s.last_fired_listings_at) ASC NULLS FIRST,
             s.sg_datetime_utc
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
END $function$;
