-- Migration 20260901180000 · level:secondary-sales · lane:D0 · writes:s4kcs_orders,s4kcs_orders_pending,order_status_xref,unified_orders · reads:vault.decrypted_secrets,net._http_response · pre:20260901173000
--
-- S4K CRM marketplace-orders ingest — the open sell-side order book for six
-- marketplaces, stored beside the other per-source order tables and folded
-- into unified_orders.
--
-- WHY. Our own ingest covers four books (evo_orders / seatgeek_orders /
-- tickpick_orders / vivid_orders). The CRM (crm.s4kcs.com/api/v1) aggregates
-- open orders across TickPick, GoTickets, SeatGeek, StubHub, Vivid Seats and
-- Gametime — so it is the ONLY source we have for **StubHub and Gametime**
-- orders. Live sample: 22,671 open orders, of which ~8,400 are StubHub and
-- ~3,070 Gametime, i.e. half the open book was invisible to us.
--
-- SHAPE. Mirrors the tickpick_orders/vivid_orders pattern exactly: a raw table
-- per source + a *_pending queue for the pg_net async ingest (request_id joins
-- net._http_response), a queue fn, a process fn, and two crons offset from each
-- other. Column set is the CRM's own /marketplace/columns response.
--
-- ⚠ DOUBLE-COUNT GUARD — read before extending the view branch.
-- The CRM book overlaps four sources we already ingest. Every row is STORED
-- (the CRM is the authoritative open-order view and is worth having whole, for
-- reconciliation against our own books), but the `unified_orders` branch is
-- restricted to the two marketplaces nothing else covers — StubHub and
-- Gametime. Widening that filter without deduping first would double-count
-- every TickPick/SeatGeek/Vivid order in every downstream aggregate.
--
-- The marketplace stays on `s4kcs_orders.source`; the view emits the constant
-- 's4kcs' because unified_orders has no per-marketplace column and adding one
-- would touch all six existing branches.
--
-- RULE 2. Read-only against crm.s4kcs.com — a GET against a documented
-- read-only endpoint. This migration adds NO write path to any upstream.
--
-- Operator authorized 2026-09-01 ("poll source every 10 mins and store same
-- place other company internal orders are stored") per CLAUDE.md rule #1.

-- ============================================================
-- (1) Raw table + pending queue
-- ============================================================

CREATE TABLE IF NOT EXISTS public.s4kcs_orders (
  source           text NOT NULL,          -- 'StubHub' | 'Gametime' | 'TickPick' | …
  s4k_order_id     text NOT NULL,          -- marketplace-native id, string per the API
  order_status     text,
  seller_status    text,
  event_name       text,
  event_date       date,
  venue_name       text,
  venue_city       text,
  venue_state      text,
  section          text,
  row              text,
  seats            text,
  quantity         int,
  price            numeric,                -- seller payout/wholesale per the API docs
  delivery         text,
  inhand_date      date,
  payout_date      date,
  purchase_date    date,
  notes            text,
  -- Cross-source ids: NULL on arrival. The CRM identifies an event by
  -- name/date/venue only, so these are the AQ mapper's to fill (PROJECT_BIBLE
  -- §0) — never hand-mapped here from a name+date match.
  tevo_event_id    bigint,
  aq_short_event_id text,
  venue_short_id   text,
  performer_short_id text,
  pulled_at        timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now(),
  raw              jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Marketplace ids are only unique WITHIN a marketplace.
  PRIMARY KEY (source, s4k_order_id)
);

CREATE INDEX IF NOT EXISTS s4kcs_orders_event_date_idx    ON public.s4kcs_orders (event_date);
CREATE INDEX IF NOT EXISTS s4kcs_orders_status_idx        ON public.s4kcs_orders (order_status);
CREATE INDEX IF NOT EXISTS s4kcs_orders_inhand_idx        ON public.s4kcs_orders (inhand_date);
CREATE INDEX IF NOT EXISTS s4kcs_orders_last_seen_idx     ON public.s4kcs_orders (last_seen_at);
CREATE INDEX IF NOT EXISTS s4kcs_orders_tevo_event_id_idx ON public.s4kcs_orders (tevo_event_id) WHERE tevo_event_id IS NOT NULL;
-- The order-lookup path resolves a pasted order number with no marketplace.
CREATE INDEX IF NOT EXISTS s4kcs_orders_order_id_idx      ON public.s4kcs_orders (s4k_order_id);

CREATE TABLE IF NOT EXISTS public.s4kcs_orders_pending (
  id              bigserial PRIMARY KEY,
  request_id      bigint NOT NULL,
  query_str       text,
  resolved_at     timestamptz,
  rows_persisted  int,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS s4kcs_orders_pending_unresolved_idx
  ON public.s4kcs_orders_pending (resolved_at) WHERE resolved_at IS NULL;

-- RLS: service_role-only, matching every other order table. No policies →
-- anon/authenticated cannot SELECT; service_role bypasses RLS.
ALTER TABLE public.s4kcs_orders         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.s4kcs_orders_pending ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- (2) Status xref — every status observed in a full live pull
-- ============================================================
-- The CRM serves the OPEN book, so nothing here is terminal except an
-- explicitly rejected order. StubHub's statuses are seller action-items
-- ("Upload Transfer Receipts"), which map to `accepted`: the sale stands, the
-- delivery does not yet.
-- ⚠ order_status_xref's unique key is (source, source_status,
-- source_status_kind) — NOT the (source, source_status) pair the view joins
-- on. `source_status_kind` defaults to 'state' but must be named explicitly
-- here, or ON CONFLICT fails with 42P10.
INSERT INTO public.order_status_xref (source, source_status, source_status_kind, canonical_status, is_terminal, is_sale_succeeded)
VALUES
  ('s4kcs', 'unfulfilled', 'state',                                'accepted', false, false),  -- Gametime
  ('s4kcs', 'PENDING_FULFILLMENT', 'state',                        'accepted', false, false),  -- GoTickets
  ('s4kcs', 'PENDING_SHIPMENT', 'state',                           'accepted', false, false),  -- Vivid
  ('s4kcs', 'confirmed', 'state',                                  'accepted', false, false),  -- SeatGeek
  ('s4kcs', 'CONFIRMED', 'state',                                  'accepted', false, false),  -- TickPick
  ('s4kcs', 'REJECTED', 'state',                                   'rejected', true,  false),
  -- StubHub seller action-items
  ('s4kcs', 'Upload Transfer Receipts', 'state',                   'accepted', false, false),
  ('s4kcs', 'Enter Ticket Barcodes', 'state',                      'accepted', false, false),
  ('s4kcs', 'Re-enter Barcodes', 'state',                          'accepted', false, false),
  ('s4kcs', 'Confirm Sale', 'state',                               'accepted', false, false),
  ('s4kcs', 'Confirm Sales', 'state',                              'accepted', false, false),
  ('s4kcs', 'Upload E-Tickets', 'state',                           'accepted', false, false),
  ('s4kcs', 'Upload QR Codes', 'state',                            'accepted', false, false),
  ('s4kcs', 'Upload Ticket Links', 'state',                        'accepted', false, false),
  ('s4kcs', 'Re-Transfer Ticket', 'state',                         'accepted', false, false),
  ('s4kcs', 'Ship Tickets', 'state',                               'accepted', false, false),
  ('s4kcs', 'Print Shipping Label', 'state',                       'accepted', false, false),
  ('s4kcs', 'Wait for Delivery', 'state',                          'accepted', false, false),
  ('s4kcs', 'Wait for Courier Pickup', 'state',                    'accepted', false, false),
  ('s4kcs', 'On the Way', 'state',                                 'accepted', false, false),
  ('s4kcs', 'Issue reported: replacement tickets offered', 'state', 'substitution', false, false),
  -- StubHub serves this one with its template placeholder unrendered. Mapped
  -- verbatim because that IS the string the API returns; normalising it would
  -- silently diverge from the raw payload.
  ('s4kcs', 'Transfer #{#TicketTypeName#}# Tickets', 'state',      'accepted', false, false)
ON CONFLICT (source, source_status, source_status_kind) DO NOTHING;

-- ============================================================
-- (2b) Defensive coercion — the feed ships junk in typed fields
-- ============================================================
-- Observed in a full live pull: empty strings across ~20k payout_date /
-- ~6k inhand_date / ~3k purchase_date / ~2.9k price, and the literal string
-- "None" (a stringified Python None from upstream) in 8 inhand_date values.
-- A bare ::date cast on that aborts the WHOLE batch — one bad row loses
-- 22k good ones — so these accept only a well-formed value and NULL the rest.
-- Regex-guarded rather than blocklisting the junk we happen to have seen:
-- the next surprise string should also become NULL, not an exception.
CREATE OR REPLACE FUNCTION public.s4kcs_as_date(p text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p ~ '^\d{4}-\d{2}-\d{2}$' THEN p::date ELSE NULL END;
$$;

CREATE OR REPLACE FUNCTION public.s4kcs_as_num(p text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p ~ '^-?\d+(\.\d+)?$' THEN p::numeric ELSE NULL END;
$$;

-- ============================================================
-- (3) s4kcs_orders_queue() — fire the live fetch
-- ============================================================
CREATE OR REPLACE FUNCTION public.s4kcs_orders_queue()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, vault
AS $$
DECLARE
  -- btrim: the seeded value carried a leading space, and a whitespace-broken
  -- key fails as an opaque 401. Cheap insurance against a re-paste.
  v_key    text := btrim(COALESCE(public.get_app_secret('crm.s4kcs.com'), ''));
  v_req_id bigint;
BEGIN
  IF v_key = '' THEN
    RAISE NOTICE 'crm.s4kcs.com vault secret unset; skipping queue';
    RETURN 0;
  END IF;

  -- No window params: the CRM already serves only the OPEN book, and its
  -- default event window (today → +2y) is what we want. One call returns every
  -- marketplace; a market that fails is reported in the body's `errors` and
  -- simply contributes no rows.
  SELECT net.http_get(
    url := 'https://crm.s4kcs.com/api/v1/marketplace/orders',
    headers := jsonb_build_object('X-API-Key', v_key, 'Accept', 'application/json'),
    timeout_milliseconds := 120000   -- the live fetch can take ~60s
  ) INTO v_req_id;

  INSERT INTO public.s4kcs_orders_pending(request_id, query_str)
  VALUES (v_req_id, 'all-markets');

  RETURN 1;
END;
$$;

REVOKE ALL ON FUNCTION public.s4kcs_orders_queue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_orders_queue() TO service_role;

-- ============================================================
-- (4) s4kcs_orders_process() — drain the queue, upsert the book
-- ============================================================
CREATE OR REPLACE FUNCTION public.s4kcs_orders_process()
RETURNS TABLE(processed integer, orders_persisted integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $$
DECLARE
  r RECORD;
  v_body jsonb;
  v_rows jsonb;
  v_processed int := 0;
  v_persisted int := 0;
  v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, h.content, h.status_code
    FROM public.s4kcs_orders_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;

    IF r.status_code = 200 THEN
      BEGIN
        v_body := r.content::jsonb;
      EXCEPTION WHEN OTHERS THEN
        v_body := NULL;
      END;
      v_rows := COALESCE(v_body->'rows', '[]'::jsonb);

      -- DISTINCT ON is MANDATORY: the feed can repeat a (source, id) pair
      -- inside one payload (observed as a byte-identical duplicate row), and
      -- Postgres rejects that with "ON CONFLICT DO UPDATE command cannot
      -- affect row a second time" — which fails the WHOLE batch, not the row.
      WITH src AS (
        SELECT DISTINCT ON (o->>'source', o->>'id') o
        FROM jsonb_array_elements(v_rows) AS o
        ORDER BY o->>'source', o->>'id'
      ),
      ins AS (
        INSERT INTO public.s4kcs_orders (
          source, s4k_order_id, order_status, seller_status,
          event_name, event_date, venue_name, venue_city, venue_state,
          section, row, seats, quantity, price, delivery,
          inhand_date, payout_date, purchase_date, notes,
          pulled_at, last_seen_at, raw
        )
        SELECT
          o->>'source',
          o->>'id',
          NULLIF(o->>'order_status',''),
          NULLIF(o->>'seller_status',''),
          NULLIF(o->>'event_name',''),
          public.s4kcs_as_date(o->>'event_date'),
          NULLIF(o->>'venue_name',''),
          NULLIF(o->>'venue_city',''),
          NULLIF(o->>'venue_state',''),
          NULLIF(o->>'section',''),
          NULLIF(o->>'row',''),
          NULLIF(o->>'seats',''),
          public.s4kcs_as_num(o->>'quantity')::int,
          public.s4kcs_as_num(o->>'price'),
          NULLIF(o->>'delivery',''),
          public.s4kcs_as_date(o->>'inhand_date'),
          public.s4kcs_as_date(o->>'payout_date'),
          public.s4kcs_as_date(o->>'purchase_date'),
          NULLIF(o->>'notes',''),
          now(), now(), o
        FROM src
        WHERE COALESCE(o->>'source','') <> '' AND COALESCE(o->>'id','') <> ''
        ON CONFLICT (source, s4k_order_id) DO UPDATE SET
          order_status  = EXCLUDED.order_status,
          seller_status = EXCLUDED.seller_status,
          event_name    = EXCLUDED.event_name,
          event_date    = EXCLUDED.event_date,
          venue_name    = EXCLUDED.venue_name,
          venue_city    = EXCLUDED.venue_city,
          venue_state   = EXCLUDED.venue_state,
          section       = EXCLUDED.section,
          row           = EXCLUDED.row,
          seats         = EXCLUDED.seats,
          quantity      = EXCLUDED.quantity,
          price         = EXCLUDED.price,
          delivery      = EXCLUDED.delivery,
          inhand_date   = EXCLUDED.inhand_date,
          payout_date   = EXCLUDED.payout_date,
          purchase_date = EXCLUDED.purchase_date,
          notes         = EXCLUDED.notes,
          last_seen_at  = now(),
          raw           = EXCLUDED.raw
        RETURNING 1
      )
      SELECT count(*) INTO v_inserted FROM ins;
      v_persisted := v_persisted + v_inserted;

      UPDATE public.s4kcs_orders_pending
        SET resolved_at = now(), rows_persisted = v_inserted
        WHERE id = r.pending_id;
    ELSE
      -- Non-200 (401 while the key rotates, 429, upstream 5xx). Resolve with a
      -- sentinel so the queue can't loop on it; the next cron tick retries.
      UPDATE public.s4kcs_orders_pending
        SET resolved_at = now(), rows_persisted = -1
        WHERE id = r.pending_id;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_persisted;
END;
$$;

REVOKE ALL ON FUNCTION public.s4kcs_orders_process() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_orders_process() TO service_role;

-- ============================================================
-- (5) unified_orders — add the two marketplaces nothing else covers
-- ============================================================
-- Rebuilt verbatim from the deployed definition with ONE branch appended.
-- See the double-count guard at the top before widening the source filter.
CREATE OR REPLACE VIEW public.unified_orders AS
 SELECT 'evo'::text AS source,
    o.evo_order_id::text AS source_order_id,
    ( SELECT min(i.event_id) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS tevo_event_id,
    NULL::text AS sg_event_id,
    o.state AS source_status,
    xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
    o.type AS source_type,
    ( SELECT sum(i.price * i.quantity::numeric) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS gross_value,
    ( SELECT sum(i.quantity) FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id) AS quantity,
    o.buyer_name, o.seller_name, o.client_name,
    o.evo_created_at AS created_at, o.evo_updated_at AS updated_at, o.last_seen_at,
    ( SELECT i.event_name FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id ORDER BY i.evo_item_id LIMIT 1) AS event_name,
    ( SELECT i.occurs_at FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id ORDER BY i.evo_item_id LIMIT 1) AS event_date,
    ( SELECT i.aq_short_event_id FROM evo_order_items i WHERE i.evo_order_id = o.evo_order_id AND i.aq_short_event_id IS NOT NULL LIMIT 1) AS aq_short_event_id
   FROM evo_orders o
     LEFT JOIN order_status_xref xref ON xref.source = 'evo'::text AND xref.source_status = o.state
UNION ALL
 SELECT 'seatgeek'::text, o.sg_order_id, o.tevo_event_id, o.sg_event_id::text,
    o.status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
    NULL::text, o.payment_total, o.sale_quantity::bigint,
    NULL::text, NULL::text, NULL::text,
    o.created_at_sg, o.last_status_at, o.last_status_at, o.sg_event_name,
        CASE WHEN o.sg_event_date IS NULL THEN NULL::timestamp without time zone
             ELSE ((o.sg_event_date::text || 'T'::text) || COALESCE(o.sg_event_time, '00:00:00'::text))::timestamp without time zone END,
    o.aq_short_event_id
   FROM seatgeek_orders o
     LEFT JOIN order_status_xref xref ON xref.source = 'seatgeek'::text AND xref.source_status = o.status
UNION ALL
 SELECT 'seatgeek_sales'::text, s.sg_sale_id, NULL::bigint, s.sg_event_id::text,
    'sold'::text, 'fulfilled'::text, true, true, NULL::text,
    s.broadcast_price * COALESCE(s.quantity, 1)::numeric, s.quantity::bigint,
    NULL::text, NULL::text, NULL::text,
    s.sale_at_utc, s.pulled_at, s.pulled_at,
    ( SELECT sgc.sg_event_name FROM sg_events_canonical sgc WHERE sgc.sg_event_id = s.sg_event_id),
    ( SELECT sgc.sg_datetime_utc::timestamp without time zone FROM sg_events_canonical sgc WHERE sgc.sg_event_id = s.sg_event_id),
    s.aq_short_event_id
   FROM ( SELECT DISTINCT ON (seatgeek_sales_snapshots.sg_sale_id) seatgeek_sales_snapshots.sg_sale_id,
            seatgeek_sales_snapshots.sg_event_id, seatgeek_sales_snapshots.broadcast_price,
            seatgeek_sales_snapshots.quantity, seatgeek_sales_snapshots.sale_at_utc,
            seatgeek_sales_snapshots.pulled_at, seatgeek_sales_snapshots.aq_short_event_id
           FROM seatgeek_sales_snapshots
          WHERE seatgeek_sales_snapshots.sg_sale_id IS NOT NULL
          ORDER BY seatgeek_sales_snapshots.sg_sale_id, seatgeek_sales_snapshots.pulled_at DESC) s
UNION ALL
 SELECT 'seatdata'::text, s.content_hash, s.tevo_event_id, NULL::text,
    'sold'::text, 'fulfilled'::text, true, true, NULL::text,
    s.price * COALESCE(NULLIF(s.quantity, 0), 1)::numeric, s.quantity::bigint,
    NULL::text, NULL::text, NULL::text,
    s.sale_timestamp, s.sale_timestamp, s.pulled_at,
    NULL::text, NULL::timestamp without time zone, NULL::text
   FROM seatdata_sales_snapshots s
UNION ALL
 SELECT 'tickpick'::text, o.tp_order_id, o.tevo_event_id, NULL::text,
    o.status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
    NULL::text, o.total, o.quantity::bigint,
    NULL::text, NULL::text, NULL::text,
    COALESCE(o.ordered_at, o.pulled_at), o.last_seen_at, o.last_seen_at,
    o.event_name, o.event_date::timestamp without time zone, o.aq_short_event_id
   FROM tickpick_orders o
     LEFT JOIN order_status_xref xref ON xref.source = 'tickpick'::text AND xref.source_status = o.status
UNION ALL
 SELECT 'vivid'::text, o.vivid_order_id, o.tevo_event_id, NULL::text,
    o.status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
    NULL::text, o.total, o.quantity::bigint,
    NULLIF(concat_ws(' '::text, o.first_name, o.last_name), ''::text), NULL::text, NULL::text,
    COALESCE(o.ordered_at, o.pulled_at), o.last_seen_at, o.last_seen_at,
    o.event_name, o.event_date::timestamp without time zone, o.aq_short_event_id
   FROM vivid_orders o
     LEFT JOIN order_status_xref xref ON xref.source = 'vivid'::text AND xref.source_status = o.status
UNION ALL
 -- S4K CRM: ONLY the marketplaces no other branch covers. See the guard above.
 SELECT 's4kcs'::text, o.s4k_order_id, o.tevo_event_id, NULL::text,
    o.order_status, xref.canonical_status, xref.is_terminal, xref.is_sale_succeeded,
    o.source AS source_type,   -- the marketplace, which the view has no column for
    o.price * COALESCE(NULLIF(o.quantity, 0), 1)::numeric, o.quantity::bigint,
    NULL::text, NULL::text, NULL::text,
    COALESCE(o.purchase_date::timestamptz, o.pulled_at), o.last_seen_at, o.last_seen_at,
    o.event_name, o.event_date::timestamp without time zone, o.aq_short_event_id
   FROM s4kcs_orders o
     LEFT JOIN order_status_xref xref ON xref.source = 's4kcs'::text AND xref.source_status = o.order_status
  WHERE o.source IN ('StubHub', 'Gametime');

-- ============================================================
-- (6) Crons — fetch every 10 minutes, drain 3 minutes behind
-- ============================================================
-- Minute marks :02/:05/:07 are saturated clusters and are avoided. The live
-- fetch can take ~60s, so the drain runs a comfortable 3 minutes later; a
-- response that misses its tick is picked up by the next one (the queue drains
-- on `resolved_at IS NULL`, not on recency).
SELECT cron.schedule(
  's4kcs_orders_queue_10min',
  '*/10 * * * *',
  'SELECT public.s4kcs_orders_queue();'
);

SELECT cron.schedule(
  's4kcs_orders_process_10min',
  '3-59/10 * * * *',
  'SELECT public.s4kcs_orders_process();'
);
