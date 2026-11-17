-- Migration 20260811230000 · lane:D0 (author) → applier (apply) · writes:section_sale_baseline [table], rebuild_section_sale_baseline(int) [fn], cron section_sale_baseline_weekly · reads:seatgeek_sales_snapshots,events · pre:mig 20260811220000 (realized-calibrated deals) · auth:builder service_role-guarded SECDEF
--
-- WHY (operator-directed 2026-08-11 "build them all in"). The v4 deal test needs
-- realized SeatGeek sales for the CURRENT event × section to compute win-probability;
-- events without recent sales surface nothing (coverage gap). This precomputes a
-- HISTORIC realized baseline — the realized-sale price distribution per (home
-- performer × section number) over a recent window — so an event with no current
-- sales still gets a realized resale anchor + win-probability from how that team's
-- seats in that section have actually sold. Rolled up from 17.7M seatgeek_sales_
-- snapshots (measured: 30d → 631k sales → ~15k groups). The scanner (next migration)
-- falls back to this when the current event has < p_min_realized_n sales.
--
-- Each group stores n_sales + median/p25/p75 AND a capped price array (200 most-
-- recent) so the scanner can compute an EXACT empirical win-probability against any
-- buy-price hurdle, not just a median. Rebuilt weekly.
--
-- ROLLBACK: cron.unschedule('section_sale_baseline_weekly');
--           DROP FUNCTION rebuild_section_sale_baseline(int); DROP TABLE section_sale_baseline;

CREATE TABLE IF NOT EXISTS public.section_sale_baseline (
  performer_id  bigint NOT NULL,
  secnum        int    NOT NULL,
  n_sales       int    NOT NULL,
  median_price  numeric,
  p25_price     numeric,
  p75_price     numeric,
  prices        numeric[],          -- up to 200 most-recent realized sale prices (exact win-prob)
  window_days   int    NOT NULL DEFAULT 45,
  computed_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (performer_id, secnum)
);
ALTER TABLE public.section_sale_baseline ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.section_sale_baseline TO authenticated, service_role;
COMMENT ON TABLE public.section_sale_baseline IS
  'Historic realized-sale distribution per (home performer × section number) from seatgeek_sales_snapshots — the fallback resale anchor + win-probability when a live event has no current realized sales. Rebuilt weekly. D0 mig 20260811230000.';

CREATE OR REPLACE FUNCTION public.rebuild_section_sale_baseline(p_window_days int DEFAULT 45)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout','240000',true);

  CREATE TEMP TABLE _s ON COMMIT DROP AS
    SELECT e.primary_performer_id AS perf,
           (regexp_match(sgs.section,'(\d{2,4})'))[1]::int AS secnum,
           sgs.broadcast_price::numeric AS p, sgs.sale_at_utc
    FROM public.seatgeek_sales_snapshots sgs
    JOIN public.events e ON e.id = sgs.tevo_event_id
    WHERE sgs.sale_at_utc > now() - (p_window_days||' days')::interval
      AND sgs.broadcast_price > 0 AND e.primary_performer_id IS NOT NULL AND sgs.section ~ '\d';

  DELETE FROM _s WHERE secnum IS NULL;

  TRUNCATE public.section_sale_baseline;
  INSERT INTO public.section_sale_baseline
    (performer_id, secnum, n_sales, median_price, p25_price, p75_price, prices, window_days)
  WITH capped AS (
    SELECT perf, secnum, p,
           row_number() OVER (PARTITION BY perf, secnum ORDER BY sale_at_utc DESC) AS rn
    FROM _s
  )
  SELECT perf, secnum, count(*)::int,
         percentile_cont(0.5)  WITHIN GROUP (ORDER BY p)::numeric,
         percentile_cont(0.25) WITHIN GROUP (ORDER BY p)::numeric,
         percentile_cont(0.75) WITHIN GROUP (ORDER BY p)::numeric,
         array_agg(p) FILTER (WHERE rn <= 200),
         p_window_days
  FROM capped
  GROUP BY perf, secnum
  HAVING count(*) >= 8;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.rebuild_section_sale_baseline(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_section_sale_baseline(int) TO service_role;
COMMENT ON FUNCTION public.rebuild_section_sale_baseline(int) IS
  'Full rebuild of section_sale_baseline from seatgeek_sales_snapshots (window default 45d). service_role only. D0 mig 20260811230000.';

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    PERFORM cron.unschedule('section_sale_baseline_weekly')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='section_sale_baseline_weekly');
    PERFORM cron.schedule('section_sale_baseline_weekly', '47 9 * * 1',
      $$SELECT public.rebuild_section_sale_baseline(45);$$);
  END IF;
END;
$cron$;
