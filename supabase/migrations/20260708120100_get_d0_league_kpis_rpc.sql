-- ============================================================================
-- Migration 20260708120100 — get_d0_league_kpis(): league sales KPIs read RPC
--
-- Lane:     A1 data plane (SECDEF read RPC; consumed by the D0 Leagues hub)
-- Touches:  get_d0_league_kpis (W/function)
-- Reads:    d0_league_summary, d0_league_price_weighted (existing views over d0_sales_fact)
-- Pre:      none
--
-- We already CAPTURE league-level realized-sales KPIs in d0_league_summary
-- (total_revenue / tickets_sold / median / avg / sale_lines) and a volume-
-- weighted median in d0_league_price_weighted — but both are internal
-- security_invoker views with no client read path. This wraps them in the
-- canonical @s4kent.com-gated SECDEF RPC so the Leagues hub can surface them.
-- Read-only; no new capture. One row per league (~6 rows) — the hub calls it
-- once and picks the active league's row.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.get_d0_league_kpis()
RETURNS TABLE (
  league                text,
  total_revenue         numeric,
  tickets_sold          bigint,
  median_price          numeric,
  avg_price             numeric,
  sale_lines            bigint,
  weighted_median_price numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT s.league,
         s.total_revenue,
         s.tickets_sold::bigint,
         s.median_price,
         s.avg_price,
         s.sale_lines::bigint,
         w.weighted_median_price
  FROM public.d0_league_summary s
  LEFT JOIN public.d0_league_price_weighted w USING (league);
END;
$func$;

REVOKE ALL ON FUNCTION public.get_d0_league_kpis() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_d0_league_kpis() TO anon, authenticated;

COMMENT ON FUNCTION public.get_d0_league_kpis() IS
  'D0 Leagues hub — per-league realized-sales KPIs (revenue / tickets sold / median / avg / weighted median / sale lines) from d0_league_summary + d0_league_price_weighted (over d0_sales_fact). Email-gated read-only.';
