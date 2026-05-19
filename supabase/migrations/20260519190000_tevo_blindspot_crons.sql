-- Migration 20260519190000 · lane:A1 · writes:cron.job,cron_policy,tevo_blindspot_discovery_attempts · pre:20260519180000
--
-- TEvo blindspot pipeline crons — companion to the detector in mig
-- 20260519180000. Two scheduled jobs:
--
--   1. tevo_blindspot_metrics_refresh_12h (twice daily @ 06:00, 18:00 UTC)
--      Refreshes `latest_event_metrics` CONCURRENTLY so the blindspot
--      detector view picks up fresh tickets_count + retail_min values
--      between collect-listings cron cycles. Without this, `owned=0`
--      events can show stale tickets_count for hours because the matview
--      doesn't auto-refresh — it's normally maintained by the bigger
--      hourly collection pipeline. Blindspot is an off-cycle consumer,
--      so it needs its own refresh hook.
--
--   2. tevo_blindspot_discovery_daily (once daily @ 07:00 UTC)
--      Pings a `tevo-blindspot-discovery` edge function (operator-deployed
--      separately) that searches TEvo /v9/events for new events matching
--      the blindspot criteria (US/CA, 31-365d out, sports-leaning) and
--      upserts winners into `events`. Pattern mirrors
--      sg_to_tevo_search_bridge (mig 20260516250000). Edge fn is OPTIONAL
--      — until deployed, the cron fires a no-op HTTP call that the
--      cron_policy gate suppresses on miss.
--
-- WHY ONLY ONE DISCOVERY/DAY (vs SG bridge's 30/day):
--   TEvo /v9/events search at the criteria scope (US/CA, 1yr horizon,
--   tickets_count threshold) returns ~few hundred candidate events. One
--   pull/day captures full inventory turnover; more would burn quota
--   without finding new events.
--
-- WHY 12h (NOT MORE FREQUENT) FOR PRICE REFRESH:
--   Blindspot detector is a sourcing aid, not a real-time market signal.
--   The 12h cadence matches SG's TRACK_BLINDSPOT polling cadence (mig
--   20260520290000: interval_seconds=43200). Consistent with SG side.

-- ============================================================
-- 1. Discovery attempts tracking table (mirrors sg_tevo_search_attempts)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.tevo_blindspot_discovery_attempts (
  attempt_id   bigserial PRIMARY KEY,
  attempted_at timestamptz NOT NULL DEFAULT now(),
  result       text        NOT NULL,    -- 'enqueued'|'edge_fn_called'|'edge_fn_missing'|'error'
  events_found int,
  events_added int,
  meta         jsonb,
  search_criteria jsonb               -- the filters passed to TEvo /v9/events
);

CREATE INDEX IF NOT EXISTS idx_tevo_blindspot_discovery_attempts_attempted_at
  ON public.tevo_blindspot_discovery_attempts(attempted_at DESC);

COMMENT ON TABLE public.tevo_blindspot_discovery_attempts IS
  'Audit log for tevo_blindspot_discovery_daily cron firings. Each row is one
   cron tick; `result` captures whether the edge fn responded, errored, or is
   missing entirely (no-op state until edge fn deployed).';

REVOKE ALL ON public.tevo_blindspot_discovery_attempts FROM PUBLIC;
GRANT SELECT, INSERT ON public.tevo_blindspot_discovery_attempts TO service_role;

-- ============================================================
-- 2. Refresh function (called by metrics_refresh_12h cron)
-- ============================================================
CREATE OR REPLACE FUNCTION public.tevo_blindspot_metrics_refresh()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_rows_before bigint;
  v_rows_after bigint;
  v_blindspot_count bigint;
BEGIN
  -- Pre-refresh row count for audit
  SELECT count(*) INTO v_rows_before FROM public.latest_event_metrics;

  -- Refresh CONCURRENTLY — non-blocking; readers continue against old data
  -- during refresh. Requires a UNIQUE index on the matview (verified
  -- present per existing matview definition).
  REFRESH MATERIALIZED VIEW CONCURRENTLY public.latest_event_metrics;

  SELECT count(*) INTO v_rows_after  FROM public.latest_event_metrics;
  SELECT count(*) INTO v_blindspot_count FROM public.v_tevo_blindspot_movers;

  RETURN jsonb_build_object(
    'fn',                'tevo_blindspot_metrics_refresh',
    'rows_before',       v_rows_before,
    'rows_after',        v_rows_after,
    'blindspot_count',   v_blindspot_count,
    'refreshed_at',      now()
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.tevo_blindspot_metrics_refresh() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tevo_blindspot_metrics_refresh() TO service_role;

COMMENT ON FUNCTION public.tevo_blindspot_metrics_refresh() IS
  'Refreshes latest_event_metrics CONCURRENTLY and returns audit row counts +
   current blindspot detector population. Called by tevo_blindspot_metrics_refresh_12h
   cron @ 06:00, 18:00 UTC. Companion to the detector in mig 20260519180000.';

-- ============================================================
-- 3. Discovery enqueue function (called by discovery_daily cron)
-- ============================================================
CREATE OR REPLACE FUNCTION public.tevo_blindspot_discovery_enqueue()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_attempt_id bigint;
  v_criteria   jsonb;
BEGIN
  -- Search criteria mirror the detector view gates so the edge fn looks
  -- for the same shape of events. Edge fn will pull TEvo /v9/events
  -- with `occurs_at.gte` + `occurs_at.lte` + country filter and score
  -- candidates before upserting into `events`.
  v_criteria := jsonb_build_object(
    'occurs_at_gte_iso', to_char((now() + interval '31 days')::date,  'YYYY-MM-DD'),
    'occurs_at_lte_iso', to_char((now() + interval '365 days')::date, 'YYYY-MM-DD'),
    'countries',         jsonb_build_array('US', 'CA'),
    'min_tickets_count', 25,
    'note',              'Blindspot discovery: only events with broker depth + active markets.'
  );

  INSERT INTO public.tevo_blindspot_discovery_attempts
    (result, search_criteria, meta)
  VALUES
    ('enqueued', v_criteria, jsonb_build_object('source', 'tevo_blindspot_discovery_daily'))
  RETURNING attempt_id INTO v_attempt_id;

  -- Fire-and-forget HTTP to the discovery edge fn. pg_net.http_get is
  -- async (§3 landmine — sleeps don't pace it). Edge fn deployment is
  -- OPERATOR-PENDING; until then this call returns a request_id that
  -- 404s harmlessly. Edge fn will INSERT a follow-up row with
  -- result='edge_fn_called' + events_found/events_added once shipped.
  BEGIN
    PERFORM net.http_get(
      url := 'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/tevo-blindspot-discovery?attempt_id=' || v_attempt_id,
      headers := jsonb_build_object('Content-Type', 'application/json')
    );
  EXCEPTION WHEN OTHERS THEN
    -- pg_net may not be available in all environments; swallow + log.
    UPDATE public.tevo_blindspot_discovery_attempts
      SET result = 'error',
          meta   = jsonb_set(coalesce(meta, '{}'::jsonb), '{error}', to_jsonb(SQLERRM))
      WHERE attempt_id = v_attempt_id;
  END;

  RETURN jsonb_build_object(
    'fn',         'tevo_blindspot_discovery_enqueue',
    'attempt_id', v_attempt_id,
    'criteria',   v_criteria,
    'queued_at',  now()
  );
END;
$$;

REVOKE ALL    ON FUNCTION public.tevo_blindspot_discovery_enqueue() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.tevo_blindspot_discovery_enqueue() TO service_role;

COMMENT ON FUNCTION public.tevo_blindspot_discovery_enqueue() IS
  'Enqueues a TEvo /v9/events search attempt for blindspot discovery + fires
   the edge fn via pg_net. Called by tevo_blindspot_discovery_daily cron
   @ 07:00 UTC. Edge fn (`tevo-blindspot-discovery`) deployment is operator-
   pending — until shipped, the HTTP call 404s harmlessly and rows stay at
   result=''enqueued''.';

-- ============================================================
-- 4. Cron schedules
-- ============================================================

-- 4a. Twice-daily price/metrics refresh @ 06:00, 18:00 UTC
DO $body$
DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'tevo_blindspot_metrics_refresh_12h';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;

  PERFORM cron.schedule(
    'tevo_blindspot_metrics_refresh_12h',
    '0 6,18 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('tevo_blindspot_metrics_refresh_12h') THEN RETURN; END IF;
      PERFORM public.tevo_blindspot_metrics_refresh();
    END $cronbody$;$cron$
  );
END $body$;

INSERT INTO public.cron_policy (
  jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
  daily_max_fires, enabled, notes
) VALUES (
  'tevo_blindspot_metrics_refresh_12h',
  '{}'::int[],            -- no peak/offpeak split — only fires at fixed UTC times
  720, 720, 2, true,
  'Refreshes latest_event_metrics CONCURRENTLY twice daily so blindspot detector picks up fresh price + tickets_count data. Mirrors SG TRACK_BLINDSPOT 12h cadence.'
) ON CONFLICT (jobname) DO UPDATE SET
  notes        = EXCLUDED.notes,
  enabled      = EXCLUDED.enabled,
  daily_max_fires = EXCLUDED.daily_max_fires,
  updated_at   = now();

-- 4b. Daily new-events discovery @ 07:00 UTC
DO $body$
DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'tevo_blindspot_discovery_daily';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;

  PERFORM cron.schedule(
    'tevo_blindspot_discovery_daily',
    '0 7 * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('tevo_blindspot_discovery_daily') THEN RETURN; END IF;
      PERFORM public.tevo_blindspot_discovery_enqueue();
    END $cronbody$;$cron$
  );
END $body$;

INSERT INTO public.cron_policy (
  jobname, peak_hours_et, peak_min_interval_min, offpeak_min_interval_min,
  daily_max_fires, enabled, notes
) VALUES (
  'tevo_blindspot_discovery_daily',
  '{}'::int[],
  1440, 1440, 1, true,
  'Daily discovery of new TEvo events matching blindspot criteria (US/CA, 31-365d, tickets>=25). Calls edge fn `tevo-blindspot-discovery` which searches TEvo /v9/events + upserts winners. Edge fn deployment is operator-pending — until shipped, attempts log as result=''enqueued''.'
) ON CONFLICT (jobname) DO UPDATE SET
  notes        = EXCLUDED.notes,
  enabled      = EXCLUDED.enabled,
  daily_max_fires = EXCLUDED.daily_max_fires,
  updated_at   = now();

-- ============================================================
-- VERIFICATION (operator runs after apply):
--
--   -- 1. Crons registered + policy rows present
--   SELECT jobname, schedule, active FROM cron.job
--   WHERE jobname LIKE 'tevo_blindspot_%' ORDER BY jobname;
--
--   SELECT jobname, daily_max_fires, enabled FROM public.cron_policy
--   WHERE jobname LIKE 'tevo_blindspot_%';
--
--   -- 2. Manually fire refresh (writes a fresh latest_event_metrics)
--   SELECT public.tevo_blindspot_metrics_refresh();
--   -- expect: jsonb with rows_before/rows_after/blindspot_count
--
--   -- 3. Manually fire discovery (logs an attempt; edge fn 404s)
--   SELECT public.tevo_blindspot_discovery_enqueue();
--   SELECT result, search_criteria, attempted_at FROM public.tevo_blindspot_discovery_attempts
--   ORDER BY attempted_at DESC LIMIT 1;
--   -- expect: one row, result='enqueued' or 'error' (depending on pg_net state)
--
--   -- 4. After edge fn deployment, attempts should flip to result='edge_fn_called'
--   --    with events_found/events_added populated. Until then result stays
--   --    'enqueued' — that's the operator-pending state.
-- ============================================================
