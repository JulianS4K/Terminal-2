-- ============================================================================
-- Migration 20260702140000 — exclude EVO-owned events from the SG "WE'RE NOT IN" chart
--
-- Lane:     D0 (terminal home panel) · level:2
-- Touches:  sg_market_chart (W, via rebuild), rebuild_sg_market_chart() (W, redefined),
--           event_metrics (R, latest owned_tickets_count per event),
--           sg_event_priority_state (R), seatgeek_event_metrics (R),
--           seatdata_sales_snapshots (R)
-- Pre-reqs: 20260608220000_sg_market_chart_blended (the CURRENT rebuild body — the
--           volume-weighted SeatGeek+SeatData blend + hybrid rank this migration
--           preserves verbatim; only the elig CTE changes).
--
-- Re-application note (2026-07-02): this supersedes the withdrawn PR #560 migration
-- 20260616260000_sg_market_chart_exclude_evo_owned.sql. That file redefined an OLDER
-- (pre-blend) rebuild_sg_market_chart body and, applied onto post-rewrite main, would
-- have REVERTED the blended-metrics work (mig 20260608220000). This version ports the
-- SAME EVO dual-source ownership gate onto main's CURRENT blended function instead.
-- Version bumped to the next free 14-digit prefix (main's latest is 20260702131000).
--
-- WHY: the "TOP 50 — SG SELLING, WE'RE NOT IN" chart judged "we're not in" on
-- SeatGeek ownership alone (sg_event_priority_state.owned_count_last_7d = 0).
-- But SeatGeek is frequently TURNED OFF for an event under a sales deal while we
-- still hold EVO/TEvo inventory at that same event — so an event we ARE exposed
-- to (via EVO) wrongly charted as a blindspot. Verified live 2026-06-16: of 836
-- charted rows, "Baltimore Orioles at Los Angeles Dodgers" (tevo 3100208,
-- 2026-06-21, rank 479) showed 20 EVO owned tickets / 5 groups while SG owned = 0.
--
-- WHAT: rebuild_sg_market_chart() eligibility now ALSO requires zero EVO owned
-- inventory — a LATERAL lookup of the latest event_metrics.owned_tickets_count
-- for the event's tevo_event_id (uses idx_event_metrics_time on (event_id,
-- captured_at DESC)). Events with no tevo link or no metrics row are treated as
-- not-EVO-owned (kept). Only the elig CTE changed; the SeatData blend, hybrid
-- scoring/ranking/movement, and the read RPC are all untouched.
--
-- PENDING OPERATOR APPLY: gated per CLAUDE.md §1 (A1 applies to prod).
-- ROLLBACK: restore the mig 20260608220000 rebuild_sg_market_chart() body.
-- ============================================================================

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
    -- latest EVO metrics for this event (NULL when unlinked or no metrics row)
    LEFT JOIN LATERAL (
      SELECT em.owned_tickets_count
      FROM public.event_metrics em
      WHERE em.event_id = p.tevo_event_id
      ORDER BY em.captured_at DESC
      LIMIT 1
    ) evo ON p.tevo_event_id IS NOT NULL
    WHERE coalesce(p.owned_count_last_7d, 0) = 0   -- we hold no SeatGeek inventory
      AND coalesce(evo.owned_tickets_count, 0) = 0 -- ...and no EVO/TEvo inventory either
                                                   -- (SG can be off under a sales deal
                                                   --  while we still sell via EVO)
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

REVOKE ALL ON FUNCTION public.rebuild_sg_market_chart() FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_sg_market_chart() TO service_role;

COMMENT ON FUNCTION public.rebuild_sg_market_chart() IS
  'Rebuilds today''s sg_market_chart: top future SG events we hold ZERO inventory in '
  '(neither SeatGeek owned_count_last_7d NOR latest EVO event_metrics.owned_tickets_count), '
  'volume-weighted SeatGeek+SeatData blend, hybrid-ranked (blended when SeatData present, '
  'else SG). Carries prev_rank/peak_rank/days_on_chart for Billboard-style movement. '
  'Daily cron @ 11:05 UTC.';

-- Re-seed today's chart so the EVO-ownership exclusion takes effect immediately on apply
-- (otherwise it would wait for the next daily cron rebuild @ 11:05 UTC).
SELECT public.rebuild_sg_market_chart();
