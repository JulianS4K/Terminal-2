-- Migration 20260520000000 · lane:A1 · writes:sg_priority_policy+sg_classify_events · pre:20260519180000 · auth:operator-approved 2026-05-18
--
-- Add WATCH tier — 30-min cadence for active non-owned SG markets.
--
-- User-reported "Milwaukee Brewers at Chicago Cubs, no sg sales showing"
-- (tonight's MLB game, 8h to event, 12k SG listings). Investigation:
--
--   • All 3 Brewers-Cubs games classified tier='OBSERVE' since 2026-05-17
--   • OBSERVE = 12h cadence, 2 polls/event/day (cap), sort_order=5
--   • Only 2 of 840 OBSERVE events polled today — budget starved
--   • HOT/WARM/COOL ate the priority cron's ~864 sales-polls/day budget first
--
-- Root cause: HOT/WARM/COOL/COLD all gate on `requires_owned=true`. Brewers
-- inventory isn't ours → falls through to OBSERVE → starved. But these are
-- LIQUID third-party markets (12k listings) that we need intel on for broker
-- activity / opportunity detection.
--
-- Fix: new WATCH tier between COOL and COLD (sort_order=5):
--   interval_seconds:    1800  (30 min)
--   max_hours_to_event:  168   (7 days)
--   requires_owned:      false
--   daily_polls_per_event: 24  (1/hr equivalent)
--
-- Classifier gates WATCH on `active_listings_last_7d > 500` to exclude
-- quiet far-future events. Without the gate, sort_order=5 would consume
-- ALL non-owned events 0-168h regardless of liquidity.
--
-- ~53 active-market events expected to graduate from OBSERVE → WATCH.
-- Cost: 53 × 24 = 1,272 polls/day added to existing ~864/day budget. Burst
-- cap per tick (6 = 3 sales + 3 listings since PR #228) will spread the
-- load; if pressure shows, follow-up to bump p_max_polls 6→10.

-- ============================================================
-- 1. Add WATCH tier (between COOL and COLD)
-- ============================================================
INSERT INTO public.sg_priority_policy
  (tier, label, interval_seconds, min_hours_to_event, max_hours_to_event,
   requires_owned, daily_polls_per_event, enabled, sort_order, notes)
VALUES (
  'WATCH', 'Active market, not owned', 1800, 0, 168, false, 24, true, 5,
  '30-min cadence for liquid third-party markets we do not own. Classifier gates this on active_listings_last_7d > 500 to avoid pulling quiet far-future events into WATCH.'
)
ON CONFLICT (tier) DO UPDATE SET
  label=EXCLUDED.label,
  interval_seconds=EXCLUDED.interval_seconds,
  min_hours_to_event=EXCLUDED.min_hours_to_event,
  max_hours_to_event=EXCLUDED.max_hours_to_event,
  requires_owned=EXCLUDED.requires_owned,
  daily_polls_per_event=EXCLUDED.daily_polls_per_event,
  enabled=true,
  sort_order=EXCLUDED.sort_order,
  notes=EXCLUDED.notes,
  updated_at=now();

-- Shift COLD/OBSERVE/SKIP sort_order to make room
UPDATE public.sg_priority_policy SET sort_order=6, updated_at=now() WHERE tier='COLD';
UPDATE public.sg_priority_policy SET sort_order=7, updated_at=now() WHERE tier='OBSERVE';
UPDATE public.sg_priority_policy SET sort_order=8, updated_at=now() WHERE tier='SKIP';

-- ============================================================
-- 2. Update sg_classify_events with explicit WATCH branch
-- ============================================================
-- Reasoning for the explicit CASE arm (vs pure table-driven sort_order
-- lookup): the policy lookup picks the first matching tier. Without
-- requires_owned, WATCH and OBSERVE both match the same 0-168h window —
-- sort_order alone would put EVERY non-owned event into WATCH including
-- quiet 30-day-out games. The explicit `listings_cnt > 500` gates it.

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
  WITH listings_by_tevo AS (
    SELECT event_id AS tevo_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days'
      AND event_id IS NOT NULL
    GROUP BY event_id
  ),
  listings_by_aq AS (
    SELECT aq_short_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '7 days'
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
        -- Definitive skip (mig 20260519170000): cancelled / if-necessary always SKIP
        WHEN em.sg_event_name ~* '(cancelled|if necessary)' THEN 'SKIP'
        -- Provisional skip (mig 20260519170000): TBD markers only when no TEvo bridge
        WHEN em.sg_event_name ~* '(\(date tbd\)|^TBD at )'
             AND em.tevo_event_id IS NULL THEN 'SKIP'
        -- A1 mig 20260520000000: WATCH supersedes OBSERVE for active non-owned
        -- markets within 7d. Threshold: >500 distinct listings in last 7d.
        WHEN em.hours_to_event >= 0
             AND em.hours_to_event < 168
             AND em.owned_cnt = 0
             AND em.listings_cnt > 500 THEN 'WATCH'
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
  'Refresh sg_event_priority_state tier per event. A1 mig 20260520000000: added WATCH tier branch (30-min cadence for non-owned markets <168h with >500 listings/7d). Catches liquid third-party markets the operator wants intel on (e.g. MLB games we do not own). Mig 20260519170000 SKIP-regex split preserved.';

-- ============================================================
-- 3. Verification probes (commented — run post-apply)
-- ============================================================
--
-- -- Confirm WATCH picked up the Brewers-Cubs games after next classifier run:
-- SELECT sg_event_id, sg_event_name, tier, hours_to_event, active_listings_last_7d
-- FROM public.sg_event_priority_state
-- WHERE sg_event_id IN (17695183, 17695182, 17695184);
--
-- -- Confirm polling resumed within 5-10 min:
-- SELECT sg_event_id, last_polled_sales_at, sales_polls_today
-- FROM public.sg_event_priority_state
-- WHERE sg_event_id IN (17695183, 17695182, 17695184);
--
-- -- Confirm no quota blowup:
-- SELECT * FROM public.v_sg_broker_429_health
-- WHERE hour_bucket > now() - interval '2 hours';
--
-- -- Game-1 anomaly probe (sg 17695183 had 0 distinct sales ever despite 629 listings):
-- SELECT net.http_get(
--   url := 'https://brokerdata.seatgeek.com/sales?token=' ||
--          public.get_app_secret('SEATGEEK_API_TOKEN') ||
--          '&event_id=17695183',
--   timeout_milliseconds := 30000
-- );
-- -- Wait ~30s, then check the response status + sales array length.
