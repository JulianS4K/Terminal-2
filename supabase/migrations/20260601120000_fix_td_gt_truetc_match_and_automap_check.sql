-- ============================================================
-- Fix GameTime (GT) automapping timezone bug + daily automap-check cron.
-- D0 2026-06-01.
--
-- ROOT CAUSE (diagnosed on "Cleveland Guardians at New York Yankees",
-- tevo 3091420/21/22): td_gt_discover_drain() matched GameTime events to our
-- canonical events purely by datetime within +/-1800s, comparing GameTime's
-- *true-UTC* datetime_utc (e.g. 2026-06-02T23:05:00) against
-- sg_events_canonical.sg_datetime_utc, which for MLB rows is stored as the
-- LOCAL wall-clock time mislabeled UTC (2026-06-02 19:05:00+00). The 4h EDT
-- offset (14400s) blows past the 30-min window, so no GT xref row was ever
-- created -> the terminal GameTime panel renders empty. The same loose
-- datetime-only join (no team/venue guard) also produced GARBAGE matches on
-- the rows that did line up by the wrong clock (e.g. "Matt Rife" / WNBA games
-- linked to Yankees GameTime URLs).
--
-- FIX (two independent defects):
--   1. Compare against events.occurs_at_local::timestamptz (reliable true UTC),
--      not sg_datetime_utc. Anchor every GT match to a tevo-mapped canonical
--      event (which is exactly what the terminal RPC needs to resolve anyway).
--   2. Parse GameTime datetime_utc as UTC explicitly ('...'::timestamp AT TIME
--      ZONE 'UTC') instead of ::timestamptz, which silently used the session tz.
--   3. Add a trigram name-similarity guard (>0.30) so a time coincidence can no
--      longer mis-map unrelated games; pick the best match by (sim, |delta|).
--
-- Plus td_gt_automap_check(): a daily self-heal/audit that re-drains, deactivates
-- clearly-wrong existing GT rows (URL team-slug vs canonical name < 0.15), and
-- flags any upcoming tevo-anchored events that carry other TD platforms but no
-- active GT mapping. Scheduled 09:35 UTC, just after discover (09:15)/drain (09:20).
--
-- ## Already applied to prod  Applied via MCP 2026-06-01
-- ============================================================

-- ---------- 1. Fixed drain ----------
CREATE OR REPLACE FUNCTION public.td_gt_discover_drain()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  r          RECORD;
  ev         RECORD;
  v_sg_id    bigint;
  v_aq_short text;
  v_count    int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_gt_discover_drain') THEN RETURN 0; END IF;

  FOR r IN
    SELECT p.id AS performer_id, h.status_code, h.content AS raw_content
    FROM public.td_gt_performers p
    JOIN net._http_response h ON h.id = p.pending_discover_request_id
    WHERE p.active = true
      AND p.pending_discover_request_id IS NOT NULL
    ORDER BY p.id
  LOOP
    IF r.status_code = 200 THEN
      FOR ev IN
        SELECT
          item->'event'->>'seo_url'                                AS seo_url,
          item->'event'->>'name'                                   AS gt_name,
          -- datetime_utc is true UTC wall time with NO offset; pin it to UTC
          -- explicitly (rtrim a stray 'Z' if present) instead of ::timestamptz,
          -- which would have used the session timezone.
          (rtrim(item->'event'->>'datetime_utc', 'Z')::timestamp
              AT TIME ZONE 'UTC')                                  AS dt_utc
        FROM jsonb_array_elements(r.raw_content::jsonb->'body'->'items') AS item
        WHERE item->'event'->>'seo_url' IS NOT NULL
          AND item->'event'->>'datetime_utc' IS NOT NULL
      LOOP
        -- Match against the canonical event's RELIABLE true UTC
        -- (events.occurs_at_local), anchored to a tevo-mapped row, with a
        -- trigram name guard so a clock coincidence can't mis-map games.
        SELECT aem.sg_event_id, aem.aq_short_event_id
        INTO   v_sg_id, v_aq_short
        FROM   public.sg_events_canonical sgc
        JOIN   public.aq_event_map aem ON aem.sg_event_id = sgc.sg_event_id
        JOIN   public.events e         ON e.id = aem.tevo_event_id
        WHERE  aem.sg_event_id IS NOT NULL
          AND  e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'
          AND  e.occurs_at_local::timestamptz > clock_timestamp()
          AND  abs(extract(epoch FROM e.occurs_at_local::timestamptz - ev.dt_utc)) < 1800
          AND  similarity(lower(coalesce(ev.gt_name, '')), lower(e.name)) > 0.30
        ORDER BY similarity(lower(coalesce(ev.gt_name, '')), lower(e.name)) DESC,
                 abs(extract(epoch FROM e.occurs_at_local::timestamptz - ev.dt_utc))
        LIMIT 1;

        IF v_sg_id IS NOT NULL THEN
          INSERT INTO public.ticketsdata_event_xref
            (event_id, platform, aq_short_event_id, event_url, active, always_on, match_method, updated_at)
          VALUES (v_sg_id, 'GT', v_aq_short, ev.seo_url, true, false, 'events_api', clock_timestamp())
          ON CONFLICT (event_id, platform) DO UPDATE
            SET event_url    = EXCLUDED.event_url,
                active       = true,
                match_method = 'events_api',
                updated_at   = clock_timestamp()
            WHERE ticketsdata_event_xref.event_url IS DISTINCT FROM EXCLUDED.event_url
               OR ticketsdata_event_xref.active = false;

          v_count := v_count + 1;
        END IF;
      END LOOP;

      PERFORM public.td_charge_credit(
        1, NULL, 'GT', '/events', 200,
        (r.raw_content::jsonb->>'quota_remaining')::int
      );
    END IF;

    UPDATE public.td_gt_performers
    SET pending_discover_request_id = NULL,
        last_discovered_at          = clock_timestamp(),
        updated_at                  = clock_timestamp()
    WHERE id = r.performer_id;
  END LOOP;

  RETURN v_count;
END $function$;

-- ---------- 2. Daily automap-check (self-heal + audit) ----------
CREATE OR REPLACE FUNCTION public.td_gt_automap_check()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_drained   int := 0;
  v_deact     int := 0;
  v_gaps      int := 0;
  v_samples   text;
BEGIN
  IF NOT public.cron_should_fire('td_gt_automap_check') THEN RETURN '{"skipped":true}'::jsonb; END IF;

  -- (a) Re-run the (now timezone-correct) drain against any cached responses.
  v_drained := public.td_gt_discover_drain();

  -- (b) Self-heal: deactivate clearly-wrong existing GT rows. Compare the
  --     "<away>-at-<home>" team slug from the GameTime URL to the canonical
  --     event name; trigram similarity < 0.15 means the loose pre-fix matcher
  --     bound this GT row to an unrelated event. Deactivate (reversible), never delete.
  WITH bad AS (
    SELECT x.event_id, x.platform
    FROM public.ticketsdata_event_xref x
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = x.event_id
    WHERE x.platform = 'GT' AND x.active = true
      AND x.event_url IS NOT NULL
      AND similarity(
            lower(replace(split_part(
              regexp_replace(x.event_url, '^https?://[^/]+/[^/]+/', ''),
              '-tickets/', 1), '-', ' ')),
            lower(sgc.sg_event_name)
          ) < 0.15
  )
  UPDATE public.ticketsdata_event_xref x
  SET active = false, updated_at = clock_timestamp()
  FROM bad
  WHERE x.event_id = bad.event_id AND x.platform = bad.platform;
  GET DIAGNOSTICS v_deact = ROW_COUNT;

  -- (c) Audit: upcoming tevo-anchored events that carry >=1 other active TD
  --     platform but NO active GT mapping = the bug's signature. Flag if any.
  WITH upcoming AS (
    SELECT DISTINCT x.event_id
    FROM public.ticketsdata_event_xref x
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = x.event_id
    WHERE x.active = true AND x.platform <> 'GT'
      AND sgc.sg_datetime_utc > now() AND sgc.sg_datetime_utc < now() + interval '120 days'
  ),
  gap AS (
    SELECT u.event_id, sgc.sg_event_name
    FROM upcoming u
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = u.event_id
    WHERE NOT EXISTS (
      SELECT 1 FROM public.ticketsdata_event_xref g
      WHERE g.event_id = u.event_id AND g.platform = 'GT' AND g.active = true)
  )
  SELECT count(*), string_agg(DISTINCT left(sg_event_name, 48), ' | ' ORDER BY left(sg_event_name,48))
  INTO v_gaps, v_samples
  FROM (SELECT event_id, sg_event_name FROM gap ORDER BY event_id LIMIT 8) s;

  IF v_gaps > 0 THEN
    PERFORM public.bot_chat_log(
      p_level := 'data-collection', p_lane := 'D0', p_event_type := 'flag',
      p_message := format('GT automap-check: %s upcoming events have other TD platforms but no GT mapping (drained %s, deactivated %s stale). Sample: %s',
                          v_gaps, v_drained, v_deact, coalesce(v_samples, '-')),
      p_related_mig := '20260601120000');
  END IF;

  RETURN jsonb_build_object('drained', v_drained, 'deactivated', v_deact, 'gaps', v_gaps);
END $function$;

-- ---------- 3. Policy + cron for the check ----------
INSERT INTO public.cron_policy
  (jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min, work_check_sql, daily_max_fires, enabled, notes)
VALUES
  ('td_gt_automap_check', ARRAY[]::int[], 1440, 1440, 'SELECT true', 1, true,
   'Daily GT automap self-heal + gap audit (D0 2026-06-01).')
ON CONFLICT (jobname) DO UPDATE
  SET offpeak_min_interval_min = EXCLUDED.offpeak_min_interval_min,
      daily_max_fires = EXCLUDED.daily_max_fires,
      enabled = true,
      updated_at = now();

DO $$ BEGIN
  PERFORM cron.unschedule('td_gt_automap_check');
EXCEPTION WHEN OTHERS THEN NULL; END $$;

SELECT cron.schedule('td_gt_automap_check', '35 9 * * *',
  $cron$DO $b$ BEGIN PERFORM public.td_gt_automap_check(); END $b$;$cron$);
