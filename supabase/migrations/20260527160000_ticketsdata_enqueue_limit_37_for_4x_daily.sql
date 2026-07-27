-- 20260527160000_ticketsdata_enqueue_limit_37_for_4x_daily.sql
--
-- Reduce td_enqueue_peak LIMIT from 40 → 37 so all 4 daily pull slots
-- fit within the 300 credit/day cap.
--
-- MATH:
--   37 events × 2 platforms (SH+VD) × 4 fires/day = 296 credits/day ≤ 300 ✓
--   Each peak slot (SH :00, VD :45) enqueues 37+37=74 events.
--   Pull drain processes them before the next slot fires 3h later.
--   Result: top 37 events (by owned_tickets DESC, median_retail_price DESC)
--   get exactly 4 pulls/day, one per peak slot.
--
-- NOTE: Adding GT (phase 2) will require revisiting this limit.
--   37 events × 3 platforms × 4 fires = 444/day → will need LIMIT ~25 or raise daily cap.

CREATE OR REPLACE FUNCTION public.td_enqueue_peak(
  p_platform     text    DEFAULT NULL,
  p_interval_tag text    DEFAULT 'manual'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  r         RECORD;
  v_count   int := 0;
  v_now     timestamptz := clock_timestamp();
  v_jobname text;
BEGIN
  v_jobname := CASE
    WHEN p_platform IS NOT NULL THEN 'td_enqueue_peak_' || lower(p_platform)
    ELSE 'td_enqueue_peak'
  END;

  IF NOT public.cron_should_fire(v_jobname) THEN RETURN 0; END IF;

  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_enqueue_peak(%): budget exhausted (daily or monthly), skipping', COALESCE(p_platform, 'all');
    RETURN 0;
  END IF;

  FOR r IN
    SELECT x.event_id, x.platform, x.event_url, x.always_on
    FROM public.ticketsdata_event_xref x
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = (
      SELECT aem.sg_event_id FROM public.aq_event_map aem
      WHERE aem.aq_short_event_id = x.aq_short_event_id
      LIMIT 1)
    WHERE x.active            = true
      AND x.event_url         IS NOT NULL
      AND x.enqueues_today    < 4
      AND (p_platform IS NULL OR x.platform = p_platform)
      AND (x.always_on = true OR sgc.sg_datetime_utc < v_now + interval '7 days')
      AND NOT EXISTS (
        SELECT 1 FROM public.td_pull_queue q
        WHERE q.event_id  = x.event_id
          AND q.platform  = x.platform
          AND q.resolved_at IS NULL)
    ORDER BY
      x.always_on            DESC,   -- pinned events (Knicks etc) always first
      x.owned_tickets        DESC NULLS LAST,   -- highest owned quantity first
      x.median_retail_price  DESC NULLS LAST,   -- then highest median price
      x.last_enqueued_at     NULLS FIRST        -- tie-break: least recently enqueued
    LIMIT 37   -- 37 × 2 platforms × 4 fires = 296 credits/day ≤ 300 cap
  LOOP
    INSERT INTO public.td_pull_queue
      (event_id, platform, event_url, interval_tag, created_at)
    VALUES (r.event_id, r.platform, r.event_url, p_interval_tag, v_now);

    UPDATE public.ticketsdata_event_xref
    SET last_enqueued_at = v_now,
        enqueues_today   = enqueues_today + 1,
        updated_at       = v_now
    WHERE (event_id, platform) = (r.event_id, r.platform);

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public.td_enqueue_peak(text, text) FROM anon, public;
COMMENT ON FUNCTION public.td_enqueue_peak(text, text) IS
  'Push (event×platform) pairs to td_pull_queue. '
  'Priority: always_on → owned_tickets DESC → median_retail_price DESC. '
  'LIMIT 37/call: 37 × 2 platforms × 4 fires = 296 credits/day (≤ 300 daily cap). '
  'p_platform scopes to one platform when called by staggered crons. '
  'Monthly budget gate + daily budget gate via td_budget_ok().';
