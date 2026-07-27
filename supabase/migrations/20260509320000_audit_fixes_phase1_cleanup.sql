-- ============================================================================
-- Migration 20260509320000 — Audit P0/P3 fixes + Phase-1 cleanup
--
-- (a) P0: Restore evo_order_items persistence in evo_orders_process()
--     Regression caught by 2026-05-09 audit. Items table has been empty
--     since the server-side cron rebuild. our_orders_by_event.tevo_event_id
--     was always NULL on the TEvo side as a result.
-- (b) P3: Drop wiki_seasons orphan (created, never populated, never read)
-- ============================================================================

DROP FUNCTION IF EXISTS evo_orders_process();
CREATE FUNCTION evo_orders_process()
RETURNS TABLE(processed int, orders_persisted int, items_persisted int) AS $$
DECLARE
  r RECORD; v_body jsonb; v_orders jsonb;
  v_processed int := 0; v_orders_persisted int := 0;
  v_items_persisted int := 0; v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, h.content, h.status_code
    FROM evo_orders_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      v_orders := COALESCE(v_body->'orders', '[]'::jsonb);

      WITH src AS (SELECT o FROM jsonb_array_elements(v_orders) AS o),
      ins AS (
        INSERT INTO evo_orders (
          evo_order_id, state, type, fraud_check_status,
          total, subtotal, tax, shipping, service_fee, refunded, balance,
          additional_expense, reference, invoice_number, po_number, instructions, partner,
          buyer_id, buyer_name, buyer_brokerage_id, buyer_brokerage_name,
          seller_id, seller_name, seller_brokerage_id, seller_brokerage_name,
          client_id, client_name,
          evo_created_at, evo_updated_at, hold_placed_at, hold_expires_at,
          pulled_at, last_seen_at, raw
        )
        SELECT
          (o->>'id')::bigint,
          o->>'state', o->>'type', o->>'fraud_check_status',
          NULLIF(o->>'total','')::numeric, NULLIF(o->>'subtotal','')::numeric,
          NULLIF(o->>'tax','')::numeric, NULLIF(o->>'shipping','')::numeric,
          NULLIF(o->>'service_fee','')::numeric, NULLIF(o->>'refunded','')::numeric,
          NULLIF(o->>'balance','')::numeric, NULLIF(o->>'additional_expense','')::numeric,
          o->>'reference', o->>'invoice_number', o->>'po_number',
          o->>'instructions', (o->>'partner')::bool,
          NULLIF(o->'buyer'->>'id','')::bigint, o->'buyer'->>'name',
          NULLIF(o->'buyer'->'brokerage'->>'id','')::bigint, o->'buyer'->'brokerage'->>'name',
          NULLIF(o->'seller'->>'id','')::bigint, o->'seller'->>'name',
          NULLIF(o->'seller'->'brokerage'->>'id','')::bigint, o->'seller'->'brokerage'->>'name',
          NULLIF(o->'client'->>'id','')::bigint, o->'client'->>'name',
          NULLIF(o->>'created_at','')::timestamptz, NULLIF(o->>'updated_at','')::timestamptz,
          NULLIF(o->>'hold_placed_at','')::timestamptz, NULLIF(o->>'hold_expires_at','')::timestamptz,
          now(), now(), o
        FROM src WHERE (o->>'id') IS NOT NULL
        ON CONFLICT (evo_order_id) DO UPDATE SET
          state = EXCLUDED.state, type = EXCLUDED.type,
          fraud_check_status = EXCLUDED.fraud_check_status,
          total = EXCLUDED.total, subtotal = EXCLUDED.subtotal,
          shipping = EXCLUDED.shipping, service_fee = EXCLUDED.service_fee,
          refunded = EXCLUDED.refunded, balance = EXCLUDED.balance,
          evo_updated_at = EXCLUDED.evo_updated_at,
          hold_placed_at = EXCLUDED.hold_placed_at, hold_expires_at = EXCLUDED.hold_expires_at,
          last_seen_at = now(), raw = EXCLUDED.raw
        RETURNING 1
      )
      SELECT count(*) INTO v_inserted FROM ins;
      v_orders_persisted := v_orders_persisted + v_inserted;

      -- RESTORED: delete + re-insert items per order so adds/removes reflect
      WITH src AS (SELECT o FROM jsonb_array_elements(v_orders) AS o WHERE (o->>'id') IS NOT NULL),
      del AS (DELETE FROM evo_order_items
              WHERE evo_order_id IN (SELECT (o->>'id')::bigint FROM src)
              RETURNING 1),
      flat AS (
        SELECT (o->>'id')::bigint AS evo_order_id, it
        FROM src, jsonb_array_elements(coalesce(o->'items','[]'::jsonb)) AS it
      ),
      ins_items AS (
        INSERT INTO evo_order_items (
          evo_order_id, evo_item_id, quantity, price,
          ticket_group_id, ticket_group_remote_id, ticket_group_office_id,
          ticket_group_section, ticket_group_row, ticket_group_seats, ticket_group_quantity,
          ticket_group_retail_price, ticket_group_wholesale_price, ticket_group_external_notes,
          event_id, event_name, occurs_at, venue_id, venue_name,
          eticket_available, eticket_delivery, raw
        )
        SELECT
          flat.evo_order_id,
          NULLIF(flat.it->>'id','')::bigint,
          NULLIF(flat.it->>'quantity','')::int,
          NULLIF(flat.it->>'price','')::numeric,
          NULLIF(flat.it->'ticket_group'->>'id','')::bigint,
          flat.it->'ticket_group'->>'remote_id',
          NULLIF(flat.it->'ticket_group'->>'office_id','')::bigint,
          flat.it->'ticket_group'->>'section', flat.it->'ticket_group'->>'row',
          coalesce(flat.it->'ticket_group'->'seats','[]'::jsonb),
          NULLIF(flat.it->'ticket_group'->>'quantity','')::int,
          NULLIF(flat.it->'ticket_group'->>'retail_price','')::numeric,
          NULLIF(flat.it->'ticket_group'->>'wholesale_price','')::numeric,
          flat.it->'ticket_group'->>'external_notes',
          NULLIF(flat.it->'ticket_group'->'event'->>'id','')::bigint,
          flat.it->'ticket_group'->'event'->>'name',
          NULLIF(flat.it->'ticket_group'->'event'->>'occurs_at','')::timestamptz,
          NULLIF(flat.it->'ticket_group'->'event'->'venue'->>'id','')::bigint,
          flat.it->'ticket_group'->'event'->'venue'->>'name',
          (flat.it->>'eticket_available')::bool,
          flat.it->>'eticket_delivery',
          flat.it
        FROM flat
        RETURNING 1
      )
      SELECT count(*) INTO v_inserted FROM ins_items;
      v_items_persisted := v_items_persisted + v_inserted;

      UPDATE evo_orders_pending SET resolved_at = now(), rows_persisted = v_orders_persisted
        WHERE id = r.pending_id;
    ELSE
      UPDATE evo_orders_pending SET resolved_at = now(), rows_persisted = -1
        WHERE id = r.pending_id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_orders_persisted, v_items_persisted;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION evo_orders_process() IS
  'Persist EVO orders + items from pg_net responses. Items are delete+reinsert '
  'per order so adds/removes reflect cleanly. Restored after audit caught '
  'regression where items block was dropped during cron rebuild.';

DROP TABLE IF EXISTS wiki_seasons;
