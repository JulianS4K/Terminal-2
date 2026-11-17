-- ============================================================================
-- Migration 20260910050000 — N2S sub offers + the ping
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_sub_offers() + n2s_sub_ping() (functions),
--           one cron. Writes only n2s_items.notified_at and bot_chat.
-- Pre-reqs: 20260910040000
--
-- READ-ONLY upstream: no API call at all. Pure SELECT over already-ingested
-- data plus a bot_chat row. RULE 2 untouched.
--
-- Operator direction 2026-09-09: "then create a ping that sends any subs for
-- those sales."
--
-- ── ⚠ N2S ECONOMICS ARE INVERTED, AND THIS IS THE WHOLE POINT ──────────────
-- The existing matcher defaults to `p_require_cheaper => true`, which is a
-- PROFIT rule: only offer a cover that beats what the seat sold for. Run
-- against the N2S book that returns exactly ZERO rows, and it would be easy to
-- report "no subs available" and move on. That conclusion is wrong.
--
-- Measured 2026-09-09 over the open N2S book with `p_require_cheaper => false`:
--   37 candidate rows across 19 orders
--    0 at or below what the seat sold for
--   37 cost MORE, from -$32.34 to -$2,289.88
--
-- Every available cover is a loss. That does not make it worthless: an N2S
-- order is an OBLIGATION, not an opportunity. The seat has already been sold
-- and failed to fulfil; the real comparison is the cost of covering versus the
-- cost of NOT covering (cancellation penalty, marketplace standing, the
-- customer). So this view deliberately does NOT require cheaper, reports
-- `cover_cost` rather than "margin"/"upside", and ranks CHEAPEST COVER FIRST
-- — least loss, not most gain. Re-imposing the profit filter here would
-- silently hide every real option.
--
-- ⚠ SEAT QUALITY IS NOT RELAXED. Same normalised section, row no worse, exact
-- quantity — the established rule stays. Loosening it (accepting a different
-- section for an order we owe) would find more covers, but that is a business
-- call about what the customer is owed, not a technical one, so it is left
-- alone and flagged rather than assumed.
--
-- ⚠ ONLY 169 OF 432 OPEN N2S ORDERS CAN BE PRICED AT ALL. The other 263
-- (Vivid 99, TickPick 88, GoTickets 43, SeatGeek 13) exist in NO order book we
-- hold and so have no tevo_event_id to match inventory against. They are NOT
-- absent from this view because they have no cover — they are absent because
-- they have never been event-mapped. Do not read a small offer count as
-- "little demand". Mapping those is the single biggest unlock left.
-- ============================================================================

-- ⚠ THIS IS A FUNCTION, NOT A VIEW, FOR A PERFORMANCE REASON THAT BITES HARD.
-- s4kcs_sub_candidates() with no p_event_ids runs the matcher over EVERY event
-- with an open order -- thousands. As a view, that full scan would re-run on
-- every SELECT, including once per two-minute ping cycle. Scoping to just the
-- events the open N2S book actually touches (~60) is the difference between a
-- sub-second call and one that cannot finish inside a cron budget.
CREATE OR REPLACE FUNCTION public.n2s_sub_offers(p_n2s_ids bigint[] DEFAULT NULL)
RETURNS TABLE (
  n2s_id           bigint,
  order_number     text,
  n2s_order_key    text,
  s4k_source       text,
  n2s_status       text,
  fail_reason      text,
  timer_expired    boolean,
  timer_expires_at timestamptz,
  alert_at         timestamptz,
  order_source     text,
  event_name       text,
  event_date       date,
  venue_name       text,
  tevo_event_id    bigint,
  section          text,
  order_row        text,
  quantity         integer,
  sold_ea          numeric,
  sub_source       text,
  sub_listing_id   bigint,
  sub_section      text,
  sub_row          text,
  sub_qty          integer,
  sub_ea           numeric,
  sub_total        numeric,
  cover_cost       numeric,
  rows_closer      integer,
  buy_url          text,
  captured_at      timestamptz,
  cover_rank       bigint
)
LANGUAGE sql STABLE
SET search_path TO 'public','pg_temp'
AS $$
  WITH n AS (
    SELECT i.*
      FROM public.n2s_items i
     WHERE NOT i.is_terminal
       AND (p_n2s_ids IS NULL OR i.n2s_id = ANY(p_n2s_ids))
  ),
  -- ⚠ NAME THE n2s COLUMNS EXPLICITLY -- `n.*` is ambiguous here. n2s_items
  -- carries its OWN event_name, venue, section, "row" and event_dt (the CRM's
  -- copy of the sale), which collide with the same names coming from
  -- v_sub_orders. The ORDER's values win: they are what the matcher matched
  -- against, so they are what an operator must see next to a cover.
  ord AS (
    SELECT n.n2s_id, n.order_number, n.n2s_order_key, n.s4k_source,
           n.status, n.fail_reason, n.timer_expired, n.timer_expires_at,
           n.alert_at,
           v.source AS order_source, v.event_name, v.event_date,
           v.venue_name, v.tevo_event_id, v.section, v."row" AS order_row,
           v.quantity, v.price_per_ticket AS sold_ea, v.order_id
      FROM n JOIN public.v_sub_orders v ON v.order_id = n.n2s_order_key
     WHERE v.tevo_event_id IS NOT NULL
  ),
  ev AS (SELECT array_agg(DISTINCT tevo_event_id) AS ids FROM ord)
  SELECT o.n2s_id, o.order_number, o.n2s_order_key, o.s4k_source,
         o.status, o.fail_reason, o.timer_expired, o.timer_expires_at,
         o.alert_at, o.order_source, o.event_name, o.event_date, o.venue_name,
         o.tevo_event_id, o.section, o.order_row, o.quantity, o.sold_ea,
         c.sub_source, c.sub_listing_id, c.sub_section, c.sub_row, c.sub_qty,
         c.sub_ea, c.sub_total,
         -- Positive = what covering this order COSTS over what it sold for.
         -- The matcher signs margin_total as a GAIN, so it is negated rather
         -- than renamed -- nobody should be able to read a loss as a profit.
         round(-c.margin_total, 2) AS cover_cost,
         c.rows_closer, c.buy_url, c.captured_at,
         row_number() OVER (PARTITION BY o.n2s_id ORDER BY c.sub_ea)
    FROM ord o
    JOIN public.s4kcs_sub_candidates(
           p_require_cheaper => false,   -- SEE HEADER: obligation, not profit
           p_per_order       => 3,
           p_event_ids       => (SELECT ids FROM ev)) c
      ON c.s4k_order_id = o.order_id AND c.source = o.order_source;
$$;

COMMENT ON FUNCTION public.n2s_sub_offers(bigint[]) IS
  'Substitute covers for open N2S ("Need to Sub") orders. Deliberately does '
  'NOT require the cover to be cheaper: an N2S order is an obligation, and as '
  'measured on 2026-09-09 every available cover cost MORE than the sale '
  '($32-$2,290). Reports cover_cost (positive = what honouring the order costs '
  'over what it sold for) and ranks cheapest cover first. Seat quality is not '
  'relaxed: same normalised section, row no worse, exact quantity.';

REVOKE ALL ON FUNCTION public.n2s_sub_offers(bigint[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_sub_offers(bigint[]) TO authenticated, service_role;

-- ── the ping ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.n2s_sub_ping()
RETURNS TABLE(items_pinged integer, offers integer, bot_chat_id bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_ids     bigint[];
  v_items   int := 0;
  v_offers  int := 0;
  v_msg     text;
  v_id      bigint;
BEGIN
  -- Best cover per not-yet-pinged open item. notified_at (not a timestamp
  -- window) is the gate, so a restart, a re-poll or a slow cycle can never
  -- re-announce the same order, and an item that gains a cover LATER still
  -- fires the first time it has one.
  DROP TABLE IF EXISTS _ping;   -- tolerate two calls in one transaction
  CREATE TEMP TABLE _ping ON COMMIT DROP AS
    SELECT o.*
      FROM public.n2s_sub_offers() o
      JOIN public.n2s_items n ON n.n2s_id = o.n2s_id
     WHERE o.cover_rank = 1
       AND n.notified_at IS NULL;

  SELECT count(*)::int, array_agg(n2s_id) INTO v_items, v_ids FROM _ping;

  IF v_items = 0 THEN
    RETURN QUERY SELECT 0, 0, NULL::bigint;
    RETURN;
  END IF;

  SELECT count(*)::int INTO v_offers
    FROM public.n2s_sub_offers(v_ids) o;

  -- The cost/free split is COUNTED, never asserted. Every cover measured on
  -- 2026-09-09 cost more than the sale, but writing that into the message text
  -- would keep claiming it long after it stopped being true.
  SELECT format(
           'N2S cover ping: %s newly-covered order(s), %s candidate(s). '
           '%s of them cost MORE than the sale, %s at or below it — an N2S '
           'order is an obligation, so these rank cheapest-cover-first, not by '
           'profit. Net cost to cover all %s: $%s (cheapest $%s, dearest $%s). '
           'Sources: %s. Detail: SELECT * FROM n2s_sub_offers() WHERE cover_rank = 1.',
           v_items, v_offers,
           count(*) FILTER (WHERE cover_cost > 0),
           count(*) FILTER (WHERE cover_cost <= 0),
           v_items,
           to_char(sum(cover_cost), 'FM999999990.00'),
           to_char(min(cover_cost), 'FM999999990.00'),
           to_char(max(cover_cost), 'FM999999990.00'),
           string_agg(DISTINCT s4k_source, ', '))
    INTO v_msg FROM _ping;

  -- bot_level is a CHECKed vocabulary: admin | security | supervisor |
  -- primary-sales | secondary-sales | data-collection. It is NOT the lane
  -- code -- passing 'd0' here violates bot_chat_bot_level_check. Broker
  -- resale work is 'secondary-sales'; the lane goes in the second argument.
  v_id := public.bot_chat_log(
            'secondary-sales', 'd0', 'flag', v_msg, NULL, '20260910050000', NULL,
            jsonb_build_object(
              'n2s_ids', to_jsonb(v_ids),
              'items', v_items,
              'offers', v_offers,
              'total_cover_cost', (SELECT round(sum(cover_cost), 2) FROM _ping)));

  UPDATE public.n2s_items SET notified_at = now() WHERE n2s_id = ANY(v_ids);

  RETURN QUERY SELECT v_items, v_offers, v_id;
END $function$;

REVOKE ALL ON FUNCTION public.n2s_sub_ping() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_sub_ping() TO service_role;

-- Runs on the odd minutes, right after n2s_items_drain_2min, so a newly
-- ingested order is priced and announced within roughly one poll cycle.
SELECT cron.schedule(
  'n2s_sub_ping_2min', '1-59/2 * * * *',
  $cron$ SELECT public.n2s_sub_ping(); $cron$
);
