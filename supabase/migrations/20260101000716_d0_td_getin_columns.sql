-- ============================================================
-- #943-2 (D0 ask, bot_chat 941/943): per-source TD get-in on the daily rollup.
-- event_listing_snapshot_daily carried td_*_median + td_*_listings but NO get-in, so the
-- multi-source KPI grid FLOOR tile could only show min(TEvo,SG) get-in and MISSED the true
-- cross-source cheapest (worked example tevo 3346011: VividSeats get-in $2,455 vs SG $3,250).
-- Adds td_{sh,gt,vd,tp,tm}_getin = MIN(list_price) per platform, computed in the SAME
-- latest-batch CTE that already produces td_*_median (non-parking, list_price>0; TM = primary,
-- mirroring tm_median). A1-authored from D0 spec, applied 2026-05-30. FE reads presence-gated.
-- ============================================================
ALTER TABLE public.event_listing_snapshot_daily
  ADD COLUMN IF NOT EXISTS td_sh_getin numeric,
  ADD COLUMN IF NOT EXISTS td_gt_getin numeric,
  ADD COLUMN IF NOT EXISTS td_vd_getin numeric,
  ADD COLUMN IF NOT EXISTS td_tp_getin numeric,
  ADD COLUMN IF NOT EXISTS td_tm_getin numeric;

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
      SELECT tds.event_id, tds.platform, tds.list_price,
             tds.raw->'offer'->>'inventoryType' AS inv_type
      FROM public.ticketsdata_listings_snapshots tds
      JOIN latest_capture lc ON lc.event_id = tds.event_id AND lc.platform = tds.platform
        AND tds.captured_at >= lc.max_at - interval '15 minutes'
      WHERE tds.is_parking = false AND tds.list_price > 0
    )
    SELECT
      sgc.tevo_event_id,
      COUNT(*) FILTER (WHERE lt.platform='SH') AS sh_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.list_price) FILTER (WHERE lt.platform='SH') AS sh_median,
      COUNT(*) FILTER (WHERE lt.platform='GT') AS gt_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.list_price) FILTER (WHERE lt.platform='GT') AS gt_median,
      COUNT(*) FILTER (WHERE lt.platform='VD') AS vd_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.list_price) FILTER (WHERE lt.platform='VD') AS vd_median,
      COUNT(*) FILTER (WHERE lt.platform='TP') AS tp_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.list_price) FILTER (WHERE lt.platform='TP') AS tp_median,
      COUNT(*) FILTER (WHERE lt.platform='TM' AND COALESCE(lt.inv_type,'primary') <> 'resale') AS tm_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.list_price)
        FILTER (WHERE lt.platform='TM' AND COALESCE(lt.inv_type,'primary') <> 'resale') AS tm_median,
      COUNT(*) FILTER (WHERE lt.platform='TM' AND lt.inv_type = 'resale') AS tm_resale_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.list_price)
        FILTER (WHERE lt.platform='TM' AND lt.inv_type = 'resale') AS tm_resale_median,
      MIN(lt.list_price) FILTER (WHERE lt.platform='SH') AS sh_getin,
      MIN(lt.list_price) FILTER (WHERE lt.platform='GT') AS gt_getin,
      MIN(lt.list_price) FILTER (WHERE lt.platform='VD') AS vd_getin,
      MIN(lt.list_price) FILTER (WHERE lt.platform='TP') AS tp_getin,
      MIN(lt.list_price) FILTER (WHERE lt.platform='TM' AND COALESCE(lt.inv_type,'primary') <> 'resale') AS tm_getin
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
