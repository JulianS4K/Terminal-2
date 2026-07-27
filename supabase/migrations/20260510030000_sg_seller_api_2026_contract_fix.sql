-- ============================================================================
-- Migration 20260510030000 — SeatGeek seller-direct API 2026-05 contract fix
--
-- Caught by the live data quality dashboard (terminal-2-dashboard.web.app)
-- showing "SG seller orders" 22+ hours stale despite the cron firing every
-- 30 min with zero failures. Investigation: cron fires HTTP, but SeatGeek
-- now returns 400 / silent-empty. Three breaking changes:
--
--   1. /listings  → "Bad value for argument page is deprecated, use page_cursor"
--   2. /orders    → "Status is required" (param renamed `statuses` → `status`)
--   3. Listings response shape FLATTENED:
--        legacy:   { id, ticket_id, event: { id, name, venue, date, time }, ... }
--        2026-05:  { seller_listing_id, ticket_id, event_id, event, venue,
--                    event_date, event_time, ... }
--      Old process function used (l->>'id') which is now NULL on every row;
--      the WHERE NOT NULL filter dropped all 500 items per page.
--
-- Phase 2 (deferred): full cursor-chain pagination so we can walk all
-- 153,584 listings instead of just the first page.
-- ============================================================================

-- ============================================================================
-- (1) Queue: drop deprecated `page=` param, rename `statuses` → `status`
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sg_seller_listings_queue(p_pages integer DEFAULT 1)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  v_req_id bigint;
BEGIN
  -- p_pages retained for ABI compat with cron job command but ignored —
  -- cursor pagination needs serial chaining (next_cursor from response N
  -- → request N+1) which our stateless loop can't do. One cursor-less
  -- page per tick. Phase 2 = state-machine cursor walk.
  PERFORM p_pages;
  SELECT net.http_get(
    url := 'https://sellerdirect-api.seatgeek.com/listings?per_page=500&token=' || v_token,
    timeout_milliseconds := 30000
  ) INTO v_req_id;
  INSERT INTO sg_seller_pending(request_id, scope, page, per_page)
  VALUES (v_req_id, 'listings', 1, 500);
  RETURN 1;
END $$;

COMMENT ON FUNCTION public.sg_seller_listings_queue(integer) IS
  'SeatGeek deprecated offset pagination 2026-05; we now fetch a single '
  'cursor-less page (per_page=500). Full cursor chain pending phase 2.';

CREATE OR REPLACE FUNCTION public.sg_seller_orders_queue(
  p_pages integer DEFAULT 1,
  p_statuses text DEFAULT 'open,pending,confirmed,fulfilled'
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  v_req_id bigint;
BEGIN
  PERFORM p_pages;
  SELECT net.http_get(
    -- 2026-05: param renamed `statuses` → `status` (singular)
    url := 'https://sellerdirect-api.seatgeek.com/orders?per_page=200&status=' ||
           replace(p_statuses, ',', '%2C') ||
           '&token=' || v_token,
    timeout_milliseconds := 30000
  ) INTO v_req_id;
  INSERT INTO sg_seller_pending(request_id, scope, page, per_page, status_csv)
  VALUES (v_req_id, 'orders', 1, 200, p_statuses);
  RETURN 1;
END $$;

COMMENT ON FUNCTION public.sg_seller_orders_queue(integer, text) IS
  'SeatGeek 2026-05: status (singular, was statuses) + offset pagination '
  'deprecated. Single cursor-less page per tick. Phase 2 = cursor chain.';

-- ============================================================================
-- (2) Process: handle the flattened response shape
-- ============================================================================

CREATE OR REPLACE FUNCTION public.sg_seller_process()
RETURNS TABLE(processed integer, orders_persisted integer, listings_persisted integer)
LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_body jsonb; v_arr jsonb;
  v_processed int := 0; v_orders int := 0; v_listings int := 0; v_count int;
BEGIN
  FOR r IN
    SELECT p.id, p.scope, p.request_id, h.content, h.status_code
    FROM sg_seller_pending p JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;

      IF r.scope = 'orders' THEN
        v_arr := COALESCE(v_body->'orders', '[]'::jsonb);
        WITH src AS (SELECT o FROM jsonb_array_elements(v_arr) AS o),
        ins AS (
          INSERT INTO seatgeek_orders (
            sg_order_id, status, created_at_sg, delivery, delivery_method, stock_type,
            sg_event_id, sg_event_name, sg_venue, sg_event_date, sg_event_time,
            sg_listing_id, sale_price, sale_row, sale_section, sale_quantity,
            payment_total, payment_price, payment_fees, payment_tax, payment_delivery,
            pulled_at, last_status_at, raw
          )
          SELECT
            -- Try new flat shape first; fall back to legacy nested for forward compat
            COALESCE(o->>'order_id', o->>'id', o->>'sg_order_id'),
            o->>'status',
            NULLIF(o->>'created_at','')::timestamptz,
            o->>'delivery', o->>'delivery_method', o->>'stock_type',
            NULLIF(COALESCE(o->>'event_id', o->'event'->>'id'),'')::bigint,
            COALESCE(o->>'event', o->'event'->>'name'),
            COALESCE(o->>'venue', o->'event'->>'venue'),
            NULLIF(COALESCE(o->>'event_date', o->'event'->>'date'),'')::date,
            COALESCE(o->>'event_time', o->'event'->>'time'),
            o->>'listing_id',
            NULLIF(o->>'sale_price','')::numeric,
            o->>'sale_row', o->>'sale_section',
            NULLIF(o->>'sale_quantity','')::int,
            NULLIF(o->'payment'->>'total','')::numeric,
            NULLIF(o->'payment'->>'price','')::numeric,
            NULLIF(o->'payment'->>'fees','')::numeric,
            NULLIF(o->'payment'->>'tax','')::numeric,
            NULLIF(o->'payment'->>'delivery','')::numeric,
            now(), now(), o
          FROM src
          WHERE COALESCE(o->>'order_id', o->>'id', o->>'sg_order_id') IS NOT NULL
          ON CONFLICT (sg_order_id) DO UPDATE SET
            status = EXCLUDED.status, delivery = EXCLUDED.delivery,
            sale_price = EXCLUDED.sale_price, sale_quantity = EXCLUDED.sale_quantity,
            payment_total = EXCLUDED.payment_total, last_status_at = now(),
            pulled_at = now(), raw = EXCLUDED.raw
          RETURNING 1
        )
        SELECT count(*) INTO v_count FROM ins;
        v_orders := v_orders + v_count;

      ELSIF r.scope = 'listings' THEN
        v_arr := COALESCE(v_body->'listings', '[]'::jsonb);
        WITH src AS (SELECT l FROM jsonb_array_elements(v_arr) AS l),
        ins AS (
          INSERT INTO seatgeek_seller_listings (
            seller_listing_id, ticket_id, sg_listing_id,
            sg_event_id, sg_event_name, sg_venue, sg_event_date, sg_event_time,
            quantity, section, row, seat_from, seat_thru, notes,
            cost, is_edelivery, is_instant, in_hand_date,
            content_hash, pulled_at, raw
          )
          SELECT
            -- 2026-05: id → seller_listing_id at top level
            COALESCE(l->>'seller_listing_id', l->>'id'),
            l->>'ticket_id',
            NULLIF(l->>'sg_listing_id','')::bigint,
            -- Event fields flattened from event.* nested object
            NULLIF(COALESCE(l->>'event_id', l->'event'->>'id'),'')::bigint,
            COALESCE(l->>'event', l->'event'->>'name'),
            COALESCE(l->>'venue', l->'event'->>'venue'),
            NULLIF(COALESCE(l->>'event_date', l->'event'->>'date'),'')::date,
            COALESCE(l->>'event_time', l->'event'->>'time'),
            (l->>'quantity')::int, l->>'section', l->>'row',
            l->>'seat_from', l->>'seat_thru', l->>'notes',
            NULLIF(l->>'cost','')::numeric,
            (l->>'is_edelivery')::bool, (l->>'is_instant')::bool,
            NULLIF(l->>'in_hand_date','')::date,
            encode(digest(
              coalesce(l->>'seller_listing_id', l->>'id','') || '|' ||
              coalesce(l->>'ticket_id','') || '|' ||
              coalesce(l->>'cost','') || '|' || coalesce(l->>'quantity',''),
              'sha256'), 'hex'),
            now(), l
          FROM src
          WHERE COALESCE(l->>'seller_listing_id', l->>'id') IS NOT NULL
          RETURNING 1
        )
        SELECT count(*) INTO v_count FROM ins;
        v_listings := v_listings + v_count;
      END IF;

      UPDATE sg_seller_pending SET resolved_at = now(),
        rows_persisted = (CASE WHEN r.scope='orders' THEN v_orders ELSE v_listings END)
        WHERE id = r.id;
    ELSE
      UPDATE sg_seller_pending SET resolved_at = now(), rows_persisted = -1 WHERE id = r.id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_orders, v_listings;
END $$;
