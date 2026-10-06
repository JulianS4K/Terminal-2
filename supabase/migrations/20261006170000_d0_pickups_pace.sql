-- Migration 20261006170000 · level:secondary-sales · lane:D0 · writes:get_d0_pickups() · reads:v_s4kcs_orders,seatgeek_orders,evo_orders,evo_order_items,order_status_xref,events,event_listing_snapshot_daily · pre:20260901180000
--
-- ============================================================================
-- Migration 20261006170000 — D0 pickups: our daily order pace per event,
-- relative to how far out the event is (hot) + open inventory not moving (cold)
--
-- Lane:     D0 (terminal)
-- Touches:  v_s4kcs_orders (R), seatgeek_orders (R), evo_orders (R),
--           evo_order_items (R), order_status_xref (R), events (R),
--           event_listing_snapshot_daily (R)
-- Pre-reqs: 20260901180000 (s4kcs_orders), v_s4kcs_orders
--
-- NOT YET APPLIED — apply is an Applier action under operator direction.
--
-- Why: the pricing desk (S4K pricing chat, 2026-10-06) hand-builds a
-- "pickups" list every morning — future events past the next week with
-- their daily order counts over the last few days, tickets and $ sold —
-- and asked for the inverse: events NOT selling relative to proximity,
-- using the open qty we still hold. Joe's framing: events inside two weeks
-- already get attention; the value is catching further-out events people
-- are "chipping away" at early. So the hot list is weighted UP by days out.
--
-- One function, two modes (read-only, no writes):
--   p_mode = 'hot'  → events with our orders in the window, ranked by
--                     orders × ln(1 + days_out/7) × sqrt(lift), where lift =
--                     window order rate vs the event's own prior-28-day rate.
--   p_mode = 'cold' → events where we still list tickets (open_qty > 0) that
--                     won't clear by event day at the current pace, ranked by
--                     projected unsold tickets × 1/sqrt(days_out) (closer =
--                     more urgent).
--
-- Order book (our sales only, cancelled/rejected excluded via
-- order_status_xref):
--   * v_s4kcs_orders (S4K CRM) for StubHub · Gametime · Vivid · TickPick ·
--     GoTickets. Its SeatGeek rows carry no purchase_date, so SeatGeek comes
--     from seatgeek_orders instead (never both → no double count).
--     GoTickets rows carry price 0.00 (RESOURCES_BIBLE §1) → $ under-reports
--     GoTickets; order and ticket counts are right.
--   * evo_orders + evo_order_items for TEvo (not in the CRM).
-- Days are America/New_York calendar days. The window is the last
-- p_window_days COMPLETE days (ending yesterday); today so far is returned
-- separately as orders_today so a partial day never drags the trend down.
--
-- open_qty = latest event_listing_snapshot_daily slot (today or yesterday):
-- greatest(evo_owned_tickets, sg_owned_tickets) — the tickets we have listed
-- (same inventory broadcast to both). It is our listed position, not a
-- Bridge/POS export, so held-back / unbroadcast tickets are not counted.
--
-- Unmapped orders (no tevo_event_id, ~8% of the CRM) are invisible here, as
-- on every terminal surface (PROJECT_BIBLE §0).
--
-- Execution is granted to service_role only; the terminal reads it through
-- /api/broker/pickups (require_auth) — wholesale $ never reaches anon.
-- Measured on prod 2026-10-06 (read-only dry run of the body with literal
-- parameters): hot ~0.4 s, cold ~1.2 s.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_d0_pickups(
  p_mode          text DEFAULT 'hot',
  p_window_days   int  DEFAULT 4,
  p_min_days_out  int  DEFAULT 7,
  p_max_days_out  int  DEFAULT 365,
  p_limit         int  DEFAULT 50
)
RETURNS TABLE (
  tevo_event_id    bigint,
  event_name       text,
  occurs_at_local  text,
  venue_name       text,
  days_out         int,
  daily            jsonb,     -- [{d, orders, tix}] oldest → newest, every window day
  orders_window    int,
  tix_window       int,
  sales_window     numeric,
  orders_today     int,
  orders_base_28d  int,
  lift             numeric,   -- window order rate ÷ prior-28-day rate (smoothed)
  trend            text,      -- 'spike' | 'rising' | 'falling' | 'flat'
  by_market        jsonb,     -- {market: orders} over the window
  open_qty         int,
  open_qty_date    date,
  needed_tix_per_day numeric, -- open_qty ÷ days_out
  pace_ratio       numeric,   -- window tix/day ÷ needed_tix_per_day
  days_to_sellout  numeric,   -- open_qty ÷ window tix/day
  projected_unsold int,
  score            numeric
)
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
WITH prm AS (
  SELECT
    lower(coalesce(p_mode, 'hot'))                                      AS mode,
    greatest(1, least(coalesce(p_window_days, 4), 14))                  AS nd,
    greatest(0, coalesce(p_min_days_out, 7))                            AS min_out,
    greatest(0, least(coalesce(p_max_days_out, 365), 730))              AS max_out,
    greatest(1, least(coalesce(p_limit, 50), 200))                      AS lim,
    (now() AT TIME ZONE 'America/New_York')::date                       AS today
),
win AS (
  SELECT p.*, p.today - 1 AS d_end, p.today - p.nd AS d_start,
         p.today - p.nd - 28 AS base_start
  FROM prm p
),
o AS (
  SELECT v.tevo_event_id AS eid, v.purchase_date AS d, v.source AS mkt,
         coalesce(v.quantity, 0) AS q,
         coalesce(v.price * greatest(coalesce(v.quantity, 1), 1), 0) AS amt
  FROM v_s4kcs_orders v
  LEFT JOIN order_status_xref x ON x.source = 's4kcs' AND x.source_status = v.order_status
  CROSS JOIN win w
  WHERE v.purchase_date >= w.base_start
    AND v.source <> 'SeatGeek'
    AND v.tevo_event_id IS NOT NULL
    AND coalesce(x.canonical_status, 'accepted') NOT IN ('cancelled', 'rejected')
  UNION ALL
  SELECT s.tevo_event_id, (s.created_at_sg AT TIME ZONE 'America/New_York')::date, 'SeatGeek',
         coalesce(s.sale_quantity, 0), coalesce(s.payment_total, 0)
  FROM seatgeek_orders s
  LEFT JOIN order_status_xref x ON x.source = 'seatgeek' AND x.source_status = s.status
  CROSS JOIN win w
  WHERE s.created_at_sg >= (w.base_start::timestamp AT TIME ZONE 'America/New_York')
    AND s.tevo_event_id IS NOT NULL
    AND coalesce(x.canonical_status, 'accepted') NOT IN ('cancelled', 'rejected')
  UNION ALL
  SELECT i.event_id, (e.evo_created_at AT TIME ZONE 'America/New_York')::date, 'TEvo',
         coalesce(i.quantity, 0), coalesce(i.price * i.quantity, 0)
  FROM evo_orders e
  JOIN evo_order_items i USING (evo_order_id)
  LEFT JOIN order_status_xref x ON x.source = 'evo' AND x.source_status = e.state
  CROSS JOIN win w
  WHERE e.evo_created_at >= (w.base_start::timestamp AT TIME ZONE 'America/New_York')
    AND i.event_id IS NOT NULL
    AND coalesce(x.canonical_status, 'accepted') NOT IN ('cancelled', 'rejected')
),
agg AS (
  SELECT o.eid,
    count(*)   FILTER (WHERE o.d BETWEEN w.d_start AND w.d_end)::int    AS orders_w,
    coalesce(sum(o.q)   FILTER (WHERE o.d BETWEEN w.d_start AND w.d_end), 0)::int AS tix_w,
    coalesce(sum(o.amt) FILTER (WHERE o.d BETWEEN w.d_start AND w.d_end), 0)       AS sales_w,
    count(*)   FILTER (WHERE o.d >= w.today)::int                       AS orders_today,
    count(*)   FILTER (WHERE o.d >= w.base_start AND o.d < w.d_start)::int AS orders_base
  FROM o CROSS JOIN win w
  GROUP BY o.eid
),
per_day AS (
  SELECT o.eid, o.d, count(*)::int AS n, sum(o.q)::int AS q
  FROM o CROSS JOIN win w
  WHERE o.d BETWEEN w.d_start AND w.d_end
  GROUP BY o.eid, o.d
),
per_mkt AS (
  SELECT o.eid, jsonb_object_agg(o.mkt, o.n) AS by_market
  FROM (SELECT o.eid, o.mkt, count(*) AS n
        FROM o CROSS JOIN win w
        WHERE o.d BETWEEN w.d_start AND w.d_end
        GROUP BY o.eid, o.mkt) o
  GROUP BY o.eid
),
inv AS (
  SELECT DISTINCT ON (s.event_id)
         s.event_id AS eid,
         greatest(coalesce(s.evo_owned_tickets, 0), coalesce(s.sg_owned_tickets, 0)) AS open_qty,
         s.snapshot_date
  FROM event_listing_snapshot_daily s CROSS JOIN win w
  WHERE s.snapshot_date >= w.today - 1
  ORDER BY s.event_id, s.snapshot_date DESC, s.captured_at DESC
),
cand AS (
  SELECT a.eid FROM agg a CROSS JOIN win w WHERE w.mode <> 'cold' AND a.orders_w > 0
  UNION
  SELECT i.eid FROM inv i CROSS JOIN win w WHERE w.mode = 'cold' AND i.open_qty > 0
),
ev AS (
  SELECT e.id AS eid, e.name, e.occurs_at_local, e.venue_name,
         (left(e.occurs_at_local, 10)::date - w.today)::int AS days_out
  FROM events e
  JOIN cand c ON c.eid = e.id
  CROSS JOIN win w
  WHERE left(e.occurs_at_local, 10) ~ '^\d{4}-\d{2}-\d{2}$'
    AND coalesce(e.name, '') !~* '\m(parking|garage)\M'
),
base AS (
  SELECT ev.*, w.nd,
    coalesce(a.orders_w, 0)      AS orders_w,
    coalesce(a.tix_w, 0)         AS tix_w,
    coalesce(a.sales_w, 0)       AS sales_w,
    coalesce(a.orders_today, 0)  AS orders_today,
    coalesce(a.orders_base, 0)   AS orders_base,
    i.open_qty, i.snapshot_date,
    -- smoothed: (window orders + 1) ÷ (expected-from-baseline + 1)
    round(((coalesce(a.orders_w, 0) + 1.0)
           / (coalesce(a.orders_base, 0) * w.nd / 28.0 + 1.0))::numeric, 2) AS lift,
    coalesce(a.tix_w, 0)::numeric / w.nd AS tix_rate,
    (SELECT jsonb_agg(jsonb_build_object('d', g::date,
                                         'orders', coalesce(pd.n, 0),
                                         'tix', coalesce(pd.q, 0)) ORDER BY g)
       FROM generate_series(w.d_start, w.d_end, interval '1 day') g
       LEFT JOIN per_day pd ON pd.eid = ev.eid AND pd.d = g::date) AS daily,
    pm.by_market
  FROM ev
  CROSS JOIN win w
  LEFT JOIN agg a      ON a.eid = ev.eid
  LEFT JOIN inv i      ON i.eid = ev.eid
  LEFT JOIN per_mkt pm ON pm.eid = ev.eid
  WHERE ev.days_out BETWEEN w.min_out AND w.max_out
),
scored AS (
  SELECT b.*,
    CASE WHEN b.open_qty > 0 AND b.days_out > 0
         THEN round(b.open_qty::numeric / b.days_out, 2) END            AS needed,
    CASE WHEN b.open_qty > 0 AND b.days_out > 0
         THEN round(b.tix_rate / (b.open_qty::numeric / b.days_out), 2) END AS pace,
    CASE WHEN b.open_qty > 0 AND b.tix_rate > 0
         THEN round(b.open_qty / b.tix_rate, 1) END                     AS sellout,
    CASE WHEN b.open_qty > 0
         THEN greatest(0, round(b.open_qty - b.tix_rate * b.days_out))::int END AS unsold
  FROM base b
)
SELECT s.eid, s.name, s.occurs_at_local, s.venue_name, s.days_out, s.daily,
       s.orders_w, s.tix_w, round(s.sales_w, 2), s.orders_today, s.orders_base,
       s.lift,
       t.trend,
       s.by_market, s.open_qty, s.snapshot_date,
       s.needed, s.pace, s.sellout, s.unsold,
       round(CASE WHEN w.mode = 'cold'
            THEN coalesce(s.unsold, 0) / sqrt(greatest(s.days_out, 1))
            ELSE s.orders_w * ln(1 + s.days_out / 7.0) * sqrt(least(s.lift, 9))
       END::numeric, 2) AS score
FROM scored s
CROSS JOIN win w
-- trend over the window's daily order counts (oldest → newest):
--   spike   last day ≥ 3 and ≥ 2× the average of the earlier days
--   rising  last > first and no day drops by more than 1 from the day before
--   falling last < first by ≥ 2
CROSS JOIN LATERAL (
  SELECT CASE
    WHEN arr[cardinality(arr)] >= 3
         AND arr[cardinality(arr)] >= 2 * greatest(1.0, (SELECT avg(v) FROM unnest(arr[1:cardinality(arr) - 1]) v))
      THEN 'spike'
    WHEN cardinality(arr) >= 2
         AND arr[cardinality(arr)] > arr[1]
         AND NOT EXISTS (SELECT 1 FROM generate_subscripts(arr, 1) k
                         WHERE k > 1 AND arr[k] < arr[k - 1] - 1)
      THEN 'rising'
    WHEN cardinality(arr) >= 2 AND arr[cardinality(arr)] < arr[1]
         AND arr[1] - arr[cardinality(arr)] >= 2
      THEN 'falling'
    ELSE 'flat' END AS trend
  FROM (SELECT array_agg((e->>'orders')::int ORDER BY k) AS arr
          FROM jsonb_array_elements(s.daily) WITH ORDINALITY AS t(e, k)) z
) t
WHERE (w.mode = 'cold' AND s.open_qty > 0 AND coalesce(s.pace, 0) < 1)
   OR (w.mode <> 'cold' AND s.orders_w > 0)
ORDER BY score DESC NULLS LAST, s.orders_w DESC
LIMIT (SELECT lim FROM prm);
$fn$;

REVOKE ALL ON FUNCTION public.get_d0_pickups(text, int, int, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_d0_pickups(text, int, int, int, int) TO service_role;

COMMENT ON FUNCTION public.get_d0_pickups(text, int, int, int, int) IS
  'D0 pickups — our daily order pace per future event. mode hot: selling now, weighted up by days out + lift vs own 28d baseline; mode cold: listed open_qty not clearing at current pace. Read via /api/broker/pickups. Mig 20261006170000.';
