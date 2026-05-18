-- Migration 20260519130000 · lane:A1 · writes:v_sg_broker_429_health+v_sg_broker_429_starved_events+check_sg_broker_429_health+cron · pre:20260519120000 · auth:operator-approved 2026-05-19
--
-- A1 — 429 monitoring protocol for SG broker pipeline.
--
-- Builds on PR #212 (429-aware processors) + PR #214 (1min→5min cadence +
-- poll_tick stagger). Now that the fix sentinel exists (-429 vs -1 vs >=0
-- in sg_broker_pending.rows_persisted), this migration adds three surfaces
-- for ongoing observability:
--
--   1. v_sg_broker_429_health — hourly pct_429 rollup over last 24h, per scope
--   2. v_sg_broker_429_starved_events — events 429'd 3+ times with no recent
--      success. Surfaces per-event hot spots the broader rollup might miss.
--   3. check_sg_broker_429_health() — alert function with hysteresis;
--      bot_chat 'flag' when pct_429 > 15% sustained over last hour AND no
--      open flag posted for this rule in the last hour.
--   4. cron sg_broker_429_health_check_15min @ */15 * * * *
--
-- Alert threshold rationale:
--   Pre-fix baseline (pre-PR #212): 53-69% pct_429 every cron cycle
--   Post-fix baseline (post-PR #212+#214 verified): <10% expected
--   Alert at 15% → 5% headroom over expected baseline; bump down to 10%
--   after a week of clean data if the threshold is too noisy.
--
-- Hysteresis: re-alerts blocked while a previous SG_BROKER_429_HEALTH flag
-- is still open in bot_chat (unresolved + within last hour). Prevents the
-- 15-min cron from spamming during a sustained incident.

-- ============================================================
-- 1. v_sg_broker_429_health — hourly rollup of pct_429
-- ============================================================
CREATE OR REPLACE VIEW public.v_sg_broker_429_health AS
SELECT
  scope,
  date_trunc('hour', fired_at) AS hour_bucket,
  count(*) AS total_fired,
  count(*) FILTER (WHERE rows_persisted = -429) AS rate_limited,
  count(*) FILTER (WHERE rows_persisted >= 0) AS ok,
  count(*) FILTER (WHERE rows_persisted = -1) AS terminal_failed,
  count(*) FILTER (WHERE resolved_at IS NULL) AS unresolved,
  round(100.0 * count(*) FILTER (WHERE rows_persisted = -429) / NULLIF(count(*), 0), 1) AS pct_429,
  round(100.0 * count(*) FILTER (WHERE rows_persisted >= 0) / NULLIF(count(*), 0), 1) AS pct_ok
FROM public.sg_broker_pending
WHERE fired_at > now() - interval '24 hours'
  AND resolved_at IS NOT NULL
GROUP BY scope, date_trunc('hour', fired_at);

GRANT SELECT ON public.v_sg_broker_429_health TO anon, authenticated, service_role;
COMMENT ON VIEW public.v_sg_broker_429_health IS
  'A1 2026-05-19: rolling 24h hourly pct_429 monitor for SG broker pipeline. Reads sg_broker_pending.rows_persisted sentinel (-429 set by 429-aware processors per PR #212).';

-- ============================================================
-- 2. v_sg_broker_429_starved_events — chronically rate-limited events
-- ============================================================
CREATE OR REPLACE VIEW public.v_sg_broker_429_starved_events AS
SELECT
  p.sg_event_id,
  p.scope,
  c.sg_event_name,
  c.sg_event_date,
  c.sg_venue_name,
  c.sg_category,
  count(*) FILTER (WHERE p.rows_persisted = -429) AS rate_limited_24h,
  count(*) FILTER (WHERE p.rows_persisted >= 0) AS ok_24h,
  max(p.fired_at) FILTER (WHERE p.rows_persisted = -429) AS last_429_at,
  max(p.fired_at) FILTER (WHERE p.rows_persisted >= 0) AS last_ok_at
FROM public.sg_broker_pending p
LEFT JOIN public.sg_events_canonical c ON c.sg_event_id = p.sg_event_id
WHERE p.fired_at > now() - interval '24 hours'
  AND p.resolved_at IS NOT NULL
GROUP BY p.sg_event_id, p.scope, c.sg_event_name, c.sg_event_date, c.sg_venue_name, c.sg_category
HAVING count(*) FILTER (WHERE p.rows_persisted = -429) >= 3
   AND (count(*) FILTER (WHERE p.rows_persisted >= 0) = 0
        OR max(p.fired_at) FILTER (WHERE p.rows_persisted = -429)
           > max(p.fired_at) FILTER (WHERE p.rows_persisted >= 0));

GRANT SELECT ON public.v_sg_broker_429_starved_events TO anon, authenticated, service_role;
COMMENT ON VIEW public.v_sg_broker_429_starved_events IS
  'A1 2026-05-19: events 429-rate-limited 3+ times in last 24h with no more recent success. Indicates per-event chronic starvation (vs systemic).';

-- ============================================================
-- 3. check_sg_broker_429_health() — alert function with hysteresis
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_sg_broker_429_health()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_pct_429_listings numeric;
  v_pct_429_sales    numeric;
  v_total_listings   int;
  v_total_sales      int;
  v_starved_count    int;
  v_alerted_recently boolean;
  v_alert_msg        text;
  v_threshold        numeric := 15.0;
BEGIN
  SELECT
    count(*) FILTER (WHERE scope = 'listings'),
    count(*) FILTER (WHERE scope = 'sales'),
    round(100.0 * count(*) FILTER (WHERE rows_persisted = -429 AND scope = 'listings')
          / NULLIF(count(*) FILTER (WHERE scope = 'listings'), 0), 1),
    round(100.0 * count(*) FILTER (WHERE rows_persisted = -429 AND scope = 'sales')
          / NULLIF(count(*) FILTER (WHERE scope = 'sales'), 0), 1)
  INTO v_total_listings, v_total_sales, v_pct_429_listings, v_pct_429_sales
  FROM public.sg_broker_pending
  WHERE fired_at > now() - interval '1 hour'
    AND resolved_at IS NOT NULL;

  SELECT count(*) INTO v_starved_count FROM public.v_sg_broker_429_starved_events;

  SELECT EXISTS (
    SELECT 1 FROM public.bot_chat
    WHERE event_type = 'flag'
      AND bot_lane = 'A1'
      AND message LIKE 'SG_BROKER_429_HEALTH:%'
      AND created_at > now() - interval '1 hour'
      AND resolved_at IS NULL
  ) INTO v_alerted_recently;

  IF (coalesce(v_pct_429_listings, 0) > v_threshold OR coalesce(v_pct_429_sales, 0) > v_threshold)
     AND NOT v_alerted_recently
  THEN
    v_alert_msg := 'SG_BROKER_429_HEALTH: pct_429 over threshold (>'
      || v_threshold::text || '%) — listings='
      || coalesce(v_pct_429_listings, 0)::text || '% ('
      || v_total_listings::text || ' req/h), sales='
      || coalesce(v_pct_429_sales, 0)::text || '% ('
      || v_total_sales::text || ' req/h). '
      || v_starved_count::text
      || ' chronically-starved events. Inspect: SELECT * FROM v_sg_broker_429_health; SELECT * FROM v_sg_broker_429_starved_events;';
    PERFORM public.bot_chat_log(
      p_level => 'admin', p_lane => 'A1',
      p_event_type => 'flag',
      p_message => v_alert_msg,
      p_related_pr => NULL, p_related_mig => '20260519130000',
      p_in_reply_to => NULL::bigint, p_meta => NULL::jsonb
    );
  END IF;

  RETURN jsonb_build_object(
    'checked_at',        now(),
    'pct_429_listings',  v_pct_429_listings,
    'pct_429_sales',     v_pct_429_sales,
    'total_listings_1h', v_total_listings,
    'total_sales_1h',    v_total_sales,
    'starved_events',    v_starved_count,
    'threshold',         v_threshold,
    'alerted',           (coalesce(v_pct_429_listings, 0) > v_threshold OR coalesce(v_pct_429_sales, 0) > v_threshold) AND NOT v_alerted_recently,
    'already_open_flag', v_alerted_recently
  );
END $function$;

REVOKE ALL ON FUNCTION public.check_sg_broker_429_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_sg_broker_429_health() TO service_role;

COMMENT ON FUNCTION public.check_sg_broker_429_health() IS
  'A1 2026-05-19: 429-rate health check. Fires bot_chat flag when last-hour pct_429 > 15% AND no open flag for this rule in last hour (hysteresis prevents spam). Scheduled @ */15 * * * *.';

-- ============================================================
-- 4. Cron sg_broker_429_health_check_15min
-- ============================================================
DO $body$ DECLARE v_jobid bigint;
BEGIN
  SELECT jobid INTO v_jobid FROM cron.job WHERE jobname = 'sg_broker_429_health_check_15min';
  IF v_jobid IS NOT NULL THEN PERFORM cron.unschedule(v_jobid); END IF;

  PERFORM cron.schedule(
    'sg_broker_429_health_check_15min',
    '*/15 * * * *',
    $cron$DO $cronbody$
    BEGIN
      IF NOT public.cron_should_fire('sg_broker_429_health_check_15min') THEN RETURN; END IF;
      PERFORM public.check_sg_broker_429_health();
    END $cronbody$;$cron$
  );
END $body$;

INSERT INTO public.cron_policy (jobname, peak_hours_et, peak_min_interval_min,
  offpeak_min_interval_min, daily_max_fires, enabled, notes)
VALUES (
  'sg_broker_429_health_check_15min',
  '{9,10,11,12,13,14,15,16,17,18,19,20}'::int[],
  15, 15, 96, true,
  '15-min 429 health probe. Alerts via bot_chat when pct_429 > 15% sustained over last hour. Hysteresis: no re-alert if open flag exists in last hour.'
) ON CONFLICT (jobname) DO UPDATE SET enabled = true, notes = EXCLUDED.notes, updated_at = now();
