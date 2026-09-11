-- ============================================================================
-- Migration 20260911070000 — Exos (Bridge / D4): reminder cron hardening (audit fixes)
--
-- Lane:     d4 (exos / bridge ticketing — customer-facing session)
-- Touches:  exos_send_event_reminders() (DROP + re-CREATE: +events_failed column),
--           exos_queue_event_reminder(uuid, uuid) (REPLACE),
--           exos_send_event_reminder_now(uuid) (REPLACE); exos_events (W: reminder_* markers)
-- Pre-reqs: 20260911051000 (applied to prod 2026-09-11)
--
-- Silent-failure audit of PR #975 (2026-09-11) found four defects in the
-- reminder pipeline shipped in 20260911051000:
--
--   A1 (critical) — the cron looped `FOR v_id IN UPDATE … RETURNING`. PL/pgSQL
--       runs a data-modifying query to completion BEFORE the first iteration, so
--       every due event was stamped reminder_*_sent_at up front; a 20s budget
--       EXIT then left the remaining events stamped-but-unmailed, and the next
--       run's `IS NULL` predicate skipped them forever. Fix: SELECT … FOR UPDATE
--       SKIP LOCKED LIMIT 200, and stamp each event individually right before
--       its fan-out, so an early exit leaves unstamped rows for the next run.
--   A2 (high) — one event whose fan-out raised (e.g. an exos_mail CHECK) rolled
--       back the entire run for every event, every 15 minutes, invisibly. Fix:
--       per-event savepoint that un-stamps the event, RAISE WARNINGs, and counts
--       it in a new `events_failed` output column.
--   A5/A6 — WHEN OTHERS around the tz formatting was wider than its purpose
--       (narrowed to invalid_parameter_value + WARNING); the internal helper
--       returned 0 for a missing/undated event instead of raising.
--   A7 (low) — the manual "Send now" consumed its 6h cooldown even when it
--       reached nobody. Fix: stamp only when at least one mail was queued; lock
--       the event row so two concurrent clicks cannot both pass the check.
--   Code review (PR #975): inside a SECURITY DEFINER body `current_user` is the
--       DEFINER, so the cron guard always passed — assert session_user instead
--       (the REVOKE/GRANT set was doing the real work). Mail subject was HTML-
--       escaped (plain-text header) and `&` was not escaped before `<`/`>` in
--       the body; the cooldown message labelled a session-local time "UTC";
--       the bad-tz fallback printed the zone twice.
--
-- Idempotent (DROP IF EXISTS + CREATE OR REPLACE). The cron job body
-- (`SELECT * FROM public.exos_send_event_reminders()`) is unchanged and picks
-- up the new signature automatically.
-- ROLLBACK: re-run the function bodies from 20260911051000.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Fan-out helper: raise on a missing/undated event; narrow the tz fallback.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_queue_event_reminder(
  p_event_id   uuid,
  p_created_by uuid DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ev      public.exos_events%ROWTYPE;
  v_tz      text;
  v_safe    text;
  v_when    text;
  v_doors   text := '';
  v_venue   text := '';
  v_subj    text;
  v_body    text;
  v_n       int := 0;
BEGIN
  SELECT * INTO v_ev FROM public.exos_events WHERE id = p_event_id;
  IF v_ev.id IS NULL OR v_ev.starts_at IS NULL THEN
    RAISE EXCEPTION 'exos_queue_event_reminder: event % not found or has no starts_at', p_event_id;
  END IF;

  -- Render times in the event's zone. Only an unrecognised zone name falls
  -- back to UTC (SQLSTATE 22023); anything else propagates.
  v_tz := coalesce(nullif(v_ev.timezone, ''), 'UTC');
  BEGIN
    v_when := to_char(v_ev.starts_at AT TIME ZONE v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
    IF v_ev.doors_at IS NOT NULL THEN
      v_doors := ' Doors open at ' || to_char(v_ev.doors_at AT TIME ZONE v_tz, 'FMHH12:MI AM') || '.';
    END IF;
  EXCEPTION WHEN invalid_parameter_value THEN
    RAISE WARNING 'exos_queue_event_reminder: event % has invalid timezone %; falling back to UTC',
      p_event_id, v_ev.timezone;
    v_tz   := 'UTC';
    v_when := to_char(v_ev.starts_at AT TIME ZONE 'UTC', 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
    v_doors := '';
  END;

  -- HTML body: escape & first, then < >. The subject is a plain-text header and
  -- must carry the RAW name (an escaped subject reads "Rock &lt;Live&gt;").
  v_safe := replace(replace(replace(coalesce(v_ev.name, 'your event'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  IF v_ev.venue_name IS NOT NULL AND v_ev.venue_name <> '' THEN
    v_venue := ' at ' || replace(replace(replace(v_ev.venue_name, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  END IF;

  v_subj := left('Reminder: ' || coalesce(v_ev.name, 'your event') || ' — ' || v_when, 200);
  v_body := '<p>Your ticket for <strong>' || v_safe || '</strong>' || v_venue ||
            ' is coming up: <strong>' || v_when || '</strong> (' || v_tz || ').' || v_doors ||
            '</p><p>Open the app to show your ticket at the door. Your entry code rotates, so ' ||
            'use the live pass rather than a screenshot.</p>';

  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  SELECT 'event-reminder', lower(u.email), v_subj, v_body, p_created_by, 'pending'
  FROM (SELECT DISTINCT owner_id FROM public.exos_tickets
         WHERE event_id = p_event_id AND status <> 'voided') h
  JOIN auth.users u ON u.id = h.owner_id
  WHERE u.email IS NOT NULL;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_queue_event_reminder(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_queue_event_reminder(uuid, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. Cron entry: claim-per-event, per-event savepoint, failure count.
--    Return type changes (+events_failed) → DROP first.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.exos_send_event_reminders();
CREATE FUNCTION public.exos_send_event_reminders()
RETURNS TABLE (events_24h int, events_2h int, mails_queued int, events_failed int)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_start   timestamptz := clock_timestamp();
  v_id      uuid;
  v_24h     int := 0;
  v_2h      int := 0;
  v_mails   int := 0;
  v_failed  int := 0;
  v_budget  boolean := false;
BEGIN
  -- session_user, not current_user: this is SECURITY DEFINER, so current_user
  -- is always the definer and would never trip.
  IF session_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_send_event_reminders: service role only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.cron_should_fire('exos_send_event_reminders') THEN
    RETURN QUERY SELECT 0, 0, 0, 0; RETURN;
  END IF;

  -- T-24h: inside 24h, more than 2h out. Claim + mail one event at a time so
  -- an early exit or a failure never strands a stamped-but-unmailed event.
  FOR v_id IN
    SELECT e.id FROM public.exos_events e
     WHERE e.status = 'published'
       AND e.reminder_24h_sent_at IS NULL
       AND e.starts_at >  now() + interval '2 hours'
       AND e.starts_at <= now() + interval '24 hours'
     ORDER BY e.starts_at
     LIMIT 200
     FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN
      UPDATE public.exos_events SET reminder_24h_sent_at = now() WHERE id = v_id;
      v_mails := v_mails + public.exos_queue_event_reminder(v_id, NULL);
      v_24h := v_24h + 1;
    EXCEPTION WHEN OTHERS THEN
      v_failed := v_failed + 1;
      RAISE WARNING 'exos_send_event_reminders: T-24h fan-out for event % failed: % (%)', v_id, SQLERRM, SQLSTATE;
      -- The savepoint rolled the stamp back; nothing else to undo.
    END;
    IF clock_timestamp() - v_start > interval '20 seconds' THEN v_budget := true; EXIT; END IF;
  END LOOP;

  -- T-2h: inside 2h and not started. Also marks 24h done so an event that was
  -- published inside the last 24h does not get two mails minutes apart.
  IF NOT v_budget THEN
    FOR v_id IN
      SELECT e.id FROM public.exos_events e
       WHERE e.status = 'published'
         AND e.reminder_2h_sent_at IS NULL
         AND e.starts_at >  now()
         AND e.starts_at <= now() + interval '2 hours'
       ORDER BY e.starts_at
       LIMIT 200
       FOR UPDATE SKIP LOCKED
    LOOP
      BEGIN
        UPDATE public.exos_events
           SET reminder_2h_sent_at  = now(),
               reminder_24h_sent_at = coalesce(reminder_24h_sent_at, now())
         WHERE id = v_id;
        v_mails := v_mails + public.exos_queue_event_reminder(v_id, NULL);
        v_2h := v_2h + 1;
      EXCEPTION WHEN OTHERS THEN
        v_failed := v_failed + 1;
        RAISE WARNING 'exos_send_event_reminders: T-2h fan-out for event % failed: % (%)', v_id, SQLERRM, SQLSTATE;
      END;
      IF clock_timestamp() - v_start > interval '20 seconds' THEN v_budget := true; EXIT; END IF;
    END LOOP;
  END IF;

  IF v_budget THEN
    RAISE WARNING 'exos_send_event_reminders: 20s budget hit after %/% events; remainder retried next run', v_24h, v_2h;
  END IF;
  RETURN QUERY SELECT v_24h, v_2h, v_mails, v_failed;
END $$;
REVOKE ALL ON FUNCTION public.exos_send_event_reminders() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_send_event_reminders() TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Manual send: lock the row; only consume the cooldown when mail went out.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_send_event_reminder_now(p_event_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org      uuid;
  v_status   text;
  v_starts   timestamptz;
  v_last     timestamptz;
  v_n        int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_send_event_reminder_now: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, status, starts_at, reminder_manual_sent_at
    INTO v_org, v_status, v_starts, v_last
    FROM public.exos_events WHERE id = p_event_id
    FOR UPDATE;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_send_event_reminder_now: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_send_event_reminder_now: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_send_event_reminder_now: event is not published';
  END IF;
  IF v_starts IS NULL OR v_starts <= now() THEN
    RAISE EXCEPTION 'exos_send_event_reminder_now: event has no future start time';
  END IF;
  IF v_last IS NOT NULL AND v_last > now() - interval '6 hours' THEN
    RAISE EXCEPTION 'exos_send_event_reminder_now: a reminder was sent % ago — wait until %',
      date_trunc('minute', now() - v_last), to_char((v_last + interval '6 hours') AT TIME ZONE 'UTC', 'HH24:MI "UTC"');
  END IF;

  v_n := public.exos_queue_event_reminder(p_event_id, auth.uid());
  IF v_n > 0 THEN
    UPDATE public.exos_events SET reminder_manual_sent_at = now() WHERE id = p_event_id;
  END IF;
  RETURN v_n;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_send_event_reminder_now(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_send_event_reminder_now(uuid) TO authenticated;
