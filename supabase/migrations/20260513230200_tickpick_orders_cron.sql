-- TickPick orders ingest — mirrors the evo_orders queue/process pattern.
-- pg_net.http_get fires the upstream request, response lands in
-- net._http_response, the process function drains the queue and upserts
-- into tickpick_orders.
--
-- Vivid uses XML — parsing in PL/pgSQL is painful; that ingest path goes
-- through a follow-up edge function (TODO). vivid_orders table is created
-- in 20260513230000 so the unified_orders view (20260513230100) compiles
-- even before vivid ingest ships.
--
-- Read-only against api.tickpick.com (GET only). RULE 2 spirit preserved —
-- this migration adds NO write paths to any upstream API.

-- ============================================================
-- tickpick_orders_queue(p_pages int)
--   Fires N pg_net.http_get calls against the TickPick orders endpoint.
--   Default p_pages=1 since TickPick's /1.0/orders doesn't expose page
--   parameters on the v1 broker feed (full list per call). p_pages is
--   kept as an arg for future pagination support.
-- ============================================================

CREATE OR REPLACE FUNCTION public.tickpick_orders_queue(p_pages integer DEFAULT 1)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  v_token   text := get_app_secret('TICKPICK_API_TOKEN');
  v_req_id  bigint;
  v_count   int := 0;
BEGIN
  IF v_token IS NULL OR v_token = '' THEN
    RAISE NOTICE 'TICKPICK_API_TOKEN vault secret unset; skipping queue';
    RETURN 0;
  END IF;

  SELECT net.http_get(
    url := 'https://api.tickpick.com/1.0/orders?status=unfulfilled',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_token,
      'Accept', 'application/json'
    ),
    timeout_milliseconds := 30000
  ) INTO v_req_id;

  INSERT INTO public.tickpick_orders_pending(request_id, query_str)
  VALUES (v_req_id, 'status=unfulfilled');
  v_count := v_count + 1;

  RETURN v_count;
END;
$$;

-- ============================================================
-- tickpick_orders_process()
--   Drain unresolved pending rows, parse JSON, upsert into tickpick_orders.
--   Records seen on this pass have last_seen_at refreshed (lets the
--   dashboard's "X minutes ago" indicator stay accurate).
-- ============================================================

CREATE OR REPLACE FUNCTION public.tickpick_orders_process()
RETURNS TABLE(processed integer, orders_persisted integer)
LANGUAGE plpgsql
AS $$
DECLARE
  r RECORD;
  v_body jsonb;
  v_orders jsonb;
  v_processed int := 0;
  v_orders_persisted int := 0;
  v_inserted int;
BEGIN
  FOR r IN
    SELECT p.id AS pending_id, p.request_id, h.content, h.status_code
    FROM public.tickpick_orders_pending p
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

      -- TickPick /orders returns a top-level JSON array; some shapes wrap
      -- it as {"orders":[...]}. Accept either.
      IF v_body IS NOT NULL AND jsonb_typeof(v_body) = 'array' THEN
        v_orders := v_body;
      ELSE
        v_orders := COALESCE(v_body->'orders', '[]'::jsonb);
      END IF;

      WITH src AS (SELECT o FROM jsonb_array_elements(v_orders) AS o),
      ins AS (
        INSERT INTO public.tickpick_orders (
          tp_order_id, event_name, event_date,
          section, row, seat_numbers,
          status, quantity, total, notes, ordered_at,
          pulled_at, last_seen_at, raw
        )
        SELECT
          COALESCE(o->>'order_number', o->>'orderId', o->>'id')::text,
          o->>'event_name',
          NULLIF(o->>'event_date','')::timestamptz,
          o->>'section',
          o->>'row',
          CASE
            WHEN jsonb_typeof(o->'seat_numbers') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(o->'seat_numbers'))
            ELSE NULL
          END,
          o->>'status',
          NULLIF(o->>'quantity','')::int,
          NULLIF(o->>'total','')::numeric,
          o->>'notes',
          NULLIF(COALESCE(o->>'order_date', o->>'created_at', o->>'createdAt'), '')::timestamptz,
          now(), now(), o
        FROM src
        WHERE COALESCE(o->>'order_number', o->>'orderId', o->>'id') IS NOT NULL
        ON CONFLICT (tp_order_id) DO UPDATE SET
          event_name   = EXCLUDED.event_name,
          event_date   = EXCLUDED.event_date,
          section      = EXCLUDED.section,
          row          = EXCLUDED.row,
          seat_numbers = EXCLUDED.seat_numbers,
          status       = EXCLUDED.status,
          quantity     = EXCLUDED.quantity,
          total        = EXCLUDED.total,
          notes        = EXCLUDED.notes,
          ordered_at   = COALESCE(EXCLUDED.ordered_at, public.tickpick_orders.ordered_at),
          last_seen_at = now(),
          raw          = EXCLUDED.raw
        RETURNING 1
      )
      SELECT count(*) INTO v_inserted FROM ins;
      v_orders_persisted := v_orders_persisted + v_inserted;

      UPDATE public.tickpick_orders_pending
        SET resolved_at = now(), rows_persisted = v_inserted
        WHERE id = r.pending_id;
    ELSE
      -- Non-200 (likely 401 while token is rotating) — mark resolved with
      -- a sentinel so the queue doesn't loop, but don't blow up.
      UPDATE public.tickpick_orders_pending
        SET resolved_at = now(), rows_persisted = -1
        WHERE id = r.pending_id;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_orders_persisted;
END;
$$;

-- ============================================================
-- pg_cron schedules
--   Queue at :00 + :30; process 5 minutes later so net._http_response
--   has time to come back. Same offset pattern as evo_orders.
-- ============================================================

SELECT cron.schedule(
  'tickpick_orders_queue_30min',
  '*/30 * * * *',
  'SELECT public.tickpick_orders_queue(1);'
);

SELECT cron.schedule(
  'tickpick_orders_process_30min',
  '5-59/30 * * * *',
  'SELECT public.tickpick_orders_process();'
);
