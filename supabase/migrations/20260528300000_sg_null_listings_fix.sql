-- 20260528300000_sg_null_listings_fix.sql
--
-- Fixes three compounding issues that caused SG listing data to go dark for
-- 141+ events within 14 days (started ~May 21, avg 6-7 day dark duration):
--
-- ROOT CAUSE CHAIN:
--   1. seatgeek_listings_snapshots rows swept after 24h TTL.
--   2. If sg_broker_listings_metrics_refresh_hourly missed a window, seatgeek_event_metrics
--      went stale → event_metrics_cte in sg_classify_events returned NULL owned/listings.
--   3. With owned_cnt = COALESCE(NULL, NULL, 0) = 0, owned events looked unowned.
--   4. Unowned US events → TRACK_BLINDSPOT (enabled=false in sg_priority_policy) or OBSERVE.
--   5. sg_priority_poll_tick skips TRACK_BLINDSPOT entirely → event never re-polled.
--   6. Data stays dark indefinitely (vicious cycle).
--
-- FIXES:
--   A. sg_classify_events: add 30d ownership fallback from event_metrics history.
--      When snapshot + fresh event_metrics are both NULL, look for any owned_tickets_count > 0
--      from event_metrics within 30 days. Prevents temporary data gap from demoting
--      owned events to unowned tier (TRACK_BLINDSPOT/OBSERVE).
--   B. sg_classify_events: COLD→COOL floor for events within 30d with missing data
--      (belt-and-suspenders — now that ownership fallback prevents COLD→TRACK_BLINDSPOT,
--      this only triggers for residual cases where owned_cnt_fallback is also exhausted).
--   C. Snapshot cron_policy: reduce min_interval 1440→1200 min. Morning snapshot at 13:30 UTC
--      was blocked when last_fire was at 16:02 UTC the prior day (21.5h < 24h). With 20h
--      interval, next fire at 13:30 + 20h gate = fires correctly (21.5h > 20h).
--   D. sweep-old-sg-listings: extend TTL 24h→48h. Gives sg_broker_listings_metrics_refresh_hourly
--      two full cycles to read snapshot data before it's swept.
--   E. One-time re-queue: reset last_polled_listings_at for stale events within 14d
--      so sg_priority_poll_tick and sg_blindspot_poll_5min process them on next runs.

-- ── A. Rewrite sg_classify_events() with ownership fallback + tier floor ────────

CREATE OR REPLACE FUNCTION public.sg_classify_events()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
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
  WITH
  -- ── Latest snapshot per event (sub-second on ~2,500 events) ──────────────────
  latest_snap AS (
    SELECT DISTINCT ON (s.event_id)
      s.event_id            AS tevo_event_id,
      s.evo_owned_tickets   AS owned_cnt,
      s.evo_tickets_count   AS listings_cnt
    FROM public.event_listing_snapshot_daily s
    WHERE s.event_id IS NOT NULL
    ORDER BY s.event_id,
             s.snapshot_date DESC,
             CASE s.snapshot_slot WHEN 'evening' THEN 3 WHEN 'midday' THEN 2 ELSE 1 END DESC
  ),

  -- ── Fresh event_metrics fallback (for events not yet in snapshot table) ───────
  latest_em AS (
    SELECT DISTINCT ON (em.event_id)
      em.event_id           AS tevo_event_id,
      em.owned_tickets_count AS owned_cnt,
      em.tickets_count      AS listings_cnt
    FROM public.event_metrics em
    ORDER BY em.event_id, em.captured_at DESC
  ),

  -- ── NEW: 30-day ownership fallback ───────────────────────────────────────────
  -- When both snapshot AND latest event_metrics return NULL, owned events are
  -- misidentified as unowned → downgraded to TRACK_BLINDSPOT (not polled by tick).
  -- This CTE finds any owned_tickets_count > 0 from event_metrics within 30 days.
  -- Used as a third-level fallback for owned_cnt ONLY — not for listings_cnt.
  -- As long as we owned tickets within 30 days, we preserve the owned-event tier.
  latest_owned_fallback AS (
    SELECT DISTINCT ON (em.event_id)
      em.event_id AS tevo_event_id,
      em.owned_tickets_count AS owned_cnt_fallback
    FROM public.event_metrics em
    WHERE em.owned_tickets_count > 0
      AND em.captured_at > now() - interval '30 days'
    ORDER BY em.event_id, em.captured_at DESC
  ),

  -- ── event data: sg_events_canonical + TEvo xref + hours_to_event ─────────────
  event_data AS (
    SELECT c.sg_event_id,
           c.sg_event_name,
           c.sg_venue_name,
           c.sg_venue_state,
           c.sg_datetime_utc,
           a.aq_short_event_id,
           coalesce(c.tevo_event_id,
                    (SELECT x.tevo_event_id FROM public.seatgeek_event_xref x
                     WHERE x.sg_event_id = c.sg_event_id LIMIT 1)) AS tevo_event_id,
           EXTRACT(epoch FROM (c.sg_datetime_utc - v_now)) / 3600 AS hours_to_event
    FROM public.sg_events_canonical c
    LEFT JOIN LATERAL (
      SELECT aq_short_event_id FROM public.aq_event_map
      WHERE sg_event_id = c.sg_event_id
      ORDER BY (aq_short_event_id LIKE 'SYS-%') ASC, aq_short_event_id
      LIMIT 1
    ) a ON true
    WHERE c.sg_datetime_utc IS NOT NULL
      AND c.sg_datetime_utc BETWEEN v_now - interval '6 hours' AND v_now + interval '365 days'
  ),

  event_metrics_cte AS (
    SELECT ed.*,
           -- owned_cnt: snapshot → latest event_metrics → 30d ownership fallback → 0
           -- The 30d fallback prevents temporarily-dark owned events from appearing unowned.
           coalesce(s.owned_cnt, m.owned_cnt, fb.owned_cnt_fallback, 0) AS owned_cnt,
           -- listings_cnt: snapshot → latest event_metrics → 0 (no 30d fallback for listings)
           coalesce(s.listings_cnt, m.listings_cnt, 0) AS listings_cnt,
           -- has_listings_data: true only when a non-NULL listing count exists from
           -- snapshot or latest event_metrics. Distinguishes data gap from confirmed zero.
           (s.listings_cnt IS NOT NULL OR m.listings_cnt IS NOT NULL) AS has_listings_data
    FROM event_data ed
    LEFT JOIN latest_snap          s  ON s.tevo_event_id  = ed.tevo_event_id
    LEFT JOIN latest_em            m  ON m.tevo_event_id  = ed.tevo_event_id
    LEFT JOIN latest_owned_fallback fb ON fb.tevo_event_id = ed.tevo_event_id
  ),

  classified AS (
    SELECT em.*,
      CASE
        WHEN em.sg_event_name ILIKE '%parking%'
             OR em.sg_venue_name ILIKE '%parking%' THEN 'SKIP'
        WHEN em.sg_event_name ~* '(cancelled|if necessary)' THEN 'SKIP'
        WHEN em.sg_event_name ~* '(\(date tbd\)|^TBD at )'
             AND em.tevo_event_id IS NULL THEN 'SKIP'
        WHEN em.hours_to_event >= 0 AND em.hours_to_event < 168
             AND em.owned_cnt = 0 AND em.listings_cnt > 150 THEN 'WATCH'
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
      END AS raw_tier
    FROM event_metrics_cte em
  ),

  -- ── NEW: Minimum-tier floor (belt-and-suspenders) ────────────────────────────
  -- Catches any residual COLD events within 30d where listing data is still missing
  -- after the ownership fallback (e.g. event never had event_metrics rows, or
  -- fallback window expired). Promotes COLD → COOL (30-min vs 4-hour interval)
  -- to break any remaining vicious-cycle cases.
  -- SKIP / WATCH / TRACK_BLINDSPOT / OBSERVE are unchanged.
  tier_floored AS (
    SELECT c.*,
      CASE
        WHEN c.raw_tier = 'COLD'
         AND NOT c.has_listings_data
         AND c.hours_to_event BETWEEN 0 AND 720
        THEN 'COOL'
        ELSE coalesce(c.raw_tier, 'SKIP')
      END AS tier
    FROM classified c
  )
  INSERT INTO public.sg_event_priority_state AS s
    (sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
     tevo_event_id, owned_count_last_7d, active_listings_last_7d, tier, hours_to_event, computed_at)
  SELECT sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc, aq_short_event_id,
         tevo_event_id, owned_cnt, listings_cnt, tier, hours_to_event, v_now
  FROM tier_floored WHERE sg_event_id IS NOT NULL
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
    sales_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day           = current_date;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$$;
REVOKE ALL ON FUNCTION public.sg_classify_events() FROM anon, public;
COMMENT ON FUNCTION public.sg_classify_events() IS
  'REWRITTEN 2026-05-27 (mig 240000): replaced listings_snapshots 24h full-table scan with '
  'event_listing_snapshot_daily + event_metrics fallback. '
  'UPDATED 2026-05-28 (mig 300000): added 30d ownership fallback (latest_owned_fallback CTE) '
  'to prevent owned events being demoted to TRACK_BLINDSPOT/OBSERVE during data gaps. '
  'Added has_listings_data flag and COLD→COOL floor for belt-and-suspenders gap protection. '
  'Root cause: 24h sweep TTL + slow metrics refresh → owned_cnt coalesced to 0 → '
  'TRACK_BLINDSPOT (enabled=false) → tick skipped event → permanent dark.';


-- ── B. Snapshot cron_policy: reduce min_interval 1440 → 1200 ────────────────────
-- event_snapshot_morning fires daily at 13:30 UTC.
-- On 2026-05-27 it fired at 16:02 UTC. Next 13:30 fire = 21.5h gap.
-- 21.5h < 24h (1440min) → skip_offpeak. Missed today entirely.
-- With 1200min (20h): 21.5h > 20h → fires. Future same-day-late fires won't block tomorrow.

UPDATE public.cron_policy SET
  peak_min_interval_min    = 1200,
  offpeak_min_interval_min = 1200,
  notes = notes || ' | 2026-05-28 mig 300000: reduced 1440→1200 min to allow 20h gap '
                || '(morning snapshot at 13:30 was blocked by 21.5h gap < 24h)'
WHERE jobname IN ('event_snapshot_morning', 'event_snapshot_midday', 'event_snapshot_evening');


-- ── C. sweep-old-sg-listings: extend TTL 24h → 48h ──────────────────────────────
-- seatgeek_listings_snapshots data was being swept after 24h. If sg_broker_listings_
-- metrics_refresh_hourly ran late or missed a window, the snapshot data was gone
-- before metrics could be updated — contributing to the ownership-loss cycle.
-- 48h gives two full refresh cycles of buffer.
-- Steady-state table size impact: ~2× (108 MB/run × 4 runs × 2 days = ~864 MB steady-state
-- vs ~432 MB before). Well within budget at ~1.3M rows total.

DO $sched$ BEGIN
  PERFORM cron.schedule(
    'sweep-old-sg-listings',
    '15 3,9,15,21 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('sweep-old-sg-listings') THEN RETURN; END IF;
      PERFORM public.sweep_old_sg_listings(48);
    END $b$;$cron$
  );
END $sched$;

UPDATE public.cron_policy SET
  notes = 'SG listings sweep: DELETE seatgeek_listings_snapshots WHERE captured_at < now()-48h. '
          '4x/day at 3:15/9:15/15:15/21:15 UTC. '
          'Changed from 24h→48h TTL 2026-05-28 (mig 300000): prevents data gap between '
          'SG poll and sg_broker_listings_metrics_refresh_hourly when refresh misses a window. '
          '48h buffer = 2 full hourly refresh cycles. '
          'Steady-state ~864 MB (was ~432 MB). First 48h run deletes prior 24h backlog.'
WHERE jobname = 'sweep-old-sg-listings';


-- ── D. One-time re-queue: reset stale last_polled_listings_at ────────────────────
-- Events within 14d that haven't been polled in 23+ hours are immediately eligible
-- on the next sg_priority_poll_tick and sg_blindspot_poll_5min runs.
-- Targets: TRACK_BLINDSPOT, WATCH, COLD, OBSERVE (not SKIP/HOT/WARM/COOL).
-- HOT/WARM/COOL are actively managed with short intervals — no reset needed.
-- SKIP events are intentionally excluded from polling.
-- Setting to now()-25h ensures eligibility on next tick without disrupting HOT/WARM events.

UPDATE public.sg_event_priority_state SET
  last_polled_listings_at = now() - interval '25 hours'
WHERE sg_datetime_utc BETWEEN now() AND now() + interval '14 days'
  AND tier NOT IN ('SKIP', 'HOT', 'WARM', 'COOL')
  AND (last_polled_listings_at IS NULL
       OR last_polled_listings_at < now() - interval '23 hours');

-- Log the fix to bot_chat for tracking
PERFORM public.bot_chat_log(
  'data-collection', 'D0', 'status',
  'mig 300000 applied: sg_classify_events rewritten (30d ownership fallback + COLD→COOL floor). '
  'Snapshot cron_policy min_interval 1440→1200 min. '
  'sweep-old-sg-listings TTL 24h→48h. '
  'One-time re-queue: reset last_polled_listings_at for stale TRACK_BLINDSPOT/WATCH/COLD/OBSERVE events within 14d.'
);
