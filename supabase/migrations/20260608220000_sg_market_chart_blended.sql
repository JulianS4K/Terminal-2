-- Migration 20260608220000 · level:2 · operator-directed (2026-06-08)
-- writes: ALTER sg_market_chart ADD sd_ma7_volume, sd_ma7_median,
--           ma7_volume_blended, ma7_median_blended, ma7_gross_blended,
--           blended_score, score_basis;
--         CREATE OR REPLACE rebuild_sg_market_chart() (volume-weighted blend + hybrid rank);
--         CREATE OR REPLACE get_sg_market_chart(int,int) (emits blended fields);
--         one rebuild to repopulate today.
-- reads:  seatdata_sales_snapshots, seatgeek_event_metrics, sg_event_priority_state.
--
-- ============================================================
-- Merge the SeatGeek and SeatData figures into SINGLE weighted columns for the
-- "TOP 50 — SG SELLING, WE'RE NOT IN" chart. Supersedes mig 20260608210000
-- (_sg_market_chart_seatdata_gmv), which surfaced SeatData GMV as a SEPARATE
-- "GMV/day SD" column. Operator directive 2026-06-08: merge into single weighted
-- Vol/day, Med px, GMV/day, Score.
--
-- Blending (volume-weighted, NULL-safe with SG fallback when no SeatData) —
-- mirrors the house count-weighted-mean idiom in get_event_amalgam()/amalgam_median
-- (mig 20260531214306):
--   ma7_volume_blended = ma7_volume + COALESCE(sd_ma7_volume,0)      (total daily sales)
--   ma7_gross_blended  = ma7_gross  + COALESCE(sd_ma7_gross,0)       (total daily gross)
--   ma7_median_blended = (ma7_median*ma7_volume + COALESCE(sd_ma7_median*sd_ma7_volume,0))
--                        / NULLIF(ma7_volume + COALESCE(sd_ma7_volume,0),0)   (vol-weighted px)
--
-- Hybrid score/rank (operator: re-rank events we have all data on, keep SG rank
-- as default when only SG data is present):
--   chart_score    = pct_volume + pct_median        (SG-only percentiles, unchanged basis)
--   blended_score  = bl_pct_volume + bl_pct_median  (percentiles over the BLENDED metrics)
--   has_sd         = COALESCE(sd_sales_7d,0) > 0
--   effective      = has_sd ? blended_score : chart_score
--   rank           = row_number() OVER (ORDER BY effective DESC,
--                                       ma7_gross_blended DESC NULLS LAST,
--                                       ma7_volume_blended DESC)
--   score_basis    = has_sd ? 'blended' : 'sg'
-- Both scores are stored; the FE shows which basis applied per row.
--
-- SeatData quantity is 0/NULL when "unknown" → treat as 1 (greatest(coalesce(qty,1),1)),
-- per sd_sales_normalized (mig 20260509070000). Per-day SeatData median is
-- percentile_cont(0.5) over raw price for that event/day, then averaged over days.
-- Events on chart but never SeatData-pulled get all-NULL SD → fall back to SG cleanly.
--
-- PENDING OPERATOR APPLY: gated per CLAUDE.md §1.
-- ROLLBACK: restore the mig 20260608210000 rebuild_sg_market_chart()/
--   get_sg_market_chart() bodies; new columns can stay (additive, nullable).
-- ============================================================

ALTER TABLE public.sg_market_chart
  ADD COLUMN IF NOT EXISTS sd_ma7_volume      numeric,
  ADD COLUMN IF NOT EXISTS sd_ma7_median      numeric,
  ADD COLUMN IF NOT EXISTS ma7_volume_blended numeric,
  ADD COLUMN IF NOT EXISTS ma7_median_blended numeric,
  ADD COLUMN IF NOT EXISTS ma7_gross_blended  numeric,
  ADD COLUMN IF NOT EXISTS blended_score      numeric,
  ADD COLUMN IF NOT EXISTS score_basis        text;

-- ---------- rebuild: volume-weighted blend + hybrid rank ----------
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
  -- SeatData sold comps: per-event/day count, gross (Σ price×qty), and median price.
  sd_daily AS (
    SELECT s.tevo_event_id,
           (s.sale_timestamp AT TIME ZONE 'UTC')::date AS d,
           count(*)                                                       AS cnt,
           sum(coalesce(s.price,0) * greatest(coalesce(s.quantity,1),1))  AS daily_gross,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY s.price)           AS daily_median
    FROM public.seatdata_sales_snapshots s
    WHERE s.sale_timestamp > now() - interval '7 days'
    GROUP BY s.tevo_event_id, (s.sale_timestamp AT TIME ZONE 'UTC')::date
  ),
  sd AS (
    SELECT tevo_event_id,
           sum(cnt)::int               AS sd_sales_7d,
           avg(cnt)::numeric           AS sd_ma7_volume,
           avg(daily_median)::numeric  AS sd_ma7_median,
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
  -- join SeatData and compute blended metrics BEFORE the blended percentile windows
  joined AS (
    SELECT e.*,
      sd.sd_sales_7d,
      sd.sd_ma7_volume,
      sd.sd_ma7_median,
      sd.sd_ma7_gross,
      (e.ma7_volume + coalesce(sd.sd_ma7_volume, 0))            AS ma7_volume_blended,
      (e.ma7_gross  + coalesce(sd.sd_ma7_gross,  0))            AS ma7_gross_blended,
      ( (e.ma7_median * e.ma7_volume
         + coalesce(sd.sd_ma7_median * sd.sd_ma7_volume, 0))
        / NULLIF(e.ma7_volume + coalesce(sd.sd_ma7_volume, 0), 0)
      )                                                          AS ma7_median_blended
    FROM elig e
    LEFT JOIN sd ON sd.tevo_event_id = e.tevo_event_id
  ),
  scored AS (
    SELECT j.*,
      (percent_rank() OVER (ORDER BY ma7_volume))::numeric          AS pct_volume,
      (percent_rank() OVER (ORDER BY ma7_median))::numeric          AS pct_median,
      (percent_rank() OVER (ORDER BY ma7_volume_blended))::numeric  AS bl_pct_volume,
      (percent_rank() OVER (ORDER BY ma7_median_blended))::numeric  AS bl_pct_median
    FROM joined j
  ),
  ranked AS (
    SELECT s.*,
      (pct_volume + pct_median)                            AS chart_score,
      (bl_pct_volume + bl_pct_median)                      AS blended_score,
      (coalesce(sd_sales_7d, 0) > 0)                       AS has_sd,
      row_number() OVER (
        ORDER BY
          CASE WHEN coalesce(sd_sales_7d, 0) > 0
               THEN (bl_pct_volume + bl_pct_median)
               ELSE (pct_volume + pct_median)
          END DESC,
          ma7_gross_blended DESC NULLS LAST,
          ma7_volume_blended DESC
      ) AS rnk
    FROM scored s
  )
  INSERT INTO public.sg_market_chart (
    chart_date, sg_event_id, rank, chart_score, pct_volume, pct_median,
    ma7_volume, ma7_median, ma7_gross, days_with_sales,
    prev_rank, peak_rank, days_on_chart,
    tevo_event_id, sg_event_name, sg_venue_name, sg_datetime_utc,
    sd_ma7_gross, sd_sales_7d,
    sd_ma7_volume, sd_ma7_median,
    ma7_volume_blended, ma7_median_blended, ma7_gross_blended,
    blended_score, score_basis)
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
    round(r.sd_ma7_gross, 2), r.sd_sales_7d,
    round(r.sd_ma7_volume, 1), round(r.sd_ma7_median, 2),
    round(r.ma7_volume_blended, 1), round(r.ma7_median_blended, 2), round(r.ma7_gross_blended, 2),
    round(r.blended_score, 4),
    CASE WHEN r.has_sd THEN 'blended' ELSE 'sg' END
  FROM ranked r
  LEFT JOIN public.sg_market_chart prev
    ON prev.sg_event_id = r.sg_event_id AND prev.chart_date = v_prev;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  DELETE FROM public.sg_market_chart WHERE chart_date < v_today - 90;

  RETURN v_count;
END $func$;

-- ---------- read RPC: emit blended fields ----------
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
      'days_with_sales',     m.days_with_sales
    ) AS obj
    FROM public.sg_market_chart m
    WHERE m.chart_date = v_date
    ORDER BY m.rank
    OFFSET greatest(coalesce(p_offset, 0), 0)
    LIMIT  least(coalesce(p_limit, 50), 500)
  ) r;

  RETURN jsonb_build_object('chart_date', v_date, 'total', v_total, 'rows', v_rows);
END $func$;

-- repopulate today's chart so the blended columns land immediately on apply
SELECT public.rebuild_sg_market_chart();
