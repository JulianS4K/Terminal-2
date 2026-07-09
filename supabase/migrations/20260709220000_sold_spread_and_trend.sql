-- Migration 20260709220000 · lane:D0 (author) → A1 (apply) · writes:performer_stat_card(+3 cols),refresh_performer_trending,refresh_performer_sg_sold,get_trending_performers(add p_sort) · reads:seatgeek_event_metrics,events,performer_stat_card · pre:mig 20260709200000 + 20260709210000 · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (alters a table + rewrites 3 fns + backfills)
--
-- D0 — sold-vs-asked spread + realized-sold trend.
--
-- Two new signals off the SG realized-sold layer:
--   * ask_over_sold_pct — how far our listing median sits above the realized SG
--     clearing median. + = asks inflated (hard to clear at ask); − = asks below
--     clearing (underpriced, a buy). e.g. Olivia Dean +94%, NCAA CWS −25%.
--   * trend_sold_30d — same-event-set 30d momentum of the REALIZED sold median
--     (from seatgeek_event_metrics capture history), the cleaner cousin of the
--     listing-based trend_px_30d.
--
-- ask_over_sold_pct is computed in refresh_performer_sg_sold (has both medians);
-- trend_sold_30d in refresh_performer_trending (adds a sold arm alongside the
-- listing arm). get_trending_performers gains p_sort ('ask' | 'sold').

ALTER TABLE public.performer_stat_card
  ADD COLUMN IF NOT EXISTS ask_over_sold_pct       numeric,
  ADD COLUMN IF NOT EXISTS trend_sold_30d          numeric,
  ADD COLUMN IF NOT EXISTS trend_sold_stable_events integer;

-- ============================================================
-- 1. Trending refresh — listing arm (unchanged) + realized-sold arm
-- ============================================================
CREATE OR REPLACE FUNCTION public.refresh_performer_trending()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  UPDATE public.performer_stat_card
     SET trend_px_30d = NULL, trend_stable_events = NULL,
         trend_sold_30d = NULL, trend_sold_stable_events = NULL
   WHERE trend_px_30d IS NOT NULL OR trend_sold_30d IS NOT NULL;

  -- ---- listing arm (amalgam median, event_listing_snapshot_daily) -----------
  WITH latest AS (SELECT max(snapshot_date) d FROM public.event_listing_snapshot_daily),
  now_ev AS (
    SELECT DISTINCT ON (event_id) event_id, amalgam_median AS med_now
    FROM public.event_listing_snapshot_daily
    WHERE snapshot_date = (SELECT d FROM latest) AND amalgam_median IS NOT NULL
    ORDER BY event_id, CASE snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 WHEN 'morning' THEN 1 ELSE 0 END DESC
  ),
  ago_ev AS (
    SELECT DISTINCT ON (event_id) event_id, amalgam_median AS med_30d
    FROM public.event_listing_snapshot_daily
    WHERE snapshot_date <= (SELECT d FROM latest) - 30 AND snapshot_date >= (SELECT d FROM latest) - 44
      AND amalgam_median IS NOT NULL
    ORDER BY event_id, snapshot_date DESC
  ),
  paired AS (
    SELECT n.event_id, (n.med_now - a.med_30d) / nullif(a.med_30d, 0) AS chg
    FROM now_ev n JOIN ago_ev a USING (event_id) WHERE a.med_30d > 0
  ),
  pe AS (
    SELECT u.pid AS performer_id, p.chg
    FROM public.events e CROSS JOIN LATERAL unnest(e.performer_ids) AS u(pid)
    JOIN paired p ON p.event_id = e.id
    WHERE e.name IS NOT NULL AND e.name !~* '(season ticket|includes tickets to all|parking|ticket package)'
  ),
  g AS (
    SELECT performer_id, count(*)::int AS n,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY chg) * 100)::numeric, 1) AS trend
    FROM pe GROUP BY performer_id HAVING count(*) >= 2
  )
  UPDATE public.performer_stat_card t
     SET trend_px_30d = g.trend, trend_stable_events = g.n, trend_computed_at = now()
    FROM g WHERE t.performer_id = g.performer_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  -- ---- realized-sold arm (sold_price_median, seatgeek_event_metrics) --------
  WITH cap AS (SELECT max(captured_at) c FROM public.seatgeek_event_metrics WHERE sold_price_median IS NOT NULL),
  sold_now AS (
    SELECT DISTINCT ON (sg_event_id) sg_event_id, tevo_event_id, sold_price_median AS med_now
    FROM public.seatgeek_event_metrics
    WHERE sold_price_median IS NOT NULL AND tevo_event_id IS NOT NULL AND captured_at >= (SELECT c FROM cap) - interval '2 days'
    ORDER BY sg_event_id, captured_at DESC
  ),
  sold_ago AS (
    SELECT DISTINCT ON (sg_event_id) sg_event_id, sold_price_median AS med_30d
    FROM public.seatgeek_event_metrics
    WHERE sold_price_median IS NOT NULL AND captured_at <= (SELECT c FROM cap) - interval '28 days'
      AND captured_at >= (SELECT c FROM cap) - interval '44 days'
    ORDER BY sg_event_id, captured_at DESC
  ),
  spaired AS (
    SELECT n.tevo_event_id, (n.med_now - a.med_30d) / nullif(a.med_30d, 0) AS chg
    FROM sold_now n JOIN sold_ago a USING (sg_event_id) WHERE a.med_30d > 0
  ),
  spe AS (
    SELECT u.pid AS performer_id, p.chg
    FROM public.events e CROSS JOIN LATERAL unnest(e.performer_ids) AS u(pid)
    JOIN spaired p ON p.tevo_event_id = e.id
  ),
  sg AS (
    SELECT performer_id, count(*)::int AS n,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY chg) * 100)::numeric, 1) AS trend
    FROM spe GROUP BY performer_id HAVING count(*) >= 2
  )
  UPDATE public.performer_stat_card t
     SET trend_sold_30d = sg.trend, trend_sold_stable_events = sg.n
    FROM sg WHERE t.performer_id = sg.performer_id;

  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.refresh_performer_trending() FROM PUBLIC;

-- ============================================================
-- 2. SG-sold refresh — add ask_over_sold_pct (asks vs realized clearing)
-- ============================================================
CREATE OR REPLACE FUNCTION public.refresh_performer_sg_sold()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_n integer;
BEGIN
  UPDATE public.performer_stat_card
     SET sg_sold_by_year = NULL, sg_sold_median = NULL, sg_sold_qty = NULL, ask_over_sold_pct = NULL
   WHERE sg_sold_by_year IS NOT NULL OR sg_sold_median IS NOT NULL;

  WITH latest AS (
    SELECT DISTINCT ON (sg_event_id) sg_event_id, tevo_event_id,
           sold_price_median, sold_price_mean, sold_quantity
    FROM public.seatgeek_event_metrics
    WHERE sold_price_median IS NOT NULL AND tevo_event_id IS NOT NULL
    ORDER BY sg_event_id, captured_at DESC
  ),
  pe AS (
    SELECT u.pid AS performer_id,
           CASE WHEN e.occurs_at_local ~ '^\d{4}' THEN left(e.occurs_at_local, 4)::int END AS yr,
           l.sold_price_median, l.sold_price_mean, l.sold_quantity
    FROM public.events e CROSS JOIN LATERAL unnest(e.performer_ids) AS u(pid)
    JOIN latest l ON l.tevo_event_id = e.id
  ),
  by_year AS (
    SELECT performer_id, yr,
           count(*)::int AS events, sum(sold_quantity)::bigint AS qty,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sold_price_median)::numeric, 2) AS sold_median,
           round((sum(sold_price_mean * sold_quantity) / nullif(sum(sold_quantity), 0))::numeric, 2) AS sold_mean
    FROM pe WHERE yr IS NOT NULL GROUP BY performer_id, yr
  ),
  agg AS (
    SELECT performer_id,
           jsonb_agg(jsonb_build_object('year', yr, 'events', events, 'qty', qty,
                       'sold_median', sold_median, 'sold_mean', sold_mean) ORDER BY yr DESC) AS by_year,
           sum(qty)::bigint AS total_qty
    FROM by_year GROUP BY performer_id
  ),
  overall AS (
    SELECT performer_id,
           round(percentile_cont(0.5) WITHIN GROUP (ORDER BY sold_price_median)::numeric, 2) AS med
    FROM pe WHERE yr IS NOT NULL GROUP BY performer_id
  )
  UPDATE public.performer_stat_card t
     SET sg_sold_by_year = a.by_year, sg_sold_qty = a.total_qty, sg_sold_median = o.med,
         ask_over_sold_pct = round(((t.price_median - o.med) / nullif(o.med, 0) * 100)::numeric, 1)
    FROM agg a JOIN overall o USING (performer_id)
   WHERE t.performer_id = a.performer_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.refresh_performer_sg_sold() FROM PUBLIC;

-- ============================================================
-- 3. get_trending_performers — add p_sort ('ask' | 'sold')
-- ============================================================
DROP FUNCTION IF EXISTS public.get_trending_performers(integer, bigint, integer);
CREATE OR REPLACE FUNCTION public.get_trending_performers(
  p_limit integer DEFAULT 25,
  p_min_market bigint DEFAULT 1000,
  p_min_events integer DEFAULT 3,
  p_sort text DEFAULT 'ask'
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text; v_result jsonb; v_sold boolean;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  v_sold := (p_sort = 'sold');
  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.k DESC NULLS LAST), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT sc.*, CASE WHEN v_sold THEN trend_sold_30d ELSE trend_px_30d END AS k
    FROM public.performer_stat_card sc
    WHERE (CASE WHEN v_sold THEN trend_sold_30d ELSE trend_px_30d END) IS NOT NULL
      AND coalesce(market_tickets,0) >= greatest(0, coalesce(p_min_market,1000))
      AND coalesce(CASE WHEN v_sold THEN trend_sold_stable_events ELSE trend_stable_events END,0)
          >= greatest(1, coalesce(p_min_events,3))
    ORDER BY (CASE WHEN v_sold THEN trend_sold_30d ELSE trend_px_30d END) DESC
    LIMIT greatest(1, least(coalesce(p_limit,25), 100))
  ) s;
  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_trending_performers(integer, bigint, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_trending_performers(integer, bigint, integer, text) TO anon, authenticated;

COMMENT ON FUNCTION public.get_trending_performers(integer, bigint, integer, text) IS
  'D0 top trending performers, p_sort ask=listing momentum (trend_px_30d) | sold=realized momentum (trend_sold_30d), liquidity-gated. @s4kent.com-gated SECDEF read.';

-- ============================================================
-- 4. Backfill both refreshes
-- ============================================================
SELECT public.refresh_performer_trending();
SELECT public.refresh_performer_sg_sold();
