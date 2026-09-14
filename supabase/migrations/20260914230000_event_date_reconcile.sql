-- ============================================================================
-- Migration 20260914230000 — when a source says "rescheduled", go ask the others
--
-- Lane:     D0 (deals surface) · reads/writes A1's sg_events_canonical — cross-lane, operator-directed
-- Touches:  sg_event_backfill_process() (CREATE OR REPLACE — now writes sg_datetime_utc too) ·
--           event_date_reconcile_queue(int) (new) · event_date_reconcile_tick() (new) ·
--           cron job event_date_reconcile_30min (new)
-- Pre-reqs: 20260914220000
--
-- Operator 2026-09-14: "if tevo is marked rescheduled poll both gotickets and seatgeek for new
-- dates, and vice versa."
--
-- ── WHY 20260914220000 WAS ONLY HALF THE FIX ───────────────────────────────
-- That migration made the deals surface PREFER TEvo's date when a source disagrees by more than
-- a day. It fixed what we read; it did nothing about the stale row itself, which keeps poisoning
-- every other consumer of sg_events_canonical.
--
-- Measured on the event that started this (tevo_event_id 3253199, SG 17921367):
--   sg_event_date    2026-07-16   sg_datetime_utc  2026-07-16   updated_at  2026-09-14 11:39
-- The row was touched TODAY and still held July. sg_canonical_refresh_v2_pull() bumps
-- updated_at while only recording listing-pull bookkeeping — it never touches a date. Nothing
-- in the system re-pulls the date of an ALREADY-MAPPED SeatGeek event.
--
-- ── THE TWO DEFECTS ────────────────────────────────────────────────────────
-- 1. sg_event_backfill_process() upserts from SeatGeek's /v2/events payload but writes ONLY
--    sg_event_date. sg_datetime_utc — the column scan_listing_deals actually reads — is left
--    untouched, so even a successful re-pull would not have corrected us.
-- 2. sg_event_backfill_queue() only ever queues ORPHANS (SG events with no canonical row). An
--    event that is mapped but wrong is invisible to it, which is exactly our case.
--
-- ── WHAT THIS ADDS ─────────────────────────────────────────────────────────
-- event_date_reconcile_queue() enqueues, into the EXISTING sg_event_backfill_pending path and
-- the EXISTING brokerdata /v2/events GET, any UPCOMING event where TEvo says 'rescheduled' or
-- where a source's date is more than a day off TEvo's. The existing drain then corrects both
-- date columns. No new upstream endpoint: RULE 2 is untouched, this is a GET on a host the
-- project already calls, reusing a queue that already exists.
--
-- Direction coverage, stated plainly because "and vice versa" deserves an honest answer:
--   TEvo  — already self-refreshing. collect-listings upserts events.occurs_at_local on every
--           watchlist sweep, which is why TEvo alone had the correct 2026-10-06 date.
--   SG    — the gap this migration closes.
--   GT    — GoTickets publishes ONLY /rest/events/delta (time-windowed, no per-event fetch), so
--           there is nothing to target. gt_catalog_sync's daily 26h delta already carries any
--           reschedule GT publishes. When a GT date is the one adrift, this tick fires at most
--           ONE widened gt_catalog_sync per run rather than hammering the delta endpoint.
--
-- ROLLBACK: DROP the two functions + the cron job; re-apply sg_event_backfill_process from its
-- prior definition (it then stops maintaining sg_datetime_utc).
-- ============================================================================

-- ── 1. The SG drain must maintain the column our scanner reads ───────────────
CREATE OR REPLACE FUNCTION public.sg_event_backfill_process()
RETURNS TABLE(processed integer, persisted integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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
        v_evt := COALESCE(v_body->'events'->0, v_body);
        IF v_evt ? 'id' THEN
          INSERT INTO sg_events_canonical (
            sg_event_id, sg_event_name, sg_event_date, sg_datetime_utc, sg_venue_name, sg_category,
            has_seller_listings, has_orders, has_v2_listings_pulled, updated_at
          )
          SELECT
            (v_evt->>'id')::bigint,
            COALESCE(NULLIF(v_evt->>'title',''), 'sg_' || (v_evt->>'id')),
            NULLIF(left(v_evt->>'datetime_local',10), '')::date,
            -- SeatGeek returns datetime_utc WITHOUT an offset, so anchor it to UTC explicitly
            -- rather than letting the session TimeZone decide (mig 20260914230000).
            COALESCE(
              (NULLIF(v_evt->>'datetime_utc','')::timestamp) AT TIME ZONE 'UTC',
              (NULLIF(v_evt->>'datetime_local','')::timestamp) AT TIME ZONE 'UTC'),
            v_evt->'venue'->>'name',
            v_evt->'taxonomies'->0->>'name',
            false, false, false, now()
          ON CONFLICT (sg_event_id) DO UPDATE SET
            sg_event_name   = COALESCE(EXCLUDED.sg_event_name, sg_events_canonical.sg_event_name),
            sg_event_date   = COALESCE(EXCLUDED.sg_event_date, sg_events_canonical.sg_event_date),
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
$function$;
COMMENT ON FUNCTION public.sg_event_backfill_process() IS
  'Drains sg_event_backfill_pending into sg_events_canonical. Maintains BOTH date columns since mig 20260914230000 — it previously wrote only sg_event_date, leaving sg_datetime_utc (the column scan_listing_deals reads) stale forever. datetime_utc is anchored AT TIME ZONE ''UTC'' because SeatGeek sends it without an offset.';

-- ── 2. Enqueue the events whose date is in doubt ─────────────────────────────
CREATE OR REPLACE FUNCTION public.event_date_reconcile_queue(p_limit integer DEFAULT 50)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
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
      AND e.occurs_at_local::timestamptz >= now()          -- only events still ahead of us
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
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/v2/events?id=' || r.sg_event_id || '&token=' || v_token,
      timeout_milliseconds := 20000
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
$function$;
COMMENT ON FUNCTION public.event_date_reconcile_queue(integer) IS
  'Queues a SeatGeek /v2/events re-pull for any UPCOMING event whose date is in doubt: TEvo state=''rescheduled'', or a source more than a day off TEvo. Reuses the existing sg_event_backfill_pending queue and GET — no new upstream endpoint (RULE 2 untouched). sg_event_backfill_queue() only ever sees orphans, so a mapped-but-wrong event was previously unreachable. 6-hour re-fire guard per event. D0 mig 20260914230000.';

-- ── 3. One tick: enqueue, drain, and nudge the GT delta if GT is the stale one ─
CREATE OR REPLACE FUNCTION public.event_date_reconcile_tick()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_queued int := 0; v_proc int := 0; v_pers int := 0; v_gt_stale int := 0; v_gt_req bigint;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '110000', true);

  v_queued := public.event_date_reconcile_queue(50);
  SELECT processed, persisted INTO v_proc, v_pers FROM public.sg_event_backfill_process();

  -- GoTickets publishes no per-event fetch, only a time-windowed delta. If GT is the source
  -- that is adrift, fire ONE widened delta pull per tick rather than hammering the endpoint.
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
$function$;
COMMENT ON FUNCTION public.event_date_reconcile_tick() IS
  'Reconciles event dates across sources: queues SeatGeek re-pulls for rescheduled/disagreeing upcoming events, drains them, and fires at most one widened GoTickets delta per run when GT is the stale source. TEvo needs no lever — collect-listings refreshes occurs_at_local on every watchlist sweep. D0 mig 20260914230000.';

REVOKE ALL ON FUNCTION public.event_date_reconcile_queue(integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.event_date_reconcile_tick() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.event_date_reconcile_queue(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.event_date_reconcile_tick() TO service_role;

-- ── 4. Cron (avoids the :02/:05/:07 marks per CLAUDE.md) ─────────────────────
SELECT cron.schedule('event_date_reconcile_30min', '18,48 * * * *', $cron$
  DO $b$ BEGIN
    IF NOT public.cron_try_lock('event_date_reconcile') THEN RETURN; END IF;
    BEGIN PERFORM public.event_date_reconcile_tick();
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'event_date_reconcile skipped: %', SQLERRM; END;
  END $b$;
$cron$);

-- ── 5. Daily catalogue sweep: reschedules, venue changes, and who agrees ─────
-- Operator 2026-09-14: "create a daily catalogue job to look for reschedules and venue changes
-- and then see if other sites match."
--
-- The 30-minute tick above is the fast path for dates. This is the wide, once-a-day sweep that
-- also watches VENUE and STATUS, and records what each source says so a disagreement is visible
-- rather than silently resolved by whichever column a consumer happens to read.
CREATE OR REPLACE FUNCTION public.venue_name_tokens(p_name text)
RETURNS text[]
LANGUAGE sql IMMUTABLE
AS $fn$
  SELECT coalesce(array_agg(t), '{}'::text[])
  FROM (
    SELECT DISTINCT t
    FROM unnest(regexp_split_to_array(lower(coalesce(p_name,'')), '[^a-z0-9]+')) AS t
    WHERE t <> ''
      AND length(t) > 1
      AND t NOT IN ('the','at','of','and','a','an','on','in','for',
                    'center','centre','theatre','theater','stadium','arena','amphitheatre',
                    'amphitheater','hall','park','field','music','family','live','hotel',
                    'casino','pavilion','coliseum','auditorium','complex','grounds','venue',
                    'club','room','lounge','bowl','dome','forum','plaza','house')
  ) q
$fn$;
COMMENT ON FUNCTION public.venue_name_tokens(text) IS
  'Identity tokens of a venue name: lowercased, split on non-alphanumerics, 1-char and generic venue words dropped. Two names AGREE when their token sets overlap. A plain containment test does not work — "Centre Bell"/"Bell Centre", "Thomas & Mack"/"Thomas and Mack" and "Cellairis Amphitheatre at Lakewood"/"Lakewood Amphitheatre" are all the same venue and all fail containment (390 false positives on the first drift run). D0 mig 20260914230000.';

CREATE TABLE IF NOT EXISTS public.event_catalogue_drift (
  tevo_event_id     bigint      NOT NULL,
  drift_kind        text        NOT NULL,
  tevo_value        text,
  sg_value          text,
  gt_value          text,
  first_detected_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now(),
  resolved_at       timestamptz,
  PRIMARY KEY (tevo_event_id, drift_kind),
  CONSTRAINT event_catalogue_drift_kind_ck CHECK (drift_kind IN ('date','venue','status'))
);
CREATE INDEX IF NOT EXISTS event_catalogue_drift_open_idx
  ON public.event_catalogue_drift (last_seen_at DESC) WHERE resolved_at IS NULL;
COMMENT ON TABLE public.event_catalogue_drift IS
  'What each source says about an event when they disagree: date (>1 day apart), venue (normalised names share nothing), or status (TEvo rescheduled / GoTickets non-active). Filled daily by event_catalogue_drift_scan(); a row resolves itself when the sources agree again. A disagreement here means a downstream date or venue is being chosen by preference order, not by fact. D0 mig 20260914230000.';

REVOKE ALL ON public.event_catalogue_drift FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON public.event_catalogue_drift TO service_role;

CREATE OR REPLACE FUNCTION public.event_catalogue_drift_scan(p_days_ahead integer DEFAULT 400)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_date int := 0; v_venue int := 0; v_status int := 0; v_resolved int := 0; v_queued int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout', '170000', true);

  CREATE TEMP TABLE _cat ON COMMIT DROP AS
  SELECT e.id AS ev,
         e.occurs_at_local::timestamptz AS tevo_dt,
         e.venue_name                   AS tevo_venue,
         e.state                        AS tevo_state,
         sgc.sg_datetime_utc            AS sg_dt,
         sgc.sg_venue_name              AS sg_venue,
         ge.event_time_utc              AS gt_dt,
         ge.venue_name                  AS gt_venue,
         ge.status                      AS gt_status
  FROM public.events e
  LEFT JOIN LATERAL (
    SELECT s2.sg_event_id, s2.sg_datetime_utc, s2.sg_venue_name
    FROM public.sg_events_canonical s2
    WHERE s2.tevo_event_id = e.id
    ORDER BY s2.updated_at DESC NULLS LAST, s2.sg_event_id LIMIT 1) sgc ON true
  LEFT JOIN LATERAL (
    SELECT g2.event_time_utc, g2.venue_name, g2.status
    FROM public.gotickets_event g2
    WHERE g2.tevo_event_id = e.id ORDER BY g2.event_time_utc LIMIT 1) ge ON true
  WHERE e.occurs_at_local IS NOT NULL
    AND e.occurs_at_local::timestamptz >= now()
    AND e.occurs_at_local::timestamptz <  now() + make_interval(days => GREATEST(p_days_ahead,1))
    AND (sgc.sg_event_id IS NOT NULL OR ge.event_time_utc IS NOT NULL);

  -- DATE: more than a day apart from TEvo on either side.
  WITH d AS (
    SELECT ev, tevo_dt::text AS tv, sg_dt::text AS sv, gt_dt::text AS gv
    FROM _cat
    WHERE (sg_dt IS NOT NULL AND abs(extract(epoch FROM (sg_dt - tevo_dt))) > 86400)
       OR (gt_dt IS NOT NULL AND abs(extract(epoch FROM (gt_dt - tevo_dt))) > 86400)),
  up AS (
    INSERT INTO public.event_catalogue_drift (tevo_event_id, drift_kind, tevo_value, sg_value, gt_value)
    SELECT ev, 'date', tv, sv, gv FROM d
    ON CONFLICT (tevo_event_id, drift_kind) DO UPDATE SET
      tevo_value = EXCLUDED.tevo_value, sg_value = EXCLUDED.sg_value, gt_value = EXCLUDED.gt_value,
      last_seen_at = now(), resolved_at = NULL
    RETURNING 1)
  SELECT count(*)::int INTO v_date FROM up;

  -- VENUE: normalised names that share nothing in either direction.
  WITH v AS (
    SELECT ev, tevo_venue AS tv, sg_venue AS sv, gt_venue AS gv,
           public.venue_name_tokens(tevo_venue) AS nt,
           public.venue_name_tokens(sg_venue)   AS ns,
           public.venue_name_tokens(gt_venue)   AS ng
    FROM _cat),
  d AS (
    SELECT ev, tv, sv, gv FROM v
    WHERE array_length(nt,1) IS NOT NULL AND (
        (array_length(ns,1) IS NOT NULL AND NOT (nt && ns))
     OR (array_length(ng,1) IS NOT NULL AND NOT (nt && ng)))),
  up AS (
    INSERT INTO public.event_catalogue_drift (tevo_event_id, drift_kind, tevo_value, sg_value, gt_value)
    SELECT ev, 'venue', tv, sv, gv FROM d
    ON CONFLICT (tevo_event_id, drift_kind) DO UPDATE SET
      tevo_value = EXCLUDED.tevo_value, sg_value = EXCLUDED.sg_value, gt_value = EXCLUDED.gt_value,
      last_seen_at = now(), resolved_at = NULL
    RETURNING 1)
  SELECT count(*)::int INTO v_venue FROM up;

  -- STATUS: TEvo says rescheduled, or GoTickets is not carrying it as active.
  WITH d AS (
    SELECT ev, tevo_state AS tv, NULL::text AS sv, gt_status AS gv
    FROM _cat
    WHERE coalesce(tevo_state,'') = 'rescheduled'
       OR (gt_status IS NOT NULL AND upper(gt_status) IN ('RESCHEDULED','CANCELLED','POSTPONED','MERGED'))),
  up AS (
    INSERT INTO public.event_catalogue_drift (tevo_event_id, drift_kind, tevo_value, sg_value, gt_value)
    SELECT ev, 'status', tv, sv, gv FROM d
    ON CONFLICT (tevo_event_id, drift_kind) DO UPDATE SET
      tevo_value = EXCLUDED.tevo_value, sg_value = EXCLUDED.sg_value, gt_value = EXCLUDED.gt_value,
      last_seen_at = now(), resolved_at = NULL
    RETURNING 1)
  SELECT count(*)::int INTO v_status FROM up;

  -- Anything open that this sweep did NOT re-detect has come back into agreement.
  UPDATE public.event_catalogue_drift SET resolved_at = now()
   WHERE resolved_at IS NULL AND last_seen_at < now() - interval '1 minute'
     AND tevo_event_id IN (SELECT ev FROM _cat);
  GET DIAGNOSTICS v_resolved = ROW_COUNT;

  -- Ask the other sites for their current answer on whatever is still in doubt.
  v_queued := public.event_date_reconcile_queue(200);

  RETURN jsonb_build_object('date_drift', v_date, 'venue_drift', v_venue, 'status_drift', v_status,
                            'resolved', v_resolved, 'sg_repulls_queued', v_queued,
                            'scanned', (SELECT count(*) FROM _cat), 'at', now());
END;
$function$;
COMMENT ON FUNCTION public.event_catalogue_drift_scan(integer) IS
  'Daily catalogue sweep over every upcoming event carried by more than one source: records date drift (>1 day), venue drift (normalised names sharing nothing) and status drift (TEvo rescheduled / GoTickets not active) into event_catalogue_drift, resolves rows that agree again, then queues SeatGeek re-pulls for what is still in doubt. D0 mig 20260914230000.';

REVOKE ALL ON FUNCTION public.event_catalogue_drift_scan(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.event_catalogue_drift_scan(integer) TO service_role;

SELECT cron.schedule('event_catalogue_drift_daily', '38 9 * * *', $cron$
  DO $b$ BEGIN
    IF NOT public.cron_try_lock('event_catalogue_drift') THEN RETURN; END IF;
    BEGIN PERFORM public.event_catalogue_drift_scan(400);
    EXCEPTION WHEN OTHERS THEN RAISE WARNING 'event_catalogue_drift skipped: %', SQLERRM; END;
  END $b$;
$cron$);
