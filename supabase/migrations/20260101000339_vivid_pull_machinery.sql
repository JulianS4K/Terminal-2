-- Migration 20260515100000 · level:admin · lane:Audit/Push · writes:public.{vivid_orders_queue,vivid_orders_process,vivid_orders_pending,vivid_orders} + 2 cron jobs · reads:vault.VIVID_API_TOKEN · pre:20260513230000,20260513230400
-- Vivid Seats broker orders ingest — closes the gap left by the original
-- TickPick/Vivid migration set (20260513230000 created the tables; 230200
-- only wired TickPick's pull and explicitly deferred Vivid with a TODO).
--
-- Operator directive 2026-05-14: "lets begin tracking vivid orders … for
-- now only collect the data, we can get a mapping key later."
--
-- Vivid's API returns XML (not JSON like TickPick/Evo/SG), so the process
-- function uses xpath() rather than jsonb operators. The XML shape was
-- inventoried via live probe (request_id 12521, 818-order response):
-- per-<order> tags: orderId, orderToken, brokerTicketId, section, row,
-- notes, quantity, cost, event, eventDate, orderDate, expectedShipDate,
-- venue, status, electronicDelivery, passThrough, listingId, productionId,
-- eventId, zone, barCodesRequired, transferViaURL, instantTransfer,
-- instantFlashSeats, productionIntegrationType, soldAsIntegrated.
--
-- Source-internal IDs (orderId, listingId, productionId, eventId,
-- brokerTicketId, orderToken) do not cross to TEvo/SG/TickPick namespaces —
-- documented in COMMENT statements (companion FK migration 20260515110000).
--
-- Vivid Seats remains RULE 2 read-only — GET against brokers.vividseats.com.
-- No fulfillment write paths are added by this migration.
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 (this session). Idempotent
-- (CREATE OR REPLACE on functions; DO blocks for cron.schedule guards).

-- ============================================================
-- vivid_orders_queue(p_status text)
--   One pg_net.http_get against the Vivid broker getOrders endpoint.
--   Status defaults to PENDING_SHIPMENT (the Unified-Order-Suite filter).
--   Request_id parked in vivid_orders_pending for the process pass.
-- ============================================================

CREATE OR REPLACE FUNCTION public.vivid_orders_queue(p_status text DEFAULT 'PENDING_SHIPMENT')
RETURNS integer
LANGUAGE plpgsql
SET search_path = 'public', 'pg_temp'
AS $$
DECLARE
  v_token  text := get_app_secret('VIVID_API_TOKEN');
  v_req_id bigint;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN
    RAISE NOTICE 'VIVID_API_TOKEN vault secret unset; skipping queue';
    RETURN 0;
  END IF;

  SELECT net.http_get(
    url := 'https://brokers.vividseats.com/webservices/v1/getOrders'
           || '?apiToken=' || v_token
           || '&status='   || p_status,
    headers := '{"Accept":"application/xml"}'::jsonb,
    timeout_milliseconds := 30000
  ) INTO v_req_id;

  INSERT INTO public.vivid_orders_pending(request_id, query_str)
  VALUES (v_req_id, 'status=' || p_status);

  RETURN 1;
END;
$$;

-- ============================================================
-- vivid_orders_process()
--   Drain unresolved pending rows, parse XML, upsert into vivid_orders.
--   Each pending row corresponds to one /getOrders response. Mode lessons
--   from probe (request_id 12521): a 818-row response is ~960 KB and
--   parses cleanly under 1 second via xpath().
--
--   2099-eventDate "Postponed - Date TBD" orders are marked with
--   status='ignored_tbd_postponed' so they're tracked in counts but
--   excluded from active-coverage metrics. The original Vivid status is
--   preserved in raw_xml.
-- ============================================================

CREATE OR REPLACE FUNCTION public.vivid_orders_process()
RETURNS TABLE(processed integer, orders_persisted integer, http_failures integer)
LANGUAGE plpgsql
SET search_path = 'public', 'pg_temp'
AS $$
DECLARE
  r RECORD;
  v_processed int := 0;
  v_orders_persisted int := 0;
  v_http_failures int := 0;
  v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, h.content::text AS body, h.status_code
    FROM public.vivid_orders_pending p
    JOIN net._http_response h ON h.id = p.request_id
    WHERE p.resolved_at IS NULL
  LOOP
    v_processed := v_processed + 1;

    IF r.status_code = 200 THEN
      WITH ord AS (
        SELECT unnest(xpath('//order', xmlparse(document r.body))) AS o
      ),
      flat AS (
        SELECT
          NULLIF((xpath('/order/orderId/text()',         o))[1]::text, '') AS vivid_order_id,
          NULLIF((xpath('/order/event/text()',           o))[1]::text, '') AS event_name,
          NULLIF((xpath('/order/eventDate/text()',       o))[1]::text, '') AS event_date_raw,
          NULLIF((xpath('/order/section/text()',         o))[1]::text, '') AS section,
          NULLIF((xpath('/order/row/text()',             o))[1]::text, '') AS row_val,
          NULLIF((xpath('/order/status/text()',          o))[1]::text, '') AS vivid_status,
          NULLIF((xpath('/order/quantity/text()',        o))[1]::text, '') AS quantity_raw,
          NULLIF((xpath('/order/cost/text()',            o))[1]::text, '') AS cost_raw,
          NULLIF((xpath('/order/transferViaURL/text()',  o))[1]::text, '') AS transfer_raw,
          NULLIF((xpath('/order/orderDate/text()',       o))[1]::text, '') AS order_date_raw,
          o AS raw_x
        FROM ord
      ),
      ins AS (
        INSERT INTO public.vivid_orders (
          vivid_order_id, event_name, event_date, section, row,
          status, quantity, total, first_name, last_name, email_address,
          transfer_via_url, ordered_at, pulled_at, last_seen_at,
          raw_xml, raw
        )
        SELECT
          vivid_order_id,
          event_name,
          NULLIF(event_date_raw,'')::timestamptz,
          section,
          row_val,
          CASE
            WHEN event_date_raw IS NOT NULL
                 AND event_date_raw::timestamptz >= '2099-01-01'::timestamptz
              THEN 'ignored_tbd_postponed'
            ELSE vivid_status
          END,
          NULLIF(quantity_raw,'')::int,
          NULLIF(cost_raw,'')::numeric,
          NULL, NULL, NULL,         -- first_name/last_name/email_address not in getOrders shape
          lower(coalesce(transfer_raw, 'false'))::boolean,
          NULLIF(order_date_raw,'')::timestamptz,
          now(), now(),
          raw_x::text,
          jsonb_build_object(
            'orderToken',       (xpath('/order/orderToken/text()',       raw_x))[1]::text,
            'brokerTicketId',   (xpath('/order/brokerTicketId/text()',   raw_x))[1]::text,
            'listingId',        (xpath('/order/listingId/text()',        raw_x))[1]::text,
            'productionId',     (xpath('/order/productionId/text()',     raw_x))[1]::text,
            'eventId',          (xpath('/order/eventId/text()',          raw_x))[1]::text,
            'venue',            (xpath('/order/venue/text()',            raw_x))[1]::text,
            'notes',            (xpath('/order/notes/text()',            raw_x))[1]::text,
            'expectedShipDate', (xpath('/order/expectedShipDate/text()', raw_x))[1]::text
          )
        FROM flat
        WHERE vivid_order_id IS NOT NULL
        ON CONFLICT (vivid_order_id) DO UPDATE SET
          event_name       = EXCLUDED.event_name,
          event_date       = EXCLUDED.event_date,
          section          = EXCLUDED.section,
          row              = EXCLUDED.row,
          status           = EXCLUDED.status,
          quantity         = EXCLUDED.quantity,
          total            = EXCLUDED.total,
          transfer_via_url = EXCLUDED.transfer_via_url,
          ordered_at       = COALESCE(EXCLUDED.ordered_at, public.vivid_orders.ordered_at),
          last_seen_at     = now(),
          raw_xml          = EXCLUDED.raw_xml,
          raw              = EXCLUDED.raw
        RETURNING 1
      )
      SELECT count(*) INTO v_inserted FROM ins;
      v_orders_persisted := v_orders_persisted + v_inserted;

      UPDATE public.vivid_orders_pending
        SET resolved_at = now(), rows_persisted = v_inserted
        WHERE id = r.pending_id;
    ELSE
      -- Non-200 (likely token rotation) — mark resolved with sentinel so
      -- the queue doesn't loop. The change_log row in bot_chat covers the
      -- escalation path.
      v_http_failures := v_http_failures + 1;
      UPDATE public.vivid_orders_pending
        SET resolved_at = now(), rows_persisted = -1
        WHERE id = r.pending_id;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_orders_persisted, v_http_failures;
END;
$$;

-- ============================================================
-- pg_cron schedules (T2 tier per CRON_HIERARCHY.md)
--   queue   at :16,:46 — collision-aware: hourly sweep_duplicate_listings
--                        also fires at :16. 2 jobs at :16, 1 at :46.
--   process at :26,:56 — collision-aware: hourly refresh-chat-corpus also
--                        fires at :26. 2 jobs at :26, 1 at :56.
--   10-min queue→process gap (Vivid's 960KB XML response returns in ~5s).
-- ============================================================

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vivid_orders_queue_30min') THEN
    PERFORM cron.schedule(
      'vivid_orders_queue_30min',
      '16,46 * * * *',
      'SELECT public.vivid_orders_queue();'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vivid_orders_process_30min') THEN
    PERFORM cron.schedule(
      'vivid_orders_process_30min',
      '26,56 * * * *',
      'SELECT public.vivid_orders_process();'
    );
  END IF;
END $$;
