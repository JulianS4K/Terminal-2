-- Migration 20260520210000 · lane:A1 · CRITICAL HOTFIX · writes:sg_classify_events · pre:20260520200000 · auth:operator-approved 2026-05-18
--
-- sg_classify_events_5min cron has been FAILING every 5 minutes since
-- 10:30 UTC (~5 hours of consecutive failures) with `statement_timeout`
-- on the listings_snapshots 7-day scan. ALL tier transitions across the
-- system were frozen during this window.
--
-- Discovered via user-reported "Mets at Nationals no SG sales": all 4
-- imminent games stuck at OBSERVE despite Game 1 having 2,210 listings
-- (qualifies for WATCH per PR #249 mig 20260520000000's >500/7d threshold).
-- The cron failure prevented the WATCH promotion from ever happening.
--
-- Root cause: listings_snapshots (8M+ rows) × 7-day GROUP BY twice (once
-- by tevo_event_id, once by aq_short_event_id) now exceeds the pg_cron
-- worker's ~2-min statement_timeout. Compounded today by:
--   - Heavy MCP scans during Yankees audit (earlier this session)
--   - New 60d+ polling cron (PR #251) firing every 5 min
--   - Cumulative table growth over recent weeks
--
-- Fix: shrink scan window from 7d → 24h. Reduces aggregate cost by ~7x
-- (verified: 3.6s vs 25s+ for each CTE). Threshold scaled proportionally
-- to preserve the "active market" signal:
--   old: listings_cnt > 500 over 7d (avg event ~1933 rows/7d)
--   new: listings_cnt > 150 over 24h (avg event ~497 rows/24h)
-- Same boolean-ish "is this market liquid?" answer.
--
-- Column name `active_listings_last_7d` retained on sg_event_priority_state
-- to avoid schema break. Value is now 24h count; minor naming drift
-- documented here. External readers consume the number, not the name.
--
-- Manual trigger included at end so all stale tiers refresh immediately
-- after apply. Verified post-apply: 200 events promoted to WATCH (was 0
-- during outage); 15 HOT, 1 WARM, 28 COOL, 27 COLD, 700 OBSERVE, 988 SKIP.

CREATE OR REPLACE FUNCTION public.sg_classify_events()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_updated int := 0;
BEGIN
  -- A1 mig 20260520210000: scan window 7d → 24h hotfix.
  WITH listings_by_tevo AS (
    SELECT event_id AS tevo_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '24 hours'
      AND event_id IS NOT NULL
    GROUP BY event_id
  ),
  listings_by_aq AS (
    SELECT aq_short_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '24 hours'
      AND aq_short_event_id IS NOT NULL
    GROUP BY aq_short_event_id
  ),
  event_metrics AS (
    SELECT c.sg_event_id, c.sg_event_name, c.sg_venue_name, c.sg_datetime_utc,
           coalesce(a.aq_short_event_id,
                    (SELECT aem.aq_short_event_id FROM public.aq_event_map aem
                     WHERE aem.sg_event_id = c.sg_event_id LIMIT 1)) AS aq_short_event_id,
           coalesce(c.tevo_event_id,
                    (SELECT x.tevo_event_id FROM public.seatgeek_event_xref x
                     WHERE x.sg_event_id = c.sg_event_id LIMIT 1)) AS tevo_event_id,
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
      CASE
        WHEN em.sg_event_name ~* '(cancelled|if necessary)' THEN 'SKIP'
        WHEN em.sg_event_name ~* '(\(date tbd\)|^TBD at )'
             AND em.tevo_event_id IS NULL THEN 'SKIP'
        -- WATCH threshold scaled to 24h window: was >500/7d, now >150/24h.
        WHEN em.hours_to_event >= 0
             AND em.hours_to_event < 168
             AND em.owned_cnt = 0
             AND em.listings_cnt > 150 THEN 'WATCH'
        ELSE
          (SELECT p.tier FROM public.sg_priority_policy p
           WHERE p.enabled = true
             AND em.hours_to_event >= coalesce(p.min_hours_to_event, -999999)
             AND em.hours_to_event <  coalesce(p.max_hours_to_event, 999999)
             AND (p.requires_owned = false OR em.owned_cnt > 0)
           ORDER BY p.sort_order LIMIT 1)
      END AS tier
    FROM event_metrics em
  )
  INSERT INTO public.sg_event_priority_state AS s
    (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
     tevo_event_id, owned_count_last_7d, active_listings_last_7d, tier, hours_to_event, computed_at)
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
         tevo_event_id, owned_cnt, listings_cnt, coalesce(tier, 'SKIP'), hours_to_event, v_now
  FROM classified WHERE sg_event_id IS NOT NULL
  ON CONFLICT (sg_event_id) DO UPDATE SET
    sg_event_name           = EXCLUDED.sg_event_name,
    sg_venue_name           = EXCLUDED.sg_venue_name,
    sg_datetime_utc         = EXCLUDED.sg_datetime_utc,
    aq_short_event_id       = EXCLUDED.aq_short_event_id,
    tevo_event_id           = EXCLUDED.tevo_event_id,
    owned_count_last_7d     = EXCLUDED.owned_count_last_7d,
    active_listings_last_7d = EXCLUDED.active_listings_last_7d,
    tier                    = EXCLUDED.tier,
    hours_to_event          = EXCLUDED.hours_to_event,
    computed_at             = EXCLUDED.computed_at,
    sales_polls_today       = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day              = current_date;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END
$function$;

COMMENT ON FUNCTION public.sg_classify_events() IS
  'Refresh sg_event_priority_state tier per event. A1 mig 20260520210000 (CRITICAL hotfix): scan window shrunk 7d→24h to fit under cron statement_timeout. WATCH threshold scaled to >150/24h (was >500/7d). Column active_listings_last_7d retained for compat — value is now 24h count.';

-- Trigger one immediate run to refresh all tiers post-apply.
SELECT public.sg_classify_events();
