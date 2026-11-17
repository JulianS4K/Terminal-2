-- Migration 20260901004828 · reconstructed from prod · writes: see body
--
-- Recorded 2026-11-17 (branch triage): applied on prod as "xref_event_listing_snapshot_freshness_bound" (version 20260901004828) but present in no
-- file in git. Body is prod's own supabase_migrations.schema_migrations.statements for that row,
-- statements separated by ';'. Recording only — it is already applied; do not re-apply.


-- ============================================================================
-- Migration — compute_event_listing_snapshot: bound EVO metrics by freshness
--             and require the event to exist
--
-- Lane:     xref+macro
-- Touches:  event_listing_snapshot_daily (W, via the function), event_metrics (R),
--           events (R)
-- Pre-reqs: none
--
-- Operator directive 2026-09-01: we should have events for the EVO listings we
-- hold.
--
-- THE BUG
-- compute_event_listing_snapshot drove its EVO figures from
--     SELECT DISTINCT ON (event_id) ... FROM event_metrics
--      ORDER BY event_id, captured_at DESC
-- with NO freshness bound and no join to `events`. It therefore took the latest
-- metrics row per event AT ANY AGE and rewrote it into today's snapshot with
-- captured_at = now(), twice a day, forever. Stale numbers were being
-- republished as current.
--
-- Worked example, event 3237291: evo_tickets_count 46, get-in 70.38, median
-- 145.86 -- byte-identical on every slot of 2026-08-30 and 2026-08-31, with
-- captured_at advancing 03:31 / 13:31 each day, while listings_snapshots held
-- NO rows for that event in seven days and `events` held no row at all. The
-- value even propagated into amalgam_getin with amalgam_source_count = 1, so
-- downstream it looked like a live single-source price for a phantom event.
--
-- The TicketsData subquery immediately below already bounds itself
-- (captured_at > now() - interval '25 hours'). The EVO side simply never did.
-- That asymmetry is the whole defect.
--
-- SCOPE OF THE CHANGE, measured before applying
--   14,384 events currently emit a row per slot
--    8,940 have metrics fresher than 25h  -> keep emitting
--    5,450 are stale                      -> stop
--          of which 5,389 (98.9%) are PAST events -- republishing a finished
--                   event's frozen book daily is pure noise
--                   18 are absent from `events` entirely (the operator's case)
--                   43 are FUTURE events whose metrics have gone cold, 23 of
--                   them for over a week. Dropping their row does not lose
--                   information -- it stops FROZEN data from MASKING the fact
--                   that collection stopped. That is the point.
--
-- Historical rows are untouched; this only stops writing new fabricated ones.
--
-- CROSS-LANE (PROJECT_BIBLE §2.6): event_listing_snapshot_daily is read by D0
-- (terminal event pages, amalgam_getin / amalgam_median, movers). After this,
-- an event with no fresh collection gets NO row for today instead of a stale
-- one. Consumers that assume a row per event per day will see gaps -- that gap
-- is the truth, and a stale price is not. Flagged to bot_chat.
-- ============================================================================

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
    -- FRESHNESS BOUND (added 2026-09-01): only metrics captured in the last 25
    -- hours, matching the TicketsData subquery below, which already bounded
    -- itself. Without this the latest row of ANY age was rewritten as today's
    -- snapshot with captured_at = now(), republishing frozen numbers forever.
    SELECT DISTINCT ON (event_id)
      event_id, tickets_count, owned_tickets_count, owned_median_retail,
      getin_price, retail_median, retail_mean, retail_min, retail_max
    FROM public.event_metrics
    WHERE captured_at > now() - interval '25 hours'
    ORDER BY event_id, captured_at DESC
  ) em
  -- and the event must actually exist in our catalogue
  JOIN public.events ev ON ev.id = em.event_id
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

COMMENT ON FUNCTION public.compute_event_listing_snapshot(text) IS
  'Writes one event_listing_snapshot_daily row per event per slot. EVO metrics are bounded to the last 25 hours (matching the TicketsData subquery, which always was) and the event must exist in `events`. Before 2026-09-01 neither held: the latest event_metrics row of ANY age was rewritten as today''s snapshot with captured_at = now(), so ~5,450 events -- 98.9% of them already past, 18 absent from `events` entirely -- had frozen numbers republished twice daily as if current, including into amalgam_getin. An event with no fresh collection now gets NO row rather than a stale one.';
;
