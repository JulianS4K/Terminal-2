-- ============================================================================
-- Migration 20260910360000 — profitable covers as a Realtime table
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_profitable_cover (NEW table, RLS + policy + grants + Realtime),
--           n2s_profitable_cover_sync() (NEW), cron n2s_cover_queue_refresh
--           (command gains the sync call).
-- Pre-reqs: 20260910350000
--
-- READ-ONLY upstream: no API call at all. RULE 2 untouched.
--
-- Operator direction 2026-09-10, choosing the destination for the profitable-
-- cover feed: "Use supabase, maybe public table or SQL or similar?"
--
-- ── WHY THIS BEATS THE WEBHOOK FOR THIS CASE ──────────────────────────────
-- The webhook (20260910350000) needs an endpoint the operator owns, and it can
-- fail in all the ways delivery fails: receiver down, retries, duplicates. A
-- Supabase table needs none of that and is still genuinely real-time, because
-- Supabase Realtime streams row changes over a websocket. The consumer
-- subscribes; no URL, no inbound firewall hole, no delivery state to reconcile.
--
-- It is also strictly more useful than a webhook alone: the same table answers
-- "what is profitable RIGHT NOW" on a plain REST read, which a webhook cannot
-- do at all — a missed webhook is simply gone.
--
-- The webhook is left in place and inert (no URL secret set). The two are
-- complementary and neither depends on the other.
--
-- ── ⚠ WHY A TABLE AND NOT A VIEW ──────────────────────────────────────────
-- Realtime replicates WAL, and a view produces no WAL of its own — publishing
-- one is impossible. v_n2s_orders therefore cannot be the feed no matter how
-- convenient it looks; the rows have to be materialised.
--
-- ── ⚠ THE SYNC IS A DIFF, NOT A REBUILD ───────────────────────────────────
-- The obvious implementation — DELETE all, INSERT all, once a minute — would
-- emit a delete+insert for every row every minute, so a subscriber would see
-- constant churn and could never tell a real change from a rewrite. Realtime
-- would be technically working and practically useless.
--
-- So this writes only genuine differences: new covers INSERT, changed covers
-- UPDATE (the ON CONFLICT carries an IS DISTINCT FROM guard, so an identical
-- row is not rewritten and emits nothing), and covers that stopped being
-- profitable DELETE. A quiet minute produces zero WAL and zero events, which
-- is what makes an event meaningful when one does arrive.
--
-- ⚠ REPLICA IDENTITY FULL is required for DELETE events to carry the row that
-- went away. With the default (primary key only) a subscriber learns an
-- n2s_id vanished but not which order it was — useless for un-flagging
-- something already shown to a human.
--
-- ── SECURITY ──────────────────────────────────────────────────────────────
-- This table carries order numbers, prices and buy links, so it follows the
-- house pattern rather than being convenient: RLS ON, a SELECT policy for
-- `authenticated` only, and NO grant to `anon`. service_role bypasses RLS as
-- usual for the writer. Realtime enforces the same RLS on subscriptions, so a
-- subscriber sees exactly what a REST read would.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.n2s_profitable_cover (
  n2s_id           bigint PRIMARY KEY,
  order_number     text        NOT NULL,
  order_key        text,
  marketplace      text,
  event_name       text,
  event_date       date,
  venue            text,
  tevo_event_id    bigint,
  sold_section     text,
  sold_row         text,
  sold_qty         integer,
  sold_price_each  numeric,
  sub_source       text,
  sub_listing_id   text,
  sub_section      text,
  sub_row          text,
  sub_qty          integer,
  sub_lot_size     integer,
  sub_price_each   numeric,
  sub_total        numeric,
  buy_url          text,
  profit           numeric     NOT NULL,
  first_seen_at    timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.n2s_profitable_cover IS
  'Live feed of open obligations whose cover settles BELOW the sale price. '
  'Maintained as a DIFF by n2s_profitable_cover_sync() so Realtime emits only '
  'genuine changes; published to supabase_realtime. profit is positive money '
  'kept (the negation of cover_cost). See migration 20260910360000.';
COMMENT ON COLUMN public.n2s_profitable_cover.sub_qty IS
  'How many tickets to BUY. Exceeds sold_qty on an over-delivery cover, where '
  'no listing sold the owed quantity and a larger lot was taken whole.';

ALTER TABLE public.n2s_profitable_cover ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS n2s_profitable_cover_sel ON public.n2s_profitable_cover;
CREATE POLICY n2s_profitable_cover_sel
  ON public.n2s_profitable_cover FOR SELECT TO authenticated USING (true);

REVOKE ALL ON public.n2s_profitable_cover FROM anon;
GRANT SELECT ON public.n2s_profitable_cover TO authenticated, service_role;

-- DELETE events must carry the departed row, not just its key.
ALTER TABLE public.n2s_profitable_cover REPLICA IDENTITY FULL;

DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_rel r
      JOIN pg_publication p ON p.oid = r.prpubid
      JOIN pg_class c ON c.oid = r.prrelid
     WHERE p.pubname = 'supabase_realtime' AND c.relname = 'n2s_profitable_cover'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.n2s_profitable_cover;
  END IF;
END $do$;

CREATE OR REPLACE FUNCTION public.n2s_profitable_cover_sync()
RETURNS TABLE(inserted integer, updated integer, deleted integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ins int := 0; v_upd int := 0; v_del int := 0;
BEGIN
  WITH src AS (
    SELECT v.n2s_id, v.order_number, v.n2s_order_key, v.s4k_source,
           v.event_name, v.event_date, v.venue, v.tevo_event_id,
           v.section, v.order_row, v.quantity, v.sold_ea,
           v.sub_source, v.sub_listing_id, v.sub_section, v.sub_row,
           v.sub_qty, v.sub_avail, v.sub_ea, v.sub_total, v.buy_url,
           round(-v.cover_cost, 2) AS profit
      FROM public.v_n2s_orders v
     WHERE v.has_cover AND v.cover_cost < 0
  ),
  gone AS (
    DELETE FROM public.n2s_profitable_cover t
     WHERE NOT EXISTS (SELECT 1 FROM src s WHERE s.n2s_id = t.n2s_id)
    RETURNING 1
  ),
  ups AS (
    INSERT INTO public.n2s_profitable_cover AS t (
      n2s_id, order_number, order_key, marketplace, event_name, event_date,
      venue, tevo_event_id, sold_section, sold_row, sold_qty, sold_price_each,
      sub_source, sub_listing_id, sub_section, sub_row, sub_qty, sub_lot_size,
      sub_price_each, sub_total, buy_url, profit)
    SELECT n2s_id, order_number, n2s_order_key, s4k_source, event_name,
           event_date, venue, tevo_event_id, section, order_row, quantity,
           sold_ea, sub_source, sub_listing_id, sub_section, sub_row, sub_qty,
           sub_avail, sub_ea, sub_total, buy_url, profit
      FROM src
    ON CONFLICT (n2s_id) DO UPDATE SET
      order_number = EXCLUDED.order_number, order_key = EXCLUDED.order_key,
      marketplace = EXCLUDED.marketplace, event_name = EXCLUDED.event_name,
      event_date = EXCLUDED.event_date, venue = EXCLUDED.venue,
      tevo_event_id = EXCLUDED.tevo_event_id,
      sold_section = EXCLUDED.sold_section, sold_row = EXCLUDED.sold_row,
      sold_qty = EXCLUDED.sold_qty, sold_price_each = EXCLUDED.sold_price_each,
      sub_source = EXCLUDED.sub_source, sub_listing_id = EXCLUDED.sub_listing_id,
      sub_section = EXCLUDED.sub_section, sub_row = EXCLUDED.sub_row,
      sub_qty = EXCLUDED.sub_qty, sub_lot_size = EXCLUDED.sub_lot_size,
      sub_price_each = EXCLUDED.sub_price_each, sub_total = EXCLUDED.sub_total,
      buy_url = EXCLUDED.buy_url, profit = EXCLUDED.profit,
      updated_at = now()
    -- ⚠ The guard that keeps Realtime meaningful: an identical row is not
    -- rewritten, so a quiet minute emits nothing at all.
    WHERE (t.sub_source, t.sub_listing_id, t.sub_section, t.sub_row,
           t.sub_qty, t.sub_price_each, t.buy_url, t.profit)
       IS DISTINCT FROM
          (EXCLUDED.sub_source, EXCLUDED.sub_listing_id, EXCLUDED.sub_section,
           EXCLUDED.sub_row, EXCLUDED.sub_qty, EXCLUDED.sub_price_each,
           EXCLUDED.buy_url, EXCLUDED.profit)
    RETURNING (xmax = 0) AS was_insert
  )
  SELECT (SELECT count(*) FROM ups WHERE was_insert)::int,
         (SELECT count(*) FROM ups WHERE NOT was_insert)::int,
         (SELECT count(*) FROM gone)::int
    INTO v_ins, v_upd, v_del;

  RETURN QUERY SELECT COALESCE(v_ins,0), COALESCE(v_upd,0), COALESCE(v_del,0);
END $function$;

REVOKE ALL ON FUNCTION public.n2s_profitable_cover_sync() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_profitable_cover_sync() TO service_role;

-- Chained onto the cover refresh so the feed changes in the same tick the
-- cover does, rather than up to a minute later on a separate schedule.
DO $do$
DECLARE v_id bigint;
BEGIN
  SELECT jobid INTO v_id FROM cron.job WHERE jobname = 'n2s_cover_queue_refresh_2min';
  IF v_id IS NOT NULL THEN
    PERFORM cron.alter_job(
      v_id,
      command := $cmd$ SELECT public.n2s_cover_queue_refresh(); SELECT public.n2s_profitable_cover_sync(); $cmd$);
  END IF;
END $do$;
