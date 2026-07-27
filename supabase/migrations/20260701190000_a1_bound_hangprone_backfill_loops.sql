-- ============================================================================
-- Migration 20260701190000 — bound the three hang-prone backfill loops
--
-- Lane:     A1
-- Touches:  public.backfill_stale_zone_metrics(int), public.evo_event_backfill_queue(int),
--           public.sg_event_backfill_queue(int). Function bodies only (CREATE OR REPLACE).
-- Pre-reqs: compute_event_zone_metrics/compute_event_section_metrics, get_app_secret,
--           tevo_sign_get, evo/sg *_backfill_pending tables, latest_event_metrics.
--
-- WHY (scheduler-wedge hardening, Part A — operator 2026-07-01):
--   These three functions are the confirmed hang sites behind the 3 pg_cron wedges on
--   2026-07-01 (~13h degraded). With cron.use_background_workers=off, ONE job that runs
--   unbounded holds an open txn that blocks cron_should_fire()/the launcher -> the whole
--   scheduler freezes. Each function loops over per-event work with an accumulating
--   pg_sleep and (in backfill) a per-iteration `SET LOCAL statement_timeout` that DOES
--   NOTHING — empirically verified on this DB: `SET LOCAL statement_timeout` inside a
--   running function is a no-op on the in-flight statement (a nested pg_sleep(4) under a
--   SET LOCAL '2s' ran the full 4s, uncancelled). Only a top-level `SET statement_timeout`
--   as its OWN statement before the call caps a nested call (verified: cancelled at 2s) —
--   which is exactly what the cron commands now carry (`SET statement_timeout='5min'; ...`
--   per 20260630300000). So the per-iteration SET LOCAL is dead weight and is removed.
--
--   FIX: give each loop a real, self-enforcing WALL-CLOCK budget via
--   `EXIT WHEN clock_timestamp() - v_start > interval 'Ns'` at the top of the loop, so a
--   single run can't sit in one of the 32 cron slots accumulating work for minutes. This
--   is defense-in-depth WITH (a) the cron-level `SET statement_timeout='5min'` hard cap
--   [verified working] and (b) the durable FastAPI scheduler watchdog
--   (scheduler_watchdog_kill_stale_backends, migration 20260701182336) that terminates any
--   backend still active >5min once the scheduler goes stale >6min.
--   Also trims the per-row pg_sleep (0.3/0.4 -> 0.1s) — pg_net http_get is async (returns a
--   request_id immediately), so the sleep only spaces request bursts; 0.1s is ample.
--
--   NOTE: orphan_event_backfill_queue_15min + midnight-catchup-sweep stay DISABLED. Re-enable
--   is gated on the Part D index build (index-backing the un-indexed orphan NOT EXISTS scans)
--   + observing a few runs complete under budget. Their cron commands already carry the
--   effective SET-prefix cap, so re-enabling later is safe + a one-liner.
--
-- Idempotent: CREATE OR REPLACE only. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-01
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) backfill_stale_zone_metrics: add a 90s loop wall-clock budget; drop the
--    no-op per-iteration SET LOCAL statement_timeout. Per-event compute stays
--    wrapped in BEGIN/EXCEPTION so one bad event is skipped, not fatal. The hard
--    total cap remains the caller's cron-level SET statement_timeout + watchdog.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.backfill_stale_zone_metrics(p_max_events integer DEFAULT 3)
 RETURNS TABLE(events_recomputed integer, zones_written integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  r RECORD; v_events int := 0; v_zones int := 0; v_n int;
  v_start timestamptz := clock_timestamp();
BEGIN
  FOR r IN (
    WITH latest_ls AS (
      SELECT event_id, captured_at AS latest_ls_at
      FROM latest_event_metrics
      WHERE captured_at >= now() - interval '7 days'
    ),
    latest_zm AS (
      SELECT event_id, MAX(captured_at) AS latest_zm_at
      FROM zone_metrics GROUP BY event_id
    )
    SELECT ll.event_id, ll.latest_ls_at
    FROM latest_ls ll
    LEFT JOIN latest_zm zm ON zm.event_id = ll.event_id
    WHERE zm.latest_zm_at IS NULL OR zm.latest_zm_at < ll.latest_ls_at
    ORDER BY ll.latest_ls_at DESC
    LIMIT p_max_events
  ) LOOP
    -- Loop wall-clock budget: never hold a cron slot longer than ~90s, no matter
    -- how large p_max_events is (midnight_catchup calls with 500).
    EXIT WHEN clock_timestamp() - v_start > interval '90 seconds';
    BEGIN
      v_n := compute_event_zone_metrics(r.event_id, r.latest_ls_at);
      PERFORM compute_event_section_metrics(r.event_id, r.latest_ls_at);
      v_events := v_events + 1;
      v_zones  := v_zones + COALESCE(v_n, 0);
    EXCEPTION
      WHEN query_canceled THEN
        RAISE NOTICE 'backfill_stale_zone_metrics: event % cancelled (statement_timeout)', r.event_id;
      WHEN OTHERS THEN
        RAISE NOTICE 'backfill_stale_zone_metrics failed for event %: %', r.event_id, SQLERRM;
    END;
  END LOOP;
  events_recomputed := v_events;
  zones_written := v_zones;
  RETURN NEXT;
END
$function$;

-- ---------------------------------------------------------------------------
-- 2) evo_event_backfill_queue: 60s loop budget + pg_sleep 0.3 -> 0.1.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.evo_event_backfill_queue(p_limit integer DEFAULT 20)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_token  text := get_app_secret('TEVO_API_TOKEN');
  v_secret text := get_app_secret('TEVO_SECRET');
  v_query  text; v_sig text; v_req_id bigint; v_count int := 0; r RECORD;
  v_start timestamptz := clock_timestamp();
BEGIN
  FOR r IN
    WITH orphans AS (
      SELECT DISTINCT it.event_id AS tevo_event_id, 'order_orphan' AS reason
      FROM evo_order_items it
      WHERE it.event_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM events e WHERE e.id = it.event_id)
    )
    SELECT o.tevo_event_id, o.reason FROM orphans o
    LEFT JOIN evo_event_backfill_pending p ON p.tevo_event_id = o.tevo_event_id
        AND p.fired_at > now() - interval '6 hours'
    WHERE p.tevo_event_id IS NULL LIMIT p_limit
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '60 seconds';
    v_query := '';
    v_sig := tevo_sign_get('/v9/events/' || r.tevo_event_id, v_query, v_secret);
    SELECT net.http_get(
      url := 'https://api.ticketevolution.com/v9/events/' || r.tevo_event_id,
      headers := jsonb_build_object(
        'X-Token', v_token, 'X-Signature', v_sig,
        'Accept', 'application/vnd.ticketevolution.api+json; version=9'),
      timeout_milliseconds := 20000
    ) INTO v_req_id;
    INSERT INTO evo_event_backfill_pending(tevo_event_id, request_id, reason, fired_at)
    VALUES (r.tevo_event_id, v_req_id, r.reason, now())
    ON CONFLICT (tevo_event_id) DO UPDATE SET
      request_id = EXCLUDED.request_id, fired_at = now(),
      resolved_at = NULL, status = NULL, reason = EXCLUDED.reason;
    v_count := v_count + 1;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RETURN v_count;
END; $function$;

-- ---------------------------------------------------------------------------
-- 3) sg_event_backfill_queue: 60s loop budget + pg_sleep 0.4 -> 0.1.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sg_event_backfill_queue(p_limit integer DEFAULT 20)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_token text := get_app_secret('SEATGEEK_API_TOKEN');
        r RECORD; v_req_id bigint; v_count int := 0;
        v_start timestamptz := clock_timestamp();
BEGIN
  FOR r IN
    WITH orphans AS (
      SELECT DISTINCT sg_event_id, 'order_orphan' AS reason
      FROM seatgeek_orders
      WHERE sg_event_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM sg_events_canonical c WHERE c.sg_event_id = seatgeek_orders.sg_event_id)
      UNION
      SELECT DISTINCT sg_event_id, 'seller_orphan'
      FROM seatgeek_seller_listings
      WHERE sg_event_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM sg_events_canonical c WHERE c.sg_event_id = seatgeek_seller_listings.sg_event_id)
      UNION
      SELECT DISTINCT sg_event_id, 'listing_orphan'
      FROM seatgeek_listings_snapshots
      WHERE sg_event_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM sg_events_canonical c WHERE c.sg_event_id = seatgeek_listings_snapshots.sg_event_id)
    )
    SELECT o.sg_event_id, o.reason FROM orphans o
    LEFT JOIN sg_event_backfill_pending p ON p.sg_event_id = o.sg_event_id
        AND p.fired_at > now() - interval '6 hours'
    WHERE p.sg_event_id IS NULL LIMIT p_limit
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '60 seconds';
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/v2/events?id=' || r.sg_event_id || '&token=' || v_token,
      timeout_milliseconds := 20000
    ) INTO v_req_id;
    INSERT INTO sg_event_backfill_pending(sg_event_id, request_id, reason, fired_at)
    VALUES (r.sg_event_id, v_req_id, r.reason, now())
    ON CONFLICT (sg_event_id) DO UPDATE SET
      request_id = EXCLUDED.request_id, fired_at = now(),
      resolved_at = NULL, status = NULL, reason = EXCLUDED.reason;
    v_count := v_count + 1;
    PERFORM pg_sleep(0.1);
  END LOOP;
  RETURN v_count;
END; $function$;
