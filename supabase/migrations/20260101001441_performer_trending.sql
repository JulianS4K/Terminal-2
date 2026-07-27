-- Migration 20260709200000 · lane:D0 (author) → A1 (apply) · writes:performer_stat_card(+3 cols),refresh_performer_trending,get_trending_performers,get_performer_stat_card_gallery(movers repoint),cron(performer-trending-refresh) · reads:event_listing_snapshot_daily,events,performer_stat_card · pre:performer_stat_card (mig 20260709140000) · auth:OPERATOR-APPROVAL REQUIRED before apply_migration (alters a table + cron + backfills)
--
-- D0 — performer TRENDING (same-event-set price momentum).
--
-- The stat-card's price_d30_pct is a performer-level aggregate that blends real
-- repricing with slate churn (events added/dropped over the window). "Trending"
-- needs the trustworthy version: compare ONLY events present in BOTH windows
-- (now vs ~30d ago) per event, then take the median per-event % change — so it
-- measures repricing, not composition change. Liquidity-gated at read time.
--
-- Stored on performer_stat_card (trend_px_30d, trend_stable_events); refreshed
-- daily (event_listing_snapshot_daily retains ~43d). The gallery 'movers' sort
-- is repointed to this trustworthy trend. get_trending_performers powers the
-- Trending table at the top of the performer page.

ALTER TABLE public.performer_stat_card
  ADD COLUMN IF NOT EXISTS trend_px_30d        numeric,   -- median per-event 30d % change, stable set
  ADD COLUMN IF NOT EXISTS trend_stable_events integer,   -- events priced in both windows
  ADD COLUMN IF NOT EXISTS trend_computed_at   timestamptz;

-- ============================================================
-- Refresh — stable-event-set momentum per performer
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
     SET trend_px_30d = NULL, trend_stable_events = NULL
   WHERE trend_px_30d IS NOT NULL;

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
    FROM public.events e
    CROSS JOIN LATERAL unnest(e.performer_ids) AS u(pid)
    JOIN paired p ON p.event_id = e.id
    WHERE e.name IS NOT NULL
      AND e.name !~* '(season ticket|includes tickets to all|parking|ticket package)'
  ),
  g AS (
    SELECT performer_id, count(*)::int AS stable_events,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY chg) * 100)::numeric, 1) AS trend_px_30d
    FROM pe GROUP BY performer_id HAVING count(*) >= 2
  )
  UPDATE public.performer_stat_card t
     SET trend_px_30d = g.trend_px_30d, trend_stable_events = g.stable_events, trend_computed_at = now()
    FROM g WHERE t.performer_id = g.performer_id;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$func$;

REVOKE ALL ON FUNCTION public.refresh_performer_trending() FROM PUBLIC;

-- ============================================================
-- Read RPC — top trending performers (gated), liquidity-floored
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_trending_performers(
  p_limit integer DEFAULT 25,
  p_min_market bigint DEFAULT 1000,
  p_min_events integer DEFAULT 3
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text; v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.trend_px_30d DESC NULLS LAST), '[]'::jsonb)
  INTO v_result
  FROM (
    SELECT * FROM public.performer_stat_card
    WHERE trend_px_30d IS NOT NULL
      AND coalesce(market_tickets,0) >= greatest(0, coalesce(p_min_market,1000))
      AND coalesce(trend_stable_events,0) >= greatest(1, coalesce(p_min_events,3))
    ORDER BY trend_px_30d DESC
    LIMIT greatest(1, least(coalesce(p_limit,25), 100))
  ) s;
  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_trending_performers(integer, bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_trending_performers(integer, bigint, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_trending_performers(integer, bigint, integer) IS
  'D0 top trending performers by same-event-set 30d price momentum (trend_px_30d), liquidity-gated. @s4kent.com-gated SECDEF read.';

-- ============================================================
-- Repoint the gallery 'movers' sort to the trustworthy trend
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_performer_stat_card_gallery(
  p_search text    DEFAULT NULL,
  p_sort   text    DEFAULT 'notional',
  p_limit  integer DEFAULT 60,
  p_sports_only boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_result jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  WITH base AS (
    SELECT s.*,
      CASE p_sort
        WHEN 'market'  THEN s.market_tickets::numeric
        WHEN 'owned'   THEN s.owned_tickets::numeric
        WHEN 'getin'   THEN -coalesce(s.getin_median, 1e12)
        WHEN 'movers'  THEN coalesce(s.trend_px_30d, s.price_d30_pct, -1e9)   -- trustworthy trend first
        ELSE coalesce(s.owned_book_notional, 0)
      END AS sortval
    FROM public.performer_stat_card s
    WHERE (p_search IS NULL OR s.performer_name ILIKE '%'||p_search||'%')
      AND (NOT p_sports_only OR s.is_sports)
  ),
  top AS (
    SELECT * FROM base ORDER BY sortval DESC NULLS LAST LIMIT greatest(1, least(coalesce(p_limit,60), 200))
  )
  SELECT coalesce(jsonb_agg((to_jsonb(top) - 'sortval') ORDER BY top.sortval DESC NULLS LAST), '[]'::jsonb)
  INTO v_result FROM top;

  RETURN v_result;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_performer_stat_card_gallery(text, text, integer, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_performer_stat_card_gallery(text, text, integer, boolean) TO anon, authenticated;

-- ============================================================
-- Backfill + daily cron (trending is not latency-sensitive; :50)
-- ============================================================
SELECT public.refresh_performer_trending();

DO $cron$
BEGIN
  PERFORM cron.unschedule('performer-trending-refresh');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$cron$;

SELECT cron.schedule('performer-trending-refresh', '50 6 * * *', $cron$
  SELECT public.refresh_performer_trending();
$cron$);
