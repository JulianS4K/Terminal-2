-- 20260527240000_sg_classify_events_fix_snapshot_basis.sql
--
-- URGENT: sg_classify_events_5min has been timing out at 120s since ~08:40 UTC today
-- (95+ consecutive failures). Root cause: function scans listings_snapshots (12.7M rows,
-- 6.8 GB) TWICE via listings_by_tevo and listings_by_aq CTEs for a 24h window.
--
-- Fix: replace both full-table scan CTEs with a DISTINCT ON join on
-- event_listing_snapshot_daily (latest snapshot per event — at most a few thousand rows).
-- Fallback to event_metrics (latest row per event) for events not yet in the snapshot table
-- (snapshot started 2026-05-27, so some events may have no snapshot row yet today).
--
-- Also: update sweep-old-listings cron from 1×/day to 4×/day (listings_snapshots grows
-- ~400K rows/day; 30-day TTL starts deleting rows from ~April 27 onward now).

-- ── 1. Rewrite sg_classify_events() ─────────────────────────────────────────

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
  -- ── NEW: replace 24h listings_snapshots scan with snapshot table lookup ──
  -- DISTINCT ON gets the most recent snapshot slot per event (sub-second on ~2,500 events)
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

  -- ── FALLBACK: event_metrics (latest row per event) for events with no snapshot yet ──
  -- event_listing_snapshot_daily started 2026-05-27; all events should have a row within 24h.
  -- After the first full day this fallback is a no-op for active events.
  latest_em AS (
    SELECT DISTINCT ON (em.event_id)
      em.event_id           AS tevo_event_id,
      em.owned_tickets_count AS owned_cnt,
      em.tickets_count      AS listings_cnt
    FROM public.event_metrics em
    ORDER BY em.event_id, em.captured_at DESC
  ),

  -- ── event data: same sg_events_canonical join as before, new metric source ──
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
           -- snapshot first, fallback to latest event_metrics row
           coalesce(s.owned_cnt,    m.owned_cnt,    0) AS owned_cnt,
           coalesce(s.listings_cnt, m.listings_cnt, 0) AS listings_cnt
    FROM event_data ed
    LEFT JOIN latest_snap s ON s.tevo_event_id = ed.tevo_event_id
    LEFT JOIN latest_em   m ON m.tevo_event_id = ed.tevo_event_id
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
      END AS tier
    FROM event_metrics_cte em
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
    sales_polls_today    = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.sales_polls_today END,
    listings_polls_today = CASE WHEN s.budget_day < current_date THEN 0 ELSE s.listings_polls_today END,
    budget_day           = current_date;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RETURN v_updated;
END;
$$;
REVOKE ALL ON FUNCTION public.sg_classify_events() FROM anon, public;
COMMENT ON FUNCTION public.sg_classify_events() IS
  'REWRITTEN 2026-05-27: replaced listings_snapshots 24h full-table scan with '
  'event_listing_snapshot_daily (DISTINCT ON latest per event) + event_metrics fallback. '
  'Was timing out at 120s on every 5-min fire due to 12.7M-row scan. '
  'Sub-second with snapshot basis. Tier logic unchanged.';

-- ── 2. Fix sweep-old-listings cron: 1×/day → 4×/day ────────────────────────
-- listings_snapshots was growing ~400K rows/day unchecked (30-day TTL starts
-- deleting rows from ~April 27 now that the table is 34 days old).
-- Run 4×/day to stay ahead of growth. Keep 30-day TTL (safe, no timeout risk).

DO $sched$ BEGIN
  -- Reschedule from 0 3 * * * to 4×/day
  PERFORM cron.schedule(
    'sweep-old-listings',
    '20 3,9,15,21 * * *',
    $cron$DO $b$ BEGIN
      IF NOT public.cron_should_fire('sweep-old-listings') THEN RETURN; END IF;
      PERFORM public.sweep_old_listings();
    END $b$;$cron$
  );
END $sched$;

-- Update cron_policy to reflect 4×/day cadence
UPDATE public.cron_policy SET
  peak_min_interval_min    = 360,
  offpeak_min_interval_min = 360,
  daily_max_fires          = 4,
  notes = 'TTL sweep: DELETE FROM listings_snapshots WHERE captured_at < now()-30d. '
          '4x/day at 3:20/9:20/15:20/21:20 UTC (was 1x/day). '
          '30-day TTL now deleting rows from ~April 27 (table 34d old). '
          'Upgraded 2026-05-27. '
          'NOTE: sg_classify_events() no longer reads from listings_snapshots (rewritten 2026-05-27) '
          'so this table is now pure archive. TTL reduction to 7d pending batched cleanup strategy.',
  updated_at = now()
WHERE jobname = 'sweep-old-listings';
