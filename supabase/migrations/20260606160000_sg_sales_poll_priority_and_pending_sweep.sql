-- Migration 20260606160000 · lane:D0 (operator-directed; cross-lane SG ingestion) · writes:sg_sales_poll_tick,sg_broker_sales_process,sg_broker_pending,cron.job · reads:sg_event_priority_state,net._http_response · pre:20260519150000 · auth:operator-approved 2026-06-06
--
-- SG sales-poll starvation fix.
--
-- Symptom (operator report 2026-06-06): on imminent HOT games (e.g. Red Sox @
-- Yankees, sg 17691551) the "SG sale med" line freezes ~1 day stale while the
-- "SG list med" line stays fresh.
--
-- Root cause: sg_sales_poll_tick fired only 8 events/tick (*/5) against ~1,150
-- eligible events (~423 DUE at any moment), and its ORDER BY had NO tier/
-- proximity priority — last_polled_sales_at NULLS FIRST. So a HOT game tonight
-- competed equally with 800+ TRACK_BLINDSPOT / COLD future events and was
-- polled only ~once/day (sales_polls_today=1). Listings were unaffected (that
-- poll runs */1 with far more headroom).
--
-- Fix (kept deliberately conservative — sales & listings SHARE the SeatGeek
-- token, so we do NOT crank throughput hard):
--   1. sg_sales_poll_tick — reorder so just-finished games (final catch-up),
--      then HOT/WARM tiers, then nearest-to-gametime are served FIRST. The
--      eligibility WHERE (collector_band required_min cadence) is unchanged.
--      Batch nudged 8 -> 20 via the cron call (below); per-event over-polling
--      is still gated by required_min, so total API load stays bounded.
--   2. sg_broker_sales_process — add a self-heal step: expire pending sales
--      rows whose pg_net response has been purged (the INNER JOIN can never
--      match them, so they accumulated to 113k zombies, oldest 2026-05-14).
--   3. One-time sweep of the existing zombie backlog.
--
-- All operator-approved 2026-06-06 (interactive). Functions reproduced verbatim
-- except the documented changes.

-- ---------- 1. priority-ordered sales poll ----------
CREATE OR REPLACE FUNCTION public.sg_sales_poll_tick(p_max integer DEFAULT 50)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE r RECORD; v_req bigint; v_now timestamptz := clock_timestamp(); v_token text := public.get_app_secret('SEATGEEK_API_TOKEN'); v_polled int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN RAISE EXCEPTION 'sg_sales_poll_tick: caller % not authorized', current_user; END IF;
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  IF p_max <= 0 THEN RETURN 0; END IF;
  FOR r IN
    WITH elig AS (
      SELECT s.sg_event_id, s.tier, s.sg_datetime_utc, s.last_polled_sales_at, EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0 AS hte
      FROM public.sg_event_priority_state s
      WHERE s.sg_datetime_utc > v_now - interval '24 hours' AND s.sg_datetime_utc <= v_now + interval '1440 hours' AND s.tier <> 'SKIP'
    )
    SELECT e.sg_event_id FROM elig e
    CROSS JOIN LATERAL public.collector_band('SG','sales', greatest(e.hte, 0)) c
    WHERE ( e.hte < -2 AND (e.last_polled_sales_at IS NULL OR e.last_polled_sales_at < e.sg_datetime_utc) )
       OR ( e.hte >= -2 AND (e.last_polled_sales_at IS NULL OR e.last_polled_sales_at < v_now - make_interval(mins => c.required_min)) )
    ORDER BY
      (e.hte < -2) DESC,                                              -- just-finished games: one final catch-up first
      CASE e.tier WHEN 'HOT' THEN 0 WHEN 'WARM' THEN 1 ELSE 2 END,    -- tier priority (HOT/WARM jump the queue)
      abs(e.hte) ASC,                                                 -- then nearest-to-gametime
      e.last_polled_sales_at NULLS FIRST,                             -- then stalest
      e.sg_event_id
    LIMIT p_max
  LOOP
    SELECT net.http_get(url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text, timeout_milliseconds := 30000) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at) VALUES (r.sg_event_id, 'sales', v_req, v_now);
    UPDATE public.sg_event_priority_state SET last_polled_sales_at = v_now, sales_polls_today = sales_polls_today + 1 WHERE sg_event_id = r.sg_event_id;
    v_polled := v_polled + 1;
  END LOOP;
  RETURN v_polled;
END $function$;

-- ---------- 2. sales processor + self-heal for purged-response pending rows ----------
CREATE OR REPLACE FUNCTION public.sg_broker_sales_process(p_limit integer DEFAULT 50)
 RETURNS TABLE(processed integer, sales_persisted integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id,
           h.status_code, h.content::jsonb AS body,
           a.aq_short_event_id,
           x.tevo_event_id
    FROM public.sg_broker_pending p
    JOIN net._http_response h ON h.id = p.request_id
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = p.sg_event_id
    LEFT JOIN public.seatgeek_event_xref x ON x.sg_event_id = p.sg_event_id
    WHERE p.scope = 'sales' AND p.resolved_at IS NULL
    ORDER BY p.fired_at
    LIMIT p_limit
  LOOP
    v_processed := v_processed + 1;
    v_inserted := NULL;
    IF r.status_code = 200 AND jsonb_typeof(r.body->'sales') = 'array' THEN
      WITH src AS (SELECT s FROM jsonb_array_elements(r.body->'sales') AS s),
      ins AS (
        INSERT INTO public.seatgeek_sales_snapshots (
          tevo_event_id, sg_event_id, pulled_at, sg_sale_id,
          broadcast_price, quantity, section, row, stock_type,
          delivery_method, in_hand_date, is_instant, seller_notes,
          sale_at_utc, raw, aq_short_event_id
        )
        SELECT r.tevo_event_id, r.sg_event_id, now(), s->>'id',
          NULLIF(s->>'bp','')::numeric, NULLIF(s->>'q','')::int,
          s->>'s', s->>'r', s->>'st', s->>'dm',
          NULLIF(s->>'ihd','')::date, NULLIF(s->>'idl','')::boolean,
          s->>'pn', NULLIF(s->>'putc','')::timestamptz, s,
          r.aq_short_event_id
        FROM src WHERE s->>'id' IS NOT NULL
        ON CONFLICT DO NOTHING
        RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);
    END IF;
    -- A1 2026-05-19: 429-aware sentinel for observability + still resolve so re-queue works
    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = CASE
            WHEN r.status_code = 200 THEN COALESCE(v_inserted, 0)
            WHEN r.status_code = 429 THEN -429   -- rate-limited; next queue cycle will re-fire
            ELSE -1                              -- 400/404/500 terminal failure
          END
      WHERE id = r.pending_id;
  END LOOP;

  -- D0 2026-06-06: self-heal. The INNER JOIN above can never match a pending
  -- row once pg_net has purged its net._http_response, so such rows would stay
  -- resolved_at IS NULL forever (113k zombie backlog before this fix). Expire
  -- the orphans (older than the pg_net TTL window) with a distinct sentinel.
  UPDATE public.sg_broker_pending p
    SET resolved_at = now(), rows_persisted = -2   -- -2 = response expired / never landed
  WHERE p.scope = 'sales' AND p.resolved_at IS NULL
    AND p.fired_at < now() - interval '1 hour'
    AND NOT EXISTS (SELECT 1 FROM net._http_response h WHERE h.id = p.request_id);

  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;

-- ---------- 3. one-time sweep of the existing zombie backlog ----------
UPDATE public.sg_broker_pending p
  SET resolved_at = now(), rows_persisted = -2
WHERE p.scope = 'sales' AND p.resolved_at IS NULL
  AND p.fired_at < now() - interval '1 hour'
  AND NOT EXISTS (SELECT 1 FROM net._http_response h WHERE h.id = p.request_id);

-- ---------- 4. raise the poll batch (8 -> 20), ordering now does the heavy lifting ----------
SELECT cron.schedule(
  'sg_sales_poll_5min',
  '*/5 * * * *',
  $cron$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_sales_poll_5min') THEN RETURN; END IF; PERFORM public.sg_sales_poll_tick(20); END $b$;$cron$
);
