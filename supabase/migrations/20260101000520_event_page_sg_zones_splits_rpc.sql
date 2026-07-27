-- Migration 20260519010000 · lane:D0 (author) → A1 (apply) · writes:get_event_sg_zones_splits · reads:seatgeek_listings_snapshots,seatgeek_event_xref · pre:20260519000000 · auth:operator-approved 2026-05-19
--
-- D0 — SG-side zones (per-section rollup) + splits (per-quantity bucket)
-- so the event Overview tab Zones + Splits panels can render TEvo vs SG
-- side-by-side.
--
-- Source: seatgeek_listings_snapshots 24h window, deduped on sglid
-- (PROJECT_BIBLE §3 — content-hash table requires DISTINCT ON).
-- Scoped on sg_event_id (idx_sg_listings_sg_event_id_time).
-- Bridge via seatgeek_event_xref.
--
-- Per-zone: min/median/max broadcast_price + listings count + tickets count.
-- Per-split: bucket on quantity (1, 2, 3, 4+) — groups + tickets + avg price.

CREATE OR REPLACE FUNCTION public.get_event_sg_zones_splits(p_event_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sg_event_id bigint;
  v_zones       jsonb;
  v_splits      jsonb;
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref
  WHERE tevo_event_id = p_event_id
  LIMIT 1;

  IF v_sg_event_id IS NULL THEN
    RETURN jsonb_build_object('hidden', true, 'reason', 'no_sg_bridge', 'sg_event_id', null,
                              'zones', '[]'::jsonb, 'splits', '{}'::jsonb);
  END IF;

  -- Dedupe 24h SG listings on sglid first (mandatory). Use broadcast_price
  -- as primary signal; retail_price_all_in as fallback when null.
  WITH deduped AS (
    SELECT DISTINCT ON (sglid)
      sglid, section, quantity,
      coalesce(broadcast_price, retail_price_all_in) AS price,
      is_broker_owned
    FROM public.seatgeek_listings_snapshots
    WHERE sg_event_id = v_sg_event_id
      AND captured_at > now() - interval '24 hours'
      AND section IS NOT NULL
    ORDER BY sglid, captured_at DESC
  )
  SELECT
    coalesce(jsonb_agg(jsonb_build_object(
      'section',  section,
      'listings', listings,
      'tickets',  tickets,
      'min',      min_p,
      'median',   median_p,
      'max',      max_p,
      'owned_listings', owned_listings
    ) ORDER BY median_p DESC NULLS LAST), '[]'::jsonb)
  INTO v_zones
  FROM (
    SELECT
      section,
      COUNT(*)                                AS listings,
      COALESCE(SUM(quantity), 0)::int         AS tickets,
      MIN(price)                              AS min_p,
      percentile_cont(0.5) WITHIN GROUP (ORDER BY price) AS median_p,
      MAX(price)                              AS max_p,
      COUNT(*) FILTER (WHERE is_broker_owned) AS owned_listings
    FROM deduped
    WHERE price IS NOT NULL
    GROUP BY section
  ) z;

  -- Splits — bucket on quantity. Same deduped source.
  WITH deduped AS (
    SELECT DISTINCT ON (sglid)
      sglid, quantity,
      coalesce(broadcast_price, retail_price_all_in) AS price
    FROM public.seatgeek_listings_snapshots
    WHERE sg_event_id = v_sg_event_id
      AND captured_at > now() - interval '24 hours'
    ORDER BY sglid, captured_at DESC
  ),
  bucketed AS (
    SELECT
      CASE
        WHEN quantity = 1 THEN 'singles'
        WHEN quantity = 2 THEN 'pairs'
        WHEN quantity = 3 THEN 'triples'
        WHEN quantity = 4 THEN 'quads'
        WHEN quantity >= 5 THEN 'five_plus'
        ELSE NULL
      END AS bucket,
      quantity, price
    FROM deduped
    WHERE quantity IS NOT NULL
  )
  SELECT
    jsonb_object_agg(bucket, jsonb_build_object(
      'groups',    groups,
      'tickets',   tickets,
      'avg_price', avg_price
    ))
  INTO v_splits
  FROM (
    SELECT
      bucket,
      COUNT(*)                  AS groups,
      COALESCE(SUM(quantity),0) AS tickets,
      AVG(price)                AS avg_price
    FROM bucketed
    WHERE bucket IS NOT NULL
    GROUP BY bucket
  ) b;

  RETURN jsonb_build_object(
    'sg_event_id', v_sg_event_id,
    'zones',       v_zones,
    'splits',      coalesce(v_splits, '{}'::jsonb),
    'hidden',      false
  );
END $func$;

REVOKE ALL ON FUNCTION public.get_event_sg_zones_splits(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_event_sg_zones_splits(integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_event_sg_zones_splits(integer) IS
  'D0 event Overview — SG zones (per-section rollup) + splits (per-quantity bucket) over 24h deduped firehose. DISTINCT ON sglid. Bridge via seatgeek_event_xref. Email-gated.';
