-- Migration 20260914222154 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "sg_canonical_pick_deterministic" (version 20260914222154) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.

DO $do$
DECLARE
  v_def text; v_args text; v_cnt int;
  v_old text := $a$LEFT JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = e.id$a$;
  v_new text := $b$LEFT JOIN LATERAL (
      SELECT s2.sg_event_name, s2.sg_datetime_utc
      FROM public.sg_events_canonical s2
      WHERE s2.tevo_event_id = e.id
      ORDER BY s2.updated_at DESC NULLS LAST, s2.sg_event_id
      LIMIT 1) sgc ON true$b$;
BEGIN
  SELECT p.prosrc, pg_get_function_arguments(p.oid) INTO v_def, v_args
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='scan_listing_deals';
  IF v_def IS NULL THEN RAISE EXCEPTION 'scan_listing_deals not found'; END IF;

  v_cnt := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'sgc join matched % times (expected exactly 1) — refusing to replace scanner', v_cnt;
  END IF;

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION public.scan_listing_deals(%s) RETURNS jsonb LANGUAGE plpgsql '
    || 'SECURITY DEFINER SET search_path TO ''public'', ''extensions'', ''pg_temp'' AS %L',
    v_args, replace(v_def, v_old, v_new));
END
$do$;

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

  -- BOTH cross-source joins are LATERAL/LIMIT 1: 444 TEvo events carry more than one
  -- sg_events_canonical row and some carry two gotickets_event rows, so a plain join yields
  -- several rows per event and the ON CONFLICT upsert below dies with "cannot affect row a
  -- second time" (mig 20260914230000 — hit on the first run).
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

  WITH v AS (
    SELECT ev, tevo_venue AS tv, sg_venue AS sv, gt_venue AS gv,
           lower(regexp_replace(coalesce(tevo_venue,''), '[^a-zA-Z0-9]', '', 'g')) AS nt,
           lower(regexp_replace(coalesce(sg_venue,''),   '[^a-zA-Z0-9]', '', 'g')) AS ns,
           lower(regexp_replace(coalesce(gt_venue,''),   '[^a-zA-Z0-9]', '', 'g')) AS ng
    FROM _cat),
  d AS (
    SELECT ev, tv, sv, gv FROM v
    WHERE nt <> '' AND (
        (ns <> '' AND position(nt in ns) = 0 AND position(ns in nt) = 0)
     OR (ng <> '' AND position(nt in ng) = 0 AND position(ng in nt) = 0))),
  up AS (
    INSERT INTO public.event_catalogue_drift (tevo_event_id, drift_kind, tevo_value, sg_value, gt_value)
    SELECT ev, 'venue', tv, sv, gv FROM d
    ON CONFLICT (tevo_event_id, drift_kind) DO UPDATE SET
      tevo_value = EXCLUDED.tevo_value, sg_value = EXCLUDED.sg_value, gt_value = EXCLUDED.gt_value,
      last_seen_at = now(), resolved_at = NULL
    RETURNING 1)
  SELECT count(*)::int INTO v_venue FROM up;

  WITH d AS (
    SELECT ev, tevo_state AS tv, NULL::text AS sv, gt_status AS gv
    FROM _cat
    WHERE coalesce(tevo_state,'') = 'rescheduled'
       OR (gt_status IS NOT NULL AND lower(gt_status) NOT IN ('active','onsale','on_sale'))),
  up AS (
    INSERT INTO public.event_catalogue_drift (tevo_event_id, drift_kind, tevo_value, sg_value, gt_value)
    SELECT ev, 'status', tv, sv, gv FROM d
    ON CONFLICT (tevo_event_id, drift_kind) DO UPDATE SET
      tevo_value = EXCLUDED.tevo_value, sg_value = EXCLUDED.sg_value, gt_value = EXCLUDED.gt_value,
      last_seen_at = now(), resolved_at = NULL
    RETURNING 1)
  SELECT count(*)::int INTO v_status FROM up;

  UPDATE public.event_catalogue_drift SET resolved_at = now()
   WHERE resolved_at IS NULL AND last_seen_at < now() - interval '1 minute'
     AND tevo_event_id IN (SELECT ev FROM _cat);
  GET DIAGNOSTICS v_resolved = ROW_COUNT;

  v_queued := public.event_date_reconcile_queue(200);

  RETURN jsonb_build_object('date_drift', v_date, 'venue_drift', v_venue, 'status_drift', v_status,
                            'resolved', v_resolved, 'sg_repulls_queued', v_queued,
                            'scanned', (SELECT count(*) FROM _cat), 'at', now());
END;
$function$;
;
