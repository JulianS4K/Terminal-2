-- Migration 20260709190000 · level:2 · lane:A1 (operator-directed 2026-07-09; D0 consumes)
-- writes: CREATE TABLE sg_owned_stall_chart, sg_owned_stall_sections;
--         CREATE fn rebuild_sg_owned_stall_chart();
--         CREATE RPC get_sg_owned_stall_chart(int,int), get_sg_owned_stall_sections(bigint);
--         cron_policy row + cron.schedule('sg_owned_stall_chart_rebuild_daily'); one initial rebuild.
-- reads:  latest_event_metrics (owned_*), events, seatgeek_event_metrics (sold_*),
--         sg_event_priority_state (sg map/last-known-owned), sd_sales_normalized,
--         event_listing_snapshot_daily, listings_snapshots (owned sections),
--         seatgeek_sales_snapshots + seatgeek_event_xref (section clearing),
--         evo_orders, vivid_orders, tickpick_orders, seatgeek_orders,
--         event_movers_index, prediction_market_xref + prediction_markets,
--         v_event_weather_with_fallback; calls get_listing_price_frontier /
--         predict_listing_sale_date (guarded — NULLs if absent/erroring).
-- pre-reqs: 20260606120000 (sibling chart pattern), 20260708042000 (cron gate
--           timeout capture-and-restore), 20260707200040/20260707200100
--           (clearing-price + frontier models; SOFT dep — calls are guarded).
--
-- ============================================================
-- "MARKET'S SELLING, WE'RE NOT — OWNED, NOT MOVING" (v2, cross-source) — the
-- owned-inventory companion to the sg_market_chart Top-50 (which only charts
-- events we hold ZERO inventory in). Charts future events we HOLD EVO inventory
-- in where the market is demonstrably absorbing tickets while OUR channels
-- (EVO / Vivid / TickPick / SG SellerDirect) sold NOTHING in the trailing 7d.
--
-- v1 was SG-tape-only: of 2,027 owned future events it could see 562 (28%).
-- v2 blends every market signal we collect (coverage measured 2026-07-09):
--
--   TIER 'sales'          — real sales tape: SG broker tape (DISTINCT ON
--                           sg_sale_id — §3 landmine) blended with SeatData
--                           sales (sd_sales_normalized; unknown qty counts 1,
--                           matching the Top-50 blend convention). 562 events.
--   TIER 'absorption_evo' — day-over-day DROPS in evo_tickets_count from
--                           event_listing_snapshot_daily (3 slots/day, kept
--                           indefinitely). Tickets/day. Requires >=3 adjacent
--                           day-pairs and >=2 tickets/day. A proxy — confounds
--                           sales with delistings — so it's labeled, and
--                           price_trend_7d_pct is carried so falling-inventory-
--                           with-rising-price (real demand) reads differently
--                           from falling-with-falling (reprice/delist).
--   TIER 'absorption_sh'  — same on td_sh_listings (StubHub listings/day;
--                           unit is LISTINGS, so supply is measured against
--                           our owned GROUPS, not tickets). Floor 0.5/day.
--   (dark — no signal anywhere: measured 3 of 2,027 events — not charted;
--    a chart of "the market is selling" can't include events with no
--    observable market. AXS/TM primary-market deltas are the future T3.)
--
--   Coverage with tiers: sales 562 + absorption-only 1,460 => 2,024 of 2,027.
--
-- RANKING — three legible percentiles, 0..3 (heat is ranked WITHIN basis so
-- tickets/day never competes against listings/day):
--   stall_score = pct_heat     percent_rank(vel_per_day) PARTITION BY basis
--               + pct_exposure percent_rank(owned_tickets × ask-or-median $)
--               + pct_supply   percent_rank(supply_ratio)
--   days_of_supply = our position ÷ market velocity (tickets÷tickets/day, or
--   owned groups÷listings/day on the sh basis). supply_ratio = days_of_supply
--   ÷ days-to-event, capped at 10 — ratio > 1 means AT the market's own rate
--   our position does not clear before the event ("act now", the FE reds it).
--
-- PRESCRIPTIVE (top 30 ranked rows + their sections; wall-clock-bounded loop,
-- every model call EXCEPTION-guarded): our per-section holdings come from the
-- latest listings_snapshots capture (is_owned AND brokerage_id=1768 — §3);
-- per section we store SG+SD 30d realized sales + clearing median + our
-- premium, and call get_listing_price_frontier (recommended/clear-by-event
-- ask) + predict_listing_sale_date at OUR median ask (P(sell before event),
-- p50 sell-by). The event row carries its largest owned section's numbers;
-- sg_owned_stall_sections carries every owned section (<=6 by qty) for the
-- panel's expandable drill.
--
-- COLOR (display-only per PROJECT_BIBLE §6a — never gates, never prices):
-- movers-index category (merged/30d), latest prediction-market implied prob
-- via prediction_market_xref, weather (outdoor precip risk) via
-- v_event_weather_with_fallback.
--
-- OUR-SALES DEFINITION (per channel, "not-dead" orders, created in window):
--   evo:      seller_brokerage_id = 1768 AND state NOT IN
--             ('rejected','canceled','canceled_post_acceptance')
--   vivid:    upper(status) NOT IN ('CANCELED','CANCELLED','REJECTED')
--   tickpick: upper(order_status) NOT IN ('REJECTED','CANCELED','CANCELLED')
--             (order_status carries CONFIRMED, absent from order_status_xref —
--             per-source predicates instead of the xref join on purpose)
--   seatgeek: lower(status) <> 'cancelled' (SellerDirect orders dark since
--             2026-06 — union-included so the chart self-heals when relit;
--             gaps tracked in KANBAN A1-OPS-30)
--   Strict is_sale_succeeded is deliberately NOT used: a real sale sits in
--   accepted/pending for days before fulfilment.
--   PLUS owned_drop_7d: decline of evo_owned_tickets in the daily snapshot —
--   inventory leaving our book with no order row = delist OR a sale on a
--   channel we don't ingest (the A1-OPS-30 blindness); FE badges it.
--
-- SG-side book/firehose stays deliberately dark since 2026-06-26
-- (RESOURCES_BIBLE §5) — sg_owned_* columns are last-known info, never a gate.
--
-- PENDING OPERATOR APPLY: prod application is gated (CLAUDE.md §1). The final
-- SELECT rebuild_sg_owned_stall_chart() seeds today's chart on apply.
-- ROLLBACK: cron.unschedule('sg_owned_stall_chart_rebuild_daily');
-- DROP FUNCTION get_sg_owned_stall_chart(int,int), get_sg_owned_stall_sections(bigint),
-- rebuild_sg_owned_stall_chart(); DROP TABLE sg_owned_stall_sections,
-- sg_owned_stall_chart; DELETE FROM cron_policy WHERE jobname =
-- 'sg_owned_stall_chart_rebuild_daily'.
-- ============================================================

-- ---------- 1. Chart history table (one ranked set per UTC day) ----------
CREATE TABLE IF NOT EXISTS public.sg_owned_stall_chart (
  chart_date           date        NOT NULL,
  tevo_event_id        bigint      NOT NULL,
  sg_event_id          bigint,           -- NULL when the event isn't SG-mapped
  rank                 integer     NOT NULL,
  stall_score          numeric     NOT NULL,   -- 0..3
  pct_heat             numeric,
  pct_exposure         numeric,
  pct_supply           numeric,
  -- market velocity (tiered)
  vel_basis            text        NOT NULL,   -- sales | absorption_evo | absorption_sh
  vel_per_day          numeric     NOT NULL,
  vel_unit             text        NOT NULL,   -- tickets | listings
  days_observed        integer,                -- tape: days with sales; proxy: day-pairs
  clearing_median      numeric,                -- blended realized median (sales tier)
  -- sales-tape detail
  sg_ma7_volume        numeric,
  sg_ma7_median        numeric,
  sg_ma7_gross         numeric,
  sd_ma7_volume        numeric,
  sd_ma7_median        numeric,
  -- absorption detail
  absorb_evo_day       numeric,                -- avg daily net EVO ticket drop (7d)
  absorb_sh_day        numeric,                -- avg daily net SH listings drop (7d)
  price_trend_7d_pct   numeric,                -- amalgam/evo median move over window
  -- our position
  owned_tickets        integer,
  owned_groups         integer,
  owned_median_ask     numeric,
  owned_as_of          timestamptz,
  ask_premium_pct      numeric,                -- our ask vs clearing_median
  owned_drop_7d        integer,                -- our own book depletion (see header)
  sg_owned_listings    integer,                -- last-known SG-side book (info)
  sg_owned_as_of       timestamptz,
  our_sales_30d        integer,
  our_last_sale_at     timestamptz,
  our_last_sale_source text,
  -- sell-through risk
  dte                  integer,
  days_of_supply       numeric,
  supply_ratio         numeric,                -- days_of_supply / dte, capped 10
  -- prescriptive (top rows; model-derived, guarded)
  top_owned_section    text,
  rec_ask              numeric,
  clear_by_event_ask   numeric,
  p_sell_at_ask_pct    numeric,
  p50_sell_by          date,
  -- color commentary (§6a — display-only)
  movers_category      text,
  pm_prob_pct          numeric,
  pm_title             text,
  weather_kind         text,
  weather_precip_pct   numeric,
  weather_summary      text,
  is_indoor            boolean,
  -- Billboard mechanics
  prev_rank            integer,
  peak_rank            integer,
  days_on_chart        integer,
  -- display (canonical TEvo, not SG — population is no longer SG-gated)
  event_name           text,
  venue_name           text,
  occurs_at            timestamptz,
  PRIMARY KEY (chart_date, tevo_event_id)
);

CREATE INDEX IF NOT EXISTS sg_owned_stall_chart_date_rank_idx
  ON public.sg_owned_stall_chart (chart_date, rank);
CREATE INDEX IF NOT EXISTS sg_owned_stall_chart_event_idx
  ON public.sg_owned_stall_chart (tevo_event_id);

REVOKE ALL ON public.sg_owned_stall_chart FROM anon, authenticated;

-- ---------- 1b. Per-section drill (top charted events only) ----------
CREATE TABLE IF NOT EXISTS public.sg_owned_stall_sections (
  chart_date           date    NOT NULL,
  tevo_event_id        bigint  NOT NULL,
  section              text    NOT NULL,
  our_qty              integer,
  our_listings         integer,
  our_median_ask       numeric,
  sec_sales_30d        integer,          -- SG+SD realized sales in the section
  sec_clearing_median  numeric,          -- realized median sold price (30d)
  sec_premium_pct      numeric,          -- our ask vs the section's clearing
  rec_ask              numeric,          -- frontier recommended (fair-clearing anchored)
  clear_by_event_ask   numeric,          -- highest ask still >=50% to clear in time
  p_sell_at_ask_pct    numeric,          -- P(sell before event) at OUR median ask
  p50_sell_by          date,
  PRIMARY KEY (chart_date, tevo_event_id, section)
);

CREATE INDEX IF NOT EXISTS sg_owned_stall_sections_event_idx
  ON public.sg_owned_stall_sections (tevo_event_id, chart_date);

REVOKE ALL ON public.sg_owned_stall_sections FROM anon, authenticated;

-- ---------- 2. Daily rebuild function ----------
CREATE OR REPLACE FUNCTION public.rebuild_sg_owned_stall_chart()
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_today    date := (now() AT TIME ZONE 'UTC')::date;
  v_prev     date;
  v_count    int := 0;
  v_deadline timestamptz;   -- wall-clock budget for the model loop (§5 self-bounding)
  v_ev       record;
  v_sec      record;
  v_j        jsonb;
  v_rec      numeric; v_cbe numeric; v_psell numeric; v_p50 date;
BEGIN
  SELECT max(chart_date) INTO v_prev
  FROM public.sg_owned_stall_chart WHERE chart_date < v_today;

  DELETE FROM public.sg_owned_stall_chart    WHERE chart_date = v_today;  -- idempotent re-run
  DELETE FROM public.sg_owned_stall_sections WHERE chart_date = v_today;

  WITH owned AS (
    -- our current EVO book, canonical event fields; cancel/ignore filtered
    SELECT l.event_id AS tevo_event_id,
           l.owned_tickets_count, l.owned_groups_count, l.owned_median_retail,
           l.captured_at AS owned_as_of,
           e.name AS event_name, e.venue_name,
           NULLIF(e.occurs_at_local,'')::timestamptz AS occurs_at
    FROM public.latest_event_metrics l
    JOIN public.events e ON e.id = l.event_id
    WHERE coalesce(l.owned_tickets_count, 0) > 0
      AND e.state IS DISTINCT FROM 'ignored'
      AND e.name !~* '(cancell?ed|postponed)'
      AND NULLIF(e.occurs_at_local,'')::timestamptz > now()
  ),
  sg_map AS (
    -- one SG event per tevo id (hottest tape wins); also last-known SG-side book
    SELECT DISTINCT ON (p.tevo_event_id)
      p.tevo_event_id, p.sg_event_id
    FROM public.sg_event_priority_state p
    JOIN owned o ON o.tevo_event_id = p.tevo_event_id
    ORDER BY p.tevo_event_id, coalesce(p.owned_count_last_7d,0) DESC, p.sg_event_id
  ),
  sg_daily AS (
    -- latest hourly rollup per (sg event, UTC day); sold_* is trailing-24h
    SELECT DISTINCT ON (m.sg_event_id, (m.captured_at AT TIME ZONE 'UTC')::date)
      m.sg_event_id, m.sold_quantity, m.sold_price_median, m.sold_gross
    FROM public.seatgeek_event_metrics m
    JOIN sg_map g ON g.sg_event_id = m.sg_event_id
    WHERE m.captured_at > now() - interval '7 days'
      AND coalesce(m.sold_quantity, 0) > 0
    ORDER BY m.sg_event_id, (m.captured_at AT TIME ZONE 'UTC')::date, m.captured_at DESC
  ),
  sg_ma AS (
    SELECT sg_event_id,
      count(*)                        AS sg_days,
      avg(sold_quantity)::numeric     AS sg_ma7_volume,
      avg(sold_price_median)::numeric AS sg_ma7_median,
      avg(sold_gross)::numeric        AS sg_ma7_gross
    FROM sg_daily GROUP BY sg_event_id
  ),
  sd_ma AS (
    -- SeatData realized sales, 7d: tickets/day (unknown qty counts 1) + median
    SELECT s.tevo_event_id,
      count(DISTINCT s.sale_timestamp::date) AS sd_days,
      (sum(coalesce(NULLIF(s.quantity,0),1))::numeric
         / greatest(count(DISTINCT s.sale_timestamp::date),1)) AS sd_ma7_volume,
      (percentile_cont(0.5) WITHIN GROUP (ORDER BY s.price))::numeric AS sd_ma7_median
    FROM public.sd_sales_normalized s
    JOIN owned o ON o.tevo_event_id = s.tevo_event_id
    WHERE s.sale_timestamp > now() - interval '7 days'
    GROUP BY s.tevo_event_id
  ),
  snap_series AS (
    -- one row per (event, snapshot day): the day's LAST slot
    SELECT DISTINCT ON (d.event_id, d.snapshot_date)
      d.event_id AS tevo_event_id, d.snapshot_date,
      d.evo_tickets_count, d.td_sh_listings, d.evo_owned_tickets,
      coalesce(d.amalgam_median, d.evo_retail_median) AS day_median
    FROM public.event_listing_snapshot_daily d
    JOIN owned o ON o.tevo_event_id = d.event_id
    WHERE d.snapshot_date > v_today - 8
    ORDER BY d.event_id, d.snapshot_date, d.captured_at DESC
  ),
  snap_pairs AS (
    -- adjacent-day pairs only (date diff = 1); drops are floored at 0
    SELECT tevo_event_id,
      count(*) FILTER (WHERE prev_evo IS NOT NULL AND evo_tickets_count IS NOT NULL) AS evo_pairs,
      avg(greatest(prev_evo - evo_tickets_count, 0))
        FILTER (WHERE prev_evo IS NOT NULL AND evo_tickets_count IS NOT NULL) AS absorb_evo_day,
      count(*) FILTER (WHERE prev_sh IS NOT NULL AND td_sh_listings IS NOT NULL) AS sh_pairs,
      avg(greatest(prev_sh - td_sh_listings, 0))
        FILTER (WHERE prev_sh IS NOT NULL AND td_sh_listings IS NOT NULL) AS absorb_sh_day
    FROM (
      SELECT tevo_event_id, snapshot_date, evo_tickets_count, td_sh_listings,
        CASE WHEN lag(snapshot_date) OVER w = snapshot_date - 1
             THEN lag(evo_tickets_count) OVER w END AS prev_evo,
        CASE WHEN lag(snapshot_date) OVER w = snapshot_date - 1
             THEN lag(td_sh_listings) OVER w END AS prev_sh
      FROM snap_series
      WINDOW w AS (PARTITION BY tevo_event_id ORDER BY snapshot_date)
    ) p
    GROUP BY tevo_event_id
  ),
  snap_trend AS (
    -- window endpoints: own-book depletion + price direction
    SELECT tevo_event_id,
      (first_value(evo_owned_tickets) OVER w_asc
         - first_value(evo_owned_tickets) OVER w_desc) AS owned_drop_7d,
      CASE WHEN first_value(day_median) OVER w_asc > 0
           THEN round(100 * (first_value(day_median) OVER w_desc
                             - first_value(day_median) OVER w_asc)
                      / first_value(day_median) OVER w_asc, 1) END AS price_trend_7d_pct,
      row_number() OVER w_asc AS rn
    FROM snap_series
    WINDOW w_asc  AS (PARTITION BY tevo_event_id ORDER BY snapshot_date
                      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING),
           w_desc AS (PARTITION BY tevo_event_id ORDER BY snapshot_date DESC
                      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
  ),
  ours AS (
    -- our own orders, all channels, "not-dead" statuses (see header)
    SELECT o.tevo_event_id, o.evo_created_at AS created_at, 'evo'::text AS src
    FROM public.evo_orders o
    WHERE o.seller_brokerage_id = 1768
      AND o.state NOT IN ('rejected','canceled','canceled_post_acceptance')
      AND o.tevo_event_id IS NOT NULL
    UNION ALL
    SELECT v.tevo_event_id, v.ordered_at, 'vivid'
    FROM public.vivid_orders v
    WHERE upper(coalesce(v.status,'')) NOT IN ('CANCELED','CANCELLED','REJECTED')
      AND v.tevo_event_id IS NOT NULL
    UNION ALL
    SELECT t.tevo_event_id, t.ordered_at, 'tickpick'
    FROM public.tickpick_orders t
    WHERE upper(coalesce(t.order_status,'')) NOT IN ('REJECTED','CANCELED','CANCELLED')
      AND t.tevo_event_id IS NOT NULL
    UNION ALL
    SELECT s2.tevo_event_id, s2.created_at_sg, 'seatgeek'
    FROM public.seatgeek_orders s2
    WHERE lower(coalesce(s2.status,'')) <> 'cancelled'
      AND s2.tevo_event_id IS NOT NULL
  ),
  our_agg AS (
    SELECT tevo_event_id,
      count(*) FILTER (WHERE created_at > now() - interval '7 days')  AS sales_7d,
      count(*) FILTER (WHERE created_at > now() - interval '30 days') AS sales_30d,
      max(created_at) AS last_sale_at
    FROM ours GROUP BY tevo_event_id
  ),
  our_last_src AS (
    SELECT DISTINCT ON (tevo_event_id) tevo_event_id, src AS last_source
    FROM ours ORDER BY tevo_event_id, created_at DESC
  ),
  assembled AS (
    SELECT o.*,
      g.sg_event_id,
      m.sg_days, m.sg_ma7_volume, m.sg_ma7_median, m.sg_ma7_gross,
      d.sd_days, d.sd_ma7_volume, d.sd_ma7_median,
      p.evo_pairs, p.absorb_evo_day, p.sh_pairs, p.absorb_sh_day,
      t.owned_drop_7d, t.price_trend_7d_pct,
      coalesce(a.sales_7d, 0)  AS our_sales_7d,
      coalesce(a.sales_30d, 0) AS our_sales_30d,
      a.last_sale_at           AS our_last_sale_at,
      ls.last_source           AS our_last_sale_source,
      greatest(1, (o.occurs_at::date - v_today))::int AS dte,
      -- tier resolution (sales > absorption_evo > absorption_sh > dark)
      CASE
        WHEN coalesce(m.sg_days,0) >= 2 OR coalesce(d.sd_days,0) >= 2 THEN 'sales'
        WHEN coalesce(p.evo_pairs,0) >= 3 AND coalesce(p.absorb_evo_day,0) >= 2   THEN 'absorption_evo'
        WHEN coalesce(p.sh_pairs,0)  >= 3 AND coalesce(p.absorb_sh_day,0) >= 0.5  THEN 'absorption_sh'
        ELSE 'dark'
      END AS vel_basis
    FROM owned o
    LEFT JOIN sg_map    g  USING (tevo_event_id)
    LEFT JOIN sg_ma     m  ON m.sg_event_id = g.sg_event_id
    LEFT JOIN sd_ma     d  USING (tevo_event_id)
    LEFT JOIN snap_pairs p USING (tevo_event_id)
    LEFT JOIN (SELECT tevo_event_id, owned_drop_7d, price_trend_7d_pct
               FROM snap_trend WHERE rn = 1) t USING (tevo_event_id)
    LEFT JOIN our_agg      a  USING (tevo_event_id)
    LEFT JOIN our_last_src ls USING (tevo_event_id)
  ),
  elig AS (
    SELECT a.*,
      CASE a.vel_basis
        WHEN 'sales'          THEN coalesce(a.sg_ma7_volume,0) + coalesce(a.sd_ma7_volume,0)
        WHEN 'absorption_evo' THEN a.absorb_evo_day
        WHEN 'absorption_sh'  THEN a.absorb_sh_day
      END AS vel_per_day,
      CASE a.vel_basis WHEN 'absorption_sh' THEN 'listings' ELSE 'tickets' END AS vel_unit,
      CASE a.vel_basis
        WHEN 'sales' THEN greatest(coalesce(a.sg_days,0), coalesce(a.sd_days,0))
        WHEN 'absorption_evo' THEN a.evo_pairs
        WHEN 'absorption_sh'  THEN a.sh_pairs
      END AS days_observed,
      -- blended realized clearing median (volume-weighted; sales tier only)
      CASE WHEN a.vel_basis = 'sales' THEN
        (coalesce(a.sg_ma7_median,0) * coalesce(a.sg_ma7_volume,0)
         + coalesce(a.sd_ma7_median,0) * coalesce(a.sd_ma7_volume,0))
        / NULLIF(coalesce(a.sg_ma7_volume,0) + coalesce(a.sd_ma7_volume,0), 0)
      END AS clearing_median
    FROM assembled a
    WHERE a.vel_basis <> 'dark'
      AND a.our_sales_7d = 0            -- "we're not": no own sale in 7d
  ),
  risk AS (
    SELECT e.*,
      CASE WHEN e.vel_per_day > 0 THEN
        round((CASE e.vel_basis WHEN 'absorption_sh'
                 THEN coalesce(e.owned_groups_count, e.owned_tickets_count)
                 ELSE e.owned_tickets_count END)::numeric / e.vel_per_day, 1)
      END AS days_of_supply
    FROM elig e
  ),
  scored AS (
    SELECT r2.*,
      least(coalesce(r2.days_of_supply / NULLIF(r2.dte,0), 0), 10) AS supply_ratio,
      -- percent_rank() is double precision; cast so round() resolves.
      -- heat is ranked within basis: tickets/day never competes with listings/day.
      (percent_rank() OVER (PARTITION BY r2.vel_basis ORDER BY r2.vel_per_day))::numeric AS pct_heat,
      (percent_rank() OVER (ORDER BY
         r2.owned_tickets_count * coalesce(r2.owned_median_retail, r2.clearing_median, 0)
       ))::numeric AS pct_exposure,
      (percent_rank() OVER (ORDER BY
         least(coalesce(r2.days_of_supply / NULLIF(r2.dte,0), 0), 10)
       ))::numeric AS pct_supply
    FROM risk r2
  ),
  ranked AS (
    SELECT s3.*,
      (pct_heat + pct_exposure + pct_supply) AS stall_score,
      row_number() OVER (
        ORDER BY (pct_heat + pct_exposure + pct_supply) DESC,
                 s3.sg_ma7_gross DESC NULLS LAST, s3.vel_per_day DESC
      ) AS rnk
    FROM scored s3
  )
  INSERT INTO public.sg_owned_stall_chart (
    chart_date, tevo_event_id, sg_event_id, rank, stall_score,
    pct_heat, pct_exposure, pct_supply,
    vel_basis, vel_per_day, vel_unit, days_observed, clearing_median,
    sg_ma7_volume, sg_ma7_median, sg_ma7_gross, sd_ma7_volume, sd_ma7_median,
    absorb_evo_day, absorb_sh_day, price_trend_7d_pct,
    owned_tickets, owned_groups, owned_median_ask, owned_as_of,
    ask_premium_pct, owned_drop_7d, sg_owned_listings, sg_owned_as_of,
    our_sales_30d, our_last_sale_at, our_last_sale_source,
    dte, days_of_supply, supply_ratio,
    movers_category, pm_prob_pct, pm_title,
    weather_kind, weather_precip_pct, weather_summary, is_indoor,
    prev_rank, peak_rank, days_on_chart,
    event_name, venue_name, occurs_at)
  SELECT
    v_today, k.tevo_event_id, k.sg_event_id, k.rnk::int, round(k.stall_score, 4),
    round(k.pct_heat, 4), round(k.pct_exposure, 4), round(k.pct_supply, 4),
    k.vel_basis, round(k.vel_per_day, 1), k.vel_unit, k.days_observed,
    round(k.clearing_median, 2),
    round(k.sg_ma7_volume, 1), round(k.sg_ma7_median, 2), round(k.sg_ma7_gross, 2),
    round(k.sd_ma7_volume, 1), round(k.sd_ma7_median, 2),
    round(k.absorb_evo_day, 1), round(k.absorb_sh_day, 1), k.price_trend_7d_pct,
    k.owned_tickets_count, k.owned_groups_count, round(k.owned_median_retail, 2), k.owned_as_of,
    CASE WHEN k.clearing_median > 0 AND k.owned_median_retail IS NOT NULL
         THEN round(100 * (k.owned_median_retail - k.clearing_median) / k.clearing_median, 1)
    END,
    k.owned_drop_7d,
    sgown.listings_owned_count, sgown.captured_at,
    k.our_sales_30d, k.our_last_sale_at, k.our_last_sale_source,
    k.dte, k.days_of_supply, round(k.supply_ratio, 2),
    mv.category,
    CASE WHEN pm.prob IS NULL THEN NULL
         WHEN pm.prob <= 1 THEN round(pm.prob * 100, 1)
         ELSE round(pm.prob, 1) END,
    pm.title,
    w.weather_kind, w.precip_pct, w.weather_summary, w.is_indoor,
    prev.rank,
    LEAST(k.rnk::int,
          coalesce((SELECT min(h.rank) FROM public.sg_owned_stall_chart h
                    WHERE h.tevo_event_id = k.tevo_event_id), k.rnk::int)),
    CASE WHEN prev.rank IS NOT NULL THEN coalesce(prev.days_on_chart, 0) + 1 ELSE 1 END,
    k.event_name, k.venue_name, k.occurs_at
  FROM ranked k
  LEFT JOIN public.sg_owned_stall_chart prev
    ON prev.tevo_event_id = k.tevo_event_id AND prev.chart_date = v_prev
  LEFT JOIN LATERAL (
    -- last-known SG-side broker-owned listings (info only; feed dark 06-26)
    SELECT sem.listings_owned_count, sem.captured_at
    FROM public.seatgeek_event_metrics sem
    WHERE sem.sg_event_id = k.sg_event_id
      AND coalesce(sem.listings_owned_count, 0) > 0
    ORDER BY sem.captured_at DESC LIMIT 1
  ) sgown ON true
  LEFT JOIN LATERAL (
    SELECT mi.category
    FROM public.event_movers_index mi
    WHERE mi.event_id = k.tevo_event_id AND mi.source = 'merged' AND mi.window_days = 30
    ORDER BY mi.last_computed_at DESC LIMIT 1
  ) mv ON true
  LEFT JOIN LATERAL (
    SELECT coalesce(pmk.last_price, pmk.yes_price) AS prob, pmk.title
    FROM public.prediction_market_xref px
    JOIN public.prediction_markets pmk
      ON pmk.market_id = px.market_id AND pmk.source = px.source
    WHERE px.tevo_event_id = k.tevo_event_id
    ORDER BY pmk.updated_at DESC NULLS LAST LIMIT 1
  ) pm ON true
  LEFT JOIN LATERAL (
    SELECT vw.weather_kind, vw.precip_pct, vw.weather_summary, vw.is_indoor
    FROM public.v_event_weather_with_fallback vw
    WHERE vw.tevo_event_id = k.tevo_event_id LIMIT 1
  ) w ON true;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- ---- prescriptive pass: top 30 rows -> per-section drill + model asks ----
  -- Wall-clock-bounded (§5 self-bounding-loop doctrine); every model call is
  -- EXCEPTION-guarded so a model regression can never kill the chart build.
  v_deadline := clock_timestamp() + interval '180 seconds';

  FOR v_ev IN
    SELECT c.tevo_event_id
    FROM public.sg_owned_stall_chart c
    WHERE c.chart_date = v_today
    ORDER BY c.rank
    LIMIT 30
  LOOP
    EXIT WHEN clock_timestamp() > v_deadline;

    -- our per-section holdings from the latest firehose capture (ours = §3:
    -- is_owned AND brokerage_id = 1768), capped at 6 sections by qty
    FOR v_sec IN
      SELECT lower(btrim(ls.section)) AS section,
             sum(ls.quantity)::int    AS our_qty,
             count(*)::int            AS our_listings,
             (percentile_cont(0.5) WITHIN GROUP (ORDER BY ls.retail_price))::numeric AS our_median_ask
      FROM public.listings_snapshots ls
      JOIN (SELECT max(captured_at) c FROM public.listings_snapshots
            WHERE event_id = v_ev.tevo_event_id) mx ON ls.captured_at = mx.c
      WHERE ls.event_id = v_ev.tevo_event_id
        AND ls.is_owned = true AND ls.brokerage_id = 1768
        AND coalesce(ls.is_ancillary, false) = false
        AND ls.section IS NOT NULL
      GROUP BY lower(btrim(ls.section))
      ORDER BY sum(ls.quantity) DESC
      LIMIT 6
    LOOP
      EXIT WHEN clock_timestamp() > v_deadline;

      v_j := NULL; v_rec := NULL; v_cbe := NULL; v_psell := NULL; v_p50 := NULL;

      BEGIN
        v_j := public.get_listing_price_frontier(v_ev.tevo_event_id, v_sec.section);
        v_rec := coalesce((v_j->>'recommended_ask')::numeric, (v_j->>'fair_clearing')::numeric);
        v_cbe := (v_j->>'clear_by_event_ask')::numeric;
      EXCEPTION WHEN OTHERS THEN v_j := NULL;
      END;

      IF v_sec.our_median_ask IS NOT NULL THEN
        BEGIN
          v_j := public.predict_listing_sale_date(v_ev.tevo_event_id, v_sec.section, v_sec.our_median_ask);
          v_psell := (v_j->>'p_sell_before_event_pct')::numeric;
          v_p50   := (v_j->>'p50_sell_by')::date;
        EXCEPTION WHEN OTHERS THEN v_j := NULL;
        END;
      END IF;

      INSERT INTO public.sg_owned_stall_sections (
        chart_date, tevo_event_id, section, our_qty, our_listings, our_median_ask,
        sec_sales_30d, sec_clearing_median, sec_premium_pct,
        rec_ask, clear_by_event_ask, p_sell_at_ask_pct, p50_sell_by)
      SELECT
        v_today, v_ev.tevo_event_id, v_sec.section, v_sec.our_qty, v_sec.our_listings,
        round(v_sec.our_median_ask::numeric, 2),
        sales.n, round(sales.med, 2),
        CASE WHEN sales.med > 0 AND v_sec.our_median_ask IS NOT NULL
             THEN round(100 * (v_sec.our_median_ask - sales.med) / sales.med, 1) END,
        round(v_rec, 2), round(v_cbe, 2), v_psell, v_p50
      FROM (
        -- section-level realized clearing: SG tape (deduped) + SeatData, 30d.
        -- DISTINCT ON is wrapped before the UNION (§3 landmine); the aggregate
        -- always yields one row, so zero-sale sections still get a drill row.
        SELECT count(*)::int AS n,
               (percentile_cont(0.5) WITHIN GROUP (ORDER BY u.price))::numeric AS med
        FROM (
          SELECT q1.price FROM (
            SELECT DISTINCT ON (ss.sg_sale_id) ss.broadcast_price AS price
            FROM public.seatgeek_sales_snapshots ss
            JOIN public.seatgeek_event_xref x ON x.sg_event_id = ss.sg_event_id
            WHERE x.tevo_event_id = v_ev.tevo_event_id
              AND lower(btrim(ss.section)) = v_sec.section
              AND ss.sale_at_utc >= now() - interval '30 days'
            ORDER BY ss.sg_sale_id, ss.pulled_at DESC
          ) q1
          UNION ALL
          SELECT sd.price
          FROM public.sd_sales_normalized sd
          WHERE sd.tevo_event_id = v_ev.tevo_event_id
            AND (lower(btrim(coalesce(sd.canonical_section,''))) = v_sec.section
                 OR lower(btrim(coalesce(sd.sd_section,''))) = v_sec.section)
            AND sd.sale_timestamp >= now() - interval '30 days'
        ) u
      ) sales;
    END LOOP;

    -- lift the largest owned section's numbers onto the event row
    UPDATE public.sg_owned_stall_chart c
    SET top_owned_section  = sec.section,
        rec_ask            = sec.rec_ask,
        clear_by_event_ask = sec.clear_by_event_ask,
        p_sell_at_ask_pct  = sec.p_sell_at_ask_pct,
        p50_sell_by        = sec.p50_sell_by
    FROM (
      SELECT section, rec_ask, clear_by_event_ask, p_sell_at_ask_pct, p50_sell_by
      FROM public.sg_owned_stall_sections
      WHERE chart_date = v_today AND tevo_event_id = v_ev.tevo_event_id
      ORDER BY our_qty DESC NULLS LAST LIMIT 1
    ) sec
    WHERE c.chart_date = v_today AND c.tevo_event_id = v_ev.tevo_event_id;
  END LOOP;

  -- retention: keep 90 days of chart history
  DELETE FROM public.sg_owned_stall_chart    WHERE chart_date < v_today - 90;
  DELETE FROM public.sg_owned_stall_sections WHERE chart_date < v_today - 90;

  RETURN v_count;
END $func$;

REVOKE ALL ON FUNCTION public.rebuild_sg_owned_stall_chart() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_sg_owned_stall_chart() TO service_role;

COMMENT ON FUNCTION public.rebuild_sg_owned_stall_chart() IS
  'Rebuilds today''s sg_owned_stall_chart (+ per-section drill for the top 30): '
  'future EVO-owned events where the market is absorbing tickets (tiered signal: '
  'SG+SeatData sales tape, else EVO/SH listings-absorption proxy from '
  'event_listing_snapshot_daily) while our own channels (evo/vivid/tickpick/sg) '
  'sold NOTHING in 7d. stall_score = pct(heat within basis) + pct($ exposure) + '
  'pct(days-of-supply / days-to-event). Top rows get frontier/clearing-model asks '
  '(guarded). Billboard mechanics mirror sg_market_chart. Daily cron @ 11:20 UTC.';

-- ---------- 3. Read RPCs (email-gated) ----------
CREATE OR REPLACE FUNCTION public.get_sg_owned_stall_chart(
  p_offset integer DEFAULT 0,
  p_limit  integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_email text;
  v_date  date;
  v_total int;
  v_rows  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT max(chart_date) INTO v_date FROM public.sg_owned_stall_chart;
  IF v_date IS NULL THEN
    RETURN jsonb_build_object('chart_date', NULL, 'total', 0, 'rows', '[]'::jsonb);
  END IF;

  SELECT count(*) INTO v_total FROM public.sg_owned_stall_chart WHERE chart_date = v_date;

  SELECT coalesce(jsonb_agg(r.obj ORDER BY (r.obj->>'rank')::int), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'rank',                 m.rank,
      'prev_rank',            m.prev_rank,
      'rank_delta',           CASE WHEN m.prev_rank IS NULL THEN NULL ELSE m.prev_rank - m.rank END,
      'is_new',               (m.prev_rank IS NULL),
      'peak_rank',            m.peak_rank,
      'days_on_chart',        m.days_on_chart,
      'tevo_event_id',        m.tevo_event_id,
      'sg_event_id',          m.sg_event_id,
      'event_name',           m.event_name,
      'venue_name',           m.venue_name,
      'occurs_at',            to_char(m.occurs_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'vel_basis',            m.vel_basis,
      'vel_per_day',          m.vel_per_day,
      'vel_unit',             m.vel_unit,
      'days_observed',        m.days_observed,
      'clearing_median',      m.clearing_median,
      'sg_ma7_volume',        m.sg_ma7_volume,
      'sg_ma7_median',        m.sg_ma7_median,
      'sg_ma7_gross',         m.sg_ma7_gross,
      'sd_ma7_volume',        m.sd_ma7_volume,
      'sd_ma7_median',        m.sd_ma7_median,
      'absorb_evo_day',       m.absorb_evo_day,
      'absorb_sh_day',        m.absorb_sh_day,
      'price_trend_7d_pct',   m.price_trend_7d_pct,
      'owned_tickets',        m.owned_tickets,
      'owned_groups',         m.owned_groups,
      'owned_median_ask',     m.owned_median_ask,
      'owned_as_of',          to_char(m.owned_as_of AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'ask_premium_pct',      m.ask_premium_pct,
      'owned_drop_7d',        m.owned_drop_7d,
      'sg_owned_listings',    m.sg_owned_listings,
      'sg_owned_as_of',       to_char(m.sg_owned_as_of AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'our_sales_30d',        m.our_sales_30d,
      'our_last_sale_at',     to_char(m.our_last_sale_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'our_last_sale_source', m.our_last_sale_source
    ) || jsonb_build_object(   -- split: jsonb_build_object caps at 100 args
      'dte',                  m.dte,
      'days_of_supply',       m.days_of_supply,
      'supply_ratio',         m.supply_ratio,
      'top_owned_section',    m.top_owned_section,
      'rec_ask',              m.rec_ask,
      'clear_by_event_ask',   m.clear_by_event_ask,
      'p_sell_at_ask_pct',    m.p_sell_at_ask_pct,
      'p50_sell_by',          to_char(m.p50_sell_by, 'YYYY-MM-DD'),
      'movers_category',      m.movers_category,
      'pm_prob_pct',          m.pm_prob_pct,
      'pm_title',             m.pm_title,
      'weather_kind',         m.weather_kind,
      'weather_precip_pct',   m.weather_precip_pct,
      'weather_summary',      m.weather_summary,
      'is_indoor',            m.is_indoor,
      'pct_heat',             m.pct_heat,
      'pct_exposure',         m.pct_exposure,
      'pct_supply',           m.pct_supply,
      'stall_score',          m.stall_score
    ) AS obj
    FROM public.sg_owned_stall_chart m
    WHERE m.chart_date = v_date
    ORDER BY m.rank
    OFFSET greatest(coalesce(p_offset, 0), 0)
    LIMIT  least(coalesce(p_limit, 50), 500)
  ) r;

  RETURN jsonb_build_object('chart_date', v_date, 'total', v_total, 'rows', v_rows);
END $func$;

REVOKE ALL ON FUNCTION public.get_sg_owned_stall_chart(integer, integer) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sg_owned_stall_chart(integer, integer) TO authenticated;

COMMENT ON FUNCTION public.get_sg_owned_stall_chart(integer, integer) IS
  'Returns {chart_date,total,rows[]} for the latest sg_owned_stall_chart day, paged '
  'by rank (offset/limit, cap 500). Powers the terminal home "MARKET''S SELLING, '
  'WE''RE NOT — OWNED, NOT MOVING" panel. Email-gated @s4kent.com.';

CREATE OR REPLACE FUNCTION public.get_sg_owned_stall_sections(p_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_email text;
  v_date  date;
  v_rows  jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT max(chart_date) INTO v_date
  FROM public.sg_owned_stall_sections WHERE tevo_event_id = p_event_id;

  SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.our_qty DESC NULLS LAST), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT section, our_qty, our_listings, our_median_ask,
           sec_sales_30d, sec_clearing_median, sec_premium_pct,
           rec_ask, clear_by_event_ask, p_sell_at_ask_pct,
           to_char(p50_sell_by, 'YYYY-MM-DD') AS p50_sell_by
    FROM public.sg_owned_stall_sections
    WHERE tevo_event_id = p_event_id AND chart_date = v_date
  ) q;

  RETURN jsonb_build_object('chart_date', v_date, 'event_id', p_event_id, 'rows', v_rows);
END $func$;

REVOKE ALL ON FUNCTION public.get_sg_owned_stall_sections(bigint) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sg_owned_stall_sections(bigint) TO authenticated;

COMMENT ON FUNCTION public.get_sg_owned_stall_sections(bigint) IS
  'Per-owned-section drill for a charted event (latest chart day): our qty/ask vs '
  'the section''s realized SG+SD clearing, + frontier recommended / clear-by-event '
  'asks and P(sell)@our ask. Populated for the top 30 ranked events. Email-gated.';

-- ---------- 4. Daily rebuild cron (gated) ----------
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sg_owned_stall_chart_rebuild_daily',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   720, 720, 2, true,
   'Daily rebuild of sg_owned_stall_chart + section drill (owned-and-stalled cross-source companion to the Top-50 non-owned chart; home panel). Fires once @ 11:20 UTC, 15 min after sg_market_chart_rebuild_daily so the two never contend; 720-min gate guards double-fire. Model loop self-bounds at 180s.')
ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et = EXCLUDED.peak_hours_et,
      peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = true,
      notes = EXCLUDED.notes,
      updated_at = now();

SELECT cron.schedule('sg_owned_stall_chart_rebuild_daily', '20 11 * * *', $cron$
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_owned_stall_chart_rebuild_daily') THEN RETURN; END IF;
    SET LOCAL statement_timeout = '480s';
    PERFORM public.rebuild_sg_owned_stall_chart();
  END $body$;
$cron$);

-- ---------- 5. Seed today's chart so the panel renders immediately on apply ----------
SELECT public.rebuild_sg_owned_stall_chart();
