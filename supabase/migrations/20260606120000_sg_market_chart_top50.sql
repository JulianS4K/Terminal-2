-- Migration 20260606120000 · level:2 · lane:D0 (operator-directed)
-- writes: CREATE TABLE sg_market_chart; CREATE fn rebuild_sg_market_chart();
--         CREATE RPC get_sg_market_chart(int,int); cron_policy row +
--         cron.schedule('sg_market_chart_rebuild_daily'); one initial rebuild.
-- reads:  seatgeek_event_metrics (sold_*), sg_event_priority_state (owned/horizon).
--
-- ============================================================
-- "TOP 50 — SG SELLING, WE'RE NOT IN" — a Billboard-style daily chart of the
-- SeatGeek market events we hold ZERO owned inventory in, ranked by sales
-- ACTIVITY (7-day moving average of daily sales VOLUME and/or MEDIAN price).
--
-- Operator directive 2026-06-06: replace the home "BLIND SPOTS — SG SELLING,
-- WE'RE NOT" pressure panel with a top-50 charting leaderboard ("think
-- Billboard top 50"), a second tab for the rest, refreshed daily.
--
-- SCORING — the "either high volume OR high median price OR both" blend:
--   chart_score = percent_rank(ma7_volume) + percent_rank(ma7_median)   (0..2)
-- An event that is high on EITHER axis charts well; high on BOTH tops it.
-- (Pure GMV = vol*price was rejected: it buries the high-price/low-volume
-- names — Ariana Grande, F1 — that are genuine opportunities.)
--
-- ELIGIBILITY: owned_count_last_7d = 0 (we are not exposed), event in the
-- future, and >= 2 days of sales in the trailing 7d (a real MA, not a spike).
--
-- CHARTING: sg_market_chart retains one ranked row set per UTC day, carrying
-- prev_rank / peak_rank / days_on_chart so the UI can show Billboard-style
-- movement (▲/▼/NEW). 90-day history retained.
--
-- SOURCE NOTE: seatgeek_event_metrics.sold_quantity is a trailing-24h count of
-- distinct sales (sg_sale_id), inserted hourly by refresh_sg_broker_sales_event_
-- metrics (@ :17). Taking the latest row per UTC day => that day's daily volume;
-- avg over the 7d window => the 7-day moving average. Sales tracking is NOT
-- ownership-gated (PROJECT_BIBLE §SG sales), so every non-owned event is covered.
--
-- PENDING OPERATOR APPLY: prod application is gated (CLAUDE.md §1). The final
-- SELECT rebuild_sg_market_chart() populates the table on apply so the panel has
-- data immediately. ROLLBACK: cron.unschedule('sg_market_chart_rebuild_daily');
-- DROP FUNCTION get_sg_market_chart(int,int), rebuild_sg_market_chart();
-- DROP TABLE sg_market_chart; DELETE cron_policy row.
-- ============================================================

-- ---------- 1. Chart history table (one ranked set per UTC day) ----------
CREATE TABLE IF NOT EXISTS public.sg_market_chart (
  chart_date       date        NOT NULL,
  sg_event_id      bigint      NOT NULL,
  rank             integer     NOT NULL,
  chart_score      numeric     NOT NULL,
  pct_volume       numeric,
  pct_median       numeric,
  ma7_volume       numeric,
  ma7_median       numeric,
  ma7_gross        numeric,
  days_with_sales  integer,
  prev_rank        integer,        -- rank on the most recent prior chart_date (NULL = new entry)
  peak_rank        integer,        -- best (lowest) rank ever achieved by this event
  days_on_chart    integer,        -- consecutive daily appearances (resets on a gap)
  tevo_event_id    bigint,
  sg_event_name    text,
  sg_venue_name    text,
  sg_datetime_utc  timestamptz,
  PRIMARY KEY (chart_date, sg_event_id)
);

CREATE INDEX IF NOT EXISTS sg_market_chart_date_rank_idx
  ON public.sg_market_chart (chart_date, rank);
CREATE INDEX IF NOT EXISTS sg_market_chart_event_idx
  ON public.sg_market_chart (sg_event_id);

-- secure-by-default: only the SECDEF RPC (owner) reads it; no anon/auth surface
REVOKE ALL ON public.sg_market_chart FROM anon, authenticated;

-- ---------- 2. Daily rebuild function ----------
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
    -- one row per (event, UTC day): latest hourly rollup; sold_* is trailing-24h
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
      -- percent_rank() is double precision; cast to numeric so round() resolves
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
    tevo_event_id, sg_event_name, sg_venue_name, sg_datetime_utc)
  SELECT
    v_today, r.sg_event_id, r.rnk::int, round(r.chart_score, 4),
    round(r.pct_volume, 4), round(r.pct_median, 4),
    round(r.ma7_volume, 1), round(r.ma7_median, 2), round(r.ma7_gross, 2), r.days_with_sales,
    prev.rank,
    -- peak = best of (today's rank, lowest rank ever before today)
    LEAST(r.rnk::int,
          coalesce((SELECT min(h.rank) FROM public.sg_market_chart h
                    WHERE h.sg_event_id = r.sg_event_id), r.rnk::int)),
    CASE WHEN prev.rank IS NOT NULL THEN coalesce(prev.days_on_chart, 0) + 1 ELSE 1 END,
    r.tevo_event_id, r.sg_event_name, r.sg_venue_name, r.sg_datetime_utc
  FROM ranked r
  LEFT JOIN public.sg_market_chart prev
    ON prev.sg_event_id = r.sg_event_id AND prev.chart_date = v_prev;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- retention: keep 90 days of chart history
  DELETE FROM public.sg_market_chart WHERE chart_date < v_today - 90;

  RETURN v_count;
END $func$;

REVOKE ALL ON FUNCTION public.rebuild_sg_market_chart() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_sg_market_chart() TO service_role;

COMMENT ON FUNCTION public.rebuild_sg_market_chart() IS
  'Rebuilds today''s sg_market_chart: top non-owned future SG events ranked by '
  'percent_rank(7d-MA sales volume) + percent_rank(7d-MA sales median). Carries '
  'prev_rank/peak_rank/days_on_chart for Billboard-style movement. Daily cron @ 11:05 UTC.';

-- ---------- 3. Read RPC (email-gated, paged: top 50 + the rest) ----------
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

REVOKE ALL ON FUNCTION public.get_sg_market_chart(integer, integer) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sg_market_chart(integer, integer) TO authenticated;

COMMENT ON FUNCTION public.get_sg_market_chart(integer, integer) IS
  'Returns {chart_date,total,rows[]} for the latest sg_market_chart day, paged by '
  'rank (offset/limit). Powers the terminal home "TOP 50 — SG SELLING, WE''RE NOT IN" '
  'panel: tab 1 = offset 0/limit 50, tab 2 = offset 50. Email-gated @s4kent.com.';

-- ---------- 4. Daily rebuild cron (gated) ----------
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES
  ('sg_market_chart_rebuild_daily',
   ARRAY[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23],
   720, 720, 2, true,
   'Daily rebuild of sg_market_chart (Top-50 non-owned SG sales chart, home panel). Fires once @ 11:05 UTC; 720-min gate guards against double-fire.')
ON CONFLICT (jobname) DO UPDATE
  SET peak_hours_et = EXCLUDED.peak_hours_et,
      peak_min_interval_min = EXCLUDED.peak_min_interval_min,
      offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = true,
      notes = EXCLUDED.notes,
      updated_at = now();

SELECT cron.schedule('sg_market_chart_rebuild_daily', '5 11 * * *', $cron$
  DO $body$ BEGIN
    IF NOT public.cron_should_fire('sg_market_chart_rebuild_daily') THEN RETURN; END IF;
    SET LOCAL statement_timeout = '120s';
    PERFORM public.rebuild_sg_market_chart();
  END $body$;
$cron$);

-- ---------- 5. Seed today's chart so the panel renders immediately on apply ----------
SELECT public.rebuild_sg_market_chart();
