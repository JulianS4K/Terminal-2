-- Migration 20260702170000 · lane:D0 (author) → A1 (apply) · writes(DDL):get_wc_seatdata_comps · reads:aq_event_map, seatdata_event_xref, seatdata_sales_snapshots, world_cup_2026 · pre:20260702155000_wc_seatmap_donor_resolver · auth:operator-requested 2026-07-02 ("build it" — full SeatData comp curve as the WC pricing benchmark)
--
-- ## Applied to prod 2026-07-02 via MCP apply_migration (operator-directed). Idempotent.
--
-- The shared get_event_seatdata_sales_full() hard-caps its window at 90 days, so a
-- now-played WC match (Match 72) shows only its final weeks, not the full ~9-month
-- sold-ticket curve that makes it a comp. This is a WC-specific, UNCAPPED read of
-- the same seatdata_sales_snapshots — full history, deduped by content_hash — with
-- a daily aggregate curve + summary. Keyed by sg_event_id (the WC surface).
--
-- BENCHMARK FALLBACK: SeatData is tevo_event_id-keyed and TEvo lists only 1 real WC
-- match (Match 72, which we own), so 21/22 upcoming matches have no realized sales.
-- For those, the RPC returns Match 72's curve flagged is_benchmark=true — the only
-- WC match with realized SeatData sales, usable as the tournament pricing benchmark.
-- The benchmark event is resolved DYNAMICALLY (the WC match with the most SeatData
-- sales), not hardcoded, so it self-updates if we acquire more. Email-gated, anon revoked.
CREATE OR REPLACE FUNCTION public.get_wc_seatdata_comps(p_sg_event_id bigint)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_email text := coalesce(auth.jwt()->>'email', '');
  v_own_tevo bigint;
  v_use_tevo bigint;
  v_is_bench boolean := false;
  v_sd bigint;
  v_result jsonb;
BEGIN
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE='42501';
  END IF;

  SELECT a.tevo_event_id INTO v_own_tevo
  FROM public.aq_event_map a WHERE a.sg_event_id = p_sg_event_id LIMIT 1;

  IF v_own_tevo IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.seatdata_sales_snapshots s WHERE s.tevo_event_id = v_own_tevo) THEN
    v_use_tevo := v_own_tevo;
  ELSE
    SELECT w.tevo_event_id INTO v_use_tevo
    FROM public.world_cup_2026 w
    WHERE w.tevo_event_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM public.seatdata_sales_snapshots s WHERE s.tevo_event_id = w.tevo_event_id)
    ORDER BY (SELECT count(*) FROM public.seatdata_sales_snapshots s WHERE s.tevo_event_id = w.tevo_event_id) DESC
    LIMIT 1;
    v_is_bench := (v_use_tevo IS NOT NULL);
  END IF;

  IF v_use_tevo IS NULL THEN
    RETURN jsonb_build_object('sg_event_id', p_sg_event_id, 'is_benchmark', false,
      'has_data', false, 'note', 'No SeatData sold-ticket comps exist for any World Cup match yet.');
  END IF;

  SELECT sd_event_id INTO v_sd FROM public.seatdata_event_xref WHERE tevo_event_id = v_use_tevo LIMIT 1;

  WITH ded AS (
    SELECT DISTINCT ON (content_hash) content_hash, sale_timestamp, price, quantity, section
    FROM public.seatdata_sales_snapshots
    WHERE tevo_event_id = v_use_tevo
    ORDER BY content_hash, pulled_at DESC
  ),
  daily AS (
    SELECT sale_timestamp::date AS d,
           count(*) AS sales, sum(quantity) AS tickets,
           round(min(price)) AS mn,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY price)) AS med,
           round(percentile_cont(0.9) WITHIN GROUP (ORDER BY price)) AS p90
    FROM ded GROUP BY 1
  )
  SELECT jsonb_build_object(
    'sg_event_id', p_sg_event_id,
    'is_benchmark', v_is_bench,
    'has_data', true,
    'benchmark_tevo_event_id', CASE WHEN v_is_bench THEN v_use_tevo END,
    'benchmark_match', CASE WHEN v_is_bench THEN
       (SELECT w.match_number || ' — ' || w.match_label || ' (' || w.venue_city || ')'
        FROM public.world_cup_2026 w WHERE w.tevo_event_id = v_use_tevo LIMIT 1) END,
    'tevo_event_id', v_use_tevo,
    'sd_event_id', v_sd,
    'summary', (SELECT jsonb_build_object(
        'sales', count(*), 'sections', count(DISTINCT section), 'tickets', sum(quantity),
        'first_sale', min(sale_timestamp)::date, 'last_sale', max(sale_timestamp)::date,
        'min', round(min(price)), 'median', round(percentile_cont(0.5) WITHIN GROUP (ORDER BY price)),
        'p90', round(percentile_cont(0.9) WITHIN GROUP (ORDER BY price)), 'max', round(max(price)))
      FROM ded),
    'daily', (SELECT coalesce(jsonb_agg(jsonb_build_object(
        'd', d, 'sales', sales, 'tickets', tickets, 'min', mn, 'median', med, 'p90', p90) ORDER BY d), '[]'::jsonb)
      FROM daily)
  ) INTO v_result;

  RETURN v_result;
END $func$;

REVOKE ALL ON FUNCTION public.get_wc_seatdata_comps(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_wc_seatdata_comps(bigint) TO authenticated;
