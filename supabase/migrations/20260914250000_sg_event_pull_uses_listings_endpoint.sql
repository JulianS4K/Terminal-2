-- The SeatGeek re-pull leg added in mig 20260914230000 never worked: every one of its 153
-- requests came back 404.
--
-- Cause: `brokerdata.seatgeek.com` has NO event-detail endpoint. The reconcile queue called
-- `/v2/events?id=<id>`, copied from `sg_event_backfill_queue` (mig 20260509360000), and that
-- path does not exist either — it returns a generic HTML 404, not a JSON "no such event".
-- Eight URL shapes were probed against a live, known-good event id; all eight 404:
--
--     /v2/events?id=      /v2/events?event_id=   /v2/events?ids=     /v2/events/<id>
--     /events?id=         /events?token=         /event?id=          /v2/event?id=
--
-- The event object is returned INLINE on `/listings`, as {cache_hit, event:{...}, listings:[...]}.
-- `routers/seatgeek.py` has always known this (`body.get("event")`); the SQL side did not.
-- `/listings?token=…&event_id=…` on the same two ids returns 200 with the event object attached.
--
-- ⚠ Landmine worth keeping: `sg_event_backfill_queue` is still on the dead `/v2/events` path and
-- is therefore also a no-op. It is NOT fixed here on purpose — pointing it at `/listings` would
-- make every orphan-event backfill drag a full listing book (1,347 rows for one event in the
-- probe above), which is a cost change on an A1 surface that wants its own decision.
--
-- The reconcile leg is bounded (50 events per half hour), so it can afford the heavier call.

-- ---------------------------------------------------------------------------
-- 1. Ask the endpoint that actually answers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.event_date_reconcile_queue(p_limit int DEFAULT 50)
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
      AND NOT EXISTS (
        SELECT 1 FROM public.sg_event_backfill_pending p
        WHERE p.sg_event_id = sgc.sg_event_id AND p.fired_at > now() - interval '6 hours')
    ORDER BY e.occurs_at_local::timestamptz
    LIMIT GREATEST(p_limit, 1)
  LOOP
    EXIT WHEN clock_timestamp() - v_start > interval '45 seconds';
    -- /listings is the ONLY endpoint that hands back the event object. We want the event and
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
    PERFORM pg_sleep(0.1);
  END LOOP;
  RETURN v_count;
END;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. Parse the shape that endpoint returns
-- ---------------------------------------------------------------------------
-- The inline event carries `name`, `category` and `datetime_utc`. It does NOT carry `title`,
-- `taxonomies` or `datetime_local`, which is all this function used to read — so without this
-- change a successful pull would have written the event name as the literal 'sg_<id>' over the
-- real one, and left the local date pointing at the pre-reschedule day.
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
    ELSE v_status := 'http_other'; END IF;
    UPDATE sg_event_backfill_pending SET resolved_at = now(), status = v_status
     WHERE sg_event_id = r.sg_event_id;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END;
$fn$;
