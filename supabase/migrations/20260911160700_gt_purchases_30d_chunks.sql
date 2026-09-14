-- ============================================================================
-- Migration 20260911160700 — gt_purchases_sync(): GoTickets caps a window at 30 days
--
-- Lane:     A1 (data plane) serving D0's deals surface
-- Touches:  gt_purchases_sync(timestamptz,timestamptz) (CREATE OR REPLACE),
--           gt_purchases_sync() (CREATE OR REPLACE)
-- Pre-reqs: 20260911160500
--
-- Already applied to prod · via MCP 2026-09-11 (fix to the just-applied poller).
--
-- MEASURED on the first live pull (request 14896468, 2026-09-11 16:5x UTC):
--   GET /rest/purchases?orderTimeFrom=<now-90d>&orderTimeTo=<now>
--   → 400 {"message":"Bad request","errors":["Date range cannot exceed 30 days"]}
-- The endpoint spec did not state the limit; the incremental wrapper's first-run
-- 90-day backfill tripped it. Fix:
--   * the 2-arg sync REFUSES a window > 30 days (RAISE) instead of queuing a
--     request that is guaranteed to 400 — a silent clamp would hide missing days;
--   * the no-arg wrapper walks the backlog in <= 30-day chunks (max 6 requests a
--     run, so a 90-day first run is 3 pulls and steady state stays 1).
-- Same verification run also recorded the SeatGeek side: request 14896467 →
--   401 {"error":{"code":421004,"message":"Your token does not allow access to
--   this endpoint at the moment"}} — the /purchases scope is still not granted to
--   our brokerdata token (the seatgeek_client.py note stands). Nothing to fix in
--   code; `sg_purchases_pending.http_status = 401` is the operator's signal.
--
-- READ-ONLY upstream: GET only. ROLLBACK: re-apply the two function bodies from
-- mig 20260911160500 (the 90-day single-window form).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.gt_purchases_sync(p_from timestamptz, p_to timestamptz)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_req bigint;
  v_fmt constant text := 'YYYY-MM-DD"T"HH24:MI:SS"Z"';
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF p_to <= p_from THEN
    RAISE EXCEPTION 'gt_purchases_sync: empty window % .. %', p_from, p_to;
  END IF;
  -- Measured 2026-09-11: the endpoint 400s on "Date range cannot exceed 30 days".
  IF p_to - p_from > interval '30 days' THEN
    RAISE EXCEPTION 'gt_purchases_sync: window % .. % exceeds the 30-day API limit; chunk it (see gt_purchases_sync())', p_from, p_to;
  END IF;
  -- pg_net does not URL-encode: escape the colons in the ISO timestamps.
  SELECT net.http_get(
    url := 'https://sc.gotickets.com/rest/purchases'
           || '?orderTimeFrom=' || replace(to_char(p_from AT TIME ZONE 'utc', v_fmt), ':', '%3A')
           || '&orderTimeTo='   || replace(to_char(p_to   AT TIME ZONE 'utc', v_fmt), ':', '%3A'),
    headers := jsonb_build_object(
      'X-Api-Access-Id',     trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'GOTICKETS_ACCESS_ID')),
      'X-Api-Access-Secret', trim((SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'GOTICKETS_API_SECRET')),
      'Accept', 'application/json'),
    timeout_milliseconds := 120000
  ) INTO v_req;
  INSERT INTO public.gt_purchases_pending (request_id, time_from, time_to) VALUES (v_req, p_from, p_to);
  RETURN v_req;
END $fn$;

-- Incremental wrapper: from the newest purchase we hold (minus a 3-day overlap so
-- late status changes are re-read), or 90 days back on first run, to now — walked
-- in <= 30-day chunks (max 6 per run). Returns the LAST request id queued.
CREATE OR REPLACE FUNCTION public.gt_purchases_sync()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_from timestamptz; v_to timestamptz; v_req bigint; v_n int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(max(create_time) - interval '3 days', now() - interval '90 days')
    INTO v_from FROM public.gotickets_purchases;
  WHILE v_from < now() AND v_n < 6 LOOP
    v_to := LEAST(v_from + interval '30 days' - interval '1 minute', now());
    v_req := public.gt_purchases_sync(v_from, v_to);
    v_from := v_to; v_n := v_n + 1;
  END LOOP;
  RETURN v_req;
END $fn$;

COMMENT ON FUNCTION public.gt_purchases_sync(timestamptz,timestamptz) IS
  'Queue GET sc.gotickets.com/rest/purchases?orderTimeFrom&orderTimeTo (both required; window <= 30 days or the API 400s — this fn RAISEs instead; pg_net). Read-only. A1 mig 20260911160700.';
COMMENT ON FUNCTION public.gt_purchases_sync() IS
  'Incremental GoTickets purchase pull: newest held purchase -3d (90d on first run) to now, in <= 30-day chunks, max 6 requests/run. A1 mig 20260911160700.';
