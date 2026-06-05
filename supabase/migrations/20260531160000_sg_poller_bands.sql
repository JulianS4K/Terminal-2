-- ============================================================
-- MIG-D — SG listings+sales pollers go band-driven, rate-aware, strand-safe.
-- A1 2026-05-31 (cadence redesign Part A4).
--
-- Collapses the 3 overlapping SG listings pollers (blindspot/floor/60d) into ONE
-- sg_listings_poll_tick that: picks due events by collector_band('SG','listings',hte),
-- backs off on a fresh low ratelimit-remaining (the floor_sweep pattern), stamps
-- last_FIRED (provisional) — and advances the cadence clock last_polled ONLY on HTTP 200
-- inside sg_broker_listings_process. A -429 leaves last_polled untouched → the event
-- re-qualifies next tick (fixes the 429 waste + the 2,674-event starvation tail).
-- sg_sales_poll_tick retuned to the SG sales bands (keeps the one-shot post-event flush).
-- Blindspot folds into bands automatically: the poller reads tier<>'SKIP' + the band
-- interval, so the TRACK_BLINDSPOT label no longer drives cadence (no classifier change).
-- ============================================================

-- ---------- 1. NEW: single band-driven, rate-aware listings poller ----------
CREATE OR REPLACE FUNCTION public.sg_listings_poll_tick(p_max int DEFAULT 20, p_min_remaining int DEFAULT 3)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  v_token     text := public.get_app_secret('SEATGEEK_API_TOKEN');
  v_remaining int;
  r           RECORD;
  v_req       bigint;
  v_now       timestamptz := clock_timestamp();
  v_count     int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;

  -- Rate-aware backoff: only on a FRESH low reading (~10s window). Stale/none => fire.
  SELECT (h.headers->>'ratelimit-remaining')::int INTO v_remaining
  FROM public.sg_broker_pending p
  JOIN net._http_response h ON h.id = p.request_id
  WHERE h.headers ? 'ratelimit-remaining' AND h.created > v_now - interval '10 seconds'
  ORDER BY h.id DESC LIMIT 1;
  IF v_remaining IS NOT NULL AND v_remaining < p_min_remaining THEN RETURN 0; END IF;

  FOR r IN
    SELECT s.sg_event_id
    FROM public.sg_event_priority_state s
    JOIN LATERAL public.collector_band('SG','listings',
           EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0) c ON true
    WHERE s.tier <> 'SKIP'
      AND s.sg_datetime_utc > v_now - interval '6 hours'
      AND ( s.last_polled_listings_at IS NULL
            OR s.last_polled_listings_at < v_now - make_interval(mins => c.required_min) )
      AND ( s.last_fired_listings_at IS NULL
            OR s.last_fired_listings_at < v_now - interval '90 seconds' )   -- don't re-fire a pending request
    ORDER BY s.last_polled_listings_at ASC NULLS FIRST, s.sg_event_id
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/listings?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'listings', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_fired_listings_at = v_now, listings_polls_today = listings_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_count := v_count + 1;
  END LOOP;
  RETURN v_count;
END $function$;
REVOKE ALL ON FUNCTION public.sg_listings_poll_tick(int,int) FROM anon, PUBLIC;

-- ---------- 2. MODIFY: drain advances the cadence clock only on HTTP 200 ----------
CREATE OR REPLACE FUNCTION public.sg_broker_listings_process(p_limit integer DEFAULT 50)
RETURNS TABLE(processed integer, listings_persisted integer)
LANGUAGE plpgsql SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE r RECORD; v_processed int := 0; v_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, p.sg_event_id,
           h.status_code, h.content::jsonb AS body,
           a.aq_short_event_id, x.tevo_event_id
    FROM public.sg_broker_pending p
    JOIN net._http_response h ON h.id = p.request_id
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = p.sg_event_id
    LEFT JOIN public.seatgeek_event_xref x ON x.sg_event_id = p.sg_event_id
    WHERE p.scope = 'listings' AND p.resolved_at IS NULL
    ORDER BY p.fired_at
    LIMIT p_limit
  LOOP
    v_processed := v_processed + 1;
    v_inserted := NULL;
    IF r.status_code = 200 AND jsonb_typeof(r.body->'listings') = 'array' THEN
      WITH src AS (SELECT l FROM jsonb_array_elements(r.body->'listings') AS l),
      ins AS (
        INSERT INTO public.seatgeek_listings_snapshots (
          tevo_event_id, sg_event_id, captured_at,
          sglid, display_id, retail_price_all_in, broadcast_price,
          deal_quality_score, quantity, splits, section, row,
          is_broker_owned, is_b2b, is_instant_download, is_sro,
          has_limited_view, is_wheelchair_acc, ada_details,
          delivery_method, in_hand_date, market_source, stock_type,
          seller_notes, endpoint, content_hash, raw, aq_short_event_id
        )
        SELECT r.tevo_event_id, r.sg_event_id, now(),
          NULLIF(l->>'sglid','')::bigint, l->>'id',
          NULLIF(l->>'pf','')::numeric, NULLIF(l->>'bp','')::numeric,
          NULLIF(l->>'ds','')::numeric, NULLIF(l->>'q','')::int,
          l->'sp', l->>'s', l->>'r',
          NULLIF(l->>'bo','')::boolean, NULLIF(l->>'is_b2b','')::boolean,
          NULLIF(l->>'idl','')::boolean, NULLIF(l->>'sro','')::boolean,
          NULLIF(l->>'lv','')::boolean, NULLIF(l->>'wa','')::boolean,
          l->>'ada', l->>'dm', NULLIF(l->>'ihd','')::date,
          l->>'m', l->>'st', l->>'pn',
          '/listings',
          md5(r.sg_event_id::text || ':' || (l->>'id') || ':' || (l->>'bp') || ':' || (l->>'q')),
          l, r.aq_short_event_id
        FROM src WHERE l->>'id' IS NOT NULL
        ON CONFLICT DO NOTHING
        RETURNING 1
      ) SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + COALESCE(v_inserted, 0);
    END IF;

    UPDATE public.sg_broker_pending
      SET resolved_at = now(),
          rows_persisted = CASE
            WHEN r.status_code = 200 THEN COALESCE(v_inserted, 0)
            WHEN r.status_code = 429 THEN -429
            ELSE -1 END
      WHERE id = r.pending_id;

    -- A1 2026-05-31: advance the cadence clock ONLY on success (strand-safe).
    IF r.status_code = 200 THEN
      UPDATE public.sg_event_priority_state
        SET last_polled_listings_at = now()
        WHERE sg_event_id = r.sg_event_id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END $function$;

-- ---------- 3. RETUNE: sales poller to the SG sales bands (keep post-event one-shot) ----------
CREATE OR REPLACE FUNCTION public.sg_sales_poll_tick(p_max int DEFAULT 50)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE r RECORD; v_req bigint; v_now timestamptz := clock_timestamp();
  v_token text := public.get_app_secret('SEATGEEK_API_TOKEN'); v_polled int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'sg_sales_poll_tick: caller % not authorized', current_user; END IF;
  IF v_token IS NULL OR v_token = '' THEN RETURN 0; END IF;
  IF p_max <= 0 THEN RETURN 0; END IF;

  FOR r IN
    WITH elig AS (
      SELECT s.sg_event_id, s.sg_datetime_utc, s.last_polled_sales_at,
             EXTRACT(epoch FROM (s.sg_datetime_utc - v_now))/3600.0 AS hte
      FROM public.sg_event_priority_state s
      WHERE s.sg_datetime_utc > v_now - interval '24 hours'
        AND s.sg_datetime_utc <= v_now + interval '1440 hours'
        AND s.tier <> 'SKIP'
    )
    SELECT e.sg_event_id
    FROM elig e
    CROSS JOIN LATERAL public.collector_band('SG','sales', greatest(e.hte, 0)) c
    WHERE ( e.hte < -2 AND (e.last_polled_sales_at IS NULL OR e.last_polled_sales_at < e.sg_datetime_utc) )  -- post-event one-shot
       OR ( e.hte >= -2 AND (e.last_polled_sales_at IS NULL
                             OR e.last_polled_sales_at < v_now - make_interval(mins => c.required_min)) )
    ORDER BY (e.hte < -2) DESC, e.last_polled_sales_at NULLS FIRST, e.sg_event_id
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url := 'https://brokerdata.seatgeek.com/sales?token=' || v_token || '&event_id=' || r.sg_event_id::text,
      timeout_milliseconds := 30000
    ) INTO v_req;
    INSERT INTO public.sg_broker_pending(sg_event_id, scope, request_id, fired_at)
      VALUES (r.sg_event_id, 'sales', v_req, v_now);
    UPDATE public.sg_event_priority_state
      SET last_polled_sales_at = v_now, sales_polls_today = sales_polls_today + 1
      WHERE sg_event_id = r.sg_event_id;
    v_polled := v_polled + 1;
  END LOOP;
  RETURN v_polled;
END $function$;
REVOKE ALL ON FUNCTION public.sg_sales_poll_tick(int) FROM anon, PUBLIC;
