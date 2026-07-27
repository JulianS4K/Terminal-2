-- ============================================================================
-- Migration 20260702004500 — SG sales re-lit + Top-50 chart enriched with EVO + TD-SH listing data
--
-- Lane:     A1 (+D0 frontend cols in static/terminal/home.js, same PR)
-- Touches:  cron active=true for the 3 SG sales-path jobs; get_sg_market_chart() (adds EVO+SH
--           fields); ticketsdata_event_xref (chart-event SH enrollment: 17 reactivated).
-- Pre-reqs: sg_market_chart (mig 20260606120000), latest_event_metrics, event_listing_snapshot_daily.
--
-- WHY (operator 2026-07-02 "turn on the sg sales, and use evo for listing data for that; also
-- turn on td stubhub listings for this as an additional source"):
--   The Top-50 'SG SELLING, WE'RE NOT IN' chart ranks on SG SALES activity — frozen since 6/26
--   (pollers off) — and would have decayed to empty within ~2-3 days ('>=2 days of sales in
--   trailing 7d' eligibility). Re-lit the SALES path only (poller sg_sales_poll_5min at 4 req/tick
--   rate-aware + sg_priority_sales_process_5min + sg_broker_sales_metrics_refresh_hourly);
--   SG LISTINGS pollers stay dark. Listing context on the chart now comes from:
--     * EVO (free, ~10-min lag): getin_price / retail_median / tickets_count via
--       latest_event_metrics keyed on tevo_event_id;
--     * TD StubHub (additional source): td_sh_median / td_sh_listings from the latest
--       event_listing_snapshot_daily row (3x-daily slots).
--   Verified: enriched 250-row query <10ms; 247/250 rows carry EVO prices, 216/250 SH medians.
--   Chart-event SH enrollment: 667/687 were active; 17 xref rows were INACTIVE (old sweep
--   deactivations) -> reactivated; ~zero net credit impact (non-owned = 1 poll/day ladder cap).
--
-- Idempotent: alter_job/CREATE OR REPLACE/guarded UPDATE. Re-apply is a no-op.
-- Already applied to prod · via MCP 2026-07-02
-- ============================================================================

DO $do$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT jobid FROM cron.job
           WHERE jobname IN ('sg_sales_poll_5min','sg_priority_sales_process_5min',
                             'sg_broker_sales_metrics_refresh_hourly')
  LOOP
    PERFORM cron.alter_job(r.jobid, active:=true);
  END LOOP;
END $do$;

-- Reactivate chart events' inactive SH xref rows (idempotent; new inserts guarded separately
-- at apply time — 0 needed, all mappable events already had rows).
UPDATE ticketsdata_event_xref x SET active=true, updated_at=now()
FROM aq_event_map aem
WHERE x.aq_short_event_id=aem.aq_short_event_id AND x.platform='SH' AND NOT x.active
  AND aem.sg_event_id IN (SELECT sg_event_id FROM sg_market_chart
                          WHERE chart_date=(SELECT max(chart_date) FROM sg_market_chart));

CREATE OR REPLACE FUNCTION public.get_sg_market_chart(p_offset integer DEFAULT 0, p_limit integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
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
END $function$;
