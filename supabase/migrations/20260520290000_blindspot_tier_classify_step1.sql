-- Migration 20260520290000 · lane:A1 · writes:sg_priority_policy,sg_classify_events · pre:20260520260000
--
-- STEP 1 of 5 — Blindspot tracking tier classification (no polling yet)
--
-- Goal (operator design 2026-05-18): track US SG events we don't own across
-- 24h–365d horizons, so a separate detection layer can flag events where
-- listings count moves ≥5% AND median price moves ≥10% over 48h. These
-- become "BLIND SPOTS — SG SELLING, WE'RE NOT" on the D0 home page.
--
-- This migration only does the tier-topology work. No polling change in
-- this step — that comes in Step 2 once we've verified events tag correctly.
--
-- Changes:
--   1. INSERT row into sg_priority_policy for tier 'TRACK_BLINDSPOT' with
--      enabled=false. The row exists for documentation + future polling
--      function reference, but the existing classify ELSE policy lookup
--      filters by p.enabled=true so it won't fall-through-assign this tier
--      to non-US events. US events get TRACK_BLINDSPOT via the explicit
--      CASE branch added below.
--   2. UPDATE existing SKIP sort_order 8 → 9 to leave room for
--      TRACK_BLINDSPOT (kept as sort_order=8, documentation only since
--      enabled=false).
--   3. CREATE OR REPLACE sg_classify_events with two new CASE branches
--      added BEFORE the existing ELSE policy lookup:
--         a. Early parking-SKIP: if name OR venue ILIKE '%parking%',
--            tier='SKIP'. Catches the 393 parking pseudo-events that
--            currently land in SKIP-by-policy-fallback and would otherwise
--            risk polling if we later expand OBSERVE.
--         b. US-state TRACK_BLINDSPOT: if hours_to_event between 24 and
--            8760 (1 year), owned_cnt=0, non-parking, and sg_venue_state
--            in the US state list, tier='TRACK_BLINDSPOT'.
--      All other CASE branches + ELSE byte-identical to mig 20260520260000.
--
-- VERIFICATION QUERIES (operator runs after apply, before Step 2):
--   -- Total TRACK_BLINDSPOT count (target: ~1,500–2,000, the non-parking
--   -- 24h–8760h US non-owned events)
--   SELECT tier, count(*) FROM public.sg_event_priority_state
--   GROUP BY tier ORDER BY 1;
--
--   -- Spot-check: every TRACK_BLINDSPOT event must have US venue + not parking
--   SELECT count(*) FILTER (WHERE sg_venue_name NOT ILIKE '%parking%'
--                            AND sg_event_name NOT ILIKE '%parking%') AS clean,
--          count(*)                                                    AS total
--   FROM public.sg_event_priority_state ps
--   JOIN public.sg_events_canonical c USING (sg_event_id)
--   WHERE ps.tier = 'TRACK_BLINDSPOT';
--   -- Expect clean == total.
--
--   -- Confirm parking events are SKIP'd, regardless of date
--   SELECT count(*) AS parking_skipped
--   FROM public.sg_event_priority_state ps
--   JOIN public.sg_events_canonical c USING (sg_event_id)
--   WHERE (c.sg_event_name ILIKE '%parking%' OR c.sg_venue_name ILIKE '%parking%')
--     AND ps.tier != 'SKIP';
--   -- Expect 0.

-- ============================================================
-- 1. Insert TRACK_BLINDSPOT policy row (enabled=false, documentation)
-- ============================================================
INSERT INTO public.sg_priority_policy
  (tier, label, interval_seconds, min_hours_to_event, max_hours_to_event,
   requires_owned, daily_polls_per_event, enabled, sort_order, notes)
VALUES
  ('TRACK_BLINDSPOT',
   'US events 24h-1yr, not owned — blindspot movers tracking',
   43200,            -- 12h
   24,
   8760,             -- 1 year
   false,
   2,                -- 2 polls/event/day (off-peak)
   false,            -- DISABLED in policy table on purpose: only classify CASE assigns this tier
   8,
   'Off-peak polling tier for US unmapped events. Cadence + state-gate live in sg_classify_events explicit CASE + the (future Step 2) sg_blindspot_poll_tick. Policy row is documentation only.')
ON CONFLICT (tier) DO UPDATE SET
  label                 = EXCLUDED.label,
  interval_seconds      = EXCLUDED.interval_seconds,
  min_hours_to_event    = EXCLUDED.min_hours_to_event,
  max_hours_to_event    = EXCLUDED.max_hours_to_event,
  requires_owned        = EXCLUDED.requires_owned,
  daily_polls_per_event = EXCLUDED.daily_polls_per_event,
  enabled               = EXCLUDED.enabled,
  sort_order            = EXCLUDED.sort_order,
  notes                 = EXCLUDED.notes,
  updated_at            = now();

-- 2. Push SKIP from sort_order 8 to 9 (defensive — TRACK_BLINDSPOT shouldn't
--    collide via ELSE lookup since enabled=false, but keep the topology clean)
UPDATE public.sg_priority_policy
   SET sort_order = 9, updated_at = now()
 WHERE tier = 'SKIP' AND sort_order = 8;


-- ============================================================
-- 3. CREATE OR REPLACE sg_classify_events with parking-SKIP and
--    explicit US-gated TRACK_BLINDSPOT branches
-- ============================================================
CREATE OR REPLACE FUNCTION public.sg_classify_events()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_updated int := 0;
  v_us_states text[] := ARRAY[
    'AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN','IA','KS','KY','LA','ME',
    'MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI',
    'SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY',
    'California','New York','Texas','Florida','Pennsylvania','Ohio','Illinois','Arizona','Washington',
    'Georgia','Massachusetts','North Carolina','Tennessee'
  ];
BEGIN
  WITH listings_by_tevo AS (
    SELECT event_id AS tevo_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '24 hours' AND event_id IS NOT NULL
    GROUP BY event_id
  ),
  listings_by_aq AS (
    SELECT aq_short_event_id,
           count(*) FILTER (WHERE is_owned = true) AS owned_cnt,
           count(*) AS listings_cnt
    FROM public.listings_snapshots
    WHERE captured_at > v_now - interval '24 hours' AND aq_short_event_id IS NOT NULL
    GROUP BY aq_short_event_id
  ),
  event_metrics AS (
    SELECT c.sg_event_id, c.sg_event_name, c.sg_venue_name, c.sg_venue_state,
           c.sg_datetime_utc,
           a.aq_short_event_id,
           coalesce(c.tevo_event_id,
                    (SELECT x.tevo_event_id FROM public.seatgeek_event_xref x
                     WHERE x.sg_event_id = c.sg_event_id LIMIT 1)) AS tevo_event_id,
           EXTRACT(epoch FROM (c.sg_datetime_utc - v_now)) / 3600 AS hours_to_event,
           coalesce(lt.owned_cnt,    la.owned_cnt,    0) AS owned_cnt,
           coalesce(lt.listings_cnt, la.listings_cnt, 0) AS listings_cnt
    FROM public.sg_events_canonical c
    LEFT JOIN LATERAL (
      SELECT aq_short_event_id
      FROM public.aq_event_map
      WHERE sg_event_id = c.sg_event_id
      ORDER BY (aq_short_event_id LIKE 'SYS-%') ASC, aq_short_event_id
      LIMIT 1
    ) a ON true
    LEFT JOIN listings_by_tevo lt ON lt.tevo_event_id = c.tevo_event_id
    LEFT JOIN listings_by_aq   la ON la.aq_short_event_id = a.aq_short_event_id
    WHERE c.sg_datetime_utc IS NOT NULL
      AND c.sg_datetime_utc BETWEEN v_now - interval '6 hours' AND v_now + interval '365 days'
  ),
  classified AS (
    SELECT em.*,
      CASE
        -- NEW: parking events always SKIP (no polling, no blindspot tracking)
        WHEN em.sg_event_name ILIKE '%parking%'
             OR em.sg_venue_name ILIKE '%parking%' THEN 'SKIP'
        WHEN em.sg_event_name ~* '(cancelled|if necessary)' THEN 'SKIP'
        WHEN em.sg_event_name ~* '(\(date tbd\)|^TBD at )'
             AND em.tevo_event_id IS NULL THEN 'SKIP'
        WHEN em.hours_to_event >= 0 AND em.hours_to_event < 168
             AND em.owned_cnt = 0 AND em.listings_cnt > 150 THEN 'WATCH'
        -- NEW: US-state blindspot tracking (24h–8760h, not owned, not parking)
        WHEN em.hours_to_event >= 24
             AND em.hours_to_event < 8760
             AND em.owned_cnt = 0
             AND em.sg_venue_state = ANY(v_us_states) THEN 'TRACK_BLINDSPOT'
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
