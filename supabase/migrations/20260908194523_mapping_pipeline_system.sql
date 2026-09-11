-- Migration 20260908194523 · level:data-collection · lane:A1 · writes:cron_policy,cron.job · reads:aq_event_map,aq_tevo_search_attempts,s4kcs_orders,td_match_results,vivid_orders,tickpick_orders,sg_seller_pending · pre:20260908184118
-- Already applied to prod · via MCP 2026-09-08 under operator direction.
-- Verified: cron.job 336 now '8,23,38,53 * * * *' with cron_policy interval
-- 15/15 (was 780/780); cron 582 mapping_health_check_daily created at '47 4 * * *';
-- v_mapping_pipeline_health returns 7 pipelines and immediately flagged the real
-- stall (tickpick_orders, 3 months 10 days); mapping_health_check() run once
-- returned 1 and wrote its bot_chat flag.
--
-- A mapping SYSTEM: open the bridge's throughput gate, and add a stall detector
-- so a dead mapping pipeline can never again go months unnoticed.
--
-- ============================================================================
-- PART 1 — the bridge is gated to TWICE A DAY, not hourly.
-- ============================================================================
-- cron.job 336 is scheduled '8 * * * *', which reads as hourly. It is not.
-- cron_should_fire() consults cron_policy, and this job's row says:
--     peak_min_interval_min = 780, offpeak_min_interval_min = 780   (13 hours)
-- Hence the '_13h' suffix in the job name. Measured over the last 24h:
-- 22 'skip_interval' decisions, 2 'fire'. At limit=30 that is ~60 candidates
-- a day against a backlog of ~940 — roughly two weeks to drain, and it only
-- ever kept pace because the pool was artificially tiny (42 rows) until
-- mig 20260908183242 widened it to ~944.
--
-- The 13h interval was a reasonable guard when every run burned its batch on
-- TEvo 429s (see mig 20260908173624 + bot_chat 3567): slow runs were the only
-- protection. That is fixed — the bridge now paces itself (pace_ms), skips the
-- fallback after a 429, and aborts the run rather than poisoning candidates.
-- Measured 2026-09-08: ~20 consecutive runs at limit=50/pace_ms=150,
-- 0 throttled and 0 errored across ~1,000 requests.
--
-- New shape: 15-minute interval, 4 fires/hour, limit=50 → ~200 candidates/hour
-- (vs ~60/day). The existing work_check
--     SELECT EXISTS(SELECT 1 FROM aq_tevo_search_candidates(1, 24))
-- makes this self-limiting: once the queue drains, the gate returns
-- 'skip_no_work' and the job stops calling TEvo at all.
--
-- ⚠ JOB NAME IS NOW A MISNOMER. It stays 'aq_to_tevo_search_bridge_13h'
-- deliberately: cron_policy and cron_gate_decisions are both keyed by jobname,
-- so renaming would orphan the gate history AND — if the policy row were missed
-- — cron_should_fire() would fall through to 'fire_no_policy', which returns
-- TRUE unconditionally and would remove the interval gate entirely. A stale
-- name is safer than an ungated bridge. Rename only as a deliberate 3-step
-- change (unschedule, reschedule, move the policy row).
--
-- ============================================================================
-- PART 2 — stall detector.
-- ============================================================================
-- Three mapping pipelines were found silently dead on 2026-09-08, none of which
-- surfaced anywhere: the aq-tevo bridge (429-poisoned since 2026-06-22, ~2.5
-- months), the SeatGeek seller ingest (healthy, but authenticating an account
-- with no orders after 2020), and tickpick_orders (no pull since 2026-05-31).
-- Every one of them had a green cron. Liveness of the SCHEDULE says nothing
-- about liveness of the DATA, which is what this view measures.
--
-- v_mapping_pipeline_health is read-only and cheap; mapping_health_check()
-- writes ONE bot_chat flag listing whatever is stalled, and stays silent when
-- everything is healthy, so it cannot become background noise.

-- ---------------------------------------------------------------- PART 1 ---
UPDATE public.cron_policy
   SET peak_min_interval_min    = 15,
       offpeak_min_interval_min = 15
 WHERE jobname = 'aq_to_tevo_search_bridge_13h';

SELECT cron.schedule(
  'aq_to_tevo_search_bridge_13h',
  '8,23,38,53 * * * *',
  $cron$
  SET statement_timeout='90s';
  DO $b$ BEGIN
    IF NOT public.cron_should_fire('aq_to_tevo_search_bridge_13h') THEN RETURN; END IF;
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/aq-to-tevo-search-bridge?limit=50&min_score=50&pace_ms=150',
      '{}'::jsonb
    );
  END $b$;
  $cron$
);

-- ---------------------------------------------------------------- PART 2 ---
CREATE OR REPLACE VIEW public.v_mapping_pipeline_health AS
WITH p AS (
  SELECT 'crm_ingest'::text AS pipeline,
         (SELECT max(pulled_at) FROM public.s4kcs_orders)            AS last_ok,
         interval '30 minutes'                                        AS max_age,
         NULL::bigint                                                 AS backlog
  UNION ALL SELECT 'crm_event_mapper',
         (SELECT max(mapped_at) FROM public.s4kcs_orders),
         interval '2 hours',
         (SELECT count(*) FROM public.s4kcs_orders
           WHERE tevo_event_id IS NULL AND event_date >= current_date)
  UNION ALL SELECT 'aq_tevo_bridge',
         (SELECT max(attempted_at) FROM public.aq_tevo_search_attempts WHERE result = 'matched'),
         interval '6 hours',
         (SELECT count(*) FROM public.aq_event_map m
            LEFT JOIN public.aq_tevo_search_attempts a ON a.aq_id = m.id
           WHERE m.tevo_event_id IS NULL AND m.sg_event_id IS NULL
             AND m.event_date >= now()::timestamp
             AND NOT (m.category IN ('Parking','parking')
                      OR m.venue_name ILIKE '%parking%' OR m.event_name ILIKE '%parking%')
             AND NOT (m.event_name ~* '(cancelled|if necessary|\(date tbd\))')
             AND NOT (m.event_name ~* 'season tickets?')
             AND (a.aq_id IS NULL OR a.attempted_at < now() - interval '24 hours'))
  UNION ALL SELECT 'td_match_apply',
         (SELECT max(applied_at) FROM public.td_match_results),
         interval '48 hours',
         (SELECT count(*) FROM public.td_match_results WHERE applied_at IS NULL)
  UNION ALL SELECT 'vivid_orders',
         (SELECT max(pulled_at) FROM public.vivid_orders),    interval '24 hours', NULL::bigint
  UNION ALL SELECT 'tickpick_orders',
         (SELECT max(pulled_at) FROM public.tickpick_orders), interval '24 hours', NULL::bigint
  UNION ALL SELECT 'seatgeek_seller',
         (SELECT max(resolved_at) FROM public.sg_seller_pending), interval '2 hours', NULL::bigint
)
SELECT pipeline, last_ok, now() - last_ok AS age, max_age, backlog,
       (last_ok IS NULL OR now() - last_ok > max_age) AS stalled
FROM p;

COMMENT ON VIEW public.v_mapping_pipeline_health IS
  'Per-pipeline mapping liveness. A green cron proves the SCHEDULE ran, not that DATA moved — three pipelines were found dead on 2026-09-08 with green crons. Read this instead.';

CREATE OR REPLACE FUNCTION public.mapping_health_check()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_txt text; v_n int;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'mapping_health_check: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  SELECT count(*), string_agg(
           format('%s (last ok %s ago, threshold %s%s)', pipeline,
                  coalesce(justify_interval(age)::text, 'NEVER'), max_age,
                  coalesce(', backlog ' || backlog::text, '')), '; ' ORDER BY pipeline)
    INTO v_n, v_txt
  FROM public.v_mapping_pipeline_health WHERE stalled;

  -- Silent when healthy: a check that always posts becomes noise and gets ignored.
  IF coalesce(v_n, 0) = 0 THEN RETURN 0; END IF;

  PERFORM public.bot_chat_log(
    p_level      => 'data-collection',
    p_lane       => 'A1',
    p_event_type => 'flag',
    p_message    => format('MAPPING PIPELINE STALLED (%s): %s. Source: v_mapping_pipeline_health. '
                        || 'A green cron only proves the schedule ran — check whether DATA moved.',
                           v_n, v_txt)
  );
  RETURN v_n;
END $function$;

REVOKE ALL ON FUNCTION public.mapping_health_check() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mapping_health_check() TO service_role;

-- Daily in the T3 window (RESOURCES_BIBLE §5), off the saturated :02/:05/:07
-- marks. Own SET prefix per the §3 pg_cron pool-leak landmine.
SELECT cron.schedule(
  'mapping_health_check_daily',
  '47 4 * * *',
  $cron$
  SET statement_timeout='120s';
  SELECT public.mapping_health_check();
  $cron$
);
