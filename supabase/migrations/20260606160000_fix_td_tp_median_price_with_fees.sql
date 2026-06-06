-- Migration 20260606160000 · lane:D0 (author) → A1 (apply) · writes:compute_event_listing_snapshot · reads:event_metrics,seatgeek_event_metrics,ticketsdata_listings_snapshots,ticketsdata_event_xref,aq_event_map,sg_events_canonical · pre:20260529174007 · auth:operator-approved 2026-06-06
--
-- D0 — FIX: TickPick (TP) median/get-in in the daily rollup were computed from
-- `list_price`, which for TickPick is a seller/base value, NOT the displayed
-- buyer price. TickPick is an all-in marketplace (no checkout fees), so the
-- market price IS `price_with_fees`. Symptom: td_tp_median rendered far below
-- reality — e.g. Detroit Tigers @ NY Yankees 6/30 (tevo 3091433) showed
-- td_tp_median = $60 while the true all-in median was $342, and $60 sits BELOW
-- the cheapest actual TP listing ($142.50). The bad value also poisoned
-- td_combined_median via LEAST(... NULLIF(td.tp_median,0) ...).
--
-- Per-platform median(list_price) vs median(price_with_fees) on that event:
--   SH 138/138 (1.00x) · GT 59/69 (1.18x) · TM 105/128 (1.21x) · VD 78/109 (1.39x)
--   TP 60/342 (5.60x, per-row ratio swings 9–15x)  ← only TP is incoherent
--
-- Surgical fix: TP uses `price_with_fees`; SH/GT/VD/TM stay on `list_price` so
-- their continuous historical daily series keeps one consistent basis. This also
-- aligns TP with get_event_all_source_listing_metrics (the live cross-source
-- panel), which already uses price_with_fees for every TD source.
--
-- NOTE: historical TP daily rows remain on the old (list_price) basis — the raw
-- firehose is trimmed (~25h retention) so past slots cannot be recomputed. Fix is
-- forward-only; the chart's TP history self-heals as old points age out.

CREATE OR REPLACE FUNCTION public.compute_event_listing_snapshot(p_slot text DEFAULT 'midday'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE v_count int := 0;
BEGIN
  INSERT INTO public.event_listing_snapshot_daily (
    event_id, snapshot_slot, snapshot_date,
    evo_tickets_count, evo_owned_tickets, evo_owned_median,
    evo_retail_getin, evo_retail_median, evo_retail_mean, evo_retail_min, evo_retail_max,
    sg_all_listings, sg_all_tickets, sg_owned_tickets, sg_owned_median, sg_all_median, sg_all_getin, sg_all_mean,
    td_sh_listings, td_sh_median, td_gt_listings, td_gt_median, td_vd_listings, td_vd_median,
    td_tp_listings, td_tp_median, td_tm_listings, td_tm_median,
    td_tm_resale_listings, td_tm_resale_median,
    td_sh_getin, td_gt_getin, td_vd_getin, td_tp_getin, td_tm_getin,
    td_combined_median, captured_at
  )
  SELECT
    em.event_id, p_slot, CURRENT_DATE,
    em.tickets_count, em.owned_tickets_count, em.owned_median_retail,
    em.getin_price, em.retail_median, em.retail_mean, em.retail_min, em.retail_max,
    sgm.listings_all_count, sgm.listings_all_tickets, sgm.listings_owned_tickets,
    sgm.listings_owned_median, sgm.listings_all_median, sgm.listings_all_min, sgm.listings_all_mean,
    td.sh_listings, td.sh_median, td.gt_listings, td.gt_median, td.vd_listings, td.vd_median,
    td.tp_listings, td.tp_median, td.tm_listings, td.tm_median,
    td.tm_resale_listings, td.tm_resale_median,
    td.sh_getin, td.gt_getin, td.vd_getin, td.tp_getin, td.tm_getin,
    LEAST(NULLIF(td.sh_median,0), NULLIF(td.gt_median,0), NULLIF(td.vd_median,0),
          NULLIF(td.tp_median,0), NULLIF(td.tm_median,0)),
    now()
  FROM (
    SELECT DISTINCT ON (event_id)
      event_id, tickets_count, owned_tickets_count, owned_median_retail,
      getin_price, retail_median, retail_mean, retail_min, retail_max
    FROM public.event_metrics ORDER BY event_id, captured_at DESC
  ) em
  LEFT JOIN (
    SELECT DISTINCT ON (tevo_event_id)
      tevo_event_id, listings_all_count, listings_all_tickets, listings_owned_tickets,
      listings_owned_median, listings_all_median, listings_all_min, listings_all_mean
    FROM public.seatgeek_event_metrics ORDER BY tevo_event_id, captured_at DESC
  ) sgm ON sgm.tevo_event_id = em.event_id
  LEFT JOIN (
    WITH latest_capture AS (
      SELECT event_id, platform, MAX(captured_at) AS max_at
      FROM public.ticketsdata_listings_snapshots
      WHERE captured_at > now() - interval '25 hours' AND is_parking = false AND list_price > 0
      GROUP BY event_id, platform
    ),
    latest_td AS (
      -- eff_price: TickPick (TP) is an all-in marketplace — its `list_price` is a
      -- seller/base value, not the displayed price — so use `price_with_fees`.
      -- Every other TD platform keeps `list_price` (coherent pre-fee basis).
      SELECT tds.event_id, tds.platform,
             CASE WHEN tds.platform = 'TP' THEN tds.price_with_fees ELSE tds.list_price END AS eff_price,
             tds.raw->'offer'->>'inventoryType' AS inv_type
      FROM public.ticketsdata_listings_snapshots tds
      JOIN latest_capture lc ON lc.event_id = tds.event_id AND lc.platform = tds.platform
        AND tds.captured_at >= lc.max_at - interval '15 minutes'
      WHERE tds.is_parking = false AND tds.list_price > 0
    )
    SELECT
      sgc.tevo_event_id,
      COUNT(*) FILTER (WHERE lt.platform='SH') AS sh_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.eff_price) FILTER (WHERE lt.platform='SH') AS sh_median,
      COUNT(*) FILTER (WHERE lt.platform='GT') AS gt_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.eff_price) FILTER (WHERE lt.platform='GT') AS gt_median,
      COUNT(*) FILTER (WHERE lt.platform='VD') AS vd_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.eff_price) FILTER (WHERE lt.platform='VD') AS vd_median,
      COUNT(*) FILTER (WHERE lt.platform='TP') AS tp_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.eff_price) FILTER (WHERE lt.platform='TP') AS tp_median,
      COUNT(*) FILTER (WHERE lt.platform='TM' AND COALESCE(lt.inv_type,'primary') <> 'resale') AS tm_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.eff_price)
        FILTER (WHERE lt.platform='TM' AND COALESCE(lt.inv_type,'primary') <> 'resale') AS tm_median,
      COUNT(*) FILTER (WHERE lt.platform='TM' AND lt.inv_type = 'resale') AS tm_resale_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.eff_price)
        FILTER (WHERE lt.platform='TM' AND lt.inv_type = 'resale') AS tm_resale_median,
      MIN(lt.eff_price) FILTER (WHERE lt.platform='SH') AS sh_getin,
      MIN(lt.eff_price) FILTER (WHERE lt.platform='GT') AS gt_getin,
      MIN(lt.eff_price) FILTER (WHERE lt.platform='VD') AS vd_getin,
      MIN(lt.eff_price) FILTER (WHERE lt.platform='TP') AS tp_getin,
      MIN(lt.eff_price) FILTER (WHERE lt.platform='TM' AND COALESCE(lt.inv_type,'primary') <> 'resale') AS tm_getin
    FROM latest_td lt
    JOIN public.ticketsdata_event_xref tdx ON tdx.event_id = lt.event_id AND tdx.active = true
    JOIN public.aq_event_map aem ON aem.aq_short_event_id = tdx.aq_short_event_id
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    GROUP BY sgc.tevo_event_id
  ) td ON td.tevo_event_id = em.event_id
  ON CONFLICT (event_id, snapshot_date, snapshot_slot) DO UPDATE SET
    evo_tickets_count=EXCLUDED.evo_tickets_count, evo_owned_tickets=EXCLUDED.evo_owned_tickets,
    evo_owned_median=EXCLUDED.evo_owned_median, evo_retail_getin=EXCLUDED.evo_retail_getin,
    evo_retail_median=EXCLUDED.evo_retail_median, evo_retail_mean=EXCLUDED.evo_retail_mean,
    evo_retail_min=EXCLUDED.evo_retail_min, evo_retail_max=EXCLUDED.evo_retail_max,
    sg_all_listings=EXCLUDED.sg_all_listings, sg_all_tickets=EXCLUDED.sg_all_tickets,
    sg_owned_tickets=EXCLUDED.sg_owned_tickets, sg_owned_median=EXCLUDED.sg_owned_median,
    sg_all_median=EXCLUDED.sg_all_median, sg_all_getin=EXCLUDED.sg_all_getin, sg_all_mean=EXCLUDED.sg_all_mean,
    td_sh_listings=EXCLUDED.td_sh_listings, td_sh_median=EXCLUDED.td_sh_median,
    td_gt_listings=EXCLUDED.td_gt_listings, td_gt_median=EXCLUDED.td_gt_median,
    td_vd_listings=EXCLUDED.td_vd_listings, td_vd_median=EXCLUDED.td_vd_median,
    td_tp_listings=EXCLUDED.td_tp_listings, td_tp_median=EXCLUDED.td_tp_median,
    td_tm_listings=EXCLUDED.td_tm_listings, td_tm_median=EXCLUDED.td_tm_median,
    td_tm_resale_listings=EXCLUDED.td_tm_resale_listings, td_tm_resale_median=EXCLUDED.td_tm_resale_median,
    td_sh_getin=EXCLUDED.td_sh_getin, td_gt_getin=EXCLUDED.td_gt_getin, td_vd_getin=EXCLUDED.td_vd_getin,
    td_tp_getin=EXCLUDED.td_tp_getin, td_tm_getin=EXCLUDED.td_tm_getin,
    td_combined_median=EXCLUDED.td_combined_median, captured_at=EXCLUDED.captured_at;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;
