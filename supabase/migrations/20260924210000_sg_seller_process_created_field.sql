-- Migration 20260924210000 · level:data-collection · lane:D7 · writes:seatgeek_orders,sg_seller_process · reads:net._http_response · pre:20260911080000
--
-- Already applied to prod · via MCP 2026-09-24 under operator direction.
-- ============================================================================
-- Migration 20260924210000 — seatgeek_orders.created_at_sg: read the field
--                            SellerDirect actually sends ("created"), backfill
--
-- Lane:     D7 (operator-directed; sg_seller_process is A1's order ingest —
--           flagged with the measurement in bot_chat #4352)
-- Touches:  sg_seller_process() — one anchored token in the orders INSERT;
--           seatgeek_orders (W: one-shot backfill of created_at_sg from raw)
-- Pre-reqs: 20260911080000 (tail-page pull), 20260515370000
--
-- READ-ONLY upstream: nothing fires; this only reads what already landed.
--
-- ── WHAT WAS TRUE BEFORE ───────────────────────────────────────────────────
-- The orders drain maps created_at_sg from o->>'created_at'. SellerDirect
-- /orders sends the field as "created" ("2026-09-22T20:05:02.427327"), so
-- every row landed by the tail-page pull (20260911080000) has a NULL creation
-- date: 6,757 of 7,157 rows on 2026-09-24, all of them with raw->>'created'
-- present. The 400 rows that DO carry a date came from an older response
-- shape. Consequence: max(created_at_sg) reads 2025-06-02 and makes the pull
-- look stale when it is not (pages 31/32 of `confirmed` today hold orders
-- created 9/18–9/22; 10 of 25 open SeatGeek N2S orders are in the book).
--
-- ── THE FIX ────────────────────────────────────────────────────────────────
-- 1. The INSERT reads COALESCE(o->>'created', o->>'created_at') — both shapes.
-- 2. One-shot backfill: created_at_sg := raw->>'created' where NULL. The raw
--    column already holds the full order object, so no fetch is needed.
-- The ON CONFLICT branch is left alone: created_at_sg is set on first insert
-- and a creation date does not change, so re-upserts need not touch it.
-- Anchored self-asserting edit; skips with a NOTICE on re-run.
-- ============================================================================

DO $do$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('public.sg_seller_process()'::regprocedure);
  IF position('COALESCE(o->>''created'', o->>''created_at'')' in d) > 0 THEN
    RAISE NOTICE 'sg_seller_process already reads the created field — skipping the body edit';
  ELSE
    a := 'NULLIF(o->>''created_at'','''')::timestamptz';
    IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN
      RAISE EXCEPTION 'anchor (created_at expression) not found exactly once — body drifted, re-derive 20260924210000';
    END IF;
    d := replace(d, a, 'NULLIF(COALESCE(o->>''created'', o->>''created_at''),'''')::timestamptz');
    EXECUTE d;
  END IF;

  d := pg_get_functiondef('public.sg_seller_process()'::regprocedure);
  IF position('COALESCE(o->>''created'', o->>''created_at'')' in d) = 0 THEN
    RAISE EXCEPTION 'post-apply check failed: created field not read';
  END IF;
END $do$;

-- One-shot backfill from the raw object already on the row (idempotent: only NULLs).
UPDATE public.seatgeek_orders
   SET created_at_sg = (raw->>'created')::timestamptz
 WHERE created_at_sg IS NULL
   AND raw->>'created' ~ '^\d{4}-\d{2}-\d{2}T';

COMMENT ON COLUMN public.seatgeek_orders.created_at_sg IS
  'Order creation time at SeatGeek. Read from the SellerDirect "created" field (or the older "created_at") since 20260924210000; rows landed 2026-09-11..24 by the tail-page pull were backfilled from raw by the same migration.';
