-- Migration 20260811271000 · lane:D0 · operator-directed 2026-08-11
--   ("fix realized med": manual curated zones + event-day normalization + weekend split).
--
--   writes: section_sale_baseline_cz [table], rebuild_section_sale_baseline_cz(int) [fn],
--           cron section_sale_baseline_cz_weekly.
--   reads: seatgeek_sales_snapshots, events, performer_zones, performer_zone_rules,
--          performer_metadata, clearing_dte_curve, section_in_range().
--   auth: builder service_role-guarded SECDEF.
--
-- Realized-sale distribution per (home performer × CURATED manual zone × weekend), with each
-- sale projected to its own event's EVENT-DAY price via the clearing curve. Keyed on the
-- operator's curated zones (performer_zones.source='curated' + performer_zone_rules ranges via
-- section_in_range) — NOT derive_zone_fallback or site zones. Parallel prices_ed[]/qtys[] arrays
-- (200 most-recent) let the scanner compute exact win-prob and quantity-band the anchor.
-- Separate from the old section_sale_baseline so the live scanner keeps running until it is
-- swapped; validate this table's medians before the swap.
--
-- ROLLBACK: cron.unschedule('section_sale_baseline_cz_weekly');
--   DROP FUNCTION rebuild_section_sale_baseline_cz(int); DROP TABLE section_sale_baseline_cz;

CREATE TABLE IF NOT EXISTS public.section_sale_baseline_cz (
  performer_id bigint  NOT NULL,
  zone_id      bigint  NOT NULL,          -- performer_zones.id (curated)
  is_weekend   boolean NOT NULL,
  n_sales      int     NOT NULL,
  median_ed    numeric,                   -- event-day-normalized median resale
  p25_ed       numeric,
  p75_ed       numeric,
  prices_ed    numeric[],                 -- up to 200 recent event-day-normalized prices
  qtys         int[],                     -- parallel quantities (for the scanner's qty-band)
  window_days  int     NOT NULL DEFAULT 45,
  computed_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (performer_id, zone_id, is_weekend)
);
ALTER TABLE public.section_sale_baseline_cz ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.section_sale_baseline_cz TO authenticated, service_role;
COMMENT ON TABLE public.section_sale_baseline_cz IS
  'Event-day-normalized realized-sale distribution per (home performer × curated zone × weekend). Resale anchor + win-prob for the deals scanner, keyed on manual curated zones. D0 mig 20260811271000.';

CREATE OR REPLACE FUNCTION public.rebuild_section_sale_baseline_cz(p_window_days int DEFAULT 45)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $fn$
DECLARE v_n integer;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'forbidden: %', current_user USING ERRCODE='42501';
  END IF;
  PERFORM set_config('statement_timeout','240000',true);

  CREATE TEMP TABLE _norm ON COMMIT DROP AS
    SELECT e.primary_performer_id AS perf,
           pz.id AS zone_id,
           (EXTRACT(dow FROM e.occurs_at_local::timestamptz)::int IN (0,5,6)) AS is_weekend,
           sgs.broadcast_price::numeric
             * COALESCE(c0.level_index / NULLIF(cs.level_index,0), 1) AS p_ed,
           coalesce(sgs.quantity,0) AS qty,
           sgs.sale_at_utc
    FROM public.seatgeek_sales_snapshots sgs
    JOIN public.events e ON e.id = sgs.tevo_event_id
    JOIN public.performer_zones pz
      ON pz.performer_id = e.primary_performer_id AND pz.venue_id = e.venue_id AND pz.source = 'curated'
    JOIN public.performer_zone_rules pzr
      ON pzr.zone_id = pz.id
     AND public.section_in_range(sgs.section, pzr.section_from, pzr.section_to)
     AND (pzr.row_from IS NULL OR pzr.row_to IS NULL OR public.section_in_range(sgs.row, pzr.row_from, pzr.row_to))
    LEFT JOIN public.performer_metadata pm ON pm.performer_id = e.primary_performer_id
    LEFT JOIN public.clearing_dte_curve cs
      ON cs.category = (CASE WHEN e.event_type='game' THEN 'Sports'
                             WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                             ELSE 'Other' END)
     AND cs.dte_bucket = public.price_dte_bucket(GREATEST((e.occurs_at_local::date - sgs.sale_at_utc::date),0))
    LEFT JOIN public.clearing_dte_curve c0
      ON c0.category = (CASE WHEN e.event_type='game' THEN 'Sports'
                             WHEN pm.top_category_name IN ('Sports','Concerts','Comedy','Theater') THEN pm.top_category_name
                             ELSE 'Other' END)
     AND c0.dte_bucket = public.price_dte_bucket(0)
    WHERE sgs.sale_at_utc > now() - (p_window_days||' days')::interval
      AND sgs.broadcast_price > 0
      AND e.occurs_at_local ~ '^\d{4}-\d\d-\d\dT';

  TRUNCATE public.section_sale_baseline_cz;
  INSERT INTO public.section_sale_baseline_cz
    (performer_id, zone_id, is_weekend, n_sales, median_ed, p25_ed, p75_ed, prices_ed, qtys, window_days)
  WITH capped AS (
    SELECT perf, zone_id, is_weekend, p_ed, qty,
           row_number() OVER (PARTITION BY perf, zone_id, is_weekend ORDER BY sale_at_utc DESC) AS rn
    FROM _norm WHERE p_ed > 0
  )
  SELECT perf, zone_id, is_weekend, count(*)::int,
         percentile_cont(0.5)  WITHIN GROUP (ORDER BY p_ed)::numeric,
         percentile_cont(0.25) WITHIN GROUP (ORDER BY p_ed)::numeric,
         percentile_cont(0.75) WITHIN GROUP (ORDER BY p_ed)::numeric,
         array_agg(p_ed ORDER BY rn) FILTER (WHERE rn <= 200),
         array_agg(qty  ORDER BY rn) FILTER (WHERE rn <= 200),
         p_window_days
  FROM capped
  GROUP BY perf, zone_id, is_weekend
  HAVING count(*) >= 8;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$fn$;
REVOKE ALL ON FUNCTION public.rebuild_section_sale_baseline_cz(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_section_sale_baseline_cz(int) TO service_role;
COMMENT ON FUNCTION public.rebuild_section_sale_baseline_cz(int) IS
  'Rebuild section_sale_baseline_cz (event-day-normalized, curated-zone + weekend keyed) from seatgeek_sales_snapshots. service_role only. D0 mig 20260811271000.';

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_cron') THEN
    PERFORM cron.unschedule('section_sale_baseline_cz_weekly')
      WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='section_sale_baseline_cz_weekly');
    PERFORM cron.schedule('section_sale_baseline_cz_weekly', '57 9 * * 1',
      $$SELECT public.rebuild_section_sale_baseline_cz(45);$$);
  END IF;
END;
$cron$;