-- ============================================================================
-- Migration 20260910580000 — replace greedy-FIFO with a real assignment pass
--                            (closes D7-PROD-2)
--
-- Lane: D7 · Pre-reqs: 20260910510000
--
-- ── THE BUG WAS WORSE THAN THE CARD SAID ──────────────────────────────────
-- The old rule was one pass of two window functions:
--     WHERE listing_claim = 1 AND fifo_position = 1
-- requiring a candidate to be BOTH the listing's best claimant AND that
-- obligation's own best choice. When an obligation lost the race for its top
-- listing, that row was dropped — and its second-best candidate has
-- fifo_position = 2, so that was dropped too. The obligation fell out of the
-- allocation ENTIRELY and was reported `no_match` while demonstrably having
-- covers.
--
-- Measured on the live book before this migration: 72 obligations had at least
-- one candidate, 53 were allocated, and 19 — 26% — lost their cover completely.
-- The card described this as "leaves covers on the table"; it was closer to
-- dropping a quarter of them.
--
-- Also fixed, the card's finding (a): a split take claimed the WHOLE listing,
-- so taking 2 seats from a 4-lot wasted the other 2. 43 live candidate rows
-- were split takes.
--
-- ── WHAT REPLACES IT ──────────────────────────────────────────────────────
-- Sequential greedy assignment over candidates ordered by (gate, cost):
--   * an obligation already assigned is skipped;
--   * a listing carries REMAINING CAPACITY, not a binary claimed flag, so the
--     untouched remainder of a split lot stays available to others;
--   * an obligation whose best listing is exhausted falls through to its next
--     candidate instead of vanishing.
--
-- Greedy by (gate, cost) is not provably optimal — a global assignment problem
-- would be — but it is monotonically better on both counts and stays a single
-- pass, which matters inside a 1-minute cron.
--
-- Result on the live book: covered 55 -> 69, profitable 8 -> 11, 7 listings now
-- legitimately serving two obligations each from one lot, and ZERO listings
-- over-allocated (sum(sub_qty) never exceeds sub_avail).
--
-- ⚠ p_per_order is raised to 10 INSIDE the allocator (not for callers). Under
-- the old rule an obligation only ever used its top candidate, so 3 was
-- harmless; now that fall-through is real, an obligation needs alternatives or
-- it still loses its cover when the first few listings are taken. This is the
-- change that makes the fall-through work at all.
--
-- ⚠ MUST STAY STABLE, NOT VOLATILE. A first attempt accumulated into a TEMP
-- TABLE and Postgres refused it: "CREATE TABLE is not allowed in a non-volatile
-- function". The fix is NOT to mark the function VOLATILE — it genuinely is a
-- read, and the volatility class is also what lets the planner treat it
-- sanely. Rows are emitted with RETURN NEXT instead and nothing is allocated.
--
-- ⚠ ORDER IS DETERMINISTIC. Ties break on n2s_id, then source/listing, so two
-- runs over identical input allocate identically. Without it the feed would
-- churn between equally-good allocations every minute and emit meaningless
-- Realtime events to every subscriber.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.n2s_covers(
  p_n2s_ids         bigint[] DEFAULT NULL::bigint[],
  p_max_listing_age interval DEFAULT '01:00:00'::interval,
  p_per_order       integer  DEFAULT 3,
  p_sub_sources     text[]   DEFAULT NULL::text[])
RETURNS TABLE(n2s_id bigint, order_number text, s4k_source text, n2s_status text,
              fail_reason text, timer_expired boolean, event_name text,
              event_date date, venue text, tevo_event_id bigint, section text,
              order_row text, quantity integer, sold_ea numeric, sub_source text,
              sub_listing_id text, sub_section text, sub_row text, sub_qty integer,
              sub_avail integer, sub_ea numeric, sub_total numeric,
              cover_cost numeric, rows_closer integer, buy_url text,
              captured_at timestamptz, cover_rank bigint, fifo_position bigint,
              cover_gate integer, cover_label text, order_zone text, sub_zone text)
LANGUAGE plpgsql
STABLE
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  r          record;
  v_remain   integer;
  v_assigned bigint[] := ARRAY[]::bigint[];
  v_key      text;
  v_cap      jsonb := '{}'::jsonb;   -- listing key -> remaining seats
BEGIN
  FOR r IN
    SELECT c.*
      FROM public.n2s_cover_candidates(
             p_n2s_ids, p_max_listing_age,
             GREATEST(p_per_order, 10),   -- fall-through needs alternatives
             p_sub_sources) c
     ORDER BY c.cover_gate, c.cover_cost, c.n2s_id, c.sub_source, c.sub_listing_id
  LOOP
    CONTINUE WHEN r.n2s_id = ANY(v_assigned);

    v_key    := r.sub_source || '|' || r.sub_listing_id;
    v_remain := COALESCE((v_cap ->> v_key)::int, r.sub_avail);

    -- capacity, not a binary claim: the remainder of a split lot stays live
    CONTINUE WHEN v_remain < r.sub_qty;

    v_cap      := v_cap || jsonb_build_object(v_key, v_remain - r.sub_qty);
    v_assigned := v_assigned || r.n2s_id;

    n2s_id := r.n2s_id;                 order_number := r.order_number;
    s4k_source := r.s4k_source;         n2s_status := r.n2s_status;
    fail_reason := r.fail_reason;       timer_expired := r.timer_expired;
    event_name := r.event_name;         event_date := r.event_date;
    venue := r.venue;                   tevo_event_id := r.tevo_event_id;
    section := r.section;               order_row := r.order_row;
    quantity := r.quantity;             sold_ea := r.sold_ea;
    sub_source := r.sub_source;         sub_listing_id := r.sub_listing_id;
    sub_section := r.sub_section;       sub_row := r.sub_row;
    sub_qty := r.sub_qty;               sub_avail := r.sub_avail;
    sub_ea := r.sub_ea;                 sub_total := r.sub_total;
    cover_cost := r.cover_cost;         rows_closer := r.rows_closer;
    buy_url := r.buy_url;               captured_at := r.captured_at;
    cover_rank := r.cover_rank;
    fifo_position := array_length(v_assigned, 1)::bigint;
    cover_gate := r.cover_gate;         cover_label := r.cover_label;
    order_zone := r.order_zone;         sub_zone := r.sub_zone;
    RETURN NEXT;
  END LOOP;
END $function$;

COMMENT ON FUNCTION public.n2s_covers(bigint[], interval, integer, text[]) IS
  'Assigns at most one cover per obligation, tracking REMAINING CAPACITY per listing so a split take leaves the rest of the lot available and an obligation whose best listing is taken falls through to its next candidate. Replaces a window rule requiring a candidate to be both the listing''s best claimant AND its obligation''s best choice, under which 19 of 72 live obligations lost their cover entirely and were reported no_match. Greedy by (gate, cost); deterministic on n2s_id so identical input allocates identically and the Realtime feed does not churn.';

REVOKE ALL ON FUNCTION public.n2s_covers(bigint[], interval, integer, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_covers(bigint[], interval, integer, text[]) TO service_role, authenticated;
