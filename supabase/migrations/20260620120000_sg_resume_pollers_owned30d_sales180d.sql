-- ============================================================================
-- Migration 20260620120000 — operator-directed: resume 5 SeatGeek ingest crons
--                            (owned listings capped ≤30d, sales horizon 90→180d)
--
-- ## Already applied to prod — applied via MCP 2026-06-20 (verified: 5 crons
--    active, fn signature 5-arg, ACL service_role-only, work_check widened 180d).
--
-- Lane:     A1 data plane (SECDEF fn DDL + cron) — operator-directed 2026-06-20
-- Touches:  sg_listings_poll_tick (DDL: +p_horizon_days), cron.job (355/248/64/
--           407/179 active+command), cron_policy (sg_sales_poll_5min work_check)
-- Pre-reqs: none. Backward compatible — the new fn param defaults NULL = prior
--           behavior; only the owned cron passes a value.
--
-- Operator directive (2026-06-20) — re-enable the paused SG ingest pollers:
--   • sg_sales_poll_5min             : resume + expand horizon 90 -> 180 days
--   • sg_seller_listings_queue_30min : resume (our SellerDirect active listings)
--   • sg_wc_listings_catchup         : resume (World-Cup force-track catchup)
--   • orphan_event_backfill_queue_15min : resume (EVO + SG orphan enqueue)
--   • sg_listings_poll_owned_1min    : resume but cap to events <= 30 days away
--
-- NOT resumed (left paused — operator did not request; the first is flagged
-- "don't re-enable" in PROJECT_BIBLE §3/§4): auto_match_sg_canonical_v3_hourly,
-- sg_seller_orders_queue_30min, sg_seller_sync_map_15min.
--
-- Notes:
--  * sg_listings_poll_tick gains p_horizon_days int DEFAULT NULL (NULL = no cap
--    = prior behavior). Its only caller is the owned cron, now passing 30. The
--    prior 4-arg signature is DROPped first — a defaulted new param creates a
--    NEW overload, not a replacement (PROJECT_BIBLE §7) → "function is not
--    unique". DROP resets ACL, so we re-lock to service_role per §2.8.5 (cron
--    runs as superuser `postgres`, which bypasses EXECUTE ACL, so this only
--    removes a latent anon/authenticated PostgREST trigger path — no functional
--    change).
--  * sg_sales_poll_5min work_check_sql window widened 1440h (60d) -> 4320h
--    (180d) so the gate doesn't suppress firing when only 60-180d events remain
--    to poll (matches the new p_horizon_days=180).
--  * All upstream calls stay GET-only (RULE 2). 429 risk: the owned poll is now
--    NARROWER (≤30d), so net SG token pressure drops, not rises.
-- ============================================================================

-- 1. Listings poller — add optional forward-horizon cap (backward compatible) --
DROP FUNCTION IF EXISTS public.sg_listings_poll_tick(integer, integer, text, numeric);

CREATE OR REPLACE FUNCTION public.sg_listings_poll_tick(
  p_max integer DEFAULT 20,
  p_min_remaining integer DEFAULT 3,
  p_owned_kind text DEFAULT NULL::text,
  p_rate_mult numeric DEFAULT 1,
  p_horizon_days integer DEFAULT NULL)
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
           (coalesce(s.owned_count_last_7d,0) > 0 OR s.force_track)) c ON true
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      -- NEW: optional forward-horizon cap (NULL = uncapped = prior behavior)
      AND ( p_horizon_days IS NULL
            OR s.sg_datetime_utc < v_now + make_interval(days => p_horizon_days) )
      AND ( p_owned_kind IS NULL
            OR (coalesce(s.owned_count_last_7d,0) > 0 OR s.force_track) = (p_owned_kind = 'owned') )
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

REVOKE EXECUTE ON FUNCTION public.sg_listings_poll_tick(integer,integer,text,numeric,integer)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sg_listings_poll_tick(integer,integer,text,numeric,integer)
  TO service_role;

-- 2. Resume + reconfigure the crons -------------------------------------------
-- owned listings poller: resume, cap to events <= 30 days away
SELECT cron.alter_job(
  355,
  command := $cmd$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_listings_poll_owned_1min') THEN RETURN; END IF; PERFORM public.sg_listings_poll_tick(4, 3, 'owned', 2, 30); END $b$;$cmd$,
  active := true);

-- sales poller: resume, expand forward horizon 90 -> 180 days
SELECT cron.alter_job(
  248,
  command := $cmd$DO $b$ BEGIN IF NOT public.cron_should_fire('sg_sales_poll_5min') THEN RETURN; END IF; PERFORM public.sg_sales_poll_tick(4, 180); END $b$;$cmd$,
  active := true);

-- seller-account active listings: resume (command unchanged)
SELECT cron.alter_job(64,  active := true);
-- World-Cup force-track catchup: resume (command unchanged)
SELECT cron.alter_job(407, active := true);
-- orphan EVO + SG event backfill enqueue: resume (command unchanged)
SELECT cron.alter_job(179, active := true);

-- 3. Widen the sales gate's work-check window 60d -> 180d to match -------------
UPDATE public.cron_policy
   SET work_check_sql = replace(work_check_sql, '1440 hours', '4320 hours')
 WHERE jobname = 'sg_sales_poll_5min'
   AND work_check_sql LIKE '%1440 hours%';
