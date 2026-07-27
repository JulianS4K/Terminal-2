-- Migration 20260608210000 · level:2 · operator-directed (2026-06-08)
-- writes: ALTER sg_market_chart ADD sd_ma7_gross, sd_sales_7d;
--         CREATE OR REPLACE rebuild_sg_market_chart() (adds SeatData GMV);
--         CREATE OR REPLACE get_sg_market_chart(int,int) (emits SeatData GMV);
--         one rebuild to repopulate today.
-- reads:  seatdata_sales_snapshots (new), + everything rebuild already read.
--
-- ============================================================
-- Add SeatData sold-comp GMV/day to the "TOP 50 — SG SELLING, WE'RE NOT IN"
-- chart. Operator directive 2026-06-08: "add the seatdata data to the GMV/day".
--
-- The chart already shows ma7_gross = SeatGeek-observed daily gross (7d-MA of
-- volume × median). Now that seatdata-poll fills SeatData sold comps for the
-- chart's top-40 events (mig 20260608200000), surface a SECOND, independent
-- GMV/day from SeatData (StubHub-primary marketplace) alongside the SG one so
-- the panel compares the two markets. They are NOT summed — different
-- marketplaces; double-counting would be wrong.
--
-- sd_ma7_gross = 7-day moving average of daily SeatData gross, where a day's
--   gross = Σ(price × qty) over that event's sales that day, averaged over the
--   days-with-sales in the trailing 7 days (mirrors the SG ma7_gross basis).
--   SeatData quantity is 0/NULL when "unknown" (data-sources doc caveat) → we
--   treat unknown as 1 ticket so the comp still contributes.
-- sd_sales_7d = raw count of SeatData sale rows in the trailing 7d (tooltip).
--
-- Keyed on tevo_event_id (seatdata_sales_snapshots' key). Chart rows without a
-- tevo_event_id, or without SeatData sales yet, get NULL → FE renders "—".
-- The chart rebuilds 11:05 UTC daily; SeatData pulls 11:00/20:00 ET — so the
-- chart reflects SeatData sales accumulated through the prior evening's pulls.
--
-- PENDING OPERATOR APPLY: gated per CLAUDE.md §1.
-- ROLLBACK: restore the prior rebuild_sg_market_chart()/get_sg_market_chart()
--   bodies; columns can stay (additive, nullable) or be dropped.
-- ============================================================

ALTER TABLE public.sg_market_chart
  ADD COLUMN IF NOT EXISTS sd_ma7_gross numeric,
  ADD COLUMN IF NOT EXISTS sd_sales_7d  integer;

-- ---------- rebuild: same logic + a SeatData GMV join ----------
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

  WITH daily AS (
    SELECT DISTINCT ON (sg_event_id, (captured_at AT TIME ZONE 'UTC')::date)
      sg_event_id,
      (captured_at AT TIME ZONE 'UTC')::date AS d,
      sold_quantity, sold_price_median, sold_gross
    FROM public.seatgeek_event_metrics
    WHERE captured_at > now() - interval '7 days'
      AND coalesce(sold_quantity, 0) > 0
    ORDER BY sg_event_id, (captured_at AT TIME ZONE 'UTC')::date, captured_at DESC
  ),
  ma AS (
    SELECT sg_event_id,
      count(*)                        AS days_with_sales,
      avg(sold_quantity)::numeric     AS ma7_volume,
      avg(sold_price_median)::numeric AS ma7_median,
      avg(sold_gross)::numeric        AS ma7_gross
    FROM daily
    GROUP BY sg_event_id
  ),
  -- SeatData sold comps: per-event 7d-MA daily gross (Σ price×qty over days w/ sales)
  sd_daily AS (
    SELECT s.tevo_event_id,
           (s.sale_timestamp AT TIME ZONE 'UTC')::date AS d,
           count(*)                                                       AS cnt,
           sum(coalesce(s.price,0) * greatest(coalesce(s.quantity,1),1))  AS daily_gross
    FROM public.seatdata_sales_snapshots s
    WHERE s.sale_timestamp > now() - interval '7 days'
    GROUP BY s.tevo_event_id, (s.sale_timestamp AT TIME ZONE 'UTC')::date
  ),
  sd AS (
    SELECT tevo_event_id,
           sum(cnt)::int               AS sd_sales_7d,
           avg(daily_gross)::numeric   AS sd_ma7_gross
    FROM sd_daily
    GROUP BY tevo_event_id
  ),
  elig AS (
    SELECT m.sg_event_id, m.days_with_sales, m.ma7_volume, m.ma7_median, m.ma7_gross,
           p.tevo_event_id, p.sg_event_name, p.sg_venue_name, p.sg_datetime_utc
    FROM ma m
    JOIN public.sg_event_priority_state p ON p.sg_event_id = m.sg_event_id
    WHERE coalesce(p.owned_count_last_7d, 0) = 0   -- we hold no inventory
      AND p.sg_datetime_utc > now()                -- future events only
      AND m.days_with_sales >= 2                   -- real MA, not a one-off spike
  ),
  scored AS (
    SELECT e.*,
      (percent_rank() OVER (ORDER BY ma7_volume))::numeric AS pct_volume,
      (percent_rank() OVER (ORDER BY ma7_median))::numeric AS pct_median
    FROM elig e
  ),
  ranked AS (
    SELECT s.*,
      (pct_volume + pct_median) AS chart_score,
      row_number() OVER (
        ORDER BY (pct_volume + pct_median) DESC, ma7_gross DESC NULLS LAST, ma7_volume DESC
      ) AS rnk
    FROM scored s
  )
  INSERT INTO public.sg_market_chart (
    chart_date, sg_event_id, rank, chart_score, pct_volume, pct_median,
    ma7_volume, ma7_median, ma7_gross, days_with_sales,
    prev_rank, peak_rank, days_on_chart,
    tevo_event_id, sg_event_name, sg_venue_name, sg_datetime_utc,
    sd_ma7_gross, sd_sales_7d)
  SELECT
    v_today, r.sg_event_id, r.rnk::int, round(r.chart_score, 4),
    round(r.pct_volume, 4), round(r.pct_median, 4),
    round(r.ma7_volume, 1), round(r.ma7_median, 2), round(r.ma7_gross, 2), r.days_with_sales,
    prev.rank,
    LEAST(r.rnk::int,
          coalesce((SELECT min(h.rank) FROM public.sg_market_chart h
                    WHERE h.sg_event_id = r.sg_event_id), r.rnk::int)),
    CASE WHEN prev.rank IS NOT NULL THEN coalesce(prev.days_on_chart, 0) + 1 ELSE 1 END,
    r.tevo_event_id, r.sg_event_name, r.sg_venue_name, r.sg_datetime_utc,
    round(sd.sd_ma7_gross, 2), sd.sd_sales_7d
  FROM ranked r
  LEFT JOIN public.sg_market_chart prev
    ON prev.sg_event_id = r.sg_event_id AND prev.chart_date = v_prev
  LEFT JOIN sd ON sd.tevo_event_id = r.tevo_event_id;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  DELETE FROM public.sg_market_chart WHERE chart_date < v_today - 90;

  RETURN v_count;
END $func$;

-- ---------- read RPC: emit the SeatData GMV fields ----------
CREATE OR REPLACE FUNCTION public.get_sg_market_chart(
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

  SELECT max(chart_date) INTO v_date FROM public.sg_market_chart;
  IF v_date IS NULL THEN
    RETURN jsonb_build_object('chart_date', NULL, 'total', 0, 'rows', '[]'::jsonb);
  END IF;

  SELECT count(*) INTO v_total FROM public.sg_market_chart WHERE chart_date = v_date;

  SELECT coalesce(jsonb_agg(r.obj ORDER BY (r.obj->>'rank')::int), '[]'::jsonb)
  INTO v_rows
  FROM (
    SELECT jsonb_build_object(
      'rank',            m.rank,
      'prev_rank',       m.prev_rank,
      'rank_delta',      CASE WHEN m.prev_rank IS NULL THEN NULL ELSE m.prev_rank - m.rank END,
      'is_new',          (m.prev_rank IS NULL),
      'peak_rank',       m.peak_rank,
      'days_on_chart',   m.days_on_chart,
      'sg_event_id',     m.sg_event_id,
      'tevo_event_id',   m.tevo_event_id,
      'sg_event_name',   m.sg_event_name,
      'sg_venue_name',   m.sg_venue_name,
      'sg_datetime_utc', to_char(m.sg_datetime_utc AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'ma7_volume',      m.ma7_volume,
      'ma7_median',      m.ma7_median,
      'ma7_gross',       m.ma7_gross,
      'sd_ma7_gross',    m.sd_ma7_gross,
      'sd_sales_7d',     m.sd_sales_7d,
      'pct_volume',      m.pct_volume,
      'pct_median',      m.pct_median,
      'chart_score',     m.chart_score,
      'days_with_sales', m.days_with_sales
    ) AS obj
    FROM public.sg_market_chart m
    WHERE m.chart_date = v_date
    ORDER BY m.rank
    OFFSET greatest(coalesce(p_offset, 0), 0)
    LIMIT  least(coalesce(p_limit, 50), 500)
  ) r;

  RETURN jsonb_build_object('chart_date', v_date, 'total', v_total, 'rows', v_rows);
END $func$;

-- repopulate today's chart so the new SeatData column lands immediately on apply
SELECT public.rebuild_sg_market_chart();
