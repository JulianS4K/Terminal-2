-- ============================================================================
-- A1.1 — seatgeek_sales_snapshots.tevo_event_id backfill enablement
--
-- Closes D0 audit proposal A1.1 (bot_chat 251/262/266).
--
-- Before this migration:
--   - seatgeek_sales_snapshots.tevo_event_id was 0.03% populated (365 of 1.3M)
--   - D2's v_sg_broker_sales_by_event view (mig 20260516220100) GROUP BYs on
--     tevo_event_id → 99% of event-grouped aggregates collapsed to NULL row
--   - Old UNIQUE(tevo_event_id, sg_sale_id) constraint only enforced on the
--     365 non-NULL rows (NULLs aren't equal in unique index), so 32,627 truly
--     identical rows existed across the table from ingest pipeline writing
--     the same (sg_event_id, sg_sale_id, pulled_at) tuple 2-3 times within
--     the same microsecond of a pulled_at batch.
--
-- This migration:
--   1. Dedups truly-identical rows (keep MIN(id) per natural key). Verified
--      safe: all duplicate rows share IDENTICAL (sg_event_id, sg_sale_id,
--      pulled_at, broadcast_price, quantity, section, sale_at_utc, ...) —
--      only id differs. Pre-flight count: 32,627 rows to delete.
--   2. Drops old UNIQUE constraint seatgeek_sales_dedup. Verified safe via
--      pg_depend: 0 functional / FK / view dependencies on it.
--   3. Adds new UNIQUE INDEX seatgeek_sales_dedup_v2 on (sg_event_id,
--      sg_sale_id, pulled_at) — the natural key for SG broker sales ingest.
--   4. BEFORE INSERT trigger trg_sg_sales_populate_tevo_event_id auto-
--      populates tevo_event_id from seatgeek_event_xref on all new rows.
--      Confirmed working via post-apply smoke test (Inter Miami sg_event_id
--      17921050 → tevo_event_id 3222237 populated correctly).
--   5. backfill_seatgeek_sales_tevo_event_id(p_chunk_size) function for
--      chunked historical backfill. Post-apply ran 5 chunks totaling
--      1,139,091 row updates → 87.35% column coverage (the remaining 13%
--      are sg_event_ids with no xref entry yet; will populate via trigger
--      as the search bridge keeps linking events).
--
-- Verified post-apply:
--   - seatgeek_sales_dedup_v2 index PRESENT
--   - old seatgeek_sales_dedup constraint GONE (count=0)
--   - trg_sg_sales_populate_tevo_event_id trigger PRESENT
--   - synthetic insert test: NULL → 3222237 via trigger
--   - v_sg_broker_sales_by_event: 60% of event rows now have tevo_event_id
--     populated (was ~0%)
--
-- Unblocks: D2's two broker-sales views + arbitrage view + any future
-- per-event SG sales analytics.
-- ============================================================================

-- 1. Dedup
WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY sg_event_id, sg_sale_id, pulled_at ORDER BY id
  ) AS rn
  FROM public.seatgeek_sales_snapshots
)
DELETE FROM public.seatgeek_sales_snapshots
WHERE id IN (SELECT id FROM ranked WHERE rn > 1);

-- 2. Drop old unique constraint (which owns the index)
ALTER TABLE public.seatgeek_sales_snapshots DROP CONSTRAINT IF EXISTS seatgeek_sales_dedup;

-- 3. New natural-key unique index
CREATE UNIQUE INDEX IF NOT EXISTS seatgeek_sales_dedup_v2
  ON public.seatgeek_sales_snapshots(sg_event_id, sg_sale_id, pulled_at);

COMMENT ON INDEX public.seatgeek_sales_dedup_v2 IS
  'Natural-key dedup for SG broker sales firehose. Each (sg_event_id, sg_sale_id, pulled_at) is one observation row. A1.1 2026-05-16: replaced old (tevo_event_id, sg_sale_id) which only enforced on 0.03% of rows.';

-- 4. BEFORE INSERT trigger — auto-populate tevo_event_id from xref on new rows
CREATE OR REPLACE FUNCTION public.trg_sg_sales_populate_tevo_event_id()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $func$
BEGIN
  IF NEW.tevo_event_id IS NULL AND NEW.sg_event_id IS NOT NULL THEN
    SELECT sgx.tevo_event_id INTO NEW.tevo_event_id
    FROM public.seatgeek_event_xref sgx
    WHERE sgx.sg_event_id = NEW.sg_event_id LIMIT 1;
  END IF;
  RETURN NEW;
END $func$;

DROP TRIGGER IF EXISTS trg_sg_sales_populate_tevo_event_id ON public.seatgeek_sales_snapshots;
CREATE TRIGGER trg_sg_sales_populate_tevo_event_id
  BEFORE INSERT ON public.seatgeek_sales_snapshots
  FOR EACH ROW EXECUTE FUNCTION public.trg_sg_sales_populate_tevo_event_id();

-- 5. Chunked backfill helper (idempotent — re-runnable for any new sg_event_ids
--    that get xref'd later but predate the trigger)
CREATE OR REPLACE FUNCTION public.backfill_seatgeek_sales_tevo_event_id(p_chunk_size int DEFAULT 100000)
RETURNS TABLE(rows_updated int, rows_remaining int)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE v_updated int := 0; v_remaining int;
BEGIN
  WITH to_update AS (
    SELECT s.id, sgx.tevo_event_id
    FROM public.seatgeek_sales_snapshots s
    JOIN public.seatgeek_event_xref sgx ON sgx.sg_event_id = s.sg_event_id
    WHERE s.tevo_event_id IS NULL
    LIMIT p_chunk_size
  ),
  upd AS (
    UPDATE public.seatgeek_sales_snapshots s
    SET tevo_event_id = tu.tevo_event_id
    FROM to_update tu
    WHERE s.id = tu.id
    RETURNING s.id
  )
  SELECT count(*)::int INTO v_updated FROM upd;

  SELECT count(*)::int INTO v_remaining
  FROM public.seatgeek_sales_snapshots s
  WHERE s.tevo_event_id IS NULL
    AND EXISTS (SELECT 1 FROM public.seatgeek_event_xref sgx WHERE sgx.sg_event_id = s.sg_event_id);

  RETURN QUERY SELECT v_updated, v_remaining;
END $func$;

REVOKE EXECUTE ON FUNCTION public.backfill_seatgeek_sales_tevo_event_id(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.backfill_seatgeek_sales_tevo_event_id(int) TO service_role;
