-- 20260527150000_ticketsdata_daily_budget_cap_300.sql
--
-- Add daily credit cap (300/day) alongside monthly cap (9,000/month).
-- Ensures 9,000 credits are spread evenly over the billing cycle rather than
-- front-loaded (at 320/day uncapped they'd exhaust around day 28).
--
-- CHANGES:
--   1. td_credits_today()   — credits used today (UTC date)
--   2. td_daily_budget_ok() — today < 300
--   3. td_budget_ok()       — combined gate: daily AND monthly (replaces scattered checks)
--   4. Update all TD function bodies to call td_budget_ok() instead of td_monthly_budget_ok()
--   5. Update cron_policy work_check_sql for all TD crons to td_budget_ok()
--
-- MATH:
--   300 credits/day × 30 days = 9,000/month — exact even spread.
--   At prior uncapped rate (4×/day × SH+VD × 40 events = 320/day) the budget
--   exhausted around day 28, leaving ~2 days dead per cycle.

-- ── 1. td_credits_today ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_credits_today()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT COALESCE(SUM(credits), 0)::integer
  FROM public.ticketsdata_credit_usage
  WHERE (called_at AT TIME ZONE 'UTC')::date = CURRENT_DATE;
$$;
REVOKE ALL ON FUNCTION public.td_credits_today() FROM anon, public;
COMMENT ON FUNCTION public.td_credits_today() IS
  'Credits used today (UTC). Pair with td_daily_budget_ok() for 300/day soft cap.';

-- ── 2. td_daily_budget_ok ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.td_daily_budget_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.td_credits_today() < 300;
  -- 300/day × 30 days = 9,000/month — exact even spread across billing cycle.
  -- Adjust threshold here if plan changes.
$$;
REVOKE ALL ON FUNCTION public.td_daily_budget_ok() FROM anon, public;
COMMENT ON FUNCTION public.td_daily_budget_ok() IS
  'Returns true if daily production budget (300 credits/day) not yet exhausted. '
  'td_credits_today() < 300. At 300/day × 30 = 9,000/month exactly.';

-- ── 3. td_budget_ok — combined gate (daily AND monthly) ──────────────────────
CREATE OR REPLACE FUNCTION public.td_budget_ok()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT public.td_daily_budget_ok() AND public.td_monthly_budget_ok();
$$;
REVOKE ALL ON FUNCTION public.td_budget_ok() FROM anon, public;
COMMENT ON FUNCTION public.td_budget_ok() IS
  'Combined budget gate: td_daily_budget_ok() AND td_monthly_budget_ok(). '
  'All TD enqueue/pull/normalize functions call this. '
  'Daily cap: 300. Monthly cap: 9,000.';

-- ── 4a. td_enqueue_peak — switch to td_budget_ok() ───────────────────────────
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
      x.always_on            DESC,
      x.owned_tickets        DESC NULLS LAST,
      x.median_retail_price  DESC NULLS LAST,
      x.last_enqueued_at     NULLS FIRST
    LIMIT 40
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

-- ── 4b. td_pull_drain — switch to td_budget_ok() ─────────────────────────────
CREATE OR REPLACE FUNCTION public.td_pull_drain(
  p_max integer DEFAULT 5
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  r        RECORD;
  v_user   text;
  v_pass   text;
  v_req_id bigint;
  v_count  int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_pull_drain') THEN RETURN 0; END IF;

  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_pull_drain: budget exhausted (daily or monthly), skipping';
    RETURN 0;
  END IF;

  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');

  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'td_pull_drain: TICKETSDATA creds missing from vault';
  END IF;

  FOR r IN
    SELECT id, event_id, platform, event_url
    FROM public.td_pull_queue
    WHERE fired_at IS NULL
    ORDER BY created_at ASC
    LIMIT p_max
  LOOP
    SELECT net.http_get(
      url     := 'https://ticketsdata.com/fetch',
      params  := jsonb_build_object(
                   'platform',  public.td_api_platform(r.platform),
                   'event_url', r.event_url,
                   'username',  v_user,
                   'password',  v_pass
                 ),
      headers := '{}'::jsonb,
      timeout_milliseconds := 35000
    ) INTO v_req_id;

    UPDATE public.td_pull_queue
    SET request_id = v_req_id,
        fired_at   = clock_timestamp()
    WHERE id = r.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public.td_pull_drain(integer) FROM anon, public;

-- ── 4c. td_normalize_drain — no change needed ────────────────────────────────
-- normalize_drain processes already-fired requests; it doesn't initiate new API
-- calls. Budget is enforced upstream at pull_drain (enqueue → pull → normalize).
-- The daily cap stops new fires naturally; in-flight requests always complete.

-- ── 4d. td_gt_discover — switch to td_budget_ok() ────────────────────────────
CREATE OR REPLACE FUNCTION public.td_gt_discover()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $$
DECLARE
  r        RECORD;
  v_user   text;
  v_pass   text;
  v_req_id bigint;
  v_count  int := 0;
BEGIN
  IF NOT public.cron_should_fire('td_gt_discover') THEN RETURN 0; END IF;

  IF NOT public.td_budget_ok() THEN
    RAISE NOTICE 'td_gt_discover: budget exhausted (daily or monthly), skipping';
    RETURN 0;
  END IF;

  v_user := public.get_app_secret('TICKETSDATA_USERNAME');
  v_pass := public.get_app_secret('TICKETSDATA_PASSWORD');

  IF v_user IS NULL OR v_pass IS NULL THEN
    RAISE EXCEPTION 'td_gt_discover: TICKETSDATA creds missing from vault';
  END IF;

  FOR r IN
    SELECT id, performer_url
    FROM public.td_gt_performers
    WHERE active = true
      AND (pending_discover_request_id IS NULL
           OR last_discovered_at IS NULL
           OR last_discovered_at < clock_timestamp() - interval '22 hours')
    ORDER BY id
  LOOP
    SELECT net.http_get(
      url     := 'https://ticketsdata.com/events',
      params  := jsonb_build_object(
                   'platform',      'gametime',
                   'performer_url', r.performer_url,
                   'username',      v_user,
                   'password',      v_pass
                 ),
      headers := '{}'::jsonb,
      timeout_milliseconds := 35000
    ) INTO v_req_id;

    UPDATE public.td_gt_performers
    SET pending_discover_request_id = v_req_id,
        updated_at                  = clock_timestamp()
    WHERE id = r.id;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;
REVOKE ALL ON FUNCTION public.td_gt_discover() FROM anon, public;

-- ── 5. Update cron_policy work_check_sql for all TD crons ────────────────────
UPDATE public.cron_policy
SET work_check_sql = 'SELECT public.td_budget_ok()',
    notes          = notes || ' [daily+monthly budget gate 2026-05-27]',
    updated_at     = now()
WHERE jobname IN (
  'td_pull_drain', 'td_normalize_drain',
  'td_enqueue_peak_sh', 'td_enqueue_peak_vd', 'td_enqueue_peak_gt',
  'td_gt_discover'
);
