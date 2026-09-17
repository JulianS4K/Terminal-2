-- 39 of the 41 events still "drifting" are not drifting at all.
--
-- The reconcile predicate asks whether two INSTANTS are more than 24 hours apart. An evening
-- event straddles UTC midnight, and a TEvo start time that has not been announced yet arrives as
-- a placeholder midnight, so the two sources routinely land 25-30 hours apart while describing
-- the same night. Those events qualify as drift every six hours, forever: re-pulled, SeatGeek
-- confirms the same answer, nothing resolves, the next cycle asks again. It is the reason the
-- backlog plateaus instead of reaching zero, and it spends the 8-per-tick SeatGeek budget that
-- mig 20260915000000 exists to protect.
--
-- Measured against the live set before changing anything:
--
--   drifting under the 24h rule                          41
--   ...within one day on TEvo's own written local date   39   <- UTC rollover, not disagreement
--   ...genuinely different                                2
--   smallest genuinely-different gap                 13 days
--
-- A first attempt at this keyed on "TEvo time is exactly midnight" and silenced only 1 of the 41,
-- because most placeholder rows still carry a timezone offset and so are not midnight once cast.
-- The dry run caught that before it shipped. What actually separates the two populations is
-- simple: the noise sits under 36 hours and the real cases start at 13 DAYS, so a 36-hour
-- threshold splits them with an enormous margin and needs nothing the callers do not already
-- have — no raw text, no venue timezone.
--
-- The cost is that a reschedule of exactly one day would no longer trip the time comparison.
-- That case is still covered: `e.state = 'rescheduled'` is an independent arm of the same
-- predicate, so an event TEvo has flagged is queued regardless of how far its clock moved.

CREATE OR REPLACE FUNCTION public.deal_event_date_disagrees(
  p_other timestamptz, p_tevo timestamptz)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $fn$
  -- 36 hours, not 24: an evening event straddles UTC midnight and an unannounced TEvo start time
  -- is a placeholder, so the same night reads 25-30 hours apart across sources. Real
  -- disagreements in the live set start at 13 days.
  SELECT p_other IS NOT NULL AND p_tevo IS NOT NULL
     AND abs(extract(epoch FROM (p_other - p_tevo))) > 129600
$fn$;

COMMENT ON FUNCTION public.deal_event_date_disagrees(timestamptz, timestamptz) IS
  'True when another source genuinely disagrees with TEvo about when an event happens. Threshold is 36h, not 24h: evening events straddle UTC midnight and unannounced TEvo start times are placeholder midnights, which made 39 of 41 live rows read as drift forever. Genuine disagreements start at 13 days.';

-- ---------------------------------------------------------------------------
-- The reconcile queue: stop re-pulling events that were never disagreeing
-- ---------------------------------------------------------------------------
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
        OR public.deal_event_date_disagrees(sgc.sg_datetime_utc, e.occurs_at_local::timestamptz)
        OR public.deal_event_date_disagrees(ge.event_time_utc,   e.occurs_at_local::timestamptz)
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

-- ---------------------------------------------------------------------------
-- The daily sweep: same predicate, so the two never disagree about what drift is
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_src text; v_args text; v_cfg text[]; v_set text := ''; v_kv text; v_a text;
BEGIN
  SELECT p.prosrc, pg_get_function_arguments(p.oid), p.proconfig INTO v_src, v_args, v_cfg
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'event_catalogue_drift_scan';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'event_catalogue_drift_scan not found';
  END IF;

  v_a := E'    WHERE (sg_dt IS NOT NULL AND abs(extract(epoch FROM (sg_dt - tevo_dt))) > 86400)\n'
         '       OR (gt_dt IS NOT NULL AND abs(extract(epoch FROM (gt_dt - tevo_dt))) > 86400)),';
  IF position(v_a in v_src) = 0 THEN
    RETURN;   -- already on the shared predicate, or the block moved: do not guess
  END IF;
  IF (length(v_src) - length(replace(v_src, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'drift predicate anchor did not match exactly once';
  END IF;

  FOREACH v_kv IN ARRAY coalesce(v_cfg, ARRAY[]::text[]) LOOP
    v_set := v_set || format(' SET %I TO %s', split_part(v_kv, '=', 1),
                             substr(v_kv, strpos(v_kv, '=') + 1));
  END LOOP;

  v_src := replace(v_src, v_a,
    E'    WHERE public.deal_event_date_disagrees(sg_dt, tevo_dt)\n'
    '       OR public.deal_event_date_disagrees(gt_dt, tevo_dt)),');

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.event_catalogue_drift_scan(%s) RETURNS jsonb '
    'LANGUAGE plpgsql SECURITY DEFINER%s AS %s',
    v_args, v_set, quote_literal(v_src));
END
$do$;

-- ---------------------------------------------------------------------------
-- The tick's GoTickets staleness count, for the same reason
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_src text; v_args text; v_cfg text[]; v_set text := ''; v_kv text; v_a text;
BEGIN
  SELECT p.prosrc, pg_get_function_arguments(p.oid), p.proconfig INTO v_src, v_args, v_cfg
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'event_date_reconcile_tick';
  IF v_src IS NULL THEN
    RAISE EXCEPTION 'event_date_reconcile_tick not found';
  END IF;

  v_a := '    AND abs(extract(epoch FROM (ge.event_time_utc - e.occurs_at_local::timestamptz))) > 86400;';
  IF position(v_a in v_src) = 0 THEN
    RETURN;
  END IF;
  IF (length(v_src) - length(replace(v_src, v_a, ''))) / length(v_a) <> 1 THEN
    RAISE EXCEPTION 'tick staleness anchor did not match exactly once';
  END IF;

  FOREACH v_kv IN ARRAY coalesce(v_cfg, ARRAY[]::text[]) LOOP
    v_set := v_set || format(' SET %I TO %s', split_part(v_kv, '=', 1),
                             substr(v_kv, strpos(v_kv, '=') + 1));
  END LOOP;

  v_src := replace(v_src, v_a,
    '    AND public.deal_event_date_disagrees(ge.event_time_utc, e.occurs_at_local::timestamptz);');

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.event_date_reconcile_tick(%s) RETURNS jsonb '
    'LANGUAGE plpgsql SECURITY DEFINER%s AS %s',
    v_args, v_set, quote_literal(v_src));
END
$do$;
