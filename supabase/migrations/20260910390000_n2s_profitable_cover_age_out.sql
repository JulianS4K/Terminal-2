-- ============================================================================
-- Migration 20260910390000 — age profitable covers out of the feed at 6 hours
--
-- Lane:     D7 (n2s obligation-covering) over A1's DB plane
-- Level:    data-collection — one function body change, same signature.
-- Touches:  n2s_profitable_cover_sync() (src CTE gains an age predicate)
-- Pre-reqs: 20260910360000
--
-- Upstream: no API call at all. RULE 2 untouched.
--
-- Operator direction 2026-09-10: "have the table auto delete any sub rows over
-- 6 hours old."
--
-- ── ⚠ WHY THIS IS *NOT* A DELETE JOB ───────────────────────────────────────
-- The obvious implementation — a cron that runs
--   DELETE FROM n2s_profitable_cover WHERE first_seen_at < now() - '6 hours'
-- — is actively harmful here, and it is worth understanding why before anyone
-- "simplifies" this back into one.
--
-- n2s_profitable_cover_sync() runs every minute and is a DIFF against a source
-- set: rows missing from src are DELETEd, rows present are INSERTed or
-- UPDATEd. A reaper deleting a row that is STILL profitable and STILL in the
-- cover queue therefore accomplishes nothing durable — the very next tick,
-- 60 seconds later, finds that n2s_id back in src and RE-INSERTS it, with a
-- fresh first_seen_at defaulting to now().
--
-- The result is a flap, not an expiry:
--   * every long-lived cover is deleted and re-added every 6 hours, forever;
--   * each cycle emits a spurious DELETE + INSERT to every Realtime
--     subscriber, who must treat them as real (a DELETE means "un-flag this",
--     an INSERT means "act on this now") — so the feed manufactures false
--     urgency on a cover that never actually changed;
--   * first_seen_at resets on every re-insert, so the row never ages out at
--     all. The reaper's own stated goal is defeated by its own side effect.
--
-- That last point generalises: ANY age measured on a column of the target
-- table is self-defeating here, because delete-and-reinsert resets it. The
-- age has to come from a SOURCE-side timestamp that survives the round trip.
--
-- ── THE FIX: EXCLUDE AT THE SOURCE, LET THE EXISTING DIFF DO THE DELETING ──
-- One predicate in the src CTE. A cover older than the cutoff simply stops
-- being a candidate, so:
--   * the existing `gone` CTE deletes it on the next tick — one DELETE event,
--     carrying the full row (REPLICA IDENTITY FULL), so subscribers un-flag
--     correctly;
--   * `ups` never re-adds it, because it is no longer in src. No flap.
-- No new cron job, no new moving part, and the "silence is meaningful"
-- property of the diff sync is preserved intact.
--
-- ── WHICH TIMESTAMP, AND WHY captured_at ───────────────────────────────────
-- captured_at is when the underlying LISTING SNAPSHOT was captured — i.e. how
-- old the market data behind this buy recommendation actually is. That is the
-- honest meaning of "this cover is 6 hours old", and it is the right thing to
-- act on: a buy link priced against 6-hour-old inventory is a guess.
--
-- It is also stable across a delete/insert cycle (it lives in the cover queue,
-- not in the feed table), which is precisely what first_seen_at and updated_at
-- are not.
--
-- updated_at would be wrong for a second, subtler reason: the sync only writes
-- when a row genuinely CHANGES (the IS DISTINCT FROM guard). So updated_at
-- means "last changed", NOT "last confirmed" — a cover whose price has simply
-- held steady for six hours looks stale by that measure while being perfectly
-- current. Ageing on it would delete the most stable covers first.
--
-- ── WHAT THIS BUYS OPERATIONALLY ───────────────────────────────────────────
-- In steady state this changes nothing: the poller refreshes listings
-- continuously, so captured_at stays minutes old (measured at authoring time:
-- 51 covers, oldest 0.87h, NONE over the cutoff). Its value is as a DEADMAN —
-- if the poll chain stalls, covers stop being re-captured, and six hours later
-- the feed empties itself instead of serving buy links priced against dead
-- inventory. An empty feed is a visible, honest failure; a stale one is not.
--
-- captured_at is NOT NULL across all 51 current covers, but the predicate is
-- written so a NULL would be excluded (NULL > x is NULL, hence not true) —
-- fail-closed, because a cover whose data age is unknowable should not be
-- presented as actionable.
--
-- ⚠ Signature deliberately UNCHANGED (still zero-arg). Adding a defaulted
-- p_max_age alongside the existing signature would make the cron's zero-arg
-- call AMBIGUOUS and require a DROP first (PROJECT_BIBLE §3). Not worth it for
-- a constant the operator set; to change the window, edit this one interval.
-- ============================================================================

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
       -- 6-hour age-out (operator, 2026-09-10). Source-side on purpose: see
       -- the migration header for why a DELETE job would flap instead of expire.
       AND v.captured_at > now() - interval '6 hours'
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

COMMENT ON FUNCTION public.n2s_profitable_cover_sync() IS
  'Diff-syncs profitable covers into n2s_profitable_cover for Realtime. Writes '
  'only genuine differences, so a quiet minute emits nothing. Covers whose '
  'underlying listing snapshot (captured_at) is older than 6 hours are excluded '
  'at the SOURCE, so the existing diff deletes them once and never re-adds them '
  '— never implement that age-out as a separate DELETE job, which would flap '
  'delete/insert every 6h and reset first_seen_at each cycle.';
