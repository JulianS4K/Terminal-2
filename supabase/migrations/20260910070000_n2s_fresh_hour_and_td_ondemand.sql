-- ============================================================================
-- Migration 20260910070000 — N2S: one-hour listing freshness, and an
--                            on-demand TicketsData pull for new arrivals
--
-- Lane:     D0 (orders surface)
-- Touches:  n2s_covers() (default freshness 24h -> 1h),
--           n2s_td_enqueue() (new), one cron
-- Pre-reqs: 20260910060000
--
-- READ-ONLY upstream: this migration issues no API call itself. It writes rows
-- into td_pull_queue, which the EXISTING budget-checked drain fires. RULE 2
-- holds: TicketsData is a GET-only inventory read.
--
-- Operator direction 2026-09-09: "only show matching sub listings that match
-- that are an hour old or less" and "also ignore tickets data crons for this
-- but only poll newest sub as they come in."
--
-- ── 1. One-hour freshness, and what it costs ───────────────────────────────
-- p_max_listing_age default drops 24h -> 1h. The parameter stays, so a wider
-- window is still available deliberately; only the default moved.
--
-- This is a large, intentional cut. Measured at the moment of the change:
--
--   window   tevo          gotickets     ticketsdata:GT   orders covered
--   24h      25 covers     39 covers     10 covers        32
--    1h      11 covers      9 covers      0 covers         9
--
-- Covered orders 32 -> 9. That is the right trade for this book and not a
-- regression to be tuned away: an N2S order is an obligation someone must
-- actually go and BUY, and a listing last seen twenty hours ago is very likely
-- gone. Offering a cover that cannot be bought wastes the 15-minute N2S timer
-- on a dead end. Nine covers you can trust beat thirty-two you cannot.
--
-- ⚠ THE ONE-HOUR RULE IS WHAT ZEROED THE TICKETSDATA ARM, not a bug in it.
-- TD's newest captured_at was 2026-09-09 10:04 UTC against a now() of 22:15 —
-- twelve hours stale, because TD's daily credit budget was already spent
-- (td_budget_ok() FALSE, 5,899 credits). Under a 1h window TD contributes
-- nothing until it is polled again. Hence part 2.
--
-- ── 2. On-demand TicketsData pull for new N2S arrivals ─────────────────────
-- "Ignore tickets data crons for this" is read as: this pipeline must not
-- DEPEND on TD's scheduled cadence, which is tuned for a curated watchlist and
-- is far too slow for a one-hour freshness rule. It is NOT read as "disable
-- TD's crons" — those serve other surfaces and are left untouched.
--
-- Instead, when a NEW N2S order arrives and maps to an event TicketsData
-- knows, that event is enqueued for a targeted pull. This is a handful of
-- events per hour rather than a broad sweep, so it is far cheaper than raising
-- the watchlist.
--
-- ⚠ THE BUDGET GUARD IS NOT BYPASSED, AND MUST NOT BE. Both td_tier_enqueue()
-- and td_pull_drain() check td_budget_ok(), and this function only INSERTs
-- rows the existing drain later fires — it makes no API call and spends no
-- credit itself. When the budget is spent the rows simply wait, and fire when
-- it resets. TicketsData is a paid, credit-metered API; a guard that exists to
-- cap spend is not an obstacle to route around.
--
-- ⚠ ONLY EVENTS ALREADY IN ticketsdata_event_xref CAN BE PULLED. td_pull_queue
-- requires an event_url, which is the xref's. An N2S event TD has never
-- discovered has no URL and is skipped rather than guessed — measured, 15 of
-- the 24 events the mapped items touch were in the xref. Discovery for the
-- rest is a separate, budgeted concern.
-- ============================================================================

-- ── 1. freshness default ───────────────────────────────────────────────────
-- Only the DEFAULT changes. A parameter default is not part of the signature,
-- so CREATE OR REPLACE is enough here -- no drop, no overload, and every
-- existing caller keeps working (the ping calls n2s_covers() with no args and
-- therefore picks the new default up automatically).
CREATE OR REPLACE FUNCTION public.n2s_covers(
  p_n2s_ids         bigint[] DEFAULT NULL,
  p_max_listing_age interval DEFAULT interval '1 hour',   -- was 24h (see header)
  p_per_order       integer  DEFAULT 3,
  p_sub_sources     text[]   DEFAULT NULL
)
RETURNS TABLE (
  n2s_id         bigint,
  order_number   text,
  s4k_source     text,
  n2s_status     text,
  fail_reason    text,
  timer_expired  boolean,
  event_name     text,
  event_date     date,
  venue          text,
  tevo_event_id  bigint,
  section        text,
  order_row      text,
  quantity       integer,
  sold_ea        numeric,
  sub_source     text,
  sub_listing_id text,
  sub_section    text,
  sub_row        text,
  sub_qty        integer,
  sub_ea         numeric,
  sub_total      numeric,
  cover_cost     numeric,
  rows_closer    integer,
  buy_url        text,
  captured_at    timestamptz,
  cover_rank     bigint
)
LANGUAGE sql STABLE
SET search_path TO 'public','pg_temp'
AS $$
  WITH o AS (
    SELECT i.n2s_id, i.order_number, i.s4k_source, i.status, i.fail_reason,
           i.timer_expired, i.event_name, i.event_dt::date AS event_date,
           i.venue, i.tevo_event_id, i.section, i."row" AS order_row,
           i.qty AS quantity, i.price_per_ticket AS sold_ea,
           public.seat_row_kind(i."row")    AS ord_kind,
           public.seat_row_rank(i."row")    AS ord_rank,
           public.seat_section_norm(i.section) AS sec_norm
      FROM public.n2s_items i
     WHERE NOT i.is_terminal
       AND i.tevo_event_id IS NOT NULL
       AND i.event_dt::date >= current_date
       AND i.qty IS NOT NULL
       AND i.price_per_ticket IS NOT NULL
       AND public.seat_row_kind(i."row") IS NOT NULL
       AND public.seat_section_norm(i.section) IS NOT NULL
       AND (p_n2s_ids IS NULL OR i.n2s_id = ANY(p_n2s_ids))
  ),
  ev AS (SELECT DISTINCT tevo_event_id AS eid FROM o),
  -- One pinned capture per event per source: see header. Taking the newest row
  -- per listing id would resurface inventory that sold hours ago.
  p_tevo AS (
    SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
      SELECT l.captured_at FROM public.listings_snapshots l
       WHERE l.event_id = ev.eid AND l.captured_at >= now() - p_max_listing_age
       ORDER BY l.captured_at DESC LIMIT 1) x
  ),
  p_gt AS (
    SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
      SELECT g.captured_at FROM public.gotickets_listings_snapshots g
       WHERE g.tevo_event_id = ev.eid AND g.captured_at >= now() - p_max_listing_age
       ORDER BY g.captured_at DESC LIMIT 1) x
  ),
  p_sg AS (
    SELECT ev.eid, x.captured_at FROM ev CROSS JOIN LATERAL (
      SELECT s.captured_at FROM public.seatgeek_listings_snapshots s
       WHERE s.tevo_event_id = ev.eid AND s.captured_at >= now() - p_max_listing_age
       ORDER BY s.captured_at DESC LIMIT 1) x
  ),
  -- ⚠ TICKETSDATA IS A CHANGE FEED, NOT A SNAPSHOT — so the pinned-capture
  -- pattern used for the other three arms is WRONG here and silently returns
  -- almost nothing. Measured: event 3286292 had 10,887 rows across 46 distinct
  -- captured_at values, but only FIVE at the newest one. TD writes a row only
  -- when a listing CHANGES (hence content_hash), so one timestamp is a delta,
  -- not the state of the event. Current state is therefore the latest row PER
  -- LISTING, which is exactly the DISTINCT ON shape the other arms must avoid.
  --
  -- ⚠ THE COST OF THAT IS REAL AND IS NOT FIXABLE FROM THIS DATA: with a
  -- change feed, a listing going absent means "unchanged", not "sold", and TD
  -- publishes no delisting marker we can see. So a TD cover may already be
  -- gone. TD covers are ADVISORY — verify before buying — and are labelled
  -- with their platform (ticketsdata:GT, :SH, :VD) so they are distinguishable
  -- from the three snapshot sources, which are authoritative about absence.
  -- `unified_listings` does not dedup TD either, so there was no established
  -- house semantic to inherit here.
  td_cur AS (
    SELECT DISTINCT ON (t.event_id, t.platform, t.td_listing_id)
           t.event_id AS eid, t.platform, t.td_listing_id, t.section, t."row",
           t.quantity, t.price_with_fees, t.list_price, t.is_parking, t.captured_at
      FROM public.ticketsdata_listings_snapshots t
     WHERE t.event_id IN (SELECT eid FROM ev)
       AND t.captured_at >= now() - p_max_listing_age
     ORDER BY t.event_id, t.platform, t.td_listing_id, t.captured_at DESC
  ),
  l AS (
    SELECT 'tevo'::text AS src, t.tevo_ticket_group_id::text AS lid, t.event_id AS eid,
           t.section AS sec, t."row" AS rw, t.quantity AS q, t.retail_price AS ea,
           NULL::text AS url, t.captured_at
      FROM p_tevo p JOIN public.listings_snapshots t
        ON t.event_id = p.eid AND t.captured_at = p.captured_at
     WHERE NOT t.is_owned AND NOT t.is_ancillary
       AND (p_sub_sources IS NULL OR 'tevo' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'gotickets', g.gt_listing_id::text, g.tevo_event_id,
           g.section, g."row", g.quantity, g.all_in_price,
           'https://pro.gotickets.com/tickets/' || g.gt_event_id
             || '/?sortBy=price&sortDirection=asc&sections=' || g.section_id,
           g.captured_at
      FROM p_gt p JOIN public.gotickets_listings_snapshots g
        ON g.tevo_event_id = p.eid AND g.captured_at = p.captured_at
     WHERE (p_sub_sources IS NULL OR 'gotickets' = ANY(p_sub_sources))
    UNION ALL
    SELECT 'seatgeek', sg.sglid::text, sg.tevo_event_id,
           sg.section, sg."row", sg.quantity, sg.retail_price_all_in,
           NULL::text, sg.captured_at
      FROM p_sg p JOIN public.seatgeek_listings_snapshots sg
        ON sg.tevo_event_id = p.eid AND sg.captured_at = p.captured_at
     WHERE NOT sg.is_broker_owned
       AND (p_sub_sources IS NULL OR 'seatgeek' = ANY(p_sub_sources))
    UNION ALL
    -- TicketsData carries the marketplace in `platform`, so the arm is
    -- labelled with it. price_with_fees is the all-in figure; list_price is
    -- pre-fee, so comparing it to an all-in sale price would flatter the
    -- cover. Parking rows are never a seat substitute.
    SELECT 'ticketsdata:' || td.platform, td.td_listing_id, td.eid,
           td.section, td."row", td.quantity,
           COALESCE(td.price_with_fees, td.list_price),
           NULL::text, td.captured_at
      FROM td_cur td
     WHERE NOT COALESCE(td.is_parking, false)
       AND COALESCE(td.price_with_fees, td.list_price) IS NOT NULL
       AND (p_sub_sources IS NULL OR 'ticketsdata' = ANY(p_sub_sources))
  ),
  m AS (
    SELECT o.*, l.src, l.lid, l.sec, l.rw, l.q, l.ea, l.url, l.captured_at,
           row_number() OVER (PARTITION BY o.n2s_id ORDER BY l.ea) AS rn
      FROM o JOIN l ON l.eid = o.tevo_event_id
       AND public.seat_section_norm(l.sec) = o.sec_norm       -- same section
       AND public.seat_row_kind(l.rw)      = o.ord_kind
       AND public.seat_row_rank(l.rw)     <= o.ord_rank       -- same or better
       AND l.q = o.quantity                                   -- exact qty
       -- NO price filter: see header. Price is reported, never gates.
  )
  SELECT n2s_id, order_number, s4k_source, status, fail_reason, timer_expired,
         event_name, event_date, venue, tevo_event_id, section, order_row,
         quantity, sold_ea, src, lid, sec, rw, q, ea,
         round(ea * quantity, 2)                  AS sub_total,
         round((ea - sold_ea) * quantity, 2)      AS cover_cost,
         (ord_rank - public.seat_row_rank(rw))    AS rows_closer,
         url, captured_at, rn
    FROM m
   WHERE rn <= p_per_order
   ORDER BY cover_cost, n2s_id;
$$;


-- ── 2. on-demand TicketsData pull for newly-arrived N2S orders ─────────────
CREATE OR REPLACE FUNCTION public.n2s_td_enqueue(
  p_max          integer  DEFAULT 20,
  p_recent_fired interval DEFAULT interval '20 minutes'
)
RETURNS TABLE(events_enqueued integer, budget_ok boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_n  integer := 0;
  v_ok boolean;
BEGIN
  -- Report the guard rather than act on it: enqueue is cheap and the drain
  -- checks the budget again before spending anything. Refusing to queue while
  -- the budget is briefly spent would mean a new order silently gets no TD
  -- coverage even after the budget resets minutes later.
  SELECT public.td_budget_ok() INTO v_ok;

  WITH want AS (
    -- Newest first: "poll newest sub as they come in". Only items that are
    -- open, mapped, in the future, and not yet announced.
    SELECT DISTINCT n.tevo_event_id AS eid
      FROM public.n2s_items n
     WHERE NOT n.is_terminal
       AND n.notified_at IS NULL
       AND n.tevo_event_id IS NOT NULL
       AND n.event_dt::date >= current_date
     ORDER BY 1
     LIMIT p_max
  ),
  cand AS (
    -- td_pull_queue requires an event_url, and the xref is the only place one
    -- exists. An event TicketsData has never discovered is SKIPPED, never
    -- guessed at.
    SELECT x.event_id, x.platform, x.event_url
      FROM public.ticketsdata_event_xref x
      JOIN want w ON w.eid = x.event_id
     WHERE x.event_url IS NOT NULL
       AND COALESCE(x.active, true)
       -- Don't stack duplicate work for the same event+platform.
       AND NOT EXISTS (
         SELECT 1 FROM public.td_pull_queue q
          WHERE q.event_id = x.event_id AND q.platform = x.platform
            AND (q.resolved_at IS NULL
                 OR q.fired_at > now() - p_recent_fired))
  ),
  ins AS (
    INSERT INTO public.td_pull_queue (event_id, platform, event_url, interval_tag)
    SELECT event_id, platform, event_url, 'n2s_ondemand' FROM cand
    RETURNING 1
  )
  SELECT count(*)::int INTO v_n FROM ins;

  RETURN QUERY SELECT v_n, v_ok;
END $function$;

COMMENT ON FUNCTION public.n2s_td_enqueue(integer, interval) IS
  'Queues a targeted TicketsData pull for the events of newly-arrived, mapped, '
  'not-yet-announced N2S orders, so the pipeline does not depend on TD''s '
  'scheduled watchlist cadence (far too slow for the 1-hour freshness rule). '
  'Inserts only — the existing budget-checked td_pull_drain() spends the '
  'credit, so this never bypasses td_budget_ok(). Events absent from '
  'ticketsdata_event_xref have no event_url and are skipped, not guessed.';

REVOKE ALL ON FUNCTION public.n2s_td_enqueue(integer, interval) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.n2s_td_enqueue(integer, interval) TO service_role;

-- Every 2 minutes, in step with the N2S poll: a new order is mapped (cron
-- 598), its event queued for TicketsData here, and announced by the ping.
SELECT cron.schedule(
  'n2s_td_enqueue_2min', '*/2 * * * *',
  $cron$ SELECT public.n2s_td_enqueue(); $cron$
);
