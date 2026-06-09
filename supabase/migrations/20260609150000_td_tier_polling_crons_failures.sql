-- Migration 20260609150000 · lane:D0 (author) → A1 (apply) ·
--   writes (DDL): td_poll_policy (new), td_poll_failures (new),
--                 td_event_tier(), td_is_peak(), td_tier_enqueue(),
--                 td_log_poll_failure() + trigger, v_td_poll_health,
--                 v_td_poll_failures_recent ·
--   reads: ticketsdata_event_xref, aq_event_map, events ·
--   writes on run: td_pull_queue (enqueue), td_poll_failures (trigger) ·
--   spends: feeds /fetch (1 credit/call via the existing drain); budget-gated ·
--   pre: 20260527050000 (xref/queue/budget), 20260608193000 (drain), cron_policy
--
-- ## NOT YET APPLIED — author-only migration file.
--    Pending A1 review + explicit operator apply (CLAUDE.md §1; cron.schedule +
--    cron_policy changes are operator-gated). Validate on a Supabase branch first.
--
-- WHAT ───────────────────────────────────────────────────────────────────────
-- Implements the time-to-event tiered polling design as SEPARATE, individually
-- toggleable per-platform enqueue crons, plus persistent failure tracking.
--
--   * Cadence + platform-breadth + peak/off-peak are TABLE-DRIVEN (td_poll_policy)
--     so they tune without a migration.
--   * One enqueue cron PER PLATFORM (td_tier_enqueue_{sh,vd,tm,gt,tp,axs}); turn
--     each on/off via cron_policy.enabled (the existing gate the 402-handler uses).
--   * Reuses the existing td_pull_queue → td_pull_drain → td_normalize_drain path
--     for the actual fetch + response handling. This migration only adds the
--     ENQUEUE side (due-based metronome) + diagnostics.
--   * SEEDED DISABLED. The old flat td_enqueue_peak_* crons are disabled here to
--     avoid double-enqueue; operator enables the new per-platform crons when the
--     owned-book onboarding begins.
--
-- Locked design encoded in td_poll_policy:
--   tier    dte        platforms                      peak / off-peak interval
--   hot     0–7        SH VD TM GT AXS  (+TP if ≤5d)   12h / 12h  (no halve)
--   warm    8–30       SH VD TM GT AXS                 ~14.8h / ~29.6h
--   cool    31–90      SH VD GT                        24h / 48h
--   cold    91–180     SH VD                           72h / 144h
--   frozen  >180       SH VD                           weekly / weekly
--   Off-peak = 9pm–9am in the EVENT's local time (per-event tz from occurs_at_local).
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. td_poll_policy — (platform, tier) → cadence + breadth. Absence of a row
--    means that platform does NOT poll that tier (the breadth decay). max_dte
--    optionally caps a row to events within N days (TickPick ≤5d).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.td_poll_policy (
  platform      text NOT NULL,
  tier          text NOT NULL CHECK (tier IN ('hot','warm','cool','cold','frozen')),
  peak_min      integer NOT NULL,            -- peak-hours poll interval, minutes
  offpeak_min   integer NOT NULL,            -- off-peak interval, minutes
  max_dte       integer,                     -- NULL = no cap; e.g. TP hot = 5
  active        boolean NOT NULL DEFAULT true,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (platform, tier)
);
REVOKE ALL ON public.td_poll_policy FROM anon, authenticated;
ALTER TABLE public.td_poll_policy ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_poll_policy_service_only ON public.td_poll_policy
  FOR ALL TO service_role USING (true);

INSERT INTO public.td_poll_policy (platform, tier, peak_min, offpeak_min, max_dte, active) VALUES
  -- SH / VD: full breadth, all tiers
  ('SH','hot',720,720,NULL,true),  ('SH','warm',888,1776,NULL,true), ('SH','cool',1440,2880,NULL,true), ('SH','cold',4320,8640,NULL,true), ('SH','frozen',10080,10080,NULL,true),
  ('VD','hot',720,720,NULL,true),  ('VD','warm',888,1776,NULL,true), ('VD','cool',1440,2880,NULL,true), ('VD','cold',4320,8640,NULL,true), ('VD','frozen',10080,10080,NULL,true),
  -- GT: drops at cold
  ('GT','hot',720,720,NULL,true),  ('GT','warm',888,1776,NULL,true), ('GT','cool',1440,2880,NULL,true),
  -- TM: drops at cool
  ('TM','hot',720,720,NULL,true),  ('TM','warm',888,1776,NULL,true),
  -- AXS: hot+warm, gated OFF until TicketsData ships AXS
  ('AXS','hot',720,720,NULL,false),('AXS','warm',888,1776,NULL,false),
  -- TP: hot only, auto-on inside 5 days (overrides its manual_opt_in demotion)
  ('TP','hot',720,720,5,true)
ON CONFLICT (platform, tier) DO NOTHING;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. helpers — tier from days-to-event, peak from per-event local time
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_event_tier(p_dte integer)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_dte IS NULL OR p_dte < 0 THEN NULL
    WHEN p_dte <= 7   THEN 'hot'
    WHEN p_dte <= 30  THEN 'warm'
    WHEN p_dte <= 90  THEN 'cool'
    WHEN p_dte <= 180 THEN 'cold'
    ELSE 'frozen' END;
$$;

-- Off-peak = local hour < 9 or >= 23. The event's tz offset is the trailing
-- ±HH:MM of occurs_at_local (ISO). If absent, default to peak (poll).
CREATE OR REPLACE FUNCTION public.td_is_peak(p_occurs_at_local text, p_now timestamptz DEFAULT now())
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_off text; v_hour int;
BEGIN
  v_off := substring(coalesce(p_occurs_at_local,'') from '([+-]\d\d:\d\d)$');
  IF v_off IS NULL THEN RETURN true; END IF;
  v_hour := extract(hour FROM ((p_now AT TIME ZONE 'UTC') + v_off::interval));
  RETURN v_hour >= 9 AND v_hour < 23;
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. td_tier_enqueue(p_platform) — due-based metronome enqueue for ONE platform.
--    Gated by its own cron_policy row + the TD budget. Honors td_poll_policy
--    (cadence + breadth + max_dte) and per-event peak/off-peak. interval_tag is
--    set to the tier so downstream + failures carry it.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_tier_enqueue(p_platform text, p_max integer DEFAULT 500)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $fn$
DECLARE
  v_job text := 'td_tier_enqueue_' || lower(p_platform);
  r RECORD;
  v_n int := 0;
BEGIN
  IF NOT public.cron_should_fire(v_job) THEN RETURN 0; END IF;
  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_tier_enqueue(%): budget exhausted', p_platform; RETURN 0;
  END IF;

  FOR r IN
    WITH cand AS (
      SELECT x.event_id, x.platform, x.event_url, x.last_fetched_at,
             COALESCE(e.occurs_at_local, NULL) AS occ,
             COALESCE( (left(e.occurs_at_local,10))::date,
                       (a.event_date)::date ) - CURRENT_DATE AS dte
      FROM public.ticketsdata_event_xref x
      LEFT JOIN public.aq_event_map a ON a.aq_short_event_id = x.aq_short_event_id
      LEFT JOIN public.events e ON e.id = COALESCE(x.tevo_event_id, a.tevo_event_id)
      WHERE x.platform = p_platform AND x.active AND x.event_url IS NOT NULL
    ),
    tiered AS (
      SELECT c.*, public.td_event_tier(c.dte) AS tier,
             public.td_is_peak(c.occ) AS is_peak
      FROM cand c
      WHERE c.dte IS NOT NULL AND c.dte >= 0
    )
    SELECT t.event_id, t.platform, t.event_url, t.tier
    FROM tiered t
    JOIN public.td_poll_policy p
      ON p.platform = t.platform AND p.tier = t.tier AND p.active
    WHERE (p.max_dte IS NULL OR t.dte <= p.max_dte)
      AND ( t.last_fetched_at IS NULL
            OR t.last_fetched_at < now()
                 - (CASE WHEN t.is_peak THEN p.peak_min ELSE p.offpeak_min END) * interval '1 minute' )
      AND NOT EXISTS (
        SELECT 1 FROM public.td_pull_queue q
        WHERE q.event_id = t.event_id AND q.platform = t.platform AND q.resolved_at IS NULL )
    ORDER BY t.last_fetched_at NULLS FIRST
    LIMIT GREATEST(p_max, 0)
  LOOP
    INSERT INTO public.td_pull_queue (event_id, platform, event_url, interval_tag, retry_count)
    VALUES (r.event_id, r.platform, r.event_url, r.tier, 0);
    UPDATE public.ticketsdata_event_xref
    SET last_enqueued_at = now(), enqueues_today = enqueues_today + 1
    WHERE (event_id, platform) = (r.event_id, r.platform);
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END $fn$;
REVOKE ALL ON FUNCTION public.td_tier_enqueue(text,integer) FROM anon, public;


-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Failure tracking — persistent log + diagnostics. A trigger captures every
--    td_pull_queue row that resolves with a non-200 status (survives queue
--    pruning, unlike td_pull_queue itself).
-- ─────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.td_poll_failures (
  id          bigserial PRIMARY KEY,
  failed_at   timestamptz NOT NULL DEFAULT now(),
  event_id    bigint,
  platform    text,
  tier        text,
  status_code int,
  error_msg   text,
  request_id  bigint
);
CREATE INDEX IF NOT EXISTS idx_td_poll_failures_recent
  ON public.td_poll_failures (failed_at DESC);
CREATE INDEX IF NOT EXISTS idx_td_poll_failures_plat
  ON public.td_poll_failures (platform, status_code, failed_at DESC);
REVOKE ALL ON public.td_poll_failures FROM anon, authenticated;
ALTER TABLE public.td_poll_failures ENABLE ROW LEVEL SECURITY;
CREATE POLICY td_poll_failures_service_only ON public.td_poll_failures
  FOR ALL TO service_role USING (true);

CREATE OR REPLACE FUNCTION public.td_log_poll_failure()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
BEGIN
  INSERT INTO public.td_poll_failures
    (event_id, platform, tier, status_code, error_msg, request_id)
  VALUES
    (NEW.event_id, NEW.platform, NEW.interval_tag, NEW.status_code,
     left(NEW.error_msg, 500), NEW.request_id);
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_td_pull_queue_failure ON public.td_pull_queue;
CREATE TRIGGER trg_td_pull_queue_failure
  AFTER UPDATE ON public.td_pull_queue
  FOR EACH ROW
  WHEN (NEW.resolved_at IS NOT NULL AND OLD.resolved_at IS NULL
        AND NEW.status_code IS DISTINCT FROM 200)
  EXECUTE FUNCTION public.td_log_poll_failure();

-- Live per-platform health (last 24h, from the queue).
CREATE OR REPLACE VIEW public.v_td_poll_health AS
SELECT
  platform,
  count(*)                                            AS attempts_24h,
  count(*) FILTER (WHERE status_code = 200)           AS ok_24h,
  count(*) FILTER (WHERE status_code IS DISTINCT FROM 200) AS fail_24h,
  round(100.0 * count(*) FILTER (WHERE status_code IS DISTINCT FROM 200)
        / NULLIF(count(*),0), 1)                      AS fail_pct,
  max(resolved_at) FILTER (WHERE status_code = 200)   AS last_ok_at,
  max(resolved_at) FILTER (WHERE status_code IS DISTINCT FROM 200) AS last_fail_at
FROM public.td_pull_queue
WHERE resolved_at > now() - interval '24 hours'
GROUP BY platform;

-- Failure breakdown by platform + status (last 72h, from the persistent log).
CREATE OR REPLACE VIEW public.v_td_poll_failures_recent AS
SELECT platform, status_code, tier,
       count(*) AS n,
       max(failed_at) AS last_at,
       (array_agg(DISTINCT left(error_msg,80)))[1:3] AS sample_errors
FROM public.td_poll_failures
WHERE failed_at > now() - interval '72 hours'
GROUP BY platform, status_code, tier
ORDER BY n DESC;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Per-platform crons — one per platform, individually toggleable via
--    cron_policy.enabled. SEEDED DISABLED. Staggered 30-min metronome.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO public.cron_policy (jobname, enabled, notes) VALUES
  ('td_tier_enqueue_sh',  false, 'Tiered per-platform enqueue (SH). Toggle to enable. 2026-06-09.'),
  ('td_tier_enqueue_vd',  false, 'Tiered per-platform enqueue (VD). Toggle to enable. 2026-06-09.'),
  ('td_tier_enqueue_tm',  false, 'Tiered per-platform enqueue (TM). Toggle to enable. 2026-06-09.'),
  ('td_tier_enqueue_gt',  false, 'Tiered per-platform enqueue (GT). Toggle to enable. 2026-06-09.'),
  ('td_tier_enqueue_tp',  false, 'Tiered per-platform enqueue (TP, ≤5d only). Toggle to enable. 2026-06-09.'),
  ('td_tier_enqueue_axs', false, 'Tiered per-platform enqueue (AXS). Keep OFF until TicketsData ships AXS. 2026-06-09.')
ON CONFLICT (jobname) DO NOTHING;

-- Retire the old flat enqueue crons to prevent double-enqueue (operator enables
-- the tiered ones above when onboarding the owned book).
UPDATE public.cron_policy
SET enabled = false,
    notes   = notes || ' [superseded by td_tier_enqueue_* 2026-06-09]'
WHERE jobname IN ('td_enqueue_peak_sh','td_enqueue_peak_vd','td_enqueue_peak_gt',
                  'td_enqueue_peak_tp','td_enqueue_peak_tm');

-- pg_cron schedules (gated internally by cron_should_fire → cron_policy.enabled).
SELECT cron.schedule('td_tier_enqueue_sh',  '0,30 * * * *',  $$SELECT public.td_tier_enqueue('SH')$$);
SELECT cron.schedule('td_tier_enqueue_vd',  '5,35 * * * *',  $$SELECT public.td_tier_enqueue('VD')$$);
SELECT cron.schedule('td_tier_enqueue_tm',  '10,40 * * * *', $$SELECT public.td_tier_enqueue('TM')$$);
SELECT cron.schedule('td_tier_enqueue_gt',  '15,45 * * * *', $$SELECT public.td_tier_enqueue('GT')$$);
SELECT cron.schedule('td_tier_enqueue_tp',  '20,50 * * * *', $$SELECT public.td_tier_enqueue('TP')$$);
SELECT cron.schedule('td_tier_enqueue_axs', '25,55 * * * *', $$SELECT public.td_tier_enqueue('AXS')$$);

-- ── Operator runbook ─────────────────────────────────────────────────────────
--   Enable a platform:   UPDATE public.cron_policy SET enabled=true  WHERE jobname='td_tier_enqueue_sh';
--   Disable a platform:  UPDATE public.cron_policy SET enabled=false WHERE jobname='td_tier_enqueue_sh';
--   Tune cadence:        UPDATE public.td_poll_policy SET peak_min=..,offpeak_min=.. WHERE platform='SH' AND tier='warm';
--   Health:              SELECT * FROM public.v_td_poll_health;
--   Failures:            SELECT * FROM public.v_td_poll_failures_recent;
