-- ============================================================================
-- Migration 20260910040000 — N2S: EVO order-key split, 2-minute poll, and a
--                            precise "new order" signal
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_items (ADD COLUMN n2s_order_key GENERATED, notified_at)
--           n2s_items_queue() (pile-up guard), crons 593/594 rescheduled
-- Pre-reqs: 20260910030000
--
-- READ-ONLY upstream: GET /api/v1/n2s/items only. RULE 2 holds.
--
-- Operator direction 2026-09-09: "poll crm every 2 minutes and only ping the
-- new orders. do the evo split also."
--
-- ── 1. The EVO split, verified rather than assumed ─────────────────────────
-- N2S spells a Ticket Evolution order `8046287-19081243`. Which half is ours
-- was MEASURED against all 17 live EVO items, not inferred from magnitude:
--
--   part 1 (`8046287`)  -> 0/17 in evo_orders, 0/17 in evo_order_items
--   part 2 (`19081243`) -> 17/17 in evo_orders, 17/17 in evo_order_items
--
-- So the key is `split_part(order_number, '-', 2)`. Part 1 is some other TEvo
-- identifier and is kept verbatim in `order_number`; nothing joins on it.
--
-- `n2s_order_key` is a GENERATED STORED column rather than something the drain
-- writes, so it cannot drift out of step with `order_number` and needs no
-- backfill on future ingest changes. Every non-EVO marketplace's order_number
-- is already the exact string our feed stores (verified by shape on live
-- samples), so they pass through unchanged.
--
-- ⚠ THE SPLIT DOES NOT RESCUE THE OTHER FOUR SOURCES, and it was never going
-- to. Re-measured against s4kcs_orders AND vivid_orders AND gotickets_sales
-- AND seatgeek_orders AND tickpick_orders: Vivid 0/99, TickPick 0/88,
-- GoTickets 0/43, SeatGeek 0/13 — genuinely in no book we hold, because they
-- are FAILED orders and the seller books carry only orders that processed.
-- With the split, matched goes 152 -> 169 of 432. The remaining 263 do not
-- need our order book: N2S itself carries event, venue, section, row, qty and
-- an explicit price_per_ticket. What they lack is a tevo_event_id, which is
-- an event-mapping problem, NOT an order-matching one.
--
-- ── 2. Two-minute poll ─────────────────────────────────────────────────────
-- The N2S timer is 15 minutes and 137 of 137 open automated items had already
-- blown it when first measured, so poll latency is the thing that matters.
--
-- ⚠ ALL THREE PAGES ARE POLLED EVERY CYCLE — "new items are on page 1" IS
-- FALSE HERE. The feed's default sort is neither id- nor created-descending:
-- `offset=0` returned id 420 first, while the newest row by both id and
-- created_at is 474. Polling only the first page would therefore miss new
-- arrivals unpredictably. Three pages every two minutes is 90 requests/hour
-- against a documented 120/minute limit — not close.
--
-- ⚠ THE "NEW ORDER" SIGNAL IS `pulled_at`, NOT PAGE POSITION. The drain's
-- upsert sets `pulled_at` only on INSERT and touches only `last_seen_at` on
-- conflict, so `pulled_at` is exactly "first time we ever saw this item",
-- independent of where it appeared in the feed. `notified_at` then records
-- what has already been pinged, so a ping fires once per item and a restart
-- or a re-poll cannot re-announce the same order.
--
-- ⚠ PILE-UP GUARD. pg_net is async and its worker backlogs 1-3 minutes under
-- load; a 2-minute queue cadence can therefore outrun the drain. The queue
-- now refuses to add work when unresolved requests are already stacked, so a
-- slow upstream degrades into "polls less often" instead of an unbounded
-- request queue. 60s timeouts were observed live at limit=1000, so this is a
-- real failure mode, not a theoretical one.
-- ============================================================================

-- ── EVO split as a generated column ────────────────────────────────────────
ALTER TABLE public.n2s_items
  ADD COLUMN IF NOT EXISTS n2s_order_key text
    GENERATED ALWAYS AS (
      CASE WHEN s4k_source = 'EVO' AND order_number LIKE '%-%'
           THEN split_part(order_number, '-', 2)
           ELSE order_number
      END
    ) STORED;

-- ── which items have already been pinged ───────────────────────────────────
ALTER TABLE public.n2s_items
  ADD COLUMN IF NOT EXISTS notified_at timestamptz;

CREATE INDEX IF NOT EXISTS n2s_items_order_key_idx ON public.n2s_items (n2s_order_key);
CREATE INDEX IF NOT EXISTS n2s_items_unnotified_idx
  ON public.n2s_items (pulled_at) WHERE notified_at IS NULL AND NOT is_terminal;

COMMENT ON COLUMN public.n2s_items.n2s_order_key IS
  'The order id in OUR namespace: for EVO the second half of the composite '
  'N2S order_number (verified 17/17 against evo_orders; the first half hits '
  'nothing), otherwise order_number verbatim. Join this to '
  'v_sub_orders.order_id, never order_number.';

COMMENT ON COLUMN public.n2s_items.notified_at IS
  'When this item was pinged. NULL = never pinged. Set by the ping so an item '
  'is announced once, surviving restarts and re-polls.';

-- ── queue gains a pile-up guard ────────────────────────────────────────────
-- ⚠ DROP THE 2-ARG FORM FIRST. Adding p_max_inflight creates an OVERLOAD, not
-- a replacement, and then `n2s_items_queue(150, 0)` -- exactly what the cron
-- calls -- is ambiguous between the 2-arg function and the 3-arg one taking
-- its default, which Postgres rejects at call time with "function is not
-- unique". The unguarded original must go, not merely be shadowed.
DROP FUNCTION IF EXISTS public.n2s_items_queue(integer, integer);

CREATE OR REPLACE FUNCTION public.n2s_items_queue(
  p_limit  integer DEFAULT 150,
  p_offset integer DEFAULT 0,
  p_max_inflight integer DEFAULT 9
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','net','vault','pg_temp'
AS $function$
DECLARE
  v_key       text := btrim(COALESCE(public.get_app_secret('crm.s4kcs.com/n2s'), ''));
  v_qs        text := format('?limit=%s&offset=%s', p_limit, p_offset);
  v_req       bigint;
  v_inflight  integer;
BEGIN
  IF v_key = '' THEN
    RAISE NOTICE 'crm.s4kcs.com/n2s vault secret unset; skipping queue';
    RETURN NULL;
  END IF;

  -- Degrade to "poll less often" rather than stacking requests forever.
  SELECT count(*) INTO v_inflight
    FROM public.n2s_items_pending WHERE resolved_at IS NULL;
  IF v_inflight >= p_max_inflight THEN
    RAISE NOTICE 'n2s: % requests already in flight; skipping this cycle', v_inflight;
    RETURN NULL;
  END IF;

  SELECT net.http_get(
    url := 'https://crm.s4kcs.com/api/v1/n2s/items' || v_qs,
    headers := jsonb_build_object('X-API-Key', v_key, 'Accept', 'application/json'),
    timeout_milliseconds := 60000
  ) INTO v_req;

  INSERT INTO public.n2s_items_pending(request_id, query_str) VALUES (v_req, v_qs);
  RETURN v_req;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_items_queue(integer,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_items_queue(integer,integer,integer) TO service_role;

-- ── 2-minute cadence; drain on the odd minutes so it trails the queue ──────
SELECT cron.unschedule('n2s_items_sync_10min');
SELECT cron.unschedule('n2s_items_drain_10min');

SELECT cron.schedule(
  'n2s_items_sync_2min', '*/2 * * * *',
  $cron$
    SELECT public.n2s_items_queue(150, 0);
    SELECT public.n2s_items_queue(150, 150);
    SELECT public.n2s_items_queue(150, 300);
  $cron$
);

-- Drains every 2 minutes on the ODD minutes: one minute behind the queue, and
-- because it loops over every unresolved row it self-heals whenever pg_net
-- takes longer than a single cycle.
SELECT cron.schedule(
  'n2s_items_drain_2min', '1-59/2 * * * *',
  $cron$ SELECT public.n2s_items_drain(); $cron$
);
