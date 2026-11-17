-- Migration 20261110060000 · level:data-collection · lane:A1 · writes:tickpick_orders_process,tickpick_orders · reads:tickpick_orders_pending,net._http_response · pre:20261110050000
--
-- TickPick order sync: map the fields TickPick actually sends (operator 2026-11-10: "fix the
-- tickpick field mapping").
--
-- tickpick_orders_process() (the cron path, resumed by 20261110050000) read `order_date` /
-- `created_at` for ordered_at and `total` for total. TickPick's GET /1.0/orders sends neither:
-- it sends `purchase_date` and a per-order `wholesale_price`, so the 1,778 orders pulled on
-- 2026-11-09 23:20 UTC landed with ordered_at and total NULL. The Apps Script ingest
-- (tickpick_orders_ingest_from_apps_script), which filled this table until 2026-05-31, already
-- maps them correctly; the cron path now uses the same mapping, so both paths write the same row:
--   event_date   ← event_date_utc, else event_date
--   order_status ← order_status            (was not written by the cron path)
--   total        ← wholesale_price          (as the Apps Script path; old rows agree)
--   ordered_at   ← purchase_date, else confirm_date, else order_date / created_at
-- Then rows already pulled get their NULL total / ordered_at / order_status from their own raw.
-- GET-only ingest is unchanged (tickpick_orders_queue is not touched).
--
-- rollback: re-create tickpick_orders_process() from its previous definition (old mapping);
--           the backfilled values are correct and need no rollback.

CREATE OR REPLACE FUNCTION public.tickpick_orders_process()
 RETURNS TABLE(processed integer, orders_persisted integer)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
          status, order_status, quantity, total, notes, ordered_at,
          pulled_at, last_seen_at, raw
        )
        SELECT
          COALESCE(o->>'order_number', o->>'orderId', o->>'id')::text,
          o->>'event_name',
          NULLIF(COALESCE(o->>'event_date_utc', o->>'event_date'), '')::timestamptz,
          o->>'section',
          o->>'row',
          CASE
            WHEN jsonb_typeof(o->'seat_numbers') = 'array'
              THEN ARRAY(SELECT jsonb_array_elements_text(o->'seat_numbers'))
            ELSE NULL
          END,
          o->>'status',
          o->>'order_status',
          NULLIF(o->>'quantity','')::int,
          NULLIF(COALESCE(o->>'wholesale_price', o->>'total'), '')::numeric,
          o->>'notes',
          NULLIF(COALESCE(o->>'purchase_date', o->>'confirm_date', o->>'order_date', o->>'created_at', o->>'createdAt'), '')::timestamptz,
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
          order_status = EXCLUDED.order_status,
          quantity     = EXCLUDED.quantity,
          total        = COALESCE(EXCLUDED.total, public.tickpick_orders.total),
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
      UPDATE public.tickpick_orders_pending
        SET resolved_at = now(), rows_persisted = -1
        WHERE id = r.pending_id;
    END IF;
  END LOOP;

  RETURN QUERY SELECT v_processed, v_orders_persisted;
END;
$function$;

-- Fill the rows the old mapping left empty, from each row's own raw TickPick payload.
UPDATE public.tickpick_orders
   SET total        = COALESCE(total, NULLIF(raw->>'wholesale_price', '')::numeric),
       ordered_at   = COALESCE(ordered_at, NULLIF(COALESCE(raw->>'purchase_date', raw->>'confirm_date'), '')::timestamptz),
       order_status = COALESCE(order_status, raw->>'order_status'),
       event_date   = COALESCE(NULLIF(raw->>'event_date_utc', '')::timestamptz, event_date)
 WHERE raw IS NOT NULL
   AND (total IS NULL OR ordered_at IS NULL OR order_status IS NULL);
