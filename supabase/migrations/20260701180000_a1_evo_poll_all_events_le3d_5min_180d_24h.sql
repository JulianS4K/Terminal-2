-- ============================================================================
-- Migration 20260701180000 — EVO listings poller: all events + le3d 5min + 180d+ 24h
--
-- Lane:     A1
-- Touches:  collector_cadence (EVO/listings band ladder), evo_listings_poll_tick() (eligibility + ordering),
--           cron evo_listings_poll_2min (per-tick throughput 50 -> 120).
-- Pre-reqs: collector_band (data-driven by min/max hours), evo_listings_poll_state, events.
--
-- WHY (operator 2026-07-01): (1) poll ALL events via EVO, not just the chat/watchlist/owned subset;
-- (2) events <3 days out -> poll every 5 min; (3) events >180 days out -> poll every 24h. EVO is the FREE
-- TEvo firehose (no credit cost), and the poller fires ASYNC net.http_post (fire-and-forget) so raising
-- its throughput adds no scheduler-wedge risk.
--   NEW EVO ladder: le3d(0-72h)=5m · le7d(72-168)=15m · d8_14(168-336)=30/60 · d15_30(336-720)=60 ·
--     d31_60(720-1440)=240 · d61p(1440-4320 = 60-180d)=720 (12h) · d181p(4320+ = 180d+)=1440 (24h).
--   ELIGIBILITY: drop the is_chat_tracked/watch_sources/owned filter -> every future non-ignored event
--     (~5.5k -> ~6.3k). ORDERING: serve most-overdue-relative-to-its-cadence first (overdue_ratio DESC)
--     so the 5-min le3d band is honored without starving the long tail (replaces last_polled NULLS FIRST).
--   THROUGHPUT: raise the per-tick cap 50 -> 120 (ceiling 120*720=86.4k invocations/day) so the expanded
--     universe + 5-min band is actually served rather than throttled by the old ~36k/day ceiling.
--
-- DOWNSTREAM NOTE: ~2.4x more collect-listings invocations => more event_metrics/section_metrics writes.
-- section_metrics retention (sweep_old_section_metrics) is currently blocked on the pending
-- idx_section_metrics_captured build; that index becomes more important under this load. Tunable any time
-- via the cron's evo_listings_poll_tick(N) arg and the collector_cadence interval columns.
--
-- Idempotent (guarded inserts + CREATE OR REPLACE + cron.alter_job). Re-apply is a no-op.
-- ============================================================================

INSERT INTO public.collector_cadence (source, scope, band, min_hours, max_hours, peak_interval_min, offpeak_interval_min, enabled, sort_order, owned_kind)
SELECT 'EVO','listings','le3d', 0, 72, 5, 5, true, 0, 'any'
WHERE NOT EXISTS (SELECT 1 FROM public.collector_cadence WHERE source='EVO' AND scope='listings' AND band='le3d');

INSERT INTO public.collector_cadence (source, scope, band, min_hours, max_hours, peak_interval_min, offpeak_interval_min, enabled, sort_order, owned_kind)
SELECT 'EVO','listings','d181p', 4320, NULL, 1440, 1440, true, 6, 'any'
WHERE NOT EXISTS (SELECT 1 FROM public.collector_cadence WHERE source='EVO' AND scope='listings' AND band='d181p');

UPDATE public.collector_cadence SET min_hours = 72
  WHERE source='EVO' AND scope='listings' AND band='le7d';
UPDATE public.collector_cadence SET max_hours = 4320
  WHERE source='EVO' AND scope='listings' AND band='d61p';
UPDATE public.collector_cadence SET min_hours=0, max_hours=72, peak_interval_min=5, offpeak_interval_min=5, enabled=true, sort_order=0
  WHERE source='EVO' AND scope='listings' AND band='le3d';
UPDATE public.collector_cadence SET min_hours=4320, max_hours=NULL, peak_interval_min=1440, offpeak_interval_min=1440, enabled=true, sort_order=6
  WHERE source='EVO' AND scope='listings' AND band='d181p';

CREATE OR REPLACE FUNCTION public.evo_listings_poll_tick(p_max integer DEFAULT 30)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r RECORD; v_n int := 0;
BEGIN
  IF p_max <= 0 THEN RETURN 0; END IF;
  FOR r IN
    WITH ev AS (
      SELECT e.id,
             EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - now()))/3600.0 AS hte,
             ps.last_polled_listings_at
      FROM public.events e
      LEFT JOIN public.evo_listings_poll_state ps ON ps.event_id = e.id
      WHERE e.occurs_at_local IS NOT NULL
        AND e.occurs_at_local::timestamptz > now() - interval '3 hours'
        AND coalesce(e.state, 'shown') <> 'ignored'
    ),
    due AS (
      SELECT ev.id, ev.last_polled_listings_at, c.required_min,
             CASE WHEN ev.last_polled_listings_at IS NULL THEN 1e9
                  ELSE (EXTRACT(epoch FROM (now() - ev.last_polled_listings_at))/60.0)
                       / NULLIF(c.required_min, 0) END AS overdue_ratio
      FROM ev
      JOIN LATERAL public.collector_band('EVO','listings', ev.hte) c ON true
      WHERE ev.last_polled_listings_at IS NULL
         OR ev.last_polled_listings_at < now() - make_interval(mins => c.required_min)
    )
    SELECT id FROM due ORDER BY overdue_ratio DESC LIMIT p_max
  LOOP
    PERFORM public._cron_invoke_edge_fn(
      'https://hzrizjeaxlqcxfrtczpq.supabase.co/functions/v1/collect-listings?event_id=' || r.id::text,
      '{}'::jsonb);
    INSERT INTO public.evo_listings_poll_state(event_id, last_polled_listings_at, listings_polls_today, budget_day)
      VALUES (r.id, now(), 1, current_date)
      ON CONFLICT (event_id) DO UPDATE SET
        last_polled_listings_at = now(),
        listings_polls_today = CASE WHEN evo_listings_poll_state.budget_day < current_date
                                    THEN 1 ELSE evo_listings_poll_state.listings_polls_today + 1 END,
        budget_day = current_date;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $function$;

SELECT cron.alter_job(
  (SELECT jobid FROM cron.job WHERE jobname='evo_listings_poll_2min'),
  command := $cmd$DO $b$ BEGIN IF NOT public.cron_should_fire('evo_listings_poll_2min') THEN RETURN; END IF; PERFORM public.evo_listings_poll_tick(120); END $b$;$cmd$
);
