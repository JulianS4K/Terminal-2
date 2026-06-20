-- 20260620120000_get_event_market_context_public.sql
--
-- New consumer-facing read RPC: get_event_market_context_public(p_event_id, p_history_days)
-- — powers the storefront event-page "Deal & demand" panel (D1 feature #1).
--
-- WHY: today the storefront shows our price in a vacuum. The DB already holds a deep
-- cross-source market picture (SeatGeek 16M listings / 12M sales, StubHub/Vivid/TickPick
-- via TicketsData, 423K daily price snapshots). This RPC projects the CONSUMER-SAFE slice
-- of that intelligence for a single event so the buyer can see: how our price compares to
-- the public secondary market ("$138 below the SeatGeek median"), a 30-day price trend, and
-- an honest demand read.
--
-- WALL COMPLIANCE (PROJECT_BIBLE §2.6 — D1 may never read broker_*/wholesale/owned fields):
-- this RPC reads broker-only views/tables (v_event_price_arbitrage, v_event_velocity_windows,
-- event_listing_snapshot_daily) but PROJECTS ONLY consumer-safe columns:
--   * our public listed price (tevo_retail_min/median + evo_retail_getin) — already shown on the store
--   * PUBLIC secondary-market prices (SeatGeek sg_all_*, realized sales; StubHub/Vivid/TickPick medians)
--   * price-movement % (get-in delta) and a derived demand label
-- It NEVER returns any *_owned_* field, any wholesale_* field, brokerage/office ids, or our raw
-- ticket counts (tevo_tix_now / evo_owned_tickets — leaking how much WE hold is the same class of
-- breach as is_owned, war-games W-3). SECURITY DEFINER + revoked from anon/authenticated so the
-- broker views are never reachable directly; the storefront backend (service_role) calls it and
-- serves the projection.
--
-- Lane: authored by D1 (storefront FE owner of the consuming panel); prod apply is operator-gated
-- and lands via A1 (CLAUDE.md §1 / PROJECT_BIBLE §2.3). D-tier has zero DB-apply authority.

CREATE OR REPLACE FUNCTION public.get_event_market_context_public(
  p_event_id      bigint,
  p_history_days  int DEFAULT 30      -- price-history window (panel sparkline uses 30)
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH arb AS (
    SELECT a.tevo_retail_min, a.tevo_retail_median,
           a.sg_all_median, a.sg_all_min,
           a.sg_sale_median_realized, a.sg_listings_count, a.sg_sales_count,
           a.sg_metrics_at
    FROM public.v_event_price_arbitrage a
    WHERE a.tevo_event_id = p_event_id
    LIMIT 1
  ),
  vel AS (
    SELECT v.tevo_getin_d24h_pct, v.sg_median_now
    FROM public.v_event_velocity_windows v
    WHERE v.tevo_event_id = p_event_id
    LIMIT 1
  ),
  hist AS (
    SELECT snapshot_date, evo_retail_getin, sg_all_median
    FROM (
      SELECT DISTINCT ON (snapshot_date)
             snapshot_date, evo_retail_getin, sg_all_median, captured_at
      FROM public.event_listing_snapshot_daily
      WHERE event_id = p_event_id
        AND snapshot_date >= current_date - GREATEST(p_history_days, 1)
      ORDER BY snapshot_date, captured_at DESC
    ) d
    ORDER BY snapshot_date
  ),
  -- Latest cross-source medians (one most-recent daily row), consumer-safe medians only.
  xsrc AS (
    SELECT sg_all_median, td_sh_median, td_vd_median, td_tp_median, td_tm_resale_median, amalgam_median
    FROM public.event_listing_snapshot_daily
    WHERE event_id = p_event_id
    ORDER BY snapshot_date DESC, captured_at DESC
    LIMIT 1
  )
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'event_id', p_event_id,
    'our_from_price', (SELECT tevo_retail_min FROM arb),
    'market', (
      SELECT jsonb_strip_nulls(jsonb_build_object(
        'median',              a.sg_all_median,
        'min',                 a.sg_all_min,
        'recent_sale_median',  a.sg_sale_median_realized,
        'listings',            a.sg_listings_count,
        'sales',               a.sg_sales_count,
        'as_of',               a.sg_metrics_at,
        'by_source', (
          SELECT jsonb_agg(s) FROM (
            SELECT jsonb_build_object('label','SeatGeek','median',x.sg_all_median) s FROM xsrc x WHERE x.sg_all_median IS NOT NULL
            UNION ALL SELECT jsonb_build_object('label','StubHub','median',x.td_sh_median) FROM xsrc x WHERE x.td_sh_median IS NOT NULL
            UNION ALL SELECT jsonb_build_object('label','Vivid Seats','median',x.td_vd_median) FROM xsrc x WHERE x.td_vd_median IS NOT NULL
            UNION ALL SELECT jsonb_build_object('label','TickPick','median',x.td_tp_median) FROM xsrc x WHERE x.td_tp_median IS NOT NULL
          ) src
        )
      ))
      FROM arb a
    ),
    'below_market', (
      SELECT CASE WHEN a.sg_all_median IS NOT NULL AND a.tevo_retail_min IS NOT NULL
                   AND a.sg_all_median > a.tevo_retail_min
        THEN jsonb_build_object(
          'amount', round(a.sg_all_median - a.tevo_retail_min)::int,
          'pct',    round(100*(a.sg_all_median - a.tevo_retail_min)/a.sg_all_median)::int,
          'vs',     'SeatGeek median')
        ELSE NULL END
      FROM arb a
    ),
    'demand', (
      SELECT jsonb_build_object(
        'getin_change_24h_pct', v.tevo_getin_d24h_pct,
        'label', CASE WHEN v.tevo_getin_d24h_pct >=  5 THEN 'rising'
                      WHEN v.tevo_getin_d24h_pct <= -5 THEN 'cooling'
                      WHEN v.tevo_getin_d24h_pct IS NULL THEN NULL
                      ELSE 'firm' END)
      FROM vel v
    ),
    'history', (
      SELECT jsonb_agg(jsonb_build_object('d', snapshot_date, 'ours', evo_retail_getin, 'market', sg_all_median))
      FROM hist
    ),
    'generated_at', now()
  ));
$function$;

-- Consumer data flows through the storefront backend (service_role) only — never a
-- direct anon/authenticated client read of the broker views behind this projection.
REVOKE ALL ON FUNCTION public.get_event_market_context_public(bigint, int) FROM anon, authenticated, public;
GRANT EXECUTE ON FUNCTION public.get_event_market_context_public(bigint, int) TO service_role;

COMMENT ON FUNCTION public.get_event_market_context_public IS
  'Storefront "Deal & demand" panel: consumer-safe cross-source market context for one event '
  '(our price vs SeatGeek/StubHub/Vivid/TickPick medians + realized sales, 30-day price history, '
  'demand label). Projects ONLY public market + our-listed prices — never owned/wholesale/broker '
  'fields or our raw ticket counts (PROJECT_BIBLE §2.6 wall). SECURITY DEFINER, service_role-only.';
