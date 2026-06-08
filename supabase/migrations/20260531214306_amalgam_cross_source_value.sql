-- ============================================================
-- Cross-source AMALGAM value on the daily rollup (operator request 2026-05-31, A1).
--
-- event_listing_snapshot_daily already stores every source side-by-side
-- (evo_retail_getin, sg_all_getin, td_{sh,gt,vd,tp,tm}_getin + medians + counts) but the
-- only cross-source COMBINE was td_combined_median = LEAST(...) — TD-only. There was no
-- single all-source blended value. This adds three GENERATED ALWAYS STORED columns that
-- blend EVERY source present for an event and AUTOMATICALLY fall back to whatever sources
-- are available (most rows are EVO-only: of ~15.9k rows only ~1.4k have SG, ~92 have TD):
--   • amalgam_getin        — cross-source market FLOOR  = LEAST(NULLIF(per-source getin,0))
--   • amalgam_source_count — how many of the 7 sources backed it (availability transparency)
--   • amalgam_median       — count-WEIGHTED mean of per-source medians (deep markets dominate;
--                            this is the inventory-weighted *typical* listing price, which for
--                            wide-distribution premium events is legitimately ≫ the get-in floor
--                            — e.g. Knicks Finals G3: getin $2,853.80 vs amalgam_median ~$8,243).
--
-- Generated columns are pure scalar exprs over same-row base columns → the working 3×/day
-- compute_event_listing_snapshot() is UNTOUCHED (they're not in its INSERT/UPDATE list and
-- recompute automatically on every upsert), and the ALTER auto-backfills all historical rows.
-- Reuses the exact LEAST/NULLIF idiom already in td_combined_median.
--
-- Plus get_event_amalgam(event_id): the same blend computed LIVE from the latest per-source
-- state (for an event-page tile between the 3 daily snapshots), and the amalgam surfaced on
-- v_event_listing_trends with DoD/WoW deltas. Indefinite retention (inherits the rollup).
-- Applied: <pending operator approval>.
-- ============================================================

-- ── 1. Generated amalgam columns (single ALTER = one rewrite; table is ~4 MB) ──
ALTER TABLE public.event_listing_snapshot_daily
  ADD COLUMN IF NOT EXISTS amalgam_getin numeric(12,2) GENERATED ALWAYS AS (
    LEAST(NULLIF(evo_retail_getin,0), NULLIF(sg_all_getin,0),
          NULLIF(td_sh_getin,0), NULLIF(td_gt_getin,0), NULLIF(td_vd_getin,0),
          NULLIF(td_tp_getin,0), NULLIF(td_tm_getin,0))
  ) STORED,
  ADD COLUMN IF NOT EXISTS amalgam_source_count smallint GENERATED ALWAYS AS (
      (NULLIF(evo_retail_getin,0) IS NOT NULL)::int + (NULLIF(sg_all_getin,0) IS NOT NULL)::int
    + (NULLIF(td_sh_getin,0) IS NOT NULL)::int + (NULLIF(td_gt_getin,0) IS NOT NULL)::int
    + (NULLIF(td_vd_getin,0) IS NOT NULL)::int + (NULLIF(td_tp_getin,0) IS NOT NULL)::int
    + (NULLIF(td_tm_getin,0) IS NOT NULL)::int
  ) STORED,
  ADD COLUMN IF NOT EXISTS amalgam_median numeric(12,2) GENERATED ALWAYS AS (
    ROUND(
      ( COALESCE(evo_retail_median * evo_tickets_count, 0)
      + COALESCE(sg_all_median     * sg_all_listings,   0)
      + COALESCE(td_sh_median      * td_sh_listings,    0)
      + COALESCE(td_gt_median      * td_gt_listings,    0)
      + COALESCE(td_vd_median      * td_vd_listings,    0)
      + COALESCE(td_tp_median      * td_tp_listings,    0)
      + COALESCE(td_tm_median      * td_tm_listings,    0) )
      / NULLIF(
          COALESCE(CASE WHEN evo_retail_median IS NOT NULL THEN evo_tickets_count END, 0)
        + COALESCE(CASE WHEN sg_all_median     IS NOT NULL THEN sg_all_listings   END, 0)
        + COALESCE(CASE WHEN td_sh_median      IS NOT NULL THEN td_sh_listings    END, 0)
        + COALESCE(CASE WHEN td_gt_median      IS NOT NULL THEN td_gt_listings    END, 0)
        + COALESCE(CASE WHEN td_vd_median      IS NOT NULL THEN td_vd_listings    END, 0)
        + COALESCE(CASE WHEN td_tp_median      IS NOT NULL THEN td_tp_listings    END, 0)
        + COALESCE(CASE WHEN td_tm_median      IS NOT NULL THEN td_tm_listings    END, 0)
      , 0)
    , 2)
  ) STORED;

COMMENT ON COLUMN public.event_listing_snapshot_daily.amalgam_getin IS
  'Cross-source market FLOOR: cheapest get-in across all available sources '
  '(LEAST over NULLIF(per-source getin,0) for EVO/SG/SH/GT/VD/TP/TM). Auto-uses only present sources.';
COMMENT ON COLUMN public.event_listing_snapshot_daily.amalgam_source_count IS
  'How many of the 7 source-streams (EVO,SG,SH,GT,VD,TP,TM) had a usable get-in for this row (0-7).';
COMMENT ON COLUMN public.event_listing_snapshot_daily.amalgam_median IS
  'Count-WEIGHTED mean of per-source medians (weight = each source listing count). '
  'Inventory-weighted typical listing price — legitimately ≫ amalgam_getin for wide-spread premium events. '
  'Only sources with a median contribute. NULL if no source has a median.';

-- ── 2. Live amalgam RPC: same blend computed from latest per-source state ──────
-- Mirrors compute_event_listing_snapshot()'s per-source gather (EVO event_metrics, SG
-- seatgeek_event_metrics, TD latest_capture/latest_td via the aq hub) for ONE event, then
-- applies the identical floor/weighted-median/source-count formula. Returns one row always
-- (NULLs + source_count 0 when an event has no data).
CREATE OR REPLACE FUNCTION public.get_event_amalgam(p_event_id bigint)
RETURNS TABLE(
  amalgam_getin numeric, amalgam_median numeric, amalgam_source_count int, sources text[],
  evo_getin numeric, evo_median numeric, evo_count int,
  sg_getin  numeric, sg_median  numeric, sg_count  int,
  sh_getin  numeric, sh_median  numeric, sh_count  int,
  gt_getin  numeric, gt_median  numeric, gt_count  int,
  vd_getin  numeric, vd_median  numeric, vd_count  int,
  tp_getin  numeric, tp_median  numeric, tp_count  int,
  tm_getin  numeric, tm_median  numeric, tm_count  int
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public','extensions','pg_temp'
AS $$
  WITH evo AS (
    SELECT em.getin_price AS getin, em.retail_median AS median, em.tickets_count AS cnt
    FROM public.event_metrics em
    WHERE em.event_id = p_event_id
    ORDER BY em.captured_at DESC LIMIT 1
  ),
  sg AS (
    SELECT sgm.listings_all_min AS getin, sgm.listings_all_median AS median, sgm.listings_all_count AS cnt
    FROM public.seatgeek_event_metrics sgm
    WHERE sgm.tevo_event_id = p_event_id
    ORDER BY sgm.captured_at DESC LIMIT 1
  ),
  td_latest_capture AS (
    SELECT tds.event_id, tds.platform, MAX(tds.captured_at) AS max_at
    FROM public.ticketsdata_listings_snapshots tds
    JOIN public.ticketsdata_event_xref tdx ON tdx.event_id = tds.event_id AND tdx.active = true
    JOIN public.aq_event_map aem ON aem.aq_short_event_id = tdx.aq_short_event_id
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE sgc.tevo_event_id = p_event_id
      AND tds.captured_at > now() - interval '25 hours' AND tds.is_parking = false AND tds.list_price > 0
    GROUP BY tds.event_id, tds.platform
  ),
  td_rows AS (
    SELECT tds.platform, tds.list_price, tds.raw->'offer'->>'inventoryType' AS inv_type
    FROM public.ticketsdata_listings_snapshots tds
    JOIN td_latest_capture lc ON lc.event_id = tds.event_id AND lc.platform = tds.platform
      AND tds.captured_at >= lc.max_at - interval '15 minutes'
    WHERE tds.is_parking = false AND tds.list_price > 0
  ),
  td AS (
    SELECT
      MIN(list_price) FILTER (WHERE platform='SH') AS sh_getin,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY list_price) FILTER (WHERE platform='SH') AS sh_median,
      COUNT(*) FILTER (WHERE platform='SH')::int AS sh_count,
      MIN(list_price) FILTER (WHERE platform='GT') AS gt_getin,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY list_price) FILTER (WHERE platform='GT') AS gt_median,
      COUNT(*) FILTER (WHERE platform='GT')::int AS gt_count,
      MIN(list_price) FILTER (WHERE platform='VD') AS vd_getin,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY list_price) FILTER (WHERE platform='VD') AS vd_median,
      COUNT(*) FILTER (WHERE platform='VD')::int AS vd_count,
      MIN(list_price) FILTER (WHERE platform='TP') AS tp_getin,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY list_price) FILTER (WHERE platform='TP') AS tp_median,
      COUNT(*) FILTER (WHERE platform='TP')::int AS tp_count,
      MIN(list_price) FILTER (WHERE platform='TM' AND COALESCE(inv_type,'primary') <> 'resale') AS tm_getin,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY list_price)
        FILTER (WHERE platform='TM' AND COALESCE(inv_type,'primary') <> 'resale') AS tm_median,
      COUNT(*) FILTER (WHERE platform='TM' AND COALESCE(inv_type,'primary') <> 'resale')::int AS tm_count
    FROM td_rows
  )
  SELECT
    LEAST(NULLIF(evo.getin,0), NULLIF(sg.getin,0), NULLIF(td.sh_getin,0), NULLIF(td.gt_getin,0),
          NULLIF(td.vd_getin,0), NULLIF(td.tp_getin,0), NULLIF(td.tm_getin,0)) AS amalgam_getin,
    ROUND( (
      ( COALESCE(evo.median*evo.cnt,0) + COALESCE(sg.median*sg.cnt,0)
      + COALESCE(td.sh_median*td.sh_count,0) + COALESCE(td.gt_median*td.gt_count,0)
      + COALESCE(td.vd_median*td.vd_count,0) + COALESCE(td.tp_median*td.tp_count,0)
      + COALESCE(td.tm_median*td.tm_count,0) )
      / NULLIF(
          COALESCE(CASE WHEN evo.median IS NOT NULL THEN evo.cnt END,0)
        + COALESCE(CASE WHEN sg.median  IS NOT NULL THEN sg.cnt  END,0)
        + COALESCE(CASE WHEN td.sh_median IS NOT NULL THEN td.sh_count END,0)
        + COALESCE(CASE WHEN td.gt_median IS NOT NULL THEN td.gt_count END,0)
        + COALESCE(CASE WHEN td.vd_median IS NOT NULL THEN td.vd_count END,0)
        + COALESCE(CASE WHEN td.tp_median IS NOT NULL THEN td.tp_count END,0)
        + COALESCE(CASE WHEN td.tm_median IS NOT NULL THEN td.tm_count END,0)
      , 0) )::numeric
    , 2) AS amalgam_median,
      (NULLIF(evo.getin,0) IS NOT NULL)::int + (NULLIF(sg.getin,0) IS NOT NULL)::int
    + (NULLIF(td.sh_getin,0) IS NOT NULL)::int + (NULLIF(td.gt_getin,0) IS NOT NULL)::int
    + (NULLIF(td.vd_getin,0) IS NOT NULL)::int + (NULLIF(td.tp_getin,0) IS NOT NULL)::int
    + (NULLIF(td.tm_getin,0) IS NOT NULL)::int AS amalgam_source_count,
    array_remove(ARRAY[
      CASE WHEN NULLIF(evo.getin,0) IS NOT NULL THEN 'EVO' END,
      CASE WHEN NULLIF(sg.getin,0)  IS NOT NULL THEN 'SG'  END,
      CASE WHEN NULLIF(td.sh_getin,0) IS NOT NULL THEN 'SH' END,
      CASE WHEN NULLIF(td.gt_getin,0) IS NOT NULL THEN 'GT' END,
      CASE WHEN NULLIF(td.vd_getin,0) IS NOT NULL THEN 'VD' END,
      CASE WHEN NULLIF(td.tp_getin,0) IS NOT NULL THEN 'TP' END,
      CASE WHEN NULLIF(td.tm_getin,0) IS NOT NULL THEN 'TM' END
    ], NULL) AS sources,
    evo.getin, evo.median, evo.cnt,
    sg.getin,  sg.median,  sg.cnt,
    td.sh_getin, td.sh_median, td.sh_count,
    td.gt_getin, td.gt_median, td.gt_count,
    td.vd_getin, td.vd_median, td.vd_count,
    td.tp_getin, td.tp_median, td.tp_count,
    td.tm_getin, td.tm_median, td.tm_count
  FROM (SELECT 1) base
  LEFT JOIN evo ON true
  LEFT JOIN sg  ON true
  LEFT JOIN td  ON true;
$$;

REVOKE ALL ON FUNCTION public.get_event_amalgam(bigint) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.get_event_amalgam(bigint) TO anon, authenticated, service_role;
COMMENT ON FUNCTION public.get_event_amalgam(bigint) IS
  'Live cross-source amalgam for one event (TEvo event_id): floor / count-weighted median / '
  'source_count / sources[] + per-source getin/median/count breakdown. Same formula as the stored '
  'amalgam_* columns on event_listing_snapshot_daily, computed from the latest live per-source state '
  '(event_metrics + seatgeek_event_metrics + ticketsdata via the aq hub). Always returns exactly one row.';

-- ── 3. Surface amalgam on the trend view (reproduce + append; cols added at end) ──
CREATE OR REPLACE VIEW public.v_event_listing_trends AS
SELECT
  s.id,
  s.event_id,
  s.snapshot_slot,
  s.snapshot_date,
  s.captured_at,

  -- EVO raw metrics
  s.evo_tickets_count,
  s.evo_owned_tickets,
  s.evo_owned_median,
  s.evo_retail_getin,
  s.evo_retail_median,
  s.evo_retail_mean,
  s.evo_retail_min,
  s.evo_retail_max,

  -- SG raw metrics
  s.sg_all_listings,
  s.sg_all_tickets,
  s.sg_owned_tickets,
  s.sg_owned_median,
  s.sg_all_median,
  s.sg_all_getin,
  s.sg_all_mean,

  -- Week-over-week delta: same slot 1 week prior (3 slots back)
  s.evo_retail_median - LAG(s.evo_retail_median, 3) OVER w_event_slot  AS evo_median_wow_delta,
  s.evo_owned_tickets - LAG(s.evo_owned_tickets,  3) OVER w_event_slot AS evo_owned_wow_delta,
  s.sg_all_median     - LAG(s.sg_all_median,      3) OVER w_event_slot AS sg_median_wow_delta,

  -- Day-over-day delta: prior same slot (1 slot back)
  s.evo_retail_median - LAG(s.evo_retail_median, 1) OVER w_event_slot  AS evo_median_dod_delta,
  s.evo_owned_tickets - LAG(s.evo_owned_tickets,  1) OVER w_event_slot AS evo_owned_dod_delta,

  -- 7-day rolling average (21 slots = 3 slots × 7 days)
  AVG(s.evo_retail_median) OVER (
    PARTITION BY s.event_id
    ORDER BY s.snapshot_date,
             CASE s.snapshot_slot WHEN 'morning' THEN 1 WHEN 'midday' THEN 2 ELSE 3 END
    ROWS BETWEEN 20 PRECEDING AND CURRENT ROW
  ) AS evo_median_21slot_avg,

  AVG(s.sg_all_median) OVER (
    PARTITION BY s.event_id
    ORDER BY s.snapshot_date,
             CASE s.snapshot_slot WHEN 'morning' THEN 1 WHEN 'midday' THEN 2 ELSE 3 END
    ROWS BETWEEN 20 PRECEDING AND CURRENT ROW
  ) AS sg_median_21slot_avg,

  -- Pricing position metrics
  CASE WHEN s.evo_retail_median > 0
    THEN ROUND((s.evo_owned_median / s.evo_retail_median) * 100, 1)
    ELSE NULL
  END AS evo_owned_vs_market_pct,

  ROUND(s.sg_all_median - s.evo_retail_median, 2) AS sg_vs_evo_spread,

  -- Inventory velocity
  s.evo_owned_tickets - LAG(s.evo_owned_tickets, 3) OVER w_event_slot AS evo_owned_7d_velocity,

  -- Event context (from sg_events_canonical)
  sgc.sg_event_name,
  sgc.sg_datetime_utc,
  sgc.sg_venue_name,
  sgc.sg_venue_city,
  sgc.sg_venue_state,
  (sgc.sg_datetime_utc::date - s.snapshot_date)::int AS days_to_event,

  -- ── Cross-source amalgam (added 2026-05-31) ───────────────────────────────
  s.amalgam_getin,
  s.amalgam_median,
  s.amalgam_source_count,
  s.amalgam_median - LAG(s.amalgam_median, 1) OVER w_event_slot AS amalgam_median_dod_delta,
  s.amalgam_median - LAG(s.amalgam_median, 3) OVER w_event_slot AS amalgam_median_wow_delta

FROM public.event_listing_snapshot_daily s
LEFT JOIN public.sg_events_canonical sgc ON sgc.tevo_event_id = s.event_id

WINDOW w_event_slot AS (
  PARTITION BY s.event_id, s.snapshot_slot
  ORDER BY s.snapshot_date
);

REVOKE ALL ON public.v_event_listing_trends FROM anon, authenticated;
GRANT SELECT ON public.v_event_listing_trends TO service_role;
