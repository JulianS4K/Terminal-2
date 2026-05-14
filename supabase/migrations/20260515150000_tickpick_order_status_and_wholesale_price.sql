-- Migration 20260515150000 · level:admin · lane:Audit/Push · writes:ADD COLUMN order_status, backfill 909 rows, CREATE OR REPLACE RPC · reads:- · pre:20260515120000
-- TickPick column-mapping fix discovered during first 909-order Apps
-- Script sync (2026-05-14 20:46 UTC).
--
-- TickPick's /1.0/orders response shape:
--   • raw.status        = EVENT lifecycle: "Scheduled" / "Rescheduled" / "Canceled"
--   • raw.order_status  = ORDER lifecycle: "CONFIRMED" / "COMPLETED" / "REJECTED"
--   • raw.wholesale_price = seller payout (the original v0 RPC pulled `o->>'total'`
--                           which doesn't exist in TickPick's payload, so all 909
--                           backfilled rows have NULL `total`)
--
-- The operator's Apps Script v2 email-checker (checkTickPickOrderStatus)
-- already established that `order_status` is the canonical state for
-- determining COMPLETED/REJECTED, while `status` is the event-lifecycle
-- field used for cancellation detection. Keep both columns.
--
-- Changes:
-- 1. ADD COLUMN tickpick_orders.order_status text
-- 2. Backfill order_status = raw->>'order_status' on existing 909 rows
-- 3. Backfill total = (raw->>'wholesale_price')::numeric on existing rows
--    where total IS NULL
-- 4. CREATE OR REPLACE the ingest RPC to map order_status + wholesale_price
--    correctly on future inserts
-- 5. COMMENT both `status` and `order_status` columns to disambiguate
--
-- ## Already applied to prod
-- Applied via MCP at 2026-05-14 (this session). Idempotent.

-- 1. New column
ALTER TABLE public.tickpick_orders
  ADD COLUMN IF NOT EXISTS order_status text;

-- 2 + 3. Backfill existing 909 rows
UPDATE public.tickpick_orders
   SET order_status = raw->>'order_status',
       total        = COALESCE(total, NULLIF(raw->>'wholesale_price','')::numeric)
 WHERE raw IS NOT NULL
   AND (order_status IS NULL OR total IS NULL);

-- 5. Column comments documenting the dual-status convention
COMMENT ON COLUMN public.tickpick_orders.status IS
  'TickPick raw.status — EVENT lifecycle ("Scheduled"/"Rescheduled"/"Canceled"). '
  'Used by Apps Script email-checker (checkTickPickOrderStatus) to detect canceled events. '
  'For order-completion state, see order_status.';

COMMENT ON COLUMN public.tickpick_orders.order_status IS
  'TickPick raw.order_status — ORDER lifecycle ("CONFIRMED"/"COMPLETED"/"REJECTED"). '
  'Canonical state for unified_orders rollups. Added 2026-05-14 after first Apps Script sync revealed schema gap.';

COMMENT ON COLUMN public.tickpick_orders.total IS
  'Seller payout amount. Populated from TickPick raw.wholesale_price '
  '(TickPick has no top-level `total` field — original RPC mapped to `total` directly which always returned NULL).';

-- 4. RPC with corrected field mapping
CREATE OR REPLACE FUNCTION public.tickpick_orders_ingest_from_apps_script(
  p_orders        jsonb,
  p_shared_secret text
)
RETURNS TABLE(inserted integer, updated integer, skipped integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public', 'pg_temp'
AS $$
DECLARE
  v_expected_secret text;
  v_total           int;
  v_inserted        int := 0;
  v_updated         int := 0;
  v_skipped         int := 0;
BEGIN
  v_expected_secret := get_app_secret('APPSCRIPT_INGEST_SECRET');
  IF v_expected_secret IS NULL OR v_expected_secret = '' THEN
    RAISE EXCEPTION 'APPSCRIPT_INGEST_SECRET unset in vault' USING ERRCODE = '42501';
  END IF;
  IF p_shared_secret IS NULL OR p_shared_secret <> v_expected_secret THEN
    RAISE EXCEPTION 'unauthorized: shared secret mismatch' USING ERRCODE = '42501';
  END IF;

  IF jsonb_typeof(p_orders) <> 'array' THEN
    RAISE EXCEPTION 'p_orders must be a JSON array' USING ERRCODE = '22P02';
  END IF;

  v_total := jsonb_array_length(p_orders);
  IF v_total = 0 THEN
    RETURN QUERY SELECT 0, 0, 0;
    RETURN;
  END IF;

  WITH src AS (
    SELECT o FROM jsonb_array_elements(p_orders) AS o
  ),
  upserted AS (
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
      o->>'status',                                                       -- event lifecycle
      o->>'order_status',                                                 -- order lifecycle (NEW)
      NULLIF(o->>'quantity','')::int,
      NULLIF(o->>'wholesale_price','')::numeric,                          -- was o->>'total'
      o->>'notes',
      NULLIF(COALESCE(o->>'purchase_date', o->>'confirm_date', o->>'order_date'), '')::timestamptz,
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
      total        = EXCLUDED.total,
      notes        = EXCLUDED.notes,
      ordered_at   = COALESCE(EXCLUDED.ordered_at, public.tickpick_orders.ordered_at),
      last_seen_at = now(),
      raw          = EXCLUDED.raw
    RETURNING (xmax = 0) AS is_new
  )
  SELECT
    count(*) FILTER (WHERE is_new)        ::int,
    count(*) FILTER (WHERE NOT is_new)    ::int
  INTO v_inserted, v_updated
  FROM upserted;

  v_skipped := v_total - v_inserted - v_updated;

  RETURN QUERY SELECT v_inserted, v_updated, v_skipped;
END;
$$;
