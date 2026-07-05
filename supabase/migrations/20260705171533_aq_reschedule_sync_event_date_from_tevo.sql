-- Migration 20260705171533 · lane:A1 (data plane — reschedule date reconcile)
--   writes (DDL): aq_reschedule_sync_from_tevo() [new]; cron 'aq_reschedule_sync_from_tevo_30min'
--   writes on run: aq_event_map.event_date (sync from TEvo when a reschedule moved it)
--   reads: public.events (evo poller cache: occurs_at_local, last_seen)
--   pre: none (public.events maintained by evo_event_backfill_process)
--   auth: operator directive 2026-07-05 (julian@s4kent.com — "check when events are
--         rescheduled and update, just have the evo poller check and update when necessary")
--
-- ## Applied to prod 2026-07-05 via MCP (idempotent + reversible). Codification.
--
-- WHY ────────────────────────────────────────────────────────────────────────
-- The evo poller (evo_event_backfill_process) keeps public.events fresh — when
-- TEvo reschedules an event, events.occurs_at_local gets the new datetime (and the
-- title often gains "(Rescheduled from …)"). But that update was never propagated
-- to aq_event_map.event_date, the cross-source hub the storefront + all td poll
-- gating read. So a rescheduled event kept its OLD date: e.g. tevo 3091424
-- "Boston Red Sox at New York Yankees" moved 6/6 → 8/29, but aq_event_map still said
-- 2026-06-06 — so it looked like a past event (no live inventory shown, poll tiers
-- treat it as over) even though it's a month out.
--
-- Scope at authoring: 288 aq rows had a stale calendar date vs TEvo; 153 were
-- freshly re-seen by the evo poller in the last 3 days (live truth); 9 were the
-- damaging "aq says past / TEvo says future" reschedule-forward case.
--
-- FIX: aq_reschedule_sync_from_tevo() copies the TEvo local datetime onto
-- aq_event_map.event_date whenever it differs, for events the evo poller has seen
-- recently (last_seen < 3d — only trust current TEvo truth, never resurrect a row
-- on stale data). The naive-local conversion mirrors the mapper's own convention
-- (left(occurs_at_local,19)::timestamp — the wall-clock before the tz offset; cf.
-- resolve_aq_tevo_from_sources / link_aq_tevo_from_events). Runs twice-hourly + once
-- now. Once the date is corrected, a reschedule-forward event re-enters
-- td_target_events (event_date > now()) and the existing td_apply_targets / sweep
-- crons re-enroll its pollers automatically — no extra wiring needed here.
--
-- Cost: free (reads our own tables). Idempotent (only writes when the value differs).
-- Rollback: drop the function + its cron. event_date values are re-derivable from
-- public.events, so leaving them corrected is harmless.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.aq_reschedule_sync_from_tevo()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'aq_reschedule_sync_from_tevo: forbidden for %', current_user USING ERRCODE = '42501';
  END IF;

  UPDATE public.aq_event_map a
  SET event_date = left(e.occurs_at_local, 19)::timestamp
  FROM public.events e
  WHERE e.id = a.tevo_event_id
    AND a.tevo_event_id IS NOT NULL
    AND e.last_seen > now() - interval '3 days'
    -- Only well-formed TEvo local strings ("YYYY-MM-DDThh:mm:ss…") so the cast can't raise.
    AND e.occurs_at_local ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}'
    AND left(e.occurs_at_local, 19)::timestamp IS DISTINCT FROM a.event_date;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$function$;
REVOKE ALL ON FUNCTION public.aq_reschedule_sync_from_tevo() FROM anon, public;

-- Twice-hourly reconcile (off saturated :02/:05/:07 marks).
SELECT cron.schedule('aq_reschedule_sync_from_tevo_30min', '13,43 * * * *',
                     $$SELECT public.aq_reschedule_sync_from_tevo()$$);

-- Correct the current backlog now (fixes the Yankees reschedule + the other stale dates).
SELECT public.aq_reschedule_sync_from_tevo();
