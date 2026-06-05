-- 20260529120000_td_focus_yankees_home_knicks_playoff.sql
-- Lane: A1 / td (TicketsData collector)
-- Operator directive (2026-05-29):
--   Track ONLY (a) the next 20 New York Yankees HOME games and
--   (b) all remaining New York Knicks PLAYOFF games via TicketsData.
--   STOP tracking every other event currently in the watchlist.
--
-- WHY this needs a code change (not just flag flips):
--   Two daily crons repopulate the watchlist, so deactivating rows alone
--   would be undone the next morning:
--     - td_watchlist_refresh()      09:00 UTC  -> re-adds next-100-by-date (SH/VD/TM)
--     - td_gt_discover()/_drain()   09:15/09:20 -> re-adds GT via performer allowlist
--   So we make the *selection logic* target-only and scope the GT allowlist.
--
-- Also fixes td_enqueue_peak(): the live version INNER JOINs sg_events_canonical,
--   so any xref row whose event has no sg_event_id can NEVER be enqueued. 6 of the
--   7 trackable Knicks playoff placeholders are sg-less, so without this fix they
--   would sit active+always_on but never actually fetch. Switch to LEFT JOIN with a
--   COALESCE(sg_datetime_utc, aem.event_date) date fallback.
--
-- NOTE: All remaining Knicks games in the source are speculative "(If Necessary)"
--   playoff placeholders (the real Finals schedule is not yet in the DB; opponent
--   shows TBD). We track all that carry SH/VD marketplace IDs (7); the lone
--   marketplace-id-less SYS placeholder is naturally excluded.

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 1) Helper: the canonical target event set (single source of truth)
--    (a) next 20 Yankees HOME games   -> name "... at New York Yankees"
--    (b) all remaining Knicks PLAYOFF -> future + playoff-tagged name
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_target_events()
 RETURNS TABLE(aq_short_event_id text, sh_event_id bigint, vivid_event_id bigint, sg_event_id bigint)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH yankees AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_name ILIKE '%at New York Yankees%'
      AND aem.event_name NOT ILIKE '%parking%'
      AND aem.event_date > now()
    ORDER BY aem.event_date ASC
    LIMIT 20
  ),
  knicks AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_name ILIKE '%knicks%'
      AND aem.event_date > now()
      AND aem.event_name NOT ILIKE '%parking%'
      AND aem.event_name NOT ILIKE '%season ticket%'
      AND ( aem.event_name ILIKE '%finals%'
         OR aem.event_name ILIKE '%playoff%'
         OR aem.event_name ILIKE '%round %'
         OR aem.event_name ILIKE '%conference%'
         OR aem.event_name ILIKE '%if necessary%'
         OR aem.event_name ~* 'game [0-9]' )
  )
  SELECT y.aq_short_event_id, y.sh_event_id, y.vivid_event_id, y.sg_event_id FROM yankees y
  UNION
  SELECT k.aq_short_event_id, k.sh_event_id, k.vivid_event_id, k.sg_event_id FROM knicks k;
$function$;

REVOKE ALL ON FUNCTION public.td_target_events() FROM PUBLIC;

-- ───────────────────────────────────────────────────────────────────────────
-- 2) Helper: apply the target set (ungated, callable directly)
--    - upsert SH + VD target rows (active=true, always_on=true => fetch now)
--    - deactivate every active row that is NOT a current target
--    - refresh owned_tickets / median_retail_price enrichment
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_apply_targets()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count int := 0;
  v_now   timestamptz := now();
BEGIN
  -- SH targets
  WITH t AS (SELECT * FROM public.td_target_events() WHERE sh_event_id IS NOT NULL)
  INSERT INTO public.ticketsdata_event_xref
    (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
  SELECT t.sh_event_id, 'SH', t.aq_short_event_id,
         'https://www.stubhub.com/x/event/' || t.sh_event_id::text || '/',
         true, true, 'direct_id', v_now
  FROM t
  ON CONFLICT (event_id, platform) DO UPDATE
    SET active = true, always_on = true,
        event_url = EXCLUDED.event_url, updated_at = v_now;
  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- VD targets
  WITH t AS (SELECT * FROM public.td_target_events() WHERE vivid_event_id IS NOT NULL)
  INSERT INTO public.ticketsdata_event_xref
    (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
  SELECT t.vivid_event_id, 'VD', t.aq_short_event_id,
         'https://www.vividseats.com/production/' || t.vivid_event_id::text,
         true, true, 'direct_id', v_now
  FROM t
  ON CONFLICT (event_id, platform) DO UPDATE
    SET active = true, always_on = true,
        event_url = EXCLUDED.event_url, updated_at = v_now;

  -- Deactivate everything that is not a current target.
  -- Target (event_id, platform) pairs: SH/VD by marketplace id, GT by sg_event_id
  -- (GT rows are discovery-managed and Yankees-only via td_gt_performers scoping).
  UPDATE public.ticketsdata_event_xref x
  SET active = false, updated_at = v_now
  WHERE x.active = true
    AND NOT EXISTS (
      SELECT 1 FROM public.td_target_events() t
      WHERE (x.platform = 'SH' AND x.event_id = t.sh_event_id)
         OR (x.platform = 'VD' AND x.event_id = t.vivid_event_id)
         OR (x.platform = 'GT' AND x.event_id = t.sg_event_id)
    );

  -- GT target rows are discovery-managed (always_on defaults false). Flip the
  -- surviving Yankees GT rows to always_on so all three platforms pull now, not
  -- only once the game falls inside the 7-day enqueue window.
  UPDATE public.ticketsdata_event_xref x
  SET always_on = true, updated_at = v_now
  WHERE x.platform = 'GT'
    AND x.active = true
    AND EXISTS (SELECT 1 FROM public.td_target_events() t WHERE t.sg_event_id = x.event_id);

  -- Enrichment for the active (target) rows: latest owned_tickets / retail median
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
END $function$;

REVOKE ALL ON FUNCTION public.td_apply_targets() FROM PUBLIC;

-- ───────────────────────────────────────────────────────────────────────────
-- 3) td_watchlist_refresh(): keep the daily cron gate + counter reset,
--    delegate selection to the target-only routine.
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_watchlist_refresh()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_count int := 0;
  v_now   timestamptz := now();
BEGIN
  IF NOT public.cron_should_fire('td_watchlist_refresh') THEN RETURN 0; END IF;

  -- reset daily enqueue counters
  UPDATE public.ticketsdata_event_xref
  SET enqueues_today = 0, updated_at = v_now
  WHERE enqueues_today > 0;

  -- target-only selection (Yankees home 20 + Knicks playoff) + deactivate others
  v_count := public.td_apply_targets();

  RETURN v_count;
END $function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 4) td_enqueue_peak(): LEFT JOIN + COALESCE date fallback so sg-less rows
--    (e.g. Knicks playoff placeholders) can be enqueued when always_on=true.
--    Only the FROM/JOIN and the date predicate change; everything else is as-is.
-- ───────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_enqueue_peak(p_platform text DEFAULT NULL::text, p_interval_tag text DEFAULT 'manual'::text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    LEFT JOIN public.aq_event_map aem        ON aem.aq_short_event_id = x.aq_short_event_id
    LEFT JOIN public.sg_events_canonical sgc ON sgc.sg_event_id       = aem.sg_event_id
    WHERE x.active            = true
      AND x.event_url         IS NOT NULL
      AND x.enqueues_today    < 3
      AND (p_platform IS NULL OR x.platform = p_platform)
      AND (x.always_on = true
           OR COALESCE(sgc.sg_datetime_utc, aem.event_date::timestamptz) < v_now + interval '7 days')
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
    LIMIT 33
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
END $function$;

-- ───────────────────────────────────────────────────────────────────────────
-- 5) One-time application (takes effect immediately, independent of the
--    09:00 UTC cron gate).
-- ───────────────────────────────────────────────────────────────────────────

-- 5a) Scope the Gametime performer allowlist to the Yankees only.
UPDATE public.td_gt_performers
SET active = false, updated_at = now()
WHERE active = true
  AND performer_url NOT ILIKE '%mlbnyy%';

-- 5b) Apply the target set now: activate Yankees-20 + Knicks-playoff (SH/VD,
--     always_on), deactivate all other currently-active rows, refresh enrichment.
SELECT public.td_apply_targets();

-- 5c) Cancel any queued-but-unfired pulls for events we just deactivated, so we
--     don't spend fetch credits on dropped events. (Soft cancel: mark resolved,
--     no deletion.)
UPDATE public.td_pull_queue q
SET resolved_at = now()
WHERE q.resolved_at IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.ticketsdata_event_xref x
    WHERE x.event_id = q.event_id
      AND x.platform = q.platform
      AND x.active   = true);

-- 5d) Seed the queue once for an immediate pull of the new target set (the
--     every-minute td_pull_drain will fire these). Deduped against open queue rows.
INSERT INTO public.td_pull_queue
  (event_id, platform, event_url, interval_tag, created_at)
SELECT x.event_id, x.platform, x.event_url, 'manual_focus_seed', now()
FROM public.ticketsdata_event_xref x
WHERE x.active = true
  AND x.always_on = true
  AND x.event_url IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.td_pull_queue q
    WHERE q.event_id = x.event_id
      AND q.platform = x.platform
      AND q.resolved_at IS NULL);

COMMIT;
