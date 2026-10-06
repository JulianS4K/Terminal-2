-- Migration 20261006180000 · level:secondary-sales · lane:D0 · writes:get_d0_pickups_v2() · reads:v_s4kcs_orders,seatgeek_orders,evo_orders,evo_order_items,order_status_xref,events,event_listing_snapshot_daily,seatgeek_sales_snapshots · pre:20261006170000
--
-- ============================================================================
-- Migration 20261006180000 — get_d0_pickups_v2: SeatGeek MARKET sales next to
-- our pace, and pick-then-enrich so the hot list stops scanning the whole book
--
-- Lane:     D0 (terminal)
-- Touches:  get_d0_pickups_v2 (W, new); v_s4kcs_orders, seatgeek_orders,
--           evo_orders, evo_order_items, order_status_xref, events,
--           event_listing_snapshot_daily, seatgeek_sales_snapshots (R)
-- Pre-reqs: 20261006170000 (v1)
--
-- Already applied to prod · via MCP 2026-10-06 under operator direction ("retry the
-- apply then merge" → add-only variant); verified: hot 50 rows / 11 SG-tracked,
-- cold 50 / 21, EXECUTE held by service_role (+ owner) only.
--
-- 1. MARKET (operator ask 2026-10-06: "add market seatgeek sales next to our
--    pace"). For every returned event, SeatGeek's public sales feed over the
--    same window: distinct sg_sale_id (the snapshot table repeats each sale
--    ~3-11×, PROJECT_BIBLE §7 "SG sales dedupe"), per day and in total.
--    The feed is EVERY SeatGeek sale on the event — ours included — so
--    sg_share = our SeatGeek orders ÷ market SeatGeek sales says how much of
--    the SeatGeek demand we are catching. The feed only covers events the SG
--    pollers track (~1.1k events with sales in any 5-day span), so
--    mkt_tracked = any SG sale on the event in the last 30 days; untracked
--    events return NULL market numbers (the UI shows "—", not a false 0).
--    New columns are appended; `daily` items gain a `mkt` key.
--
-- 2. SPEED. v1 measured 4.2 s for hot·50 inside the function: it built the
--    latest-inventory snapshot for all ~80k events (400k rows, sort spilled to
--    disk) and the daily/market-split JSON for every candidate before ranking.
--    v2 ranks first (hot needs only order counts + days out + lift), cuts to
--    p_limit, then enriches just those rows; inventory for hot rows is one
--    indexed lookup per event (idx_els_daily_event_date). Cold still needs the
--    whole listed book to rank, so it keeps the full snapshot scan. The mode
--    tests read p_mode directly (a one-time filter, so the unused branch never
--    runs) and the events CTE is NOT MATERIALIZED (each join probes
--    events_pkey instead of regex-scanning every event).
--
-- Same parameters and ranking as v1. ADD-ONLY: RETURNS TABLE grows, which
-- CREATE OR REPLACE cannot do in place, and a DROP + CREATE of v1 kept being
-- cancelled at apply (destructive-statement confirmation). So v2 is a new
-- function beside v1; /api/broker/pickups calls v2 and falls back to v1 when
-- v2 is absent. v1 (mig 20261006170000) stays as-is and can be dropped later.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_d0_pickups_v2(
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
  daily            jsonb,     -- [{d, orders, tix, mkt}] oldest → newest; mkt = SG market sales that day (null if untracked)
  orders_window    int,
  tix_window       int,
  sales_window     numeric,
  orders_today     int,
  orders_base_28d  int,
  lift             numeric,   -- window order rate ÷ prior-28-day rate (smoothed)
  trend            text,      -- 'spike' | 'rising' | 'falling' | 'flat'
  by_market        jsonb,     -- {market: our orders} over the window
  open_qty         int,
  open_qty_date    date,
  needed_tix_per_day numeric, -- open_qty ÷ days_out
  pace_ratio       numeric,   -- window tix/day ÷ needed_tix_per_day
  days_to_sellout  numeric,   -- open_qty ÷ window tix/day
  projected_unsold int,
  score            numeric,
  mkt_tracked      boolean,   -- SG public sales feed covers this event (any sale in the last 30 days)
  mkt_sales_window int,       -- SG market sales (distinct) in the window; null if untracked
  mkt_tix_window   int,       -- tickets in those sales
  mkt_sales_today  int,       -- SG market sales so far today (ET)
  sg_share         numeric    -- our SeatGeek orders ÷ SG market sales in the window
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
         p.today - p.nd - 28 AS base_start,
         (p.today - p.nd)::timestamp AT TIME ZONE 'America/New_York' AS ts_start,
         p.today::timestamp          AT TIME ZONE 'America/New_York' AS ts_today
  FROM prm p
),
-- Our order book (same sources + exclusions as v1).
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
    count(*)   FILTER (WHERE o.d >= w.base_start AND o.d < w.d_start)::int AS orders_base,
    count(*)   FILTER (WHERE o.d BETWEEN w.d_start AND w.d_end AND o.mkt = 'SeatGeek')::int AS sg_orders_w
  FROM o CROSS JOIN win w
  GROUP BY o.eid
),
ev AS NOT MATERIALIZED (  -- event facts; inlined per use so each join hits events_pkey instead of scanning all ~140k events
  SELECT e.id AS eid, e.name, e.occurs_at_local, e.venue_name,
         (left(e.occurs_at_local, 10)::date - w.today)::int AS days_out
  FROM events e CROSS JOIN win w
  WHERE left(e.occurs_at_local, 10) ~ '^\d{4}-\d{2}-\d{2}$'
    AND coalesce(e.name, '') !~* '\m(parking|garage)\M'
),
-- HOT: rank on orders × days-out × lift, then cut to p_limit.
hot AS (
  SELECT ev.eid, a.orders_w * ln(1 + ev.days_out / 7.0)
           * sqrt(least((a.orders_w + 1.0) / (a.orders_base * w.nd / 28.0 + 1.0), 9)) AS score
  FROM agg a
  JOIN ev ON ev.eid = a.eid
  CROSS JOIN win w
  WHERE lower(coalesce(p_mode, 'hot')) <> 'cold' AND a.orders_w > 0   -- param-only → one-time filter
    AND ev.days_out BETWEEN w.min_out AND w.max_out
  ORDER BY score DESC, a.orders_w DESC
  LIMIT (SELECT lim FROM prm)
),
-- COLD: needs the whole listed book to rank, so the full snapshot scan lives
-- here only (one-time filter skips it in hot mode).
inv_all AS (
  SELECT DISTINCT ON (s.event_id)
         s.event_id AS eid,
         greatest(coalesce(s.evo_owned_tickets, 0), coalesce(s.sg_owned_tickets, 0)) AS open_qty
  FROM event_listing_snapshot_daily s CROSS JOIN win w
  WHERE lower(coalesce(p_mode, 'hot')) = 'cold' AND s.snapshot_date >= w.today - 1   -- skipped entirely in hot mode
  ORDER BY s.event_id, s.snapshot_date DESC, s.captured_at DESC
),
cold AS (
  SELECT ev.eid,
         greatest(0, round(i.open_qty - coalesce(a.tix_w, 0)::numeric / w.nd * ev.days_out))
           / sqrt(greatest(ev.days_out, 1)) AS score
  FROM inv_all i
  JOIN ev ON ev.eid = i.eid
  LEFT JOIN agg a ON a.eid = i.eid
  CROSS JOIN win w
  WHERE lower(coalesce(p_mode, 'hot')) = 'cold' AND i.open_qty > 0
    AND ev.days_out BETWEEN w.min_out AND w.max_out
    AND ev.days_out > 0
    AND coalesce(a.tix_w, 0)::numeric / w.nd < i.open_qty::numeric / ev.days_out   -- pace < 1
  ORDER BY score DESC
  LIMIT (SELECT lim FROM prm)
),
picked AS (SELECT * FROM hot UNION ALL SELECT * FROM cold),
-- Enrichment: only for the picked rows.
inv AS (
  SELECT p.eid, s.open_qty, s.snapshot_date
  FROM picked p CROSS JOIN win w
  CROSS JOIN LATERAL (
    SELECT greatest(coalesce(d.evo_owned_tickets, 0), coalesce(d.sg_owned_tickets, 0)) AS open_qty,
           d.snapshot_date
    FROM event_listing_snapshot_daily d
    WHERE d.event_id = p.eid AND d.snapshot_date >= w.today - 1
    ORDER BY d.snapshot_date DESC, d.captured_at DESC
    LIMIT 1
  ) s
),
per_day AS MATERIALIZED (  -- read inside a per-row subquery: build once, not once per row
  SELECT o.eid, o.d, count(*)::int AS n, sum(o.q)::int AS q
  FROM o JOIN picked p ON p.eid = o.eid CROSS JOIN win w
  WHERE o.d BETWEEN w.d_start AND w.d_end
  GROUP BY o.eid, o.d
),
per_mkt AS (
  SELECT x.eid, jsonb_object_agg(x.mkt, x.n) AS by_market
  FROM (SELECT o.eid, o.mkt, count(*) AS n
        FROM o JOIN picked p ON p.eid = o.eid CROSS JOIN win w
        WHERE o.d BETWEEN w.d_start AND w.d_end
        GROUP BY o.eid, o.mkt) x
  GROUP BY x.eid
),
-- SeatGeek public sales feed: one row per distinct sale, window + today.
mkt_sales AS (
  SELECT p.eid, (z.sale_at_utc AT TIME ZONE 'America/New_York')::date AS d, z.q
  FROM picked p CROSS JOIN win w
  CROSS JOIN LATERAL (
    SELECT DISTINCT ON (x.sg_sale_id) x.sale_at_utc, coalesce(x.quantity, 1) AS q
    FROM seatgeek_sales_snapshots x
    WHERE x.tevo_event_id = p.eid
      AND x.sale_at_utc >= w.ts_start
      AND x.sg_sale_id IS NOT NULL
    ORDER BY x.sg_sale_id
  ) z
),
mkt_day AS MATERIALIZED (
  SELECT eid, d, count(*)::int AS n, sum(q)::int AS q FROM mkt_sales GROUP BY eid, d
),
mkt_cov AS (
  SELECT p.eid, EXISTS (
           SELECT 1 FROM seatgeek_sales_snapshots x
           WHERE x.tevo_event_id = p.eid AND x.sale_at_utc >= w.ts_today - interval '30 days'
         ) AS tracked
  FROM picked p CROSS JOIN win w
),
base AS (
  SELECT p.eid, p.score AS pick_score, ev.name, ev.occurs_at_local, ev.venue_name, ev.days_out, w.nd,
    coalesce(a.orders_w, 0)      AS orders_w,
    coalesce(a.tix_w, 0)         AS tix_w,
    coalesce(a.sales_w, 0)       AS sales_w,
    coalesce(a.orders_today, 0)  AS orders_today,
    coalesce(a.orders_base, 0)   AS orders_base,
    coalesce(a.sg_orders_w, 0)   AS sg_orders_w,
    i.open_qty, i.snapshot_date,
    round(((coalesce(a.orders_w, 0) + 1.0)
           / (coalesce(a.orders_base, 0) * w.nd / 28.0 + 1.0))::numeric, 2) AS lift,
    coalesce(a.tix_w, 0)::numeric / w.nd AS tix_rate,
    mc.tracked,
    (SELECT jsonb_agg(jsonb_build_object(
              'd', g::date,
              'orders', coalesce(pd.n, 0),
              'tix', coalesce(pd.q, 0),
              'mkt', CASE WHEN mc.tracked THEN coalesce(md.n, 0) END) ORDER BY g)
       FROM generate_series(w.d_start, w.d_end, interval '1 day') g
       LEFT JOIN per_day pd ON pd.eid = p.eid AND pd.d = g::date
       LEFT JOIN mkt_day md ON md.eid = p.eid AND md.d = g::date) AS daily,
    pm.by_market,
    (SELECT sum(md.n) FROM mkt_day md WHERE md.eid = p.eid AND md.d BETWEEN w.d_start AND w.d_end)::int AS mkt_n,
    (SELECT sum(md.q) FROM mkt_day md WHERE md.eid = p.eid AND md.d BETWEEN w.d_start AND w.d_end)::int AS mkt_q,
    (SELECT sum(md.n) FROM mkt_day md WHERE md.eid = p.eid AND md.d >= w.today)::int AS mkt_today
  FROM picked p
  JOIN ev ON ev.eid = p.eid
  CROSS JOIN win w
  LEFT JOIN agg a      ON a.eid = p.eid
  LEFT JOIN inv i      ON i.eid = p.eid
  LEFT JOIN per_mkt pm ON pm.eid = p.eid
  LEFT JOIN mkt_cov mc ON mc.eid = p.eid
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
       round(s.pick_score::numeric, 2) AS score,
       coalesce(s.tracked, false),
       CASE WHEN s.tracked THEN coalesce(s.mkt_n, 0) END,
       CASE WHEN s.tracked THEN coalesce(s.mkt_q, 0) END,
       CASE WHEN s.tracked THEN coalesce(s.mkt_today, 0) END,
       CASE WHEN s.tracked AND coalesce(s.mkt_n, 0) > 0
            THEN round(s.sg_orders_w::numeric / s.mkt_n, 3) END
FROM scored s
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
ORDER BY s.pick_score DESC NULLS LAST, s.orders_w DESC;
$fn$;

REVOKE ALL ON FUNCTION public.get_d0_pickups_v2(text, int, int, int, int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_d0_pickups_v2(text, int, int, int, int) TO service_role;

COMMENT ON FUNCTION public.get_d0_pickups_v2(text, int, int, int, int) IS
  'D0 pickups v2 (successor of get_d0_pickups) — our daily order pace per future event + SeatGeek market sales (distinct, same window) and our SG share. mode hot: selling now, weighted up by days out + lift vs own 28d baseline; mode cold: listed open_qty not clearing at current pace. Read via /api/broker/pickups. Migs 20261006170000, 20261006180000.';
