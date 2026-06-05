-- Migration 20260603120000 · lane:D0 (author) → A1 (apply) · writes:get_event_all_source_listing_metrics · reads:listings_snapshots,seatgeek_listings_snapshots,ticketsdata_listings_snapshots,seatgeek_event_xref,aq_event_map,ticketsdata_event_xref · pre:20260527140000 · auth:operator-approved 2026-06-03
--
-- D0 — uniform per-source listing distribution for the event Overview
-- CROSS-SOURCE panel. The prior panel (get_event_cross_source_metrics)
-- reads PRECOMPUTED metric tables (event_metrics / seatgeek_event_metrics),
-- which only TEvo + SG populate — so SH/GT/VD/TP/TM showed blank Min/P90/Tickets.
--
-- This RPC computes the SAME distribution for EVERY source on the fly from the
-- raw firehoses, so the table is fully populated with one consistent methodology:
--   listings · tickets (Σqty) · min · median · p90 · owned_median
--
-- Window: the latest collection batch per source (rows within 30 min of that
-- source's max(captured_at) for the event) — i.e. the current book, deduped to
-- one poll cycle (never count(*) across the whole firehose: PROJECT_BIBLE §3).
-- Non-parking listings, price > 0. Prices are all-in where the source has it
-- (SG retail_price_all_in, TD price_with_fees); TEvo uses retail_price.
--
-- Bridge resolution (all from the tevo event id, server-side):
--   SG  → seatgeek_event_xref.sg_event_id
--   TD  → aq_event_map.aq_short_event_id → ticketsdata_event_xref(platform,event_id)
--
-- Return shape (FE renders a metric-rows × source-cols table; all 7 sources
-- always present in fixed order, null cells where a source has no book):
--   { event_id, sources:[ {key,label,listings,tickets,min,median,p90,owned_median}, … ] }

CREATE OR REPLACE FUNCTION public.get_event_all_source_listing_metrics(p_event_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sg_event_id bigint;
  v_result      jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  WITH
  tevo_mx AS (SELECT max(captured_at) mx FROM public.listings_snapshots WHERE event_id = p_event_id),
  tevo AS (
    SELECT retail_price::numeric AS p, quantity AS q, is_owned AS owned
    FROM public.listings_snapshots, tevo_mx
    WHERE event_id = p_event_id AND tevo_mx.mx IS NOT NULL
      AND captured_at >= tevo_mx.mx - interval '30 min'
      AND section !~* 'parking|garage|lot' AND retail_price > 0
  ),
  sg_mx AS (SELECT max(captured_at) mx FROM public.seatgeek_listings_snapshots WHERE sg_event_id = v_sg_event_id),
  sg AS (
    SELECT retail_price_all_in::numeric AS p, quantity AS q, is_broker_owned AS owned
    FROM public.seatgeek_listings_snapshots, sg_mx
    WHERE sg_event_id = v_sg_event_id AND sg_mx.mx IS NOT NULL
      AND captured_at >= sg_mx.mx - interval '30 min'
      AND section !~* 'parking|garage|lot' AND retail_price_all_in > 0
  ),
  td AS (
    SELECT lower(x.platform) AS plat, s.price_with_fees::numeric AS p, s.quantity AS q
    FROM public.aq_event_map a
    JOIN public.ticketsdata_event_xref x ON x.aq_short_event_id = a.aq_short_event_id
    JOIN LATERAL (
      SELECT max(captured_at) mx FROM public.ticketsdata_listings_snapshots
      WHERE platform = x.platform AND event_id = x.event_id
    ) m ON true
    JOIN public.ticketsdata_listings_snapshots s
      ON s.platform = x.platform AND s.event_id = x.event_id
     AND s.captured_at >= m.mx - interval '30 min'
    WHERE a.tevo_event_id = p_event_id
      AND s.section !~* 'parking|garage|lot' AND s.price_with_fees > 0
  ),
  allrows AS (
    SELECT 'tevo' AS src, p, q, owned FROM tevo
    UNION ALL SELECT 'sg', p, q, owned FROM sg
    UNION ALL SELECT plat, p, q, NULL::boolean FROM td
  ),
  agg AS (
    SELECT src,
      count(*)::int                                                    AS listings,
      sum(q)::bigint                                                   AS tickets,
      min(p)                                                           AS mn,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY p)                   AS med,
      percentile_cont(0.9) WITHIN GROUP (ORDER BY p)                   AS p90,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY (CASE WHEN owned THEN p END)) AS owned_med
    FROM allrows GROUP BY src
  )
  SELECT jsonb_build_object(
    'event_id',    p_event_id,
    'sg_event_id', v_sg_event_id,
    'sources',
      jsonb_agg(
        jsonb_build_object(
          'key',          o.k,
          'label',        o.lbl,
          'listings',     a.listings,
          'tickets',      a.tickets,
          'min',          round(a.mn),
          'median',       round(a.med),
          'p90',          round(a.p90),
          'owned_median', round(a.owned_med)
        ) ORDER BY o.ord)
  )
  INTO v_result
  FROM (VALUES
    ('tevo','TEvo',1),('sg','SG',2),('sh','SH',3),('gt','GT',4),
    ('vd','VD',5),('tp','TP',6),('tm','TM',7)
  ) o(k, lbl, ord)
  LEFT JOIN agg a ON a.src = o.k;

  RETURN coalesce(v_result, jsonb_build_object('event_id', p_event_id, 'sources', '[]'::jsonb));
END
$func$;

REVOKE ALL ON FUNCTION public.get_event_all_source_listing_metrics(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_all_source_listing_metrics(integer) TO anon, authenticated;
