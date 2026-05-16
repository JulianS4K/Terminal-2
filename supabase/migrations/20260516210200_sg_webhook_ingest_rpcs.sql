-- Migration 20260516210200 · lane:A1 (D2-authored) · writes:7 sg_seller_*_ingest() RPCs · reads:seatgeek_orders,sg_seller_* tables · pre:20260516210100 · auth:operator-permitted 2026-05-16
-- WS2 part 3/3: per-notification-type ingest RPCs called by the SG SellerDirect
-- webhook edge function. Each takes a jsonb array (`data` field of the
-- envelope) plus the metadata.seller_id, and UPSERTs into the appropriate
-- table. All return (inserted, updated, skipped) for telemetry.
-- All SECURITY DEFINER, service_role-gated, callable only by edge function.

-- ============================================================
-- 1. sg_seller_orders_ingest_from_webhook — order.created → seatgeek_orders
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_seller_orders_ingest_from_webhook(
  p_orders    jsonb,
  p_seller_id bigint DEFAULT NULL
) RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_total int; v_inserted int := 0; v_updated int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_seller_orders_ingest_from_webhook: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_orders) <> 'array' THEN
    RAISE EXCEPTION 'p_orders must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_orders);
  IF v_total = 0 THEN RETURN QUERY SELECT 0, 0, 0; RETURN; END IF;

  WITH src AS (SELECT o FROM jsonb_array_elements(p_orders) AS o),
  upserted AS (
    INSERT INTO public.seatgeek_orders (
      sg_order_id, status, created_at_sg,
      delivery, delivery_method, stock_type, fulfillment_issue_message,
      pickup_email, pickup_phone, pickup_availability, pickup_location, pickup_instructions,
      sg_event_id, sg_event_name, sg_venue, sg_event_date, sg_event_time,
      sg_listing_id, sale_price, sale_row, sale_section, sale_quantity,
      payment_total, payment_price, payment_fees,
      pulled_at, last_status_at, raw
    )
    SELECT
      (o->>'id')::text,
      COALESCE(o->>'status', 'unknown'),
      NULLIF(o->>'created','')::timestamptz,
      o->>'delivery',
      o->>'delivery_method',
      o->>'stock_type',
      o->>'fulfillment_issue_message',
      o->>'pickup_email',
      o->>'pickup_phone',
      o->>'pickup_availability',
      o->>'pickup_location',
      o->>'pickup_instructions',
      NULLIF(o->'event'->>'seatgeek_event_id','')::bigint,
      o->'event'->>'name',
      o->'event'->>'venue',
      NULLIF(o->'event'->>'date','')::date,
      o->'event'->>'time',
      o->'listing'->>'id',
      NULLIF(o->'listing'->>'price','')::numeric,
      o->'listing'->>'row',
      o->'listing'->>'section',
      NULLIF(o->'listing'->>'quantity','')::int,
      NULLIF(o->>'total','')::numeric,
      NULLIF(o->>'subtotal','')::numeric,
      NULLIF(o->>'fees','')::numeric,
      now(), now(), o
    FROM src
    WHERE (o->>'id') IS NOT NULL
    ON CONFLICT (sg_order_id) DO UPDATE SET
      status                    = EXCLUDED.status,
      delivery                  = COALESCE(EXCLUDED.delivery, public.seatgeek_orders.delivery),
      delivery_method           = COALESCE(EXCLUDED.delivery_method, public.seatgeek_orders.delivery_method),
      stock_type                = COALESCE(EXCLUDED.stock_type, public.seatgeek_orders.stock_type),
      fulfillment_issue_message = EXCLUDED.fulfillment_issue_message,
      pickup_email              = EXCLUDED.pickup_email,
      pickup_phone              = EXCLUDED.pickup_phone,
      pickup_availability       = EXCLUDED.pickup_availability,
      pickup_location           = EXCLUDED.pickup_location,
      pickup_instructions       = EXCLUDED.pickup_instructions,
      sg_event_name             = COALESCE(EXCLUDED.sg_event_name, public.seatgeek_orders.sg_event_name),
      sg_venue                  = COALESCE(EXCLUDED.sg_venue, public.seatgeek_orders.sg_venue),
      sale_price                = COALESCE(EXCLUDED.sale_price, public.seatgeek_orders.sale_price),
      sale_row                  = COALESCE(EXCLUDED.sale_row, public.seatgeek_orders.sale_row),
      sale_section              = COALESCE(EXCLUDED.sale_section, public.seatgeek_orders.sale_section),
      sale_quantity             = COALESCE(EXCLUDED.sale_quantity, public.seatgeek_orders.sale_quantity),
      payment_total             = COALESCE(EXCLUDED.payment_total, public.seatgeek_orders.payment_total),
      payment_price             = COALESCE(EXCLUDED.payment_price, public.seatgeek_orders.payment_price),
      payment_fees              = COALESCE(EXCLUDED.payment_fees, public.seatgeek_orders.payment_fees),
      last_status_at            = now(),
      raw                       = EXCLUDED.raw
    RETURNING (xmax = 0) AS is_new
  )
  SELECT count(*) FILTER (WHERE is_new)::int,
         count(*) FILTER (WHERE NOT is_new)::int
    INTO v_inserted, v_updated
  FROM upserted;

  RETURN QUERY SELECT v_inserted, v_updated, (v_total - v_inserted - v_updated);
END $$;

REVOKE ALL ON FUNCTION public.sg_seller_orders_ingest_from_webhook(jsonb, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_seller_orders_ingest_from_webhook(jsonb, bigint) TO service_role;


-- ============================================================
-- 2. sg_seller_order_retransfers_ingest
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_seller_order_retransfers_ingest(
  p_events          jsonb,
  p_seller_id       bigint DEFAULT NULL,
  p_notification_id uuid   DEFAULT NULL
) RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_total int; v_inserted int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_seller_order_retransfers_ingest: caller % not authorized', current_user;
  END IF;
  IF jsonb_typeof(p_events) <> 'array' THEN
    RAISE EXCEPTION 'p_events must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_events);
  IF v_total = 0 OR p_notification_id IS NULL THEN RETURN QUERY SELECT 0, 0, v_total; RETURN; END IF;

  WITH src AS (SELECT e FROM jsonb_array_elements(p_events) AS e),
  ins AS (
    INSERT INTO public.sg_seller_order_retransfers (
      notification_id, seller_id, seller_order_id,
      buyer_email, buyer_first_name, buyer_last_name, buyer_phone, raw
    )
    SELECT p_notification_id, p_seller_id,
           e->>'seller_order_id',
           e->>'buyer_email',
           e->>'buyer_first_name',
           e->>'buyer_last_name',
           e->>'buyer_phone',
           e
    FROM src
    WHERE (e->>'seller_order_id') IS NOT NULL
    ON CONFLICT (seller_order_id, notification_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::int INTO v_inserted FROM ins;
  RETURN QUERY SELECT v_inserted, 0, (v_total - v_inserted);
END $$;

REVOKE ALL ON FUNCTION public.sg_seller_order_retransfers_ingest(jsonb, bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_seller_order_retransfers_ingest(jsonb, bigint, uuid) TO service_role;


-- ============================================================
-- 3. sg_seller_order_fulfillment_errors_ingest
--    Per SG spec, this notification has a SINGLE-OBJECT data field (not an
--    array — see "data": {...} vs "data": [...] in the docs example). We
--    still accept jsonb to be defensive; if it's an array we take element 0.
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_seller_order_fulfillment_errors_ingest(
  p_events          jsonb,
  p_seller_id       bigint DEFAULT NULL,
  p_notification_id uuid   DEFAULT NULL
) RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_inserted int := 0;
  v_event jsonb;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_seller_order_fulfillment_errors_ingest: caller % not authorized', current_user;
  END IF;
  IF p_notification_id IS NULL THEN RETURN QUERY SELECT 0, 0, 1; RETURN; END IF;
  -- Normalize: SG sends object-shape; if wrapped in an array take first elem.
  IF jsonb_typeof(p_events) = 'array' THEN
    v_event := p_events->0;
  ELSIF jsonb_typeof(p_events) = 'object' THEN
    v_event := p_events;
  ELSE
    RETURN QUERY SELECT 0, 0, 1; RETURN;
  END IF;

  INSERT INTO public.sg_seller_order_fulfillment_errors (
    notification_id, seller_id,
    external_order_id, sd_order_id, sg_event_id,
    event_name, event_date, event_venue,
    delivery_method, stock_type, section, row,
    issue_code, issue_message, issue_developer_msg, tokens, raw
  )
  VALUES (
    p_notification_id, p_seller_id,
    v_event->'order'->>'order_id',
    v_event->'order'->>'sd_order_id',
    NULLIF(v_event->'event'->>'seatgeek_event_id','')::bigint,
    v_event->'event'->>'name',
    v_event->'event'->>'date',
    v_event->'event'->>'venue',
    v_event->'order'->>'delivery_method',
    v_event->'order'->>'stock_type',
    v_event->'order'->>'section',
    v_event->'order'->>'row',
    v_event->'order_issue'->>'code',
    v_event->'order_issue'->>'message',
    v_event->'order_issue'->>'developer_message',
    v_event->'tokens',
    v_event
  )
  ON CONFLICT (notification_id) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN QUERY SELECT v_inserted, 0, (1 - v_inserted);
END $$;

REVOKE ALL ON FUNCTION public.sg_seller_order_fulfillment_errors_ingest(jsonb, bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_seller_order_fulfillment_errors_ingest(jsonb, bigint, uuid) TO service_role;


-- ============================================================
-- 4. sg_seller_listing_inactive_events_ingest
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_seller_listing_inactive_events_ingest(
  p_events          jsonb,
  p_seller_id       bigint DEFAULT NULL,
  p_notification_id uuid   DEFAULT NULL
) RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_total int; v_inserted int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_seller_listing_inactive_events_ingest: caller % not authorized', current_user;
  END IF;
  IF jsonb_typeof(p_events) <> 'array' THEN
    RAISE EXCEPTION 'p_events must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_events);
  IF v_total = 0 OR p_notification_id IS NULL THEN RETURN QUERY SELECT 0, 0, v_total; RETURN; END IF;

  WITH src AS (SELECT e FROM jsonb_array_elements(p_events) AS e),
  ins AS (
    INSERT INTO public.sg_seller_listing_inactive_events (
      notification_id, seller_id,
      sg_listing_id, seller_listing_id,
      event_id, event_name, event_datetime, reason, raw
    )
    SELECT p_notification_id, p_seller_id,
           (e->>'sg_listing_id')::bigint,
           e->>'seller_listing_id',
           (e->>'event_id')::bigint,
           e->>'event_name',
           NULLIF(e->>'event_datetime','')::timestamptz,
           e->>'reason',
           e
    FROM src
    WHERE (e->>'sg_listing_id') IS NOT NULL AND (e->>'event_id') IS NOT NULL
    ON CONFLICT (sg_listing_id, notification_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::int INTO v_inserted FROM ins;
  RETURN QUERY SELECT v_inserted, 0, (v_total - v_inserted);
END $$;

REVOKE ALL ON FUNCTION public.sg_seller_listing_inactive_events_ingest(jsonb, bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_seller_listing_inactive_events_ingest(jsonb, bigint, uuid) TO service_role;


-- ============================================================
-- 5. sg_seller_listing_visibility_ingest
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_seller_listing_visibility_ingest(
  p_events          jsonb,
  p_seller_id       bigint DEFAULT NULL,
  p_notification_id uuid   DEFAULT NULL
) RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_total int; v_inserted int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_seller_listing_visibility_ingest: caller % not authorized', current_user;
  END IF;
  IF jsonb_typeof(p_events) <> 'array' THEN
    RAISE EXCEPTION 'p_events must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_events);
  IF v_total = 0 OR p_notification_id IS NULL THEN RETURN QUERY SELECT 0, 0, v_total; RETURN; END IF;

  WITH src AS (SELECT e FROM jsonb_array_elements(p_events) AS e),
  ins AS (
    INSERT INTO public.sg_seller_listing_visibility (
      notification_id, seller_id,
      seller_listing_id, event_id,
      hidden_reason_code, hidden_reason_description, raw
    )
    SELECT p_notification_id, p_seller_id,
           e->>'seller_listing_id',
           (e->>'event_id')::bigint,
           e->>'hidden_reason_code',
           e->>'hidden_reason_description',
           e
    FROM src
    WHERE (e->>'seller_listing_id') IS NOT NULL AND (e->>'event_id') IS NOT NULL
    ON CONFLICT (seller_listing_id, event_id, notification_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::int INTO v_inserted FROM ins;
  RETURN QUERY SELECT v_inserted, 0, (v_total - v_inserted);
END $$;

REVOKE ALL ON FUNCTION public.sg_seller_listing_visibility_ingest(jsonb, bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_seller_listing_visibility_ingest(jsonb, bigint, uuid) TO service_role;


-- ============================================================
-- 6. sg_seller_listing_normalization_ingest
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_seller_listing_normalization_ingest(
  p_events          jsonb,
  p_seller_id       bigint DEFAULT NULL,
  p_notification_id uuid   DEFAULT NULL
) RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_total int; v_inserted int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_seller_listing_normalization_ingest: caller % not authorized', current_user;
  END IF;
  IF jsonb_typeof(p_events) <> 'array' THEN
    RAISE EXCEPTION 'p_events must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_events);
  IF v_total = 0 OR p_notification_id IS NULL THEN RETURN QUERY SELECT 0, 0, v_total; RETURN; END IF;

  WITH src AS (SELECT e FROM jsonb_array_elements(p_events) AS e),
  ins AS (
    INSERT INTO public.sg_seller_listing_normalization (
      notification_id, seller_id,
      sg_listing_id, seller_listing_id,
      event_id, venue_id, map_config_id,
      section_raw, row_raw, section_normalized, row_normalized,
      mapkey, normalized, row_warning, seatgeek_notes, visible_on_map, raw
    )
    SELECT p_notification_id, p_seller_id,
           (e->>'sg_listing_id')::bigint,
           e->>'seller_listing_id',
           NULLIF(e->>'event_id','')::bigint,
           NULLIF(e->>'venue_id','')::bigint,
           NULLIF(e->>'map_config_id','')::int,
           e->>'section_raw',
           e->>'row_raw',
           e->>'section_normalized',
           e->>'row_normalized',
           e->>'mapkey',
           NULLIF(e->>'normalized','')::boolean,
           e->>'row_warning',
           e->>'seatgeek_notes',
           NULLIF(e->>'visible_on_map','')::boolean,
           e
    FROM src
    WHERE (e->>'sg_listing_id') IS NOT NULL
    ON CONFLICT (sg_listing_id, notification_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::int INTO v_inserted FROM ins;
  RETURN QUERY SELECT v_inserted, 0, (v_total - v_inserted);
END $$;

REVOKE ALL ON FUNCTION public.sg_seller_listing_normalization_ingest(jsonb, bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_seller_listing_normalization_ingest(jsonb, bigint, uuid) TO service_role;


-- ============================================================
-- 7. sg_seller_listing_normalization_changes_ingest
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_seller_listing_normalization_changes_ingest(
  p_events          jsonb,
  p_seller_id       bigint DEFAULT NULL,
  p_notification_id uuid   DEFAULT NULL
) RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_total int; v_inserted int := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'sg_seller_listing_normalization_changes_ingest: caller % not authorized', current_user;
  END IF;
  IF jsonb_typeof(p_events) <> 'array' THEN
    RAISE EXCEPTION 'p_events must be a JSON array' USING ERRCODE = '22P02';
  END IF;
  v_total := jsonb_array_length(p_events);
  IF v_total = 0 OR p_notification_id IS NULL THEN RETURN QUERY SELECT 0, 0, v_total; RETURN; END IF;

  WITH src AS (SELECT e FROM jsonb_array_elements(p_events) AS e),
  ins AS (
    INSERT INTO public.sg_seller_listing_normalization_changes (
      notification_id, seller_id,
      sg_listing_id, seller_listing_id,
      event_id, venue_id, map_config_id,
      previous_normalized, previous_row_warning,
      normalized, row_warning, seatgeek_notes, change_source, raw
    )
    SELECT p_notification_id, p_seller_id,
           (e->>'sg_listing_id')::bigint,
           e->>'seller_listing_id',
           NULLIF(e->>'event_id','')::bigint,
           NULLIF(e->>'venue_id','')::bigint,
           NULLIF(e->>'map_config_id','')::int,
           NULLIF(e->>'previous_normalized','')::boolean,
           e->>'previous_row_warning',
           NULLIF(e->>'normalized','')::boolean,
           e->>'row_warning',
           e->>'seatgeek_notes',
           e->>'change_source',
           e
    FROM src
    WHERE (e->>'sg_listing_id') IS NOT NULL
    ON CONFLICT (sg_listing_id, notification_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::int INTO v_inserted FROM ins;
  RETURN QUERY SELECT v_inserted, 0, (v_total - v_inserted);
END $$;

REVOKE ALL ON FUNCTION public.sg_seller_listing_normalization_changes_ingest(jsonb, bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sg_seller_listing_normalization_changes_ingest(jsonb, bigint, uuid) TO service_role;
