-- ============================================================================
-- Migration 20260911161300 — sg_purchases_sync(): SeatGeek /purchases contract (72h window, 10/page)
--
-- Lane:     A1 (data plane) serving D0's deals surface
-- Touches:  sg_purchases_sync(timestamptz,timestamptz,int,int) (CREATE OR REPLACE),
--           sg_purchases_sync() (CREATE OR REPLACE)
-- Pre-reqs: 20260911160500
--
-- Already applied to prod · via MCP 2026-09-11 (operator supplied the endpoint spec).
--
-- THE SPEC (operator-pasted 2026-09-11, brokerdata GET /purchases):
--   * start_time / end_time — ISO 8601, NO timezone offset; "the maximum time delta
--     between start_time and end_time is 72 hours"; with neither given the window
--     defaults to the last 5 minutes.
--   * per_page — "Maximum value is 10"; page — 1-based.
--   * order_status — pending | confirmed | fulfilled (we pull all).
-- Mig 160500 asked for 90 days in one window with per_page up to 100: it would have
-- 400'd the moment the scope is granted (today it 401s first — code 421004, scope not
-- granted — so nothing was lost). Fixes:
--   1. the 4-arg sync REFUSES a window > 72h and clamps per_page to 10 (RAISE, not a
--      silent clamp of the window — missing days must be visible);
--   2. the no-arg wrapper walks a WATERMARK forward in <= 72h chunks: watermark = the
--      latest end_time of a resolved HTTP-200 pull (so an empty 72h window still
--      advances; a 401/400 does NOT advance, the same window is retried); first run
--      starts 90 days back; max 8 chunks per run (= 24 days), so the 90-day backfill
--      completes over the first ~4 runs and steady state is 1–2 chunks;
--   3. while the scope is denied, back off: if the newest 3 resolved pulls are all 401
--      within the last 24h, fire ONE probe per run instead of 8.
-- Paging inside a window stays in sg_purchases_drain (meta.total → page+1, cap 50).
--
-- READ-ONLY upstream: GET only. ROLLBACK: re-apply the two bodies from mig 160500.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sg_purchases_sync(
  p_start timestamptz, p_end timestamptz, p_page int DEFAULT 1, p_per_page int DEFAULT 10)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_req bigint;
  v_fmt constant text := 'YYYY-MM-DD"T"HH24:MI:SS';
  v_pp int := LEAST(GREATEST(coalesce(p_per_page, 10), 1), 10);   -- API maximum is 10
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;
  IF v_token IS NULL OR v_token = '' THEN RETURN NULL; END IF;
  IF p_end <= p_start THEN
    RAISE EXCEPTION 'sg_purchases_sync: empty window % .. %', p_start, p_end;
  END IF;
  IF p_end - p_start > interval '72 hours' THEN
    RAISE EXCEPTION 'sg_purchases_sync: window % .. % exceeds the 72-hour API limit; chunk it (see sg_purchases_sync())', p_start, p_end;
  END IF;

  SELECT net.http_get(
    url := 'https://brokerdata.seatgeek.com/purchases?token=' || v_token
           || '&start_time=' || to_char(p_start AT TIME ZONE 'utc', v_fmt)
           || '&end_time='   || to_char(p_end   AT TIME ZONE 'utc', v_fmt)
           || '&page=' || GREATEST(p_page, 1)::text
           || '&per_page=' || v_pp::text,
    timeout_milliseconds := 30000
  ) INTO v_req;
  INSERT INTO public.sg_purchases_pending (request_id, start_time, end_time, page, per_page)
  VALUES (v_req, p_start, p_end, GREATEST(p_page, 1), v_pp);
  RETURN v_req;
END $fn$;

CREATE OR REPLACE FUNCTION public.sg_purchases_sync()
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE
  v_from timestamptz; v_to timestamptz; v_req bigint; v_n int := 0; v_max int := 8;
  v_denied boolean;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE = '42501';
  END IF;

  -- Scope still denied? (newest 3 resolved pulls all 401 inside 24h) → one probe only.
  SELECT count(*) = 3 INTO v_denied FROM (
    SELECT http_status FROM public.sg_purchases_pending
    WHERE resolved_at > now() - interval '24 hours' ORDER BY resolved_at DESC LIMIT 3) x
  WHERE http_status = 401;
  IF v_denied THEN v_max := 1; END IF;

  -- Watermark: latest end_time of a successful pull; first run reaches 90 days back.
  SELECT coalesce(max(end_time), now() - interval '90 days') INTO v_from
  FROM public.sg_purchases_pending WHERE http_status = 200;

  WHILE v_from < now() - interval '1 minute' AND v_n < v_max LOOP
    v_to := LEAST(v_from + interval '72 hours', now());
    v_req := public.sg_purchases_sync(v_from, v_to, 1, 10);
    v_from := v_to; v_n := v_n + 1;
  END LOOP;
  RETURN v_req;
END $fn$;

COMMENT ON FUNCTION public.sg_purchases_sync(timestamptz,timestamptz,int,int) IS
  'Queue GET brokerdata /purchases for a [start,end] window (<= 72h or RAISE) + page (per_page capped at the API max of 10; pg_net). Read-only. A1 mig 20260911161300.';
COMMENT ON FUNCTION public.sg_purchases_sync() IS
  'Incremental SeatGeek purchase pull: watermark = latest end_time of a 200 pull (90d back on first run), walked in <= 72h chunks, max 8/run; drops to 1 probe/run while the last 3 pulls are 401 (scope denied). A1 mig 20260911161300.';
