-- Migration 20260515270000 · level:admin · lane:Audit/Push · writes:sg_classify_events() v2 · pre:20260515260000
-- The v1 classifier (20260515260000) only counted owned listings via
-- aq_event_map.sg_event_id linkage, so events not in aq_event_map (Knicks
-- playoffs, NBA games whose AQ row is SYS-, etc.) classified as OBSERVE.
-- 157 of our owned events DO have sg_events_canonical.tevo_event_id mapped
-- directly. v2 uses BOTH join paths so HOT/WARM/COOL/COLD light up.
--
-- ## Already applied to prod  Applied via MCP 2026-05-14.
-- Post-apply: HOT=0 (no events <6h right now), WARM=4, COOL=30, COLD=69
-- = 103 owned events now classified for tiered polling.

CREATE OR REPLACE FUNCTION public.sg_classify_events()
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_updated int := 0;
BEGIN
  WITH listings_by_tevo AS (
    SELECT event_id AS tevo_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days' AND event_id IS NOT NULL
    GROUP BY event_id
  ),
  listings_by_aq AS (
    SELECT aq_short_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days' AND aq_short_event_id IS NOT NULL
    GROUP BY aq_short_event_id
  ),
  event_metrics AS (
    SELECT
      c.sg_event_id, c.sg_event_name, c.sg_venue_name, c.sg_datetime_utc,
      coalesce(a.aq_short_event_id,
               (SELECT aem.aq_short_event_id FROM public.aq_event_map aem WHERE aem.sg_event_id = c.sg_event_id LIMIT 1)) AS aq_short_event_id,
      EXTRACT(epoch FROM (c.sg_datetime_utc - v_now)) / 3600 AS hours_to_event,
      coalesce(lt.owned_cnt,    la.owned_cnt,    0) AS owned_cnt,
      coalesce(lt.listings_cnt, la.listings_cnt, 0) AS listings_cnt
    FROM public.sg_events_canonical c
    LEFT JOIN public.aq_event_map a ON a.sg_event_id = c.sg_event_id
    LEFT JOIN listings_by_tevo lt ON lt.tevo_event_id = c.tevo_event_id
    LEFT JOIN listings_by_aq   la ON la.aq_short_event_id = a.aq_short_event_id
    WHERE c.sg_datetime_utc IS NOT NULL
      AND c.sg_datetime_utc BETWEEN v_now - interval '6 hours' AND v_now + interval '60 days'
  ),
  classified AS (
    SELECT em.*,
      (SELECT p.tier FROM public.sg_priority_policy p
       WHERE p.enabled = true
         AND em.hours_to_event >= coalesce(p.min_hours_to_event, -999999)
         AND em.hours_to_event <  coalesce(p.max_hours_to_event, 999999)
         AND (p.requires_owned = false OR em.owned_cnt > 0)
       ORDER BY p.sort_order LIMIT 1) AS tier
    FROM event_metrics em
  )
  INSERT INTO public.sg_event_priority_state AS s
    (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
     owned_count_last_7d, active_listings_last_7d, tier, hours_to_event, computed_at)
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
         owned_cnt, listings_cnt, coalesce(tier, 'SKIP'), hours_to_event, v_now
  FROM classified WHERE sg_event_id IS NOT NULL
  ON CONFLICT (sg_event_id) DO UPDATE SET
    sg_event_name=EXCLUDED.sg_event_name, sg_venue_name=EXCLUDED.sg_venue_name,
    sg_datetime_utc=EXCLUDED.sg_datetime_utc, aq_short_event_id=EXCLUDED.aq_short_event_id,
    owned_count_last_7d=EXCLUDED.owned_count_last_7d,
    active_listings_last_7d=EXCLUDED.active_listings_last_7d,
    tier=EXCLUDED.tier, hours_to_event=EXCLUDED.hours_to_event, computed_at=EXCLUDED.computed_at,
    sales_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day = current_date;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END $func$;
