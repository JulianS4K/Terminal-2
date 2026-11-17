-- The reconcile leg is now rate-limiting the whole SeatGeek account.
--
-- Mig 20260914250000 repointed it from the (non-existent) /v2/events to /listings, which is the
-- only endpoint that returns the event object — but /listings also returns the event's entire
-- listing book, up to ~1,350 rows. Firing 50 of those every 30 minutes, 0.1s apart, alongside
-- the listing pollers that already run every 2 minutes, pushed the account over its limit:
--
--   hour     429s
--   03:00       0
--   04:00      48    <- first 50-event reconcile batch at 04:48
--   05:00      50
--
-- 79 of the leg's own requests came back {"message":"API rate limit exceeded"}. Nothing before
-- 04:00 had 429'd at all, so this is the leg's own appetite, and the budget it is spending is
-- shared with sg_listings_poll_*, sg_sales_poll_5min and everything else on that token.
--
-- Three changes, all about asking for less:
--   · 50 events per tick -> 8, and 0.1s between calls -> 0.5s
--   · a 429 is now recorded as 'http_429' instead of the generic 'http_other', so the back-off
--     has something honest to read and so the next person can see what happened
--   · the tick stands down entirely for one cycle after seeing a 429, and a 429'd event becomes
--     re-fireable after 25 minutes rather than serving the full 6-hour cooldown — it never got
--     an answer, so it should not be treated like one that did
--
-- 8 per tick is 384/day against ~135 drifting events, so the backlog still clears in hours.

CREATE OR REPLACE FUNCTION public.event_date_reconcile_queue(p_limit int DEFAULT 8)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_token text := get_app_secret('SEATGEEK_API_TOKEN');
        r RECORD; v_req_id bigint; v_count int := 0;
        v_start timestamptz := clock_timestamp();
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;

  -- Stand down for a cycle if the last one was throttled. Queueing into a 429 just burns more
  -- of the shared budget and starves the listing pollers that share this token.
  IF EXISTS (SELECT 1 FROM public.sg_event_backfill_pending
              WHERE reason = 'date_reconcile' AND status = 'http_429'
                AND resolved_at > now() - interval '25 minutes') THEN
    RETURN 0;
  END IF;

  FOR r IN
    SELECT sgc.sg_event_id
    FROM public.events e
    JOIN LATERAL (
      SELECT s2.sg_event_id, s2.sg_datetime_utc FROM public.sg_events_canonical s2
      WHERE s2.tevo_event_id = e.id
      ORDER BY s2.updated_at DESC NULLS LAST, s2.sg_event_id LIMIT 1) sgc ON true
    LEFT JOIN LATERAL (
      SELECT g2.event_time_utc FROM public.gotickets_event g2
      WHERE g2.tevo_event_id = e.id ORDER BY g2.event_time_utc LIMIT 1) ge ON true
    WHERE e.occurs_at_local IS NOT NULL
      AND e.occurs_at_local::timestamptz >= now()
      AND (
        e.state = 'rescheduled'
        OR abs(extract(epoch FROM (sgc.sg_datetime_utc - e.occurs_at_local::timestamptz))) > 86400
        OR abs(extract(epoch FROM (ge.event_time_utc   - e.occurs_at_local::timestamptz))) > 86400
      )
      -- A throttled request never got an answer, so it does not earn the full cooldown.
      AND NOT EXISTS (
        SELECT 1 FROM public.sg_event_backfill_pending p
        WHERE p.sg_event_id = sgc.sg_event_id
          AND p.fired_at > now() - CASE WHEN p.status = 'http_429'
                                        THEN interval '25 minutes'
                                        ELSE interval '6 hours' END)
    ORDER BY e.occurs_at_local::timestamptz
    LIMIT GREATEST(p_limit, 1)
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '45 seconds';
    -- /listings is the only endpoint that hands back the event object. We want the event and
    -- discard the listings; the regular listing pollers own that side.
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token
             || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO public.sg_event_backfill_pending(sg_event_id, request_id, reason, fired_at)
    VALUES (r.sg_event_id, v_req_id, 'date_reconcile', now())
    ON CONFLICT (sg_event_id) DO UPDATE SET
      request_id = EXCLUDED.request_id, fired_at = now(),
      resolved_at = NULL, status = NULL, reason = EXCLUDED.reason;
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END;
$fn$;

-- Record the throttle as itself. 'http_other' hid a 429 behind the same label as a 500.
CREATE OR REPLACE FUNCTION public.sg_event_backfill_process()
RETURNS TABLE(processed int, persisted int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE r RECORD; v_body jsonb; v_evt jsonb;
        v_processed int := 0; v_persisted int := 0; v_status text;
BEGIN
  FOR r IN
    SELECT p.sg_event_id, p.request_id, h.content, h.status_code
    FROM sg_event_backfill_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb; v_status := 'success';
      EXCEPTION WHEN OTHERS THEN v_body := NULL; v_status := 'json_err'; END;
      IF v_body IS NOT NULL THEN
        -- events[] (the old /v2/events shape) · event{} (inline on /listings) · a bare object
        v_evt := COALESCE(v_body->'events'->0, v_body->'event', v_body);
        IF v_evt ? 'id' THEN
          INSERT INTO sg_events_canonical (
            sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_venue_name, sg_category,
            has_seller_listings, has_orders, has_v2_listings_pulled, updated_at
          )
          SELECT
            (v_evt->>'id')::bigint,
            COALESCE(NULLIF(v_evt->>'title',''), NULLIF(v_evt->>'name',''), 'sg_' || (v_evt->>'id')),
            NULLIF(left(v_evt->>'datetime_local',10), '')::date,
            COALESCE(
              (NULLIF(v_evt->>'datetime_utc','')::timestamp) AT TIME ZONE 'UTC',
              (NULLIF(v_evt->>'datetime_local','')::timestamp) AT TIME ZONE 'UTC'),
            v_evt->'venue'->>'name',
            COALESCE(v_evt->'taxonomies'->0->>'name', NULLIF(v_evt->>'category','')),
            false, false, false, now()
          ON CONFLICT (sg_event_id) DO UPDATE SET
            sg_event_name   = COALESCE(EXCLUDED.sg_event_name, sg_events_canonical.sg_event_name),
            -- This payload has no local date and no venue timezone, so a moved event cannot have
            -- its local date recomputed here. Drop it rather than keep yesterday's answer: the
            -- reschedule case is exactly why this pull exists.
            sg_event_date   = CASE
                                WHEN EXCLUDED.sg_event_date IS NOT NULL THEN EXCLUDED.sg_event_date
                                WHEN EXCLUDED.sg_datetime_utc IS NOT NULL
                                 AND sg_events_canonical.sg_datetime_utc IS NOT NULL
                                 AND abs(extract(epoch FROM (EXCLUDED.sg_datetime_utc
                                                           - sg_events_canonical.sg_datetime_utc))) > 86400
                                     THEN NULL
                                ELSE sg_events_canonical.sg_event_date
                              END,
            sg_datetime_utc = COALESCE(EXCLUDED.sg_datetime_utc, sg_events_canonical.sg_datetime_utc),
            sg_venue_name   = COALESCE(EXCLUDED.sg_venue_name, sg_events_canonical.sg_venue_name),
            sg_category     = COALESCE(EXCLUDED.sg_category, sg_events_canonical.sg_category),
            updated_at      = now();
          v_persisted := v_persisted + 1;
        END IF;
      END IF;
    ELSIF r.status_code = 404 THEN v_status := 'http_404';
    ELSIF r.status_code = 429 THEN v_status := 'http_429';
    ELSE v_status := 'http_other'; END IF;
    UPDATE sg_event_backfill_pending SET resolved_at = now(), status = v_status
     WHERE sg_event_id = r.sg_event_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END;
$fn$;

-- The tick's own appetite, matched to the queue's new default.
CREATE OR REPLACE FUNCTION public.event_date_reconcile_tick()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE v_queued int := 0; v_proc int := 0; v_pers int := 0; v_gt_stale int := 0; v_gt_req bigint;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '110000', true);

  v_queued := public.event_date_reconcile_queue(8);
  SELECT processed, persisted INTO v_proc, v_pers FROM public.sg_event_backfill_process();

  SELECT count(*) INTO v_gt_stale
  FROM public.events e
  JOIN LATERAL (
    SELECT g2.event_time_utc FROM public.gotickets_event g2
    WHERE g2.tevo_event_id = e.id ORDER BY g2.event_time_utc LIMIT 1) ge ON true
  WHERE e.occurs_at_local IS NOT NULL
    AND e.occurs_at_local::timestamptz >= now()
    AND abs(extract(epoch FROM (ge.event_time_utc - e.occurs_at_local::timestamptz))) > 86400;

  IF v_gt_stale > 0 THEN
    BEGIN v_gt_req := public.gt_catalog_sync(interval '7 days');
    EXCEPTION WHEN OTHERS THEN v_gt_req := NULL; END;
  END IF;

  RETURN jsonb_build_object('queued_sg', v_queued, 'drained', v_proc, 'persisted', v_pers,
                            'gt_stale_events', v_gt_stale, 'gt_delta_request', v_gt_req, 'at', now());
END;
$fn$;
