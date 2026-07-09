-- Migration 20260709190000 · level:2 · lane:A1 (operator-directed 2026-07-09; D0 consumes)
-- REDESIGN IN PLACE of the "TOP 50 — SG SELLING, WE'RE NOT IN" chart.
-- writes:  ALTER TABLE sg_market_chart ADD platform_breadth; CREATE OR REPLACE
--          rebuild_sg_market_chart() + get_sg_market_chart(int,int); reseed.
-- reads:   seatgeek_event_metrics, sg_event_priority_state, seatdata_sales_snapshots
--          (base table, content_hash-deduped — NOT the sd_sales_normalized view, whose
--          per-row normalize_sd_listing() LATERAL blew the 120s rebuild budget),
--          event_listing_snapshot_daily, latest_event_metrics, axs_events.
-- pre-reqs: 20260606120000 (chart), 20260608220000 (blended cols), 20260702004500
--           (evo/sh depth in the RPC). Idempotent (CREATE OR REPLACE + ADD IF NOT EXISTS).
--
-- ## Already applied to prod — via MCP 2026-07-09 (operator-authorized "do it when green").
--    Re-apply is a no-op. Post-apply verified: 730 rows, breadth/median_all populated on all,
--    35 with AXS/TM primary, tier mix {blended,sg,seatdata}. A first apply attempt hit >120s
--    (the sd_sales_normalized VIEW's per-row normalize_sd_listing() LATERAL) + a planner
--    nested-loop that recomputed the aggregations per outer row — cancelled (clean rollback),
--    then fixed here: base-table + content_hash dedup for SeatData, and AS MATERIALIZED on the
--    heavy CTEs (rebuild now ~seconds, well under the 120s daily-cron budget).
--
-- ============================================================
-- WHY (operator 2026-07-09): the chart is DISCOVERY — the top US events we hold
-- NO position in — but it ranked on SeatGeek sales ALONE. The blend columns
-- (sd_*/ma7_*_blended/blended_score) were dead (NULL), and EVO/StubHub depth was
-- display-only in the RPC, never in the ranking. Redesign: **use every platform's
-- demand to rank**, while the eligibility ("we're not in it") and the SG-anchored
-- shape (the 5 internal consumers — seatdata_due_events, td_target_events,
-- get_event_demand_context, sg_market_chart_reveal_pull, open_notebook) are
-- preserved. Strictly ADDITIVE: one new column, previously-NULL blend columns now
-- populated, all existing columns/keys unchanged.
--
-- ELIGIBILITY (unchanged intent — "top US events we have NO position in"):
--   * ZERO position both sides — SG owned_count_last_7d = 0 AND EVO owned = 0
--   * future event; US scope carried by sg_event_priority_state (SG-anchored)
--   * a real market on ANY sales platform — BROADENED from "SG >=2 sale-days" to
--     "SG >=2 sale-days OR SeatData >=2 sale-days", so an event SeatGeek's tape
--     misses but SeatData sees still surfaces.
--
-- RANKING — all-platform demand (was: SG volume + SG median only):
--   chart_score = pct(blended sales volume)      -- SG + SeatData tickets/day
--               + pct(market_median_all)         -- median of the per-platform median
--                                                   prices (SG·SeatData sold +
--                                                   StubHub·GT·Vivid·EVO): a cross-
--                                                   platform value/price indicator
--               + 0.5 · pct(platform_breadth)    -- how many platforms show a live
--                                                   market (SG·SeatData sales +
--                                                   StubHub·GT·Vivid·EVO depth)
--   High velocity OR a high all-platform price OR a broad liquid market charts;
--   high on all three tops it. **SeatData sales BOOST when available** — they add
--   to blended volume, to the median-of-medians, and to breadth — with no penalty
--   when absent (coalesce → 0). score_basis ∈ {blended, sg, seatdata} records the
--   tape mix. blended GMV/day is retained as the ranking tiebreak.
--   (EVO/StubHub price depth is supply, not sales — it informs breadth + the
--   median-of-medians here but never fabricates sales velocity we didn't observe.)
--
-- ROLLBACK: restore the SG-only rebuild_sg_market_chart()/get_sg_market_chart()
-- from mig 20260606120000 (+ its evo/sh RPC from 20260702004500); the
-- platform_breadth column can stay (nullable, harmless) or be dropped.
-- ============================================================

-- ---------- 1. Additive columns (ranking transparency; RPC/panel surface them) ----------
ALTER TABLE public.sg_market_chart
  ADD COLUMN IF NOT EXISTS platform_breadth integer;
ALTER TABLE public.sg_market_chart
  ADD COLUMN IF NOT EXISTS market_median_all numeric;
ALTER TABLE public.sg_market_chart
  ADD COLUMN IF NOT EXISTS primary_sources text;

COMMENT ON COLUMN public.sg_market_chart.platform_breadth IS
  'Count of platforms showing a live market for this (owned=0) event: SG sales, '
  'SeatData sales, StubHub listings, GoTickets listings, Vivid listings, EVO tickets. '
  'A breadth term in chart_score (all-platform redesign, mig 20260709190000).';
COMMENT ON COLUMN public.sg_market_chart.market_median_all IS
  'Median of the per-platform median prices (SG sold, SeatData sold, StubHub, '
  'GoTickets, Vivid, EVO retail) — a cross-platform value indicator, and the price '
  'axis of chart_score (all-platform redesign, mig 20260709190000).';
COMMENT ON COLUMN public.sg_market_chart.primary_sources IS
  'Which PRIMARY (face-value) markets still have inventory for this event: AXS '
  '(is_axs_primary + probe_status=axs_ok) and/or TM (td_tm_listings > 0). NULL = '
  'resale-only. NOTE: SeatGeek primary is NOT observable — our brokerdata.seatgeek.com '
  'feed is resale-only (market_source=exchange), verified 2026-07-09 against the '
  'SG-primary Austin FC event 17921663 (only resale listings captured). Adding SG '
  'primary would need a new SeatGeek consumer/v2 pull. mig 20260709190000.';

-- ---------- 2. Rebuild function — all-platform demand ranking ----------
CREATE OR REPLACE FUNCTION public.rebuild_sg_market_chart()
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_today date := (now() AT TIME ZONE 'UTC')::date;
  v_prev  date;
  v_count int := 0;
BEGIN
  SELECT max(chart_date) INTO v_prev
  FROM public.sg_market_chart WHERE chart_date < v_today;

  DELETE FROM public.sg_market_chart WHERE chart_date = v_today;  -- idempotent re-run

  WITH sg_daily AS (
    -- latest hourly rollup per (sg event, UTC day); sold_* is trailing-24h
    SELECT DISTINCT ON (sg_event_id, (captured_at AT TIME ZONE 'UTC')::date)
      sg_event_id, sold_quantity, sold_price_median, sold_gross
    FROM public.seatgeek_event_metrics
    WHERE captured_at > now() - interval '7 days'
      AND coalesce(sold_quantity, 0) > 0
    ORDER BY sg_event_id, (captured_at AT TIME ZONE 'UTC')::date, captured_at DESC
  ),
  -- MATERIALIZED (all three heavy aggregations): the eligibility join starts from
  -- sg_event_priority_state and the planner underestimates its post-filter row count
  -- to rows=1, which without materialization triggers a NESTED LOOP that recomputes
  -- each aggregation per outer row (measured: rebuild >120s, blew the cron budget).
  -- Materializing forces each to compute exactly once → hash/merge joins, ~seconds.
  sg_ma AS MATERIALIZED (
    SELECT sg_event_id,
      count(*)                        AS days_with_sales,
      avg(sold_quantity)::numeric     AS ma7_volume,
      avg(sold_price_median)::numeric AS ma7_median,
      avg(sold_gross)::numeric        AS ma7_gross
    FROM sg_daily GROUP BY sg_event_id
  ),
  sd_ma AS MATERIALIZED (
    -- SeatData realized sales, 7d: tickets/day (unknown qty counts 1) + median + daily gross.
    -- Reads the BASE table, NOT the sd_sales_normalized view: that view runs a per-row
    -- normalize_sd_listing() LATERAL (zone/section canonicalization) we don't need here, and
    -- it drove the rebuild past the 120s cron budget. Dedup on content_hash — seatdata
    -- re-inserts each poll (same overcount landmine as seatgeek_sales_snapshots, §3).
    SELECT tevo_event_id,
      count(*)                                    AS sd_sales_7d,
      count(DISTINCT sale_day)                    AS sd_days,
      (sum(coalesce(NULLIF(quantity,0),1))::numeric
         / greatest(count(DISTINCT sale_day),1))                 AS sd_ma7_volume,
      (percentile_cont(0.5) WITHIN GROUP (ORDER BY price))::numeric AS sd_ma7_median,
      (sum(price * coalesce(NULLIF(quantity,0),1))::numeric
         / greatest(count(DISTINCT sale_day),1))                 AS sd_ma7_gross
    FROM (
      SELECT DISTINCT ON (content_hash)
        tevo_event_id, (sale_timestamp AT TIME ZONE 'UTC')::date AS sale_day, price, quantity
      FROM public.seatdata_sales_snapshots
      WHERE sale_timestamp > now() - interval '7 days' AND tevo_event_id IS NOT NULL
      ORDER BY content_hash, pulled_at DESC
    ) d
    GROUP BY tevo_event_id
  ),
  depth AS MATERIALIZED (
    -- latest cross-source listing depth + medians per event (StubHub/GT/Vivid + TM primary)
    SELECT DISTINCT ON (d.event_id) d.event_id AS tevo_event_id,
      d.td_sh_listings, d.td_gt_listings, d.td_vd_listings,
      d.td_sh_median, d.td_gt_median, d.td_vd_median,
      d.td_tm_listings                                  -- TM = PRIMARY/face (resale is td_tm_resale_*)
    FROM public.event_listing_snapshot_daily d
    WHERE d.snapshot_date > v_today - 8
    ORDER BY d.event_id, d.snapshot_date DESC,
             CASE d.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC
  ),
  prim_axs AS MATERIALIZED (
    -- events with live AXS PRIMARY (veritix) inventory
    SELECT DISTINCT a.tevo_event_id
    FROM public.axs_events a
    WHERE a.is_axs_primary = true AND a.active = true
      AND a.probe_status = 'axs_ok' AND a.tevo_event_id IS NOT NULL
  ),
  elig AS (
    SELECT p.sg_event_id, p.tevo_event_id, p.sg_event_name, p.sg_venue_name, p.sg_datetime_utc,
           sg.days_with_sales, sg.ma7_volume, sg.ma7_median, sg.ma7_gross,
           sd.sd_sales_7d, sd.sd_days, sd.sd_ma7_volume, sd.sd_ma7_median, sd.sd_ma7_gross,
           dp.td_sh_listings, dp.td_gt_listings, dp.td_vd_listings,
           dp.td_sh_median, dp.td_gt_median, dp.td_vd_median, dp.td_tm_listings,
           lem.tickets_count AS evo_tickets, lem.retail_median AS evo_median,
           (pa.tevo_event_id IS NOT NULL) AS has_axs_primary
    FROM public.sg_event_priority_state p
    LEFT JOIN sg_ma sg ON sg.sg_event_id = p.sg_event_id
    LEFT JOIN sd_ma sd ON sd.tevo_event_id = p.tevo_event_id
    LEFT JOIN depth dp ON dp.tevo_event_id = p.tevo_event_id
    LEFT JOIN prim_axs pa ON pa.tevo_event_id = p.tevo_event_id
    LEFT JOIN public.latest_event_metrics lem ON lem.event_id = p.tevo_event_id
    WHERE coalesce(p.owned_count_last_7d, 0) = 0        -- no SeatGeek position
      AND coalesce(lem.owned_tickets_count, 0) = 0      -- ...and no EVO/TEvo position
      AND p.sg_datetime_utc > now()                     -- future events only
      AND ( coalesce(sg.days_with_sales, 0) >= 2        -- real market on ANY sales platform
            OR coalesce(sd.sd_days, 0) >= 2 )
  ),
  blended AS (
    SELECT e.*,
      (coalesce(e.ma7_volume,0) + coalesce(e.sd_ma7_volume,0)) AS vol_blended,
      CASE WHEN coalesce(e.ma7_volume,0) + coalesce(e.sd_ma7_volume,0) > 0
        THEN (coalesce(e.ma7_median,0)*coalesce(e.ma7_volume,0)
              + coalesce(e.sd_ma7_median,0)*coalesce(e.sd_ma7_volume,0))
             / (coalesce(e.ma7_volume,0) + coalesce(e.sd_ma7_volume,0))
      END AS med_blended,
      (coalesce(e.ma7_gross,0) + coalesce(e.sd_ma7_gross,0)) AS gross_blended,
      -- median of the per-platform median prices (the cross-platform value axis)
      (SELECT (percentile_cont(0.5) WITHIN GROUP (ORDER BY v))::numeric
       FROM unnest(ARRAY[e.ma7_median, e.sd_ma7_median, e.td_sh_median,
                         e.td_gt_median, e.td_vd_median, e.evo_median]) AS v
       WHERE v IS NOT NULL AND v > 0) AS market_median_all,
      ( (coalesce(e.ma7_volume,0)     > 0)::int
      + (coalesce(e.sd_ma7_volume,0)  > 0)::int
      + (coalesce(e.td_sh_listings,0) > 0)::int
      + (coalesce(e.td_gt_listings,0) > 0)::int
      + (coalesce(e.td_vd_listings,0) > 0)::int
      + (coalesce(e.evo_tickets,0)    > 0)::int ) AS platform_breadth,
      CASE WHEN coalesce(e.days_with_sales,0) >= 2 AND coalesce(e.sd_days,0) >= 2 THEN 'blended'
           WHEN coalesce(e.days_with_sales,0) >= 2                               THEN 'sg'
           ELSE 'seatdata' END AS score_basis,
      -- primary (face-value) availability: AXS + TM only (SG feed is resale-only)
      NULLIF(array_to_string(array_remove(ARRAY[
        CASE WHEN e.has_axs_primary THEN 'AXS' END,
        CASE WHEN coalesce(e.td_tm_listings,0) > 0 THEN 'TM' END
      ], NULL), ','), '') AS primary_sources
    FROM elig e
  ),
  scored AS (
    SELECT b.*,
      (percent_rank() OVER (ORDER BY b.vol_blended))::numeric                      AS pct_volume,
      (percent_rank() OVER (ORDER BY b.market_median_all NULLS FIRST))::numeric    AS pct_median,
      (percent_rank() OVER (ORDER BY b.platform_breadth))::numeric                 AS pct_breadth
    FROM blended b
  ),
  ranked AS (
    SELECT s.*,
      (pct_volume + pct_median + 0.5 * pct_breadth) AS chart_score,
      row_number() OVER (
        ORDER BY (pct_volume + pct_median + 0.5 * pct_breadth) DESC,
                 s.gross_blended DESC NULLS LAST, s.vol_blended DESC
      ) AS rnk
    FROM scored s
  )
  INSERT INTO public.sg_market_chart (
    chart_date, sg_event_id, rank, chart_score, pct_volume, pct_median,
    ma7_volume, ma7_median, ma7_gross, days_with_sales,
    sd_ma7_gross, sd_sales_7d, sd_ma7_volume, sd_ma7_median,
    ma7_volume_blended, ma7_median_blended, ma7_gross_blended, blended_score, score_basis,
    platform_breadth, market_median_all, primary_sources,
    prev_rank, peak_rank, days_on_chart,
    tevo_event_id, sg_event_name, sg_venue_name, sg_datetime_utc)
  SELECT
    v_today, r.sg_event_id, r.rnk::int, round(r.chart_score, 4),
    round(r.pct_volume, 4), round(r.pct_median, 4),
    round(r.ma7_volume, 1), round(r.ma7_median, 2), round(r.ma7_gross, 2), r.days_with_sales,
    round(r.sd_ma7_gross, 2), r.sd_sales_7d, round(r.sd_ma7_volume, 1), round(r.sd_ma7_median, 2),
    round(r.vol_blended, 1), round(r.med_blended, 2), round(r.gross_blended, 2),
    round(r.chart_score, 4), r.score_basis,
    r.platform_breadth, round(r.market_median_all, 2), r.primary_sources,
    prev.rank,
    LEAST(r.rnk::int,
          coalesce((SELECT min(h.rank) FROM public.sg_market_chart h
                    WHERE h.sg_event_id = r.sg_event_id), r.rnk::int)),
    CASE WHEN prev.rank IS NOT NULL THEN coalesce(prev.days_on_chart, 0) + 1 ELSE 1 END,
    r.tevo_event_id, r.sg_event_name, r.sg_venue_name, r.sg_datetime_utc
  FROM ranked r
  LEFT JOIN public.sg_market_chart prev
    ON prev.sg_event_id = r.sg_event_id AND prev.chart_date = v_prev;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  DELETE FROM public.sg_market_chart WHERE chart_date < v_today - 90;
  RETURN v_count;
END $func$;

REVOKE ALL ON FUNCTION public.rebuild_sg_market_chart() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_sg_market_chart() TO service_role;

COMMENT ON FUNCTION public.rebuild_sg_market_chart() IS
  'Rebuilds sg_market_chart: top US events we hold NO position in (SG owned=0 AND '
  'EVO owned=0), ranked by ALL-PLATFORM demand = pct(SG+SeatData blended volume) + '
  'pct(blended GMV/day) + 0.5·pct(platform breadth: SG·SeatData sales + SH·GT·VD·EVO '
  'depth). Eligible on a real market on ANY sales platform (SG or SeatData >=2 '
  'sale-days). Daily cron @ 11:05 UTC. Feeds the home discovery panel + '
  'seatdata_due_events / td_target_events / get_event_demand_context.';

-- ---------- 3. Read RPC — surface platform_breadth (+ unchanged evo/sh live depth) ----------
CREATE OR REPLACE FUNCTION public.get_sg_market_chart(
  p_offset integer DEFAULT 0,
  p_limit  integer DEFAULT 50
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $func$
DECLARE
  v_email text; v_date date; v_total int; v_rows jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT max(chart_date) INTO v_date FROM public.sg_market_chart;
  IF v_date IS NULL THEN
    RETURN jsonb_build_object('chart_date', NULL, 'total', 0, 'rows', '[]'::jsonb);
  END IF;

  SELECT count(*) INTO v_total FROM public.sg_market_chart WHERE chart_date = v_date;

  SELECT coalesce(jsonb_agg(r.obj ORDER BY (r.obj->>'rank')::int), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'rank',                m.rank,
      'prev_rank',           m.prev_rank,
      'rank_delta',          CASE WHEN m.prev_rank IS NULL THEN NULL ELSE m.prev_rank - m.rank END,
      'is_new',              (m.prev_rank IS NULL),
      'peak_rank',           m.peak_rank,
      'days_on_chart',       m.days_on_chart,
      'sg_event_id',         m.sg_event_id,
      'tevo_event_id',       m.tevo_event_id,
      'sg_event_name',       m.sg_event_name,
      'sg_venue_name',       m.sg_venue_name,
      'sg_datetime_utc',     to_char(m.sg_datetime_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'ma7_volume',          m.ma7_volume,
      'ma7_median',          m.ma7_median,
      'ma7_gross',           m.ma7_gross,
      'sd_ma7_gross',        m.sd_ma7_gross,
      'sd_sales_7d',         m.sd_sales_7d,
      'sd_ma7_volume',       m.sd_ma7_volume,
      'sd_ma7_median',       m.sd_ma7_median,
      'ma7_volume_blended',  m.ma7_volume_blended,
      'ma7_median_blended',  m.ma7_median_blended,
      'ma7_gross_blended',   m.ma7_gross_blended,
      'pct_volume',          m.pct_volume,
      'pct_median',          m.pct_median,
      'chart_score',         m.chart_score,
      'blended_score',       m.blended_score,
      'score_basis',         m.score_basis,
      'platform_breadth',    m.platform_breadth,
      'market_median_all',   m.market_median_all,
      'primary_sources',     m.primary_sources,
      'days_with_sales',     m.days_with_sales,
      'evo_getin',           lem.getin_price,
      'evo_median',          lem.retail_median,
      'evo_tickets',         lem.tickets_count,
      'sh_median',           shs.td_sh_median,
      'sh_listings',         shs.td_sh_listings
    ) AS obj
    FROM public.sg_market_chart m
    LEFT JOIN public.latest_event_metrics lem ON lem.event_id = m.tevo_event_id
    LEFT JOIN LATERAL (
      SELECT s.td_sh_median, s.td_sh_listings
      FROM public.event_listing_snapshot_daily s
      WHERE s.event_id = m.tevo_event_id AND s.td_sh_median IS NOT NULL
      ORDER BY s.snapshot_date DESC,
               CASE s.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC
      LIMIT 1
    ) shs ON true
    WHERE m.chart_date = v_date
    ORDER BY m.rank
    OFFSET greatest(coalesce(p_offset, 0), 0)
    LIMIT  least(coalesce(p_limit, 50), 500)
  ) r;

  RETURN jsonb_build_object('chart_date', v_date, 'total', v_total, 'rows', v_rows);
END $func$;

REVOKE ALL ON FUNCTION public.get_sg_market_chart(integer, integer) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sg_market_chart(integer, integer) TO authenticated;

COMMENT ON FUNCTION public.get_sg_market_chart(integer, integer) IS
  'Returns {chart_date,total,rows[]} for the latest sg_market_chart day, paged by rank. '
  'Powers the home "MARKET SELLING, WE''RE NOT IN" discovery panel: all-platform demand '
  'ranking (SG+SeatData blend + breadth) with live EVO/StubHub depth. Email-gated @s4kent.com.';

-- ---------- 4. Reseed today's chart with the all-platform ranking ----------
SELECT public.rebuild_sg_market_chart();
