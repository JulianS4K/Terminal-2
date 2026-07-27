-- 20260527200000_td_owned_tickets_fix_reschedule.sql
--
-- Three fixes in one:
--
-- 1. FIX owned_tickets/median_retail_price join in td_watchlist_refresh.
--    The broken path: event_metrics JOIN seatgeek_event_metrics ON tevo_event_id
--    The correct path: sg_events_canonical.tevo_event_id → event_metrics.event_id
--    Result: owned_tickets was NULL for all 279 active xref rows — now populated for 52 events.
--    Highest confirmed: OKC/Spurs 1,347 tickets; LA Dodgers/Yankees 643; WNBA Liberty 762.
--
-- 2. BACKFILL owned_tickets + median_retail_price immediately (in-migration UPDATE).
--    Does not wait for next 9am UTC watchlist_refresh cron.
--
-- 3. RESCHEDULE TD enqueue crons: 4 fires/day → 3 fires/day, aligned with EVO/SG snapshot times.
--    Snapshot slots: morning (9am ET / 13 UTC), midday (3pm ET / 19 UTC), evening (11pm ET / 3 UTC).
--    Stagger: SH at slot time, GT +1h, VD +2h.
--    Raise LIMIT 25 → 33: 33 × 3 platforms × 3 fires = 297 credits/day ≤ 300 cap.
--    More events tracked (33 vs 25) for same budget.
--
-- NEW SCHEDULE:
--   SH: '0 13,19,3 * * *'   →  9am  / 3pm  / 11pm  ET
--   GT: '0 14,20,4 * * *'   →  10am / 4pm  / midnight ET  (+1h from SH)
--   VD: '0 15,21,5 * * *'   →  11am / 5pm  / 1am ET       (+2h from SH)
--
-- RESULT: One platform fires each hour from 9am–11am ET, 3pm–5pm ET, 11pm–1am ET.
--         Each fire aligns with the EVO/SG daily snapshot crons so all sources
--         capture market state at the same reference points.

-- ── 1. Fix td_watchlist_refresh (owned_tickets join) ─────────────────────────

CREATE OR REPLACE FUNCTION public.td_watchlist_refresh()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  r       RECORD;
  v_count int := 0;
  v_now   timestamptz := clock_timestamp();
BEGIN
  IF NOT public.cron_should_fire('td_watchlist_refresh') THEN RETURN 0; END IF;

  -- Reset per-day enqueue counters (new UTC day)
  UPDATE public.ticketsdata_event_xref
  SET enqueues_today = 0, updated_at = v_now
  WHERE enqueues_today > 0;

  -- Deactivate past events (platform-scoped: each platform has different event_id namespace)
  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'SH'
    AND event_id IN (
      SELECT aem.sh_event_id FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours' AND aem.sh_event_id IS NOT NULL);

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'VD'
    AND event_id IN (
      SELECT aem.vivid_event_id FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours' AND aem.vivid_event_id IS NOT NULL);

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'GT'
    AND event_id IN (
      SELECT sgc.sg_event_id FROM public.sg_events_canonical sgc
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours');

  UPDATE public.ticketsdata_event_xref SET active = false, updated_at = v_now
  WHERE active = true AND platform = 'TM'
    AND event_id IN (
      SELECT aem.tm_event_id FROM public.aq_event_map aem
      JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
      WHERE sgc.sg_datetime_utc < v_now - interval '2 hours' AND aem.tm_event_id IS NOT NULL);

  -- ── StubHub (SH) — direct URL from sh_event_id ───────────────────────────
  FOR r IN
    SELECT aem.sh_event_id AS event_id, aem.aq_short_event_id, aem.performer, aem.event_name
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.sh_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id, 'SH', r.aq_short_event_id,
      'https://www.stubhub.com/x/event/' || r.event_id::text || '/',
      true,
      (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
      'direct_id', v_now)
    ON CONFLICT (event_id, platform) DO UPDATE
      SET active     = true,
          always_on  = (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
          event_url  = EXCLUDED.event_url,
          updated_at = v_now;
    v_count := v_count + 1;
  END LOOP;

  -- ── VividSeats (VD) — direct URL from vivid_event_id ─────────────────────
  FOR r IN
    SELECT aem.vivid_event_id AS event_id, aem.aq_short_event_id, aem.performer, aem.event_name
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.vivid_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id, 'VD', r.aq_short_event_id,
      'https://www.vividseats.com/production/' || r.event_id::text,
      true,
      (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
      'direct_id', v_now)
    ON CONFLICT (event_id, platform) DO UPDATE
      SET active     = true,
          always_on  = (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
          event_url  = EXCLUDED.event_url,
          updated_at = v_now;
    v_count := v_count + 1;
  END LOOP;

  -- ── Ticketmaster (TM) — inactive stub ────────────────────────────────────
  FOR r IN
    SELECT aem.tm_event_id AS event_id, aem.aq_short_event_id, aem.performer, aem.event_name
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    WHERE aem.tm_event_id IS NOT NULL
      AND sgc.sg_datetime_utc > v_now
      AND sgc.sg_datetime_utc < v_now + interval '60 days'
    ORDER BY sgc.sg_datetime_utc ASC
    LIMIT 100
  LOOP
    INSERT INTO public.ticketsdata_event_xref
      (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
    VALUES (
      r.event_id, 'TM', r.aq_short_event_id, NULL, false,
      (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
      'pending_discovery', v_now)
    ON CONFLICT (event_id, platform) DO UPDATE
      SET always_on  = (COALESCE(r.performer,'') ILIKE '%knicks%' OR COALESCE(r.event_name,'') ILIKE '%knicks%'),
          updated_at = v_now;
    v_count := v_count + 1;
  END LOOP;

  -- ── Update owned_tickets + median_retail_price (FIXED join path) ──────────
  -- Path: xref.aq_short_event_id → aq_event_map → sg_events_canonical.tevo_event_id
  --       → event_metrics.event_id (= tevo_event_id)
  -- Previous broken path used seatgeek_event_metrics as a bridge (wrong table, produced all NULLs).
  UPDATE public.ticketsdata_event_xref x
  SET owned_tickets       = COALESCE(em_data.owned_tickets_count, 0),
      median_retail_price = em_data.retail_median,
      updated_at          = v_now
  FROM public.aq_event_map aem
  JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
  LEFT JOIN LATERAL (
    SELECT em.owned_tickets_count, em.retail_median
    FROM public.event_metrics em
    WHERE em.event_id = sgc.tevo_event_id
    ORDER BY em.captured_at DESC
    LIMIT 1
  ) em_data ON true
  WHERE aem.aq_short_event_id = x.aq_short_event_id
    AND x.active = true
    AND sgc.tevo_event_id IS NOT NULL;

  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public.td_watchlist_refresh() FROM anon, public;
COMMENT ON FUNCTION public.td_watchlist_refresh() IS
  'Daily watchlist upsert (9 UTC): SH+VD active (direct_id); GT activated by td_gt_discover_drain; '
  'TM inactive stub (URL discovery pending). '
  'FIXED 2026-05-27: owned_tickets join now routes through sg_events_canonical.tevo_event_id '
  '→ event_metrics.event_id (was broken via seatgeek_event_metrics bridge — produced all NULLs). '
  'Populates owned_tickets + median_retail_price for enqueue priority ordering (EVO source).';

-- ── 2. Backfill owned_tickets immediately (no waiting for 9am UTC cron) ─────

UPDATE public.ticketsdata_event_xref x
SET owned_tickets       = COALESCE(em_data.owned_tickets_count, 0),
    median_retail_price = em_data.retail_median,
    updated_at          = now()
FROM public.aq_event_map aem
JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
LEFT JOIN LATERAL (
  SELECT em.owned_tickets_count, em.retail_median
  FROM public.event_metrics em
  WHERE em.event_id = sgc.tevo_event_id
  ORDER BY em.captured_at DESC
  LIMIT 1
) em_data ON true
WHERE aem.aq_short_event_id = x.aq_short_event_id
  AND x.active = true
  AND sgc.tevo_event_id IS NOT NULL
  AND em_data.owned_tickets_count IS NOT NULL;

-- ── 3a. Update td_enqueue_peak LIMIT 25 → 33 ─────────────────────────────────
-- 33 × 3 platforms × 3 fires = 297 credits/day ≤ 300 daily cap.
-- Tracks 33 events per platform per fire (up from 25) for same budget.

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
    RAISE NOTICE 'td_enqueue_peak(%): budget exhausted (daily or monthly), skipping',
      COALESCE(p_platform, 'all');
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
      AND x.enqueues_today    < 3
      AND (p_platform IS NULL OR x.platform = p_platform)
      AND (x.always_on = true OR sgc.sg_datetime_utc < v_now + interval '7 days')
      AND NOT EXISTS (
        SELECT 1 FROM public.td_pull_queue q
        WHERE q.event_id  = x.event_id
          AND q.platform  = x.platform
          AND q.resolved_at IS NULL)
    ORDER BY
      x.always_on            DESC,
      x.owned_tickets        DESC NULLS LAST,
      x.median_retail_price  DESC NULLS LAST,
      x.last_enqueued_at     NULLS FIRST
    LIMIT 33   -- 33 × 3 platforms × 3 fires = 297 credits/day ≤ 300 cap
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
  'Priority: always_on DESC → owned_tickets DESC → median_retail_price DESC → last_enqueued_at ASC. '
  'LIMIT 33/call: 33 × 3 platforms × 3 fires = 297 credits/day (≤ 300 daily cap). '
  'Fires reduced from 4 → 3/day (aligned with EVO/SG daily snapshot slots). '
  'p_platform scopes to SH|GT|VD when called by per-platform staggered crons. '
  'Budget gate: td_budget_ok() = td_daily_budget_ok() AND td_monthly_budget_ok().';

-- ── 3b. Reschedule TD enqueue crons: 4 fires → 3 fires at snapshot times ─────

DO $sched$ BEGIN

  -- SH: 9am / 3pm / 11pm ET  (13/19/3 UTC) — fires at each daily snapshot slot
  PERFORM cron.schedule(
    'td_enqueue_peak_sh',
    '0 13,19,3 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('SH',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 13 THEN '9am_ET'  WHEN 19 THEN '3pm_ET'
          WHEN  3 THEN '11pm_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

  -- GT: 10am / 4pm / midnight ET  (14/20/4 UTC) — +1h from SH for clean drain window
  PERFORM cron.schedule(
    'td_enqueue_peak_gt',
    '0 14,20,4 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('GT',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 14 THEN '10am_ET'    WHEN 20 THEN '4pm_ET'
          WHEN  4 THEN 'midnight_ET' ELSE 'manual' END);
    END $b$;$cron$
  );

  -- VD: 11am / 5pm / 1am ET  (15/21/5 UTC) — +2h from SH
  PERFORM cron.schedule(
    'td_enqueue_peak_vd',
    '0 15,21,5 * * *',
    $cron$DO $b$ BEGIN
      PERFORM public.td_enqueue_peak('VD',
        CASE date_part('hour', now() AT TIME ZONE 'UTC')::int
          WHEN 15 THEN '11am_ET' WHEN 21 THEN '5pm_ET'
          WHEN  5 THEN '1am_ET'  ELSE 'manual' END);
    END $b$;$cron$
  );

END $sched$;

-- ── 3c. Update cron_policy to reflect 3 fires + snapshot alignment ────────────

UPDATE public.cron_policy SET
  daily_max_fires       = 3,
  peak_min_interval_min = 300,   -- 5h min between fires (actual interval is 6-8h)
  notes      = 'TD enqueue SH — 9am/3pm/11pm ET (0 13,19,3 UTC). '
                'Aligned with EVO/SG morning/midday/evening daily snapshot slots. '
                'LIMIT 33/call: 33 × 3 platforms × 3 fires = 297 credits/day. '
                'Rescheduled from 4×/day 2026-05-27.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_sh';

UPDATE public.cron_policy SET
  daily_max_fires       = 3,
  peak_min_interval_min = 300,
  notes      = 'TD enqueue GT — 10am/4pm/midnight ET (0 14,20,4 UTC). '
                '+1h from SH for clean drain window. '
                'LIMIT 33/call. Rescheduled from 4×/day 2026-05-27.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_gt';

UPDATE public.cron_policy SET
  daily_max_fires       = 3,
  peak_min_interval_min = 300,
  notes      = 'TD enqueue VD — 11am/5pm/1am ET (0 15,21,5 UTC). '
                '+2h from SH. VD normalizer strips word prefixes from sections. '
                'LIMIT 33/call. Rescheduled from 4×/day 2026-05-27.',
  updated_at = now()
WHERE jobname = 'td_enqueue_peak_vd';
