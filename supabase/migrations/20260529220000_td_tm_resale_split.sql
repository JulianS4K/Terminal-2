-- ============================================================
-- Ticketmaster primary vs resale split + aq_event_map.tm_event_id mapping.
-- Authored by A1 (a1/td lane) 2026-05-29.
-- ============================================================
-- TM events carry TWO inventory pools in the same ISMDS /fetch, distinguished by
-- `inventoryType` on each offer: **'primary'** (box-office face value) and **'resale'**
-- (verified fan-to-fan). MLB/Yankees here are primary-only; NBA/Knicks-type games show
-- resale (verified live on Spurs@Thunder WCF: 997 resale offers, all priced, med $700).
-- The two pools are DIFFERENT datasets and must be metricized separately.
--
-- The normalizer already captures both pools (same facet/offer shape) and preserves the
-- discriminator in `raw->'offer'->>'inventoryType'`. Rather than add a sparse column to the
-- 489MB/525k-row firehose (full-table rewrite under exclusive lock), the split reads
-- inventoryType from raw at metrics time:
--   td_tm_listings / td_tm_median        = PRIMARY (inventoryType <> 'resale')
--   td_tm_resale_listings / td_tm_resale_median = RESALE (inventoryType = 'resale')
-- td_combined_median keeps PRIMARY only (resale is secondary-market, not a floor).
--
-- Also maps the discovered TM event ids into aq_event_map.tm_event_id (hex->bigint) so
-- downstream cross-source processing can join TM by direct id instead of re-discovering.
-- ============================================================

ALTER TABLE public.event_listing_snapshot_daily
  ADD COLUMN IF NOT EXISTS td_tm_resale_listings int,
  ADD COLUMN IF NOT EXISTS td_tm_resale_median   numeric;

CREATE OR REPLACE FUNCTION public.compute_event_listing_snapshot(p_slot text DEFAULT 'midday'::text)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE v_count int := 0; v_jobname text;
BEGIN
  v_jobname := 'event_snapshot_' || p_slot;
  IF p_slot NOT IN ('morning','midday','evening') THEN v_jobname := 'event_snapshot_morning'; END IF;
  IF NOT public.cron_should_fire(v_jobname) THEN RETURN 0; END IF;

  INSERT INTO public.event_listing_snapshot_daily (
    event_id, snapshot_slot, snapshot_date,
    evo_tickets_count, evo_owned_tickets, evo_owned_median,
    evo_retail_getin, evo_retail_median, evo_retail_mean, evo_retail_min, evo_retail_max,
    sg_all_listings, sg_all_tickets, sg_owned_tickets, sg_owned_median, sg_all_median, sg_all_getin, sg_all_mean,
    td_sh_listings, td_sh_median, td_gt_listings, td_gt_median, td_vd_listings, td_vd_median,
    td_tp_listings, td_tp_median, td_tm_listings, td_tm_median,
    td_tm_resale_listings, td_tm_resale_median,
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
      -- TM PRIMARY (box-office): inventoryType is not 'resale' (NULL/legacy treated as primary)
      COUNT(*) FILTER (WHERE lt.platform='TM' AND COALESCE(lt.inv_type,'primary') <> 'resale') AS tm_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.list_price)
        FILTER (WHERE lt.platform='TM' AND COALESCE(lt.inv_type,'primary') <> 'resale') AS tm_median,
      -- TM RESALE (verified fan-to-fan): inventoryType = 'resale'
      COUNT(*) FILTER (WHERE lt.platform='TM' AND lt.inv_type = 'resale') AS tm_resale_listings,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY lt.list_price)
        FILTER (WHERE lt.platform='TM' AND lt.inv_type = 'resale') AS tm_resale_median
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
    td_combined_median=EXCLUDED.td_combined_median, captured_at=EXCLUDED.captured_at;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

-- Discover-drain: same as 210000 + keep aq_event_map.tm_event_id in sync (direct-id mapping)
CREATE OR REPLACE FUNCTION public.td_tm_discover_drain()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE r RECORD; v_count int := 0; v_n int;
BEGIN
  IF NOT public.cron_should_fire('td_tm_discover_drain') THEN RETURN 0; END IF;
  FOR r IN SELECT p.id AS performer_id, h.status_code, h.content AS raw_content
    FROM public.td_tm_performers p JOIN net._http_response h ON h.id = p.pending_discover_request_id
    WHERE p.active = true AND p.pending_discover_request_id IS NOT NULL ORDER BY p.id
  LOOP
    IF r.status_code = 200 THEN
      WITH items AS (
        SELECT item->>'id' AS tm_hex, item->>'url' AS event_url, item->>'discoveryId' AS discovery_id,
               item->>'title' AS title,
               (item->'dates'->>'startDate')::timestamptz AS dt_utc, item->'venue'->>'name' AS venue
        FROM jsonb_array_elements(COALESCE(r.raw_content::jsonb->'body'->'items','[]'::jsonb)) AS item
        WHERE item->>'id' ~ '^[0-9A-Fa-f]{1,16}$'
          AND item->>'url' LIKE 'https://www.ticketmaster.com/%/event/%'
          AND item->>'title' NOT LIKE '%*%' AND lower(item->>'title') NOT LIKE '%parking%'
          AND COALESCE((item->>'cancelled')::boolean, false) = false
          AND (item->'dates'->>'startDate') IS NOT NULL
      ),
      matched AS (
        SELECT DISTINCT ON (t.aq_short_event_id)
          t.aq_short_event_id, i.tm_hex, i.event_url, i.discovery_id
        FROM items i
        CROSS JOIN public.td_target_events() t
        JOIN public.aq_event_map aem ON aem.aq_short_event_id = t.aq_short_event_id
        WHERE abs(extract(epoch FROM (aem.event_date::timestamptz - i.dt_utc))) < 64800
          AND ((aem.event_name ILIKE '%yankees%' AND i.venue ILIKE '%yankee stadium%')
            OR (aem.event_name ILIKE '%knicks%'  AND i.venue ILIKE '%madison square garden%'))
        ORDER BY t.aq_short_event_id,
                 (CASE WHEN i.title ILIKE '%vs.%' OR i.title ILIKE '% at %' THEN 0 ELSE 1 END),
                 abs(extract(epoch FROM (aem.event_date::timestamptz - i.dt_utc)))
      )
      INSERT INTO public.ticketsdata_event_xref
        (event_id, platform, aq_short_event_id, event_url, td_event_id, active, always_on, match_method, updated_at)
      SELECT ('x'||lpad(tm_hex,16,'0'))::bit(64)::bigint, 'TM', aq_short_event_id, event_url, discovery_id,
             true, true, 'tm_events_venue_date', clock_timestamp()
      FROM matched
      ON CONFLICT (event_id, platform) DO UPDATE
        SET event_url = EXCLUDED.event_url, td_event_id = EXCLUDED.td_event_id, active = true, always_on = true,
            aq_short_event_id = EXCLUDED.aq_short_event_id, match_method = 'tm_events_venue_date', updated_at = clock_timestamp();
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_count := v_count + v_n;
      -- map TM ids into the aq hub for fast direct-id processing
      UPDATE public.aq_event_map aem SET tm_event_id = x.event_id
      FROM public.ticketsdata_event_xref x
      WHERE x.platform='TM' AND x.active = true AND x.aq_short_event_id = aem.aq_short_event_id
        AND aem.tm_event_id IS DISTINCT FROM x.event_id;
      PERFORM public.td_charge_credit(1, NULL, 'TM', '/events', 200, (r.raw_content::jsonb->>'quota_remaining')::int);
    END IF;
    UPDATE public.td_tm_performers SET pending_discover_request_id = NULL, last_discovered_at = clock_timestamp(), updated_at = clock_timestamp()
    WHERE id = r.performer_id;
  END LOOP;
  RETURN v_count;
END $function$;

-- One-time backfill: map current active TM focus events into aq_event_map (hex->bigint ids)
UPDATE public.aq_event_map aem SET tm_event_id = x.event_id
FROM public.ticketsdata_event_xref x
WHERE x.platform='TM' AND x.active = true AND x.aq_short_event_id = aem.aq_short_event_id
  AND aem.tm_event_id IS DISTINCT FROM x.event_id;

-- Post-apply smoke:
--   SELECT event_id, td_tm_listings, td_tm_median, td_tm_resale_listings, td_tm_resale_median
--   FROM event_listing_snapshot_daily WHERE snapshot_date=CURRENT_DATE AND td_tm_listings IS NOT NULL;
--   SELECT count(*) FROM aq_event_map WHERE tm_event_id > 1e15;  -- mapped focus events
