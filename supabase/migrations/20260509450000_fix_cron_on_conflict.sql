-- ============================================================================
-- Migration 20260509450000 — Fix ON CONFLICT in sg_listings_process +
--                            evo_orders_process (Phase 1 stability)
--
-- Discovered during the Phase 1 stability audit:
--   - sg_listings_process_5min:  17 of 35 runs failed in last 24h with
--     "duplicate key value violates unique constraint seatgeek_listings_dedup"
--     INSERT was missing ON CONFLICT for re-pulled listings.
--   - evo_orders_process_30min:  4 of 5 runs failed with
--     "duplicate key value violates unique constraint
--      evo_order_items_evo_item_id_key"
--     Items INSERT was missing ON CONFLICT on evo_item_id.
--
-- Both are batch INSERTs without idempotency. Adding ON CONFLICT clauses
-- so re-pulls of the same data become no-ops (or upserts where appropriate)
-- instead of throwing and rolling back the whole transaction.
-- ============================================================================

CREATE OR REPLACE FUNCTION sg_listings_process()
RETURNS TABLE(processed integer, rows_persisted integer)
LANGUAGE plpgsql AS $$
DECLARE
  r RECORD; v_body jsonb; v_listings jsonb;
  v_processed int := 0; v_persisted int := 0; v_count int;
BEGIN
  FOR r IN
    SELECT p.id, p.request_id, p.sg_event_id, h.content, h.status_code
    FROM sg_listings_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;
    IF r.status_code = 200 THEN
      BEGIN v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN v_body := NULL; END;
      v_listings := COALESCE(v_body->'listings', '[]'::jsonb);

      WITH src AS (
        SELECT l, COALESCE(
          (SELECT tevo_event_id FROM seatgeek_event_xref WHERE sg_event_id = r.sg_event_id),
          NULL::bigint
        ) AS tevo_event_id
        FROM jsonb_array_elements(v_listings) AS l
      ),
      ins AS (
        INSERT INTO seatgeek_listings_snapshots (
          tevo_event_id, sg_event_id, captured_at,
          sglid, display_id, retail_price_all_in, broadcast_price,
          deal_quality_score, quantity, splits, section, row,
          is_b2b, is_instant_download, is_sro, has_limited_view, is_wheelchair_acc,
          delivery_method, market_source, stock_type, raw,
          endpoint, content_hash
        )
        SELECT
          src.tevo_event_id, r.sg_event_id, now(),
          NULLIF(src.l->>'sglid','')::bigint,
          src.l->>'id',
          (src.l->>'pf')::numeric, (src.l->>'bp')::numeric,
          NULLIF(src.l->>'ds','')::numeric,
          (src.l->>'q')::int,
          src.l->'sp', src.l->>'s', src.l->>'r',
          (src.l->>'is_b2b')::bool, (src.l->>'idl')::bool,
          (src.l->>'sro')::bool, (src.l->>'lv')::bool, (src.l->>'wa')::bool,
          src.l->>'dm', src.l->>'m', src.l->>'st',
          src.l, 'v2/listings',
          encode(digest(
            r.sg_event_id::text || '|' || coalesce(src.l->>'sglid','') || '|' ||
            coalesce(src.l->>'id','') || '|' || coalesce(src.l->>'s','') || '|' ||
            coalesce(src.l->>'r','') || '|' || coalesce(src.l->>'q','') || '|' ||
            coalesce(src.l->>'pf','') || '|' || coalesce(src.l->>'bp',''),
            'sha256'), 'hex')
        FROM src
        ON CONFLICT (tevo_event_id, sglid, content_hash) DO NOTHING  -- IDEMPOTENT
        RETURNING 1
      )
      SELECT count(*) INTO v_count FROM ins;
      v_persisted := v_persisted + v_count;
      UPDATE sg_listings_pending SET resolved_at = now(), rows_persisted = v_count
        WHERE id = r.id;
    ELSE
      UPDATE sg_listings_pending SET resolved_at = now(), rows_persisted = -1
        WHERE id = r.id;
    END IF;
  END LOOP;
  RETURN QUERY SELECT v_processed, v_persisted;
END;
$$;

CREATE OR REPLACE FUNCTION evo_orders_process()
RETURNS TABLE(processed integer, orders_persisted integer, items_persisted integer)
LANGUAGE plpgsql AS $$
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

      -- Orders upsert (unchanged from prior version)
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

      -- Items upsert — KEY FIX: ON CONFLICT (evo_item_id) DO UPDATE
      -- replaces the prior delete+insert pattern that broke when multiple
      -- pending batches referenced the same items.
      WITH src AS (SELECT o FROM jsonb_array_elements(v_orders) AS o WHERE (o->>'id') IS NOT NULL),
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
        WHERE flat.it->>'id' IS NOT NULL
        ON CONFLICT (evo_item_id) DO UPDATE SET
          evo_order_id     = EXCLUDED.evo_order_id,
          quantity         = EXCLUDED.quantity,
          price            = EXCLUDED.price,
          ticket_group_id  = EXCLUDED.ticket_group_id,
          event_id         = EXCLUDED.event_id,
          event_name       = EXCLUDED.event_name,
          occurs_at        = EXCLUDED.occurs_at,
          venue_id         = EXCLUDED.venue_id,
          venue_name       = EXCLUDED.venue_name,
          raw              = EXCLUDED.raw
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
$$;
