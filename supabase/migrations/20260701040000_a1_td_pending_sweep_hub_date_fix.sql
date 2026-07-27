-- ============================================================================
-- Migration 20260701040000 — td_pending_sweep: gate past-event deactivation on the HUB date
--
-- Lane:     A1
-- Touches:  td_pending_sweep() (past-event deactivation source), ticketsdata_event_xref (reactivate
--           wrongly-swept SH/VD future events).
-- Pre-reqs: events (occurs_at_local = authoritative event datetime), aq_event_map, sg_events_canonical.
--
-- WHY (operator 2026-06-30/07-01): td_pending_sweep deactivated SH/VD/GT/TM xref rows whose joined
-- sg_events_canonical.sg_datetime_utc was >2h past. But that SG datetime is STALE for rescheduled /
-- mismapped events, so the sweep wrongly deactivated ~176 valid FUTURE events on 2026-06-29 23:25 —
-- including owned inventory (e.g. a Yankees split-doubleheader "Rescheduled from 5/23", real date 9/22,
-- 420 owned tickets: its SG-canonical row still read the old 5/23 => swept). Symptom: those events silently
-- dropped out of SH/VD polling.
--   FIX: gate deactivation on the HUB event datetime (events.occurs_at_local via aq_event_map.tevo_event_id),
--   which is authoritative and reschedule-aware. Only deactivate when the hub says the event is genuinely
--   >2h past; rows with an unknown/unparseable hub date are left alone. Queue-cleanup logic preserved.
--   REACTIVATE: turn the wrongly-swept SH/VD rows back on (hub date still future, NOT deactivated for a real
--   403/404). Scoped to SH/VD only — TM stays MSG-scoped, GT untouched — so no other intentional
--   deactivation is undone. Restored 178 SH + 217 VD events (~210k owned tickets).
--
-- Idempotent (CREATE OR REPLACE + guarded UPDATE). Re-apply is a no-op.
-- ============================================================================

-- 1. Rewrite td_pending_sweep: past-event checks now use the hub date, not the stale SG date.
CREATE OR REPLACE FUNCTION public.td_pending_sweep()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_now timestamptz := clock_timestamp();
BEGIN
  IF NOT public.cron_should_fire('td_pending_sweep') THEN RETURN; END IF;

  DELETE FROM public.td_pull_queue
  WHERE resolved_at IS NOT NULL AND created_at < v_now - interval '7 days';

  UPDATE public.td_pull_queue
  SET resolved_at = v_now, status_code = -1,
      error_msg   = 'timeout_sweep — pg_net request unresolved after 1h'
  WHERE fired_at IS NOT NULL AND resolved_at IS NULL
    AND fired_at < v_now - interval '1 hour';

  -- Deactivate genuinely-past events, judged by the AUTHORITATIVE hub datetime (events.occurs_at_local),
  -- keyed per platform through aq_event_map. Rows with an unknown/unparseable hub date are left alone.
  UPDATE public.ticketsdata_event_xref x SET active = false, updated_at = v_now
  WHERE x.active = true AND x.platform = 'SH'
    AND EXISTS (
      SELECT 1 FROM public.aq_event_map aem JOIN public.events e ON e.id = aem.tevo_event_id
      WHERE aem.sh_event_id = x.event_id AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
        AND e.occurs_at_local::timestamptz < v_now - interval '2 hours');

  UPDATE public.ticketsdata_event_xref x SET active = false, updated_at = v_now
  WHERE x.active = true AND x.platform = 'VD'
    AND EXISTS (
      SELECT 1 FROM public.aq_event_map aem JOIN public.events e ON e.id = aem.tevo_event_id
      WHERE aem.vivid_event_id = x.event_id AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
        AND e.occurs_at_local::timestamptz < v_now - interval '2 hours');

  UPDATE public.ticketsdata_event_xref x SET active = false, updated_at = v_now
  WHERE x.active = true AND x.platform = 'GT'
    AND EXISTS (
      SELECT 1 FROM public.aq_event_map aem JOIN public.events e ON e.id = aem.tevo_event_id
      WHERE aem.sg_event_id = x.event_id AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
        AND e.occurs_at_local::timestamptz < v_now - interval '2 hours');

  UPDATE public.ticketsdata_event_xref x SET active = false, updated_at = v_now
  WHERE x.active = true AND x.platform = 'TM'
    AND EXISTS (
      SELECT 1 FROM public.aq_event_map aem JOIN public.events e ON e.id = aem.tevo_event_id
      WHERE aem.tm_event_id = x.event_id AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
        AND e.occurs_at_local::timestamptz < v_now - interval '2 hours');
END $function$;

-- 2. Reactivate the wrongly-swept SH/VD rows: hub event still FUTURE and not deactivated for a 403/404.
UPDATE public.ticketsdata_event_xref x
   SET active = true, updated_at = now(),
       meta = coalesce(x.meta,'{}'::jsonb)
              || jsonb_build_object('reactivated_at', now(),
                                    'reactivated_reason', 'td_pending_sweep_stale_sg_date')
 WHERE x.active = false
   AND x.platform IN ('SH','VD')
   AND NOT (x.meta ? '403_at') AND NOT (x.meta ? '404_at')
   AND EXISTS (
     SELECT 1 FROM public.aq_event_map aem JOIN public.events e ON e.id = aem.tevo_event_id
     WHERE ((x.platform = 'SH' AND aem.sh_event_id    = x.event_id)
         OR (x.platform = 'VD' AND aem.vivid_event_id = x.event_id))
       AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
       AND e.occurs_at_local::timestamptz > now());
