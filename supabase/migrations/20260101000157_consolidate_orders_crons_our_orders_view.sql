-- ============================================================================
-- Migration 20260509290000 — Architecture: Supabase = backend, Railway = frontend
--
-- Acts on three product directives:
--
-- 1. We only have access to OUR OWN SG sales (sellerdirect /orders), not
--    market-wide /sales. Drop the broker /sales cron + tables (built in
--    20260509280000 in error). Move SG-our-sales pull to server-side at
--    same 30-min cadence as EVO orders.
--
-- 2. Railway is now treated as frontend-only. Migrate the last Railway-
--    bound data cron (seatgeek-seller-collect-10min) to plpgsql + pg_net
--    so the data pipeline runs entirely on Supabase.
--
-- 3. Add `our_orders` view (UNION evo_orders + seatgeek_orders only) for
--    the "our actual sales across both platforms" rollup. Distinct from
--    `unified_orders` which mixes in SeatData (market observations).
-- ============================================================================

-- (1) Drop broker /sales cron + cleanup
SELECT cron.unschedule('sg_sales_queue_daily');
SELECT cron.unschedule('sg_sales_process_daily');
DROP FUNCTION IF EXISTS sg_sales_queue(int);
DROP FUNCTION IF EXISTS sg_sales_process();
DROP TABLE IF EXISTS sg_sales_pending;

-- (2) Server-side SG seller orders + listings (replaces Railway cron)
CREATE TABLE IF NOT EXISTS sg_seller_pending (
  id          bigserial PRIMARY KEY,
  request_id  bigint NOT NULL,
  scope       text NOT NULL,           -- 'orders' | 'listings'
  page        int NOT NULL,
  per_page    int,
  status_csv  text,
  fired_at    timestamptz DEFAULT now(),
  resolved_at timestamptz,
  rows_persisted int
);

CREATE OR REPLACE FUNCTION sg_seller_orders_queue(
  p_pages int DEFAULT 3,
  p_statuses text DEFAULT 'open,pending,confirmed,fulfilled'
) RETURNS int AS $$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  v_page int; v_req_id bigint; v_count int := 0;
BEGIN
  FOR v_page IN 1..p_pages LOOP
    SELECT net.http_get(
      url := 'https://sellerdirect-api.seatgeek.com/orders?page=' || v_page ||
             '&per_page=200&statuses=' || replace(p_statuses, ',', '%2C') ||
             '&token=' || v_token,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO sg_seller_pending(request_id, scope, page, per_page, status_csv)
    VALUES (v_req_id, 'orders', v_page, 200, p_statuses);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sg_seller_listings_queue(p_pages int DEFAULT 5) RETURNS int AS $$
DECLARE
  v_token text := get_app_secret('SEATGEEK_API_TOKEN');
  v_page int; v_req_id bigint; v_count int := 0;
BEGIN
  FOR v_page IN 1..p_pages LOOP
    SELECT net.http_get(
      url := 'https://sellerdirect-api.seatgeek.com/listings?page=' || v_page ||
             '&per_page=200&token=' || v_token,
      timeout_milliseconds := 30000
    ) INTO v_req_id;
    INSERT INTO sg_seller_pending(request_id, scope, page, per_page)
    VALUES (v_req_id, 'listings', v_page, 200);
    v_count := v_count + 1;
    PERFORM pg_sleep(0.5);
  END LOOP;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sg_seller_process()
RETURNS TABLE(processed int, orders_persisted int, listings_persisted int) AS $$
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
            o->>'id', o->>'status', NULLIF(o->>'created_at','')::timestamptz,
            o->>'delivery', o->>'delivery_method', o->>'stock_type',
            NULLIF(o->'event'->>'id','')::bigint,
            o->'event'->>'name', o->'event'->>'venue',
            NULLIF(o->'event'->>'date','')::date, o->'event'->>'time',
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
          FROM src WHERE (o->>'id') IS NOT NULL
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
            l->>'id', l->>'ticket_id',
            NULLIF(l->>'sg_listing_id','')::bigint,
            NULLIF(l->'event'->>'id','')::bigint,
            l->'event'->>'name', l->'event'->>'venue',
            NULLIF(l->'event'->>'date','')::date, l->'event'->>'time',
            (l->>'quantity')::int, l->>'section', l->>'row',
            l->>'seat_from', l->>'seat_thru', l->>'notes',
            NULLIF(l->>'cost','')::numeric,
            (l->>'is_edelivery')::bool, (l->>'is_instant')::bool,
            NULLIF(l->>'in_hand_date','')::date,
            encode(digest(
              coalesce(l->>'id','') || '|' || coalesce(l->>'ticket_id','') || '|' ||
              coalesce(l->>'cost','') || '|' || coalesce(l->>'quantity',''),
              'sha256'), 'hex'),
            now(), l
          FROM src WHERE (l->>'id') IS NOT NULL
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
END;
$$ LANGUAGE plpgsql;

-- (3) Align EVO + SG seller orders to 30-min cadence
SELECT cron.unschedule('evo_orders_queue_10min');
SELECT cron.unschedule('evo_orders_process_10min');

SELECT cron.schedule('evo_orders_queue_30min',     '*/30 * * * *',
  $$ SELECT evo_orders_queue(2); $$);
SELECT cron.schedule('evo_orders_process_30min',   '5-59/30 * * * *',
  $$ SELECT evo_orders_process(); $$);

SELECT cron.schedule('sg_seller_orders_queue_30min',   '*/30 * * * *',
  $$ SELECT sg_seller_orders_queue(3); $$);
SELECT cron.schedule('sg_seller_listings_queue_30min', '2-59/30 * * * *',
  $$ SELECT sg_seller_listings_queue(5); $$);
SELECT cron.schedule('sg_seller_process_30min',        '5-59/30 * * * *',
  $$ SELECT sg_seller_process(); $$);

-- (4) Disable Railway-bound seller cron
SELECT cron.unschedule('seatgeek-seller-collect-10min');

-- (5) our_orders + our_orders_by_event views — TEvo + SG only, no SeatData
CREATE OR REPLACE VIEW our_orders AS
SELECT
  'tevo'::text AS source,
  evo_order_id::text AS source_order_id,
  state AS source_status,
  COALESCE(
    (SELECT canonical_status FROM order_status_xref
     WHERE source = 'tevo' AND lower(source_status) = lower(evo_orders.state)
     LIMIT 1), 'unknown') AS canonical_status,
  total AS gross_amount,
  evo_created_at AS source_created_at,
  evo_updated_at AS source_updated_at,
  hold_expires_at,
  buyer_brokerage_name AS counterparty,
  (SELECT min(event_id) FROM evo_order_items WHERE evo_order_id = evo_orders.evo_order_id) AS tevo_event_id,
  pulled_at
FROM evo_orders
UNION ALL
SELECT
  'sg_seller'::text,
  sg_order_id, status,
  COALESCE(
    (SELECT canonical_status FROM order_status_xref
     WHERE source = 'sg_seller' AND lower(source_status) = lower(seatgeek_orders.status)
     LIMIT 1), 'unknown'),
  payment_total,
  created_at_sg, last_status_at, NULL::timestamptz,
  delivery, tevo_event_id, pulled_at
FROM seatgeek_orders;

COMMENT ON VIEW our_orders IS
  'OUR own sales rolled up across TEvo + SG sellerdirect. Distinct from '
  'unified_orders which mixes in SeatData (market observations of sales '
  'we did NOT make). Day-trader use: actual book / cash flow rollup.';

CREATE OR REPLACE VIEW our_orders_by_event AS
SELECT
  tevo_event_id,
  count(*) AS our_orders_total,
  count(*) FILTER (WHERE source='tevo')      AS tevo_orders,
  count(*) FILTER (WHERE source='sg_seller') AS sg_seller_orders,
  sum(gross_amount) FILTER (WHERE canonical_status='fulfilled') AS gross_fulfilled,
  count(*) FILTER (WHERE canonical_status='fulfilled') AS count_fulfilled,
  count(*) FILTER (WHERE canonical_status='pending')   AS count_pending,
  count(*) FILTER (WHERE canonical_status='accepted')  AS count_accepted,
  count(*) FILTER (WHERE canonical_status='cancelled') AS count_cancelled,
  count(*) FILTER (WHERE canonical_status='rejected')  AS count_rejected,
  max(source_updated_at) AS latest_activity
FROM our_orders
GROUP BY tevo_event_id;

COMMENT ON VIEW our_orders_by_event IS
  'Per-event rollup of our_orders. Powers "our book on this game" widget.';
