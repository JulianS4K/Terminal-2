-- 20260527140000_ticketsdata_unified_listings_cross_source.sql
--
-- Surface TicketsData listings in unified_listings view and terminal.
-- Depends on: 20260527130000 (ticketsdata_listings_snapshots populated by crons).
--
-- CHANGES:
--   1. unified_listings — add TD arm (SH/VD/GT from ticketsdata_listings_snapshots)
--   2. get_event_cross_source_metrics — add TD aggregate stats + per-platform breakdown
--
-- TD source_key values added: 'td_sh' | 'td_vd' | 'td_gt'
-- TD stats window: last 24 hours of snapshots (non-parking listings only).
-- JOIN path: ticketsdata_listings_snapshots
--            → ticketsdata_event_xref (event_id, platform)
--            → aq_event_map (aq_short_event_id → sg_event_id)


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. unified_listings — add TD arm
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.unified_listings AS

 -- TEvo
 SELECT 'tevo'::text AS source_key,
    ls.event_id AS tevo_event_id,
    NULL::bigint AS sg_event_id,
    NULL::bigint AS sd_event_id,
    ls.tevo_ticket_group_id::text AS source_listing_id,
    ls.section,
    ls."row",
    ls.quantity,
    ls.retail_price,
    ls.wholesale_price,
    to_jsonb(ls.splits) AS splits_jsonb,
    ls.eticket AS is_eticket,
    ls.wheelchair AS is_wheelchair,
    ls.instant_delivery AS is_instant,
    ls.is_ancillary,
    ls.type AS listing_type,
    ls.brokerage_name,
    ls.is_owned,
    NULL::text AS sg_market_tier,
    NULL::boolean AS sg_is_b2b,
    ls.captured_at,
    ls.aq_short_event_id,
    ls.venue_short_id,
    ls.performer_short_id
   FROM listings_snapshots ls

UNION ALL

 -- SG broker
 SELECT 'sg_broker'::text AS source_key,
    sls.tevo_event_id,
    sls.sg_event_id,
    NULL::bigint AS sd_event_id,
    sls.display_id AS source_listing_id,
    sls.section,
    sls."row",
    sls.quantity,
    sls.retail_price_all_in AS retail_price,
    sls.broadcast_price AS wholesale_price,
    sls.splits AS splits_jsonb,
    NULL::boolean AS is_eticket,
    sls.is_wheelchair_acc AS is_wheelchair,
    sls.is_instant_download AS is_instant,
    NULL::boolean AS is_ancillary,
    NULL::text AS listing_type,
    NULL::text AS brokerage_name,
    sls.is_broker_owned AS is_owned,
    sls.market_source AS sg_market_tier,
    sls.is_b2b AS sg_is_b2b,
    sls.captured_at,
    sls.aq_short_event_id,
    sls.venue_short_id,
    sls.performer_short_id
   FROM seatgeek_listings_snapshots sls

UNION ALL

 -- SG seller (our own inventory on SG)
 SELECT 'sg_seller'::text AS source_key,
    ssl.tevo_event_id,
    ssl.sg_event_id,
    NULL::bigint AS sd_event_id,
    ssl.seller_listing_id AS source_listing_id,
    ssl.section,
    ssl."row",
    ssl.quantity,
    ssl.cost AS retail_price,
    NULL::numeric AS wholesale_price,
    to_jsonb(ARRAY[ssl.quantity]) AS splits_jsonb,
    NULL::boolean AS is_eticket,
    NULL::boolean AS is_wheelchair,
    ssl.is_instant,
    NULL::boolean AS is_ancillary,
    NULL::text AS listing_type,
    NULL::text AS brokerage_name,
    true AS is_owned,
    'exchange'::text AS sg_market_tier,
    false AS sg_is_b2b,
    ssl.pulled_at AS captured_at,
    ssl.aq_short_event_id,
    ssl.venue_short_id,
    ssl.performer_short_id
   FROM seatgeek_seller_listings ssl

UNION ALL

 -- SeatData
 SELECT 'seatdata'::text AS source_key,
    sdl.tevo_event_id,
    NULL::bigint AS sg_event_id,
    sdl.sd_event_id,
    sdl.content_hash AS source_listing_id,
    sdl.section,
    sdl."row",
    sdl.quantity,
    sdl.price AS retail_price,
    NULL::numeric AS wholesale_price,
    to_jsonb(ARRAY[sdl.quantity]) AS splits_jsonb,
    NULL::boolean AS is_eticket,
    NULL::boolean AS is_wheelchair,
    NULL::boolean AS is_instant,
    NULL::boolean AS is_ancillary,
    NULL::text AS listing_type,
    NULL::text AS brokerage_name,
    NULL::boolean AS is_owned,
    NULL::text AS sg_market_tier,
    NULL::boolean AS sg_is_b2b,
    sdl.pulled_at AS captured_at,
    NULL::text AS aq_short_event_id,
    NULL::text AS venue_short_id,
    NULL::text AS performer_short_id
   FROM seatdata_listings_snapshots sdl

UNION ALL

 -- TicketsData (SH + VD + GT) — market listings snapshot
 -- source_key: 'td_sh' | 'td_vd' | 'td_gt'
 -- Parking listings included (is_ancillary=true) so consumers can filter.
 -- sg_event_id joined via xref.aq_short_event_id → aq_event_map.sg_event_id.
 SELECT
    'td_' || lower(tls.platform)  AS source_key,
    NULL::bigint                  AS tevo_event_id,
    aem.sg_event_id               AS sg_event_id,
    NULL::bigint                  AS sd_event_id,
    tls.td_listing_id             AS source_listing_id,
    tls.section,
    tls."row",
    tls.quantity,
    tls.list_price                AS retail_price,
    NULL::numeric                 AS wholesale_price,
    NULL::jsonb                   AS splits_jsonb,
    NULL::boolean                 AS is_eticket,
    NULL::boolean                 AS is_wheelchair,
    NULL::boolean                 AS is_instant,
    tls.is_parking                AS is_ancillary,
    'market'::text                AS listing_type,
    NULL::text                    AS brokerage_name,
    false                         AS is_owned,
    NULL::text                    AS sg_market_tier,
    NULL::boolean                 AS sg_is_b2b,
    tls.captured_at,
    xref.aq_short_event_id,
    aem.venue_short_id,
    aem.performer_short_id
   FROM public.ticketsdata_listings_snapshots tls
   JOIN public.ticketsdata_event_xref xref
     ON (xref.event_id, xref.platform) = (tls.event_id, tls.platform)
   LEFT JOIN public.aq_event_map aem
     ON aem.aq_short_event_id = xref.aq_short_event_id
   WHERE tls.platform IN ('SH', 'VD', 'GT');

COMMENT ON VIEW public.unified_listings IS
  'All listing sources in a single queryable surface. '
  'source_key values: tevo, sg_broker, sg_seller, seatdata, td_sh, td_vd, td_gt. '
  'TD arm added 2026-05-27 (20260527140000). Filter is_ancillary=false to exclude parking.';


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. get_event_cross_source_metrics — add TD aggregate stats
--    Adds to response:
--      td        — per-platform breakdown: {SH:{...}, VD:{...}, GT:{...}}
--      td_agg    — aggregate across all TD platforms (used in rows array)
--    Adds td value to each row in rows array.
--    FE renders td as a 4th column ("TD Market") next to SG.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_event_cross_source_metrics(p_event_id integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_sg_event_id bigint;
  v_aq_short    text;
  v_tevo        jsonb;
  v_sg          jsonb;
  v_td          jsonb;   -- per-platform TD breakdown
  v_td_agg      jsonb;   -- aggregate TD stats (all platforms, non-parking, last 24h)
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  -- Bridge: TEvo event_id → SG event_id → aq_short_event_id
  SELECT sg_event_id INTO v_sg_event_id
  FROM public.seatgeek_event_xref WHERE tevo_event_id = p_event_id LIMIT 1;

  IF v_sg_event_id IS NOT NULL THEN
    SELECT aq_short_event_id INTO v_aq_short
    FROM public.aq_event_map
    WHERE sg_event_id = v_sg_event_id
    LIMIT 1;
  END IF;

  -- TEvo side: latest event_metrics snapshot
  SELECT to_jsonb(t) INTO v_tevo
  FROM (
    SELECT DISTINCT ON (event_id)
      event_id, tickets_count, groups_count,
      retail_median, retail_p90, getin_price,
      owned_median_retail, nonowned_median_retail,
      captured_at
    FROM public.event_metrics
    WHERE event_id = p_event_id
    ORDER BY event_id, captured_at DESC
  ) t;

  -- SG side: latest seatgeek_event_metrics snapshot
  IF v_sg_event_id IS NOT NULL THEN
    SELECT to_jsonb(s) INTO v_sg
    FROM (
      SELECT DISTINCT ON (sg_event_id)
        sg_event_id,
        listings_all_count, listings_all_tickets,
        listings_all_median, listings_all_p90, listings_all_min,
        listings_owned_median,
        sold_price_median,
        captured_at
      FROM public.seatgeek_event_metrics
      WHERE sg_event_id = v_sg_event_id
      ORDER BY sg_event_id, captured_at DESC
    ) s;
  END IF;

  -- TD side: snapshot data from last 24h (non-parking only)
  IF v_aq_short IS NOT NULL THEN

    -- Aggregate across all TD platforms
    SELECT to_jsonb(t) INTO v_td_agg
    FROM (
      SELECT
        COUNT(*)                                                            AS listing_count,
        SUM(tls.quantity)                                                   AS tickets_count,
        MIN(tls.list_price)                                                 AS min_price,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tls.list_price)        AS median_price,
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY tls.list_price)        AS p90_price,
        MAX(tls.captured_at)                                                AS last_captured
      FROM public.ticketsdata_event_xref x
      JOIN public.ticketsdata_listings_snapshots tls
        ON (tls.event_id, tls.platform) = (x.event_id, x.platform)
      WHERE x.aq_short_event_id = v_aq_short
        AND NOT tls.is_parking
        AND tls.captured_at > now() - interval '24 hours'
    ) t;

    -- Per-platform breakdown (for the td key in the response)
    SELECT jsonb_object_agg(t.platform, to_jsonb(t)) INTO v_td
    FROM (
      SELECT
        x.platform,
        COUNT(*)                                                            AS listing_count,
        SUM(tls.quantity)                                                   AS tickets_count,
        MIN(tls.list_price)                                                 AS min_price,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY tls.list_price)        AS median_price,
        MAX(tls.captured_at)                                                AS last_captured
      FROM public.ticketsdata_event_xref x
      JOIN public.ticketsdata_listings_snapshots tls
        ON (tls.event_id, tls.platform) = (x.event_id, x.platform)
      WHERE x.aq_short_event_id = v_aq_short
        AND NOT tls.is_parking
        AND tls.captured_at > now() - interval '24 hours'
      GROUP BY x.platform
    ) t;

  END IF;

  RETURN jsonb_build_object(
    'event_id',    p_event_id,
    'sg_event_id', v_sg_event_id,
    'tevo',        v_tevo,
    'sg',          v_sg,
    'td',          v_td,       -- per-platform breakdown
    'td_agg',      v_td_agg,   -- aggregate (used in rows)
    -- Pre-aligned rows with td column. td = aggregate value across all TD platforms.
    'rows', jsonb_build_array(
      jsonb_build_object('label', 'Listings count',
        'tevo', v_tevo->'groups_count',
        'sg',   v_sg->'listings_all_count',
        'td',   v_td_agg->'listing_count',
        'is_money', false),
      jsonb_build_object('label', 'Tickets available',
        'tevo', v_tevo->'tickets_count',
        'sg',   v_sg->'listings_all_tickets',
        'td',   v_td_agg->'tickets_count',
        'is_money', false),
      jsonb_build_object('label', 'Min price',
        'tevo', v_tevo->'getin_price',
        'sg',   v_sg->'listings_all_min',
        'td',   v_td_agg->'min_price',
        'is_money', true),
      jsonb_build_object('label', 'Median price',
        'tevo', v_tevo->'retail_median',
        'sg',   v_sg->'listings_all_median',
        'td',   v_td_agg->'median_price',
        'is_money', true),
      jsonb_build_object('label', 'P90 price',
        'tevo', v_tevo->'retail_p90',
        'sg',   v_sg->'listings_all_p90',
        'td',   v_td_agg->'p90_price',
        'is_money', true),
      jsonb_build_object('label', 'Owned median',
        'tevo', v_tevo->'owned_median_retail',
        'sg',   v_sg->'listings_owned_median',
        'td',   NULL,
        'is_money', true),
      jsonb_build_object('label', 'Non-owned median',
        'tevo', v_tevo->'nonowned_median_retail',
        'sg',   NULL,
        'td',   NULL,
        'is_money', true),
      jsonb_build_object('label', 'Realized sale median',
        'tevo', NULL,
        'sg',   v_sg->'sold_price_median',
        'td',   NULL,
        'is_money', true)
    )
  );
END $func$;

COMMENT ON FUNCTION public.get_event_cross_source_metrics(integer) IS
  'Cross-source metrics: TEvo event_metrics + SG seatgeek_event_metrics + TD ticketsdata_listings_snapshots. '
  'TD stats: last 24h non-parking snapshots. Returns td (per-platform), td_agg (aggregate), and td column in rows[]. '
  'Updated 2026-05-27 (20260527140000).';
