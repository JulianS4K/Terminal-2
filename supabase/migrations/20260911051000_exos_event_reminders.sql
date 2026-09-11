-- ============================================================================
-- Migration 20260911051000 — Exos (Bridge / D4): automatic pre-event reminders
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_events (W: +reminder_24h_sent_at, +reminder_2h_sent_at,
--                           +reminder_manual_sent_at),
--           exos_mail (W: template allowlist +'event-reminder'; INSERT rows),
--           exos_tickets (R), auth.users (R),
--           exos_queue_event_reminder() (new, internal),
--           exos_send_event_reminders() (new, cron / service_role),
--           exos_send_event_reminder_now(uuid) (new, staff RPC),
--           cron.schedule (exos_send_event_reminders, when pg_cron present)
-- Pre-reqs: 20260520160000 (exos_mail), 20260520130000 (exos_tickets),
--           20260523220000 (holder fan-out pattern), 20260515250000 (cron_should_fire),
--           edge fn exos-mail-drain + cron exos-mail-drain-2min (already live)
-- Already applied to prod · via MCP 2026-09-11 (operator-directed; PR #975) —
--   cron exos_send_event_reminders scheduled, verified in cron.job.
--
-- KANBAN D4-OPS-21 (free-first backlog) + d4_bridge/KANBAN "Commit 10".
-- Attendees expect "your event is tomorrow" / "doors open soon" mail. Nothing
-- queued it: the mail rail (exos_mail + drainer) exists and the holder fan-out
-- pattern exists (exos_notify_event_holders), but no scheduler.
--
-- Design:
--   * Two automatic sends per published event, T-24h and T-2h before starts_at,
--     each recorded ONCE on the event row (reminder_24h_sent_at / _2h_sent_at)
--     so a re-run, a late cron, or a reschedule never double-sends. Windows are
--     catch-up safe: an event whose 24h mark passed while the cron was down
--     still gets the 24h mail as long as the event has not started.
--   * A reschedule that moves the event out again resets nothing by itself —
--     exos_reschedule_event already mails holders 'event-rescheduled'; the
--     reminder columns are cleared here ONLY when starts_at moves later than
--     the window already sent (see trigger below), so a postponed event gets a
--     fresh reminder cycle.
--   * One manual "Send reminder now" for owner/manager with a 6h cooldown.
--   * Recipient + body are server-derived (no open relay): one mail per DISTINCT
--     non-voided holder, event name HTML-escaped, times rendered in the event's
--     IANA timezone (falls back to UTC on a bad tz rather than failing).
--   * Cron: every 15 min at :11/:26/:41/:56 (off the saturated :00/:02/:05/:07
--     marks, MIGRATION_CONVENTIONS §5), gated by cron_should_fire, service_role
--     guard, 20s wall-clock budget. Idle cost is one indexed scan.
--
-- The template allowlist is rebuilt as the FULL UNION (base 5 + event-announce
-- + ticket-issued + waitlist-open + event-announcement + event-rescheduled +
-- event-reminder), so this applies cleanly whether or not 20260703150000 (the
-- reconcile) landed. NOTE: 'waitlist-open' (mig 20260616180000, live in prod's
-- CHECK today) was missing from the 0703 reconcile's union — the CI harness
-- caught it (A1 waitlist notify) when this migration first mirrored that list.
--
-- ROLLBACK: DROP FUNCTION exos_send_event_reminder_now(uuid), exos_send_event_reminders(),
--   exos_queue_event_reminder(uuid, uuid); DROP TRIGGER exos_events_reminder_reset;
--   DROP FUNCTION exos_tg_reminder_reset(); cron.unschedule('exos_send_event_reminders');
--   ALTER TABLE exos_events DROP COLUMN reminder_24h_sent_at, reminder_2h_sent_at,
--   reminder_manual_sent_at; re-add the 20260703150000 template CHECK.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Bookkeeping columns.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS reminder_24h_sent_at    timestamptz,
  ADD COLUMN IF NOT EXISTS reminder_2h_sent_at     timestamptz,
  ADD COLUMN IF NOT EXISTS reminder_manual_sent_at timestamptz;

COMMENT ON COLUMN public.exos_events.reminder_24h_sent_at IS
  'When the automatic T-24h holder reminder was queued (NULL = not yet). Cleared by exos_tg_reminder_reset when starts_at moves later.';
COMMENT ON COLUMN public.exos_events.reminder_2h_sent_at IS
  'When the automatic T-2h holder reminder was queued (NULL = not yet).';
COMMENT ON COLUMN public.exos_events.reminder_manual_sent_at IS
  'Last manual "Send reminder now" by staff; enforces the 6h cooldown in exos_send_event_reminder_now.';

-- Cron scans only published, upcoming events that still owe a reminder.
CREATE INDEX IF NOT EXISTS exos_events_reminder_due_idx
  ON public.exos_events (starts_at)
  WHERE status = 'published'
    AND (reminder_24h_sent_at IS NULL OR reminder_2h_sent_at IS NULL);

-- ---------------------------------------------------------------------------
-- 2. Template allowlist — full union + 'event-reminder'.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template IN (
  'transfer-initiated','transfer-claimed','org-invite',
  'event-cancelled','event-updated',
  'event-announce','ticket-issued','waitlist-open',
  'event-announcement','event-rescheduled',
  'event-reminder'));

-- ---------------------------------------------------------------------------
-- 3. Internal fan-out: queue one 'event-reminder' per distinct current holder.
--    Not callable by clients — both public entry points below run as owner.
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
    RETURN 0;
  END IF;

  -- Render times in the event's zone; a malformed tz must not break the send.
  v_tz := coalesce(nullif(v_ev.timezone, ''), 'UTC');
  BEGIN
    v_when := to_char(v_ev.starts_at AT TIME ZONE v_tz, 'FMDay, FMMonth FMDD "at" FMHH12:MI AM');
    IF v_ev.doors_at IS NOT NULL THEN
      v_doors := ' Doors open at ' || to_char(v_ev.doors_at AT TIME ZONE v_tz, 'FMHH12:MI AM') || '.';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_tz   := 'UTC';
    v_when := to_char(v_ev.starts_at AT TIME ZONE 'UTC', 'FMDay, FMMonth FMDD "at" FMHH12:MI AM') || ' UTC';
    v_doors := '';
  END;

  v_safe := replace(replace(coalesce(v_ev.name, 'your event'), '<', '&lt;'), '>', '&gt;');
  IF v_ev.venue_name IS NOT NULL AND v_ev.venue_name <> '' THEN
    v_venue := ' at ' || replace(replace(v_ev.venue_name, '<', '&lt;'), '>', '&gt;');
  END IF;

  v_subj := left('Reminder: ' || v_safe || ' — ' || v_when, 200);
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
-- 4. Cron entry point: claim due events atomically, then fan out.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_send_event_reminders()
RETURNS TABLE (events_24h int, events_2h int, mails_queued int)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_start  timestamptz := clock_timestamp();
  v_id     uuid;
  v_24h    int := 0;
  v_2h     int := 0;
  v_mails  int := 0;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_send_event_reminders: service role only' USING ERRCODE = '42501';
  END IF;
  IF NOT public.cron_should_fire('exos_send_event_reminders') THEN
    RETURN QUERY SELECT 0, 0, 0; RETURN;
  END IF;

  -- T-24h: inside 24h, but more than 2h out (the 2h mail covers the last stretch).
  FOR v_id IN
    UPDATE public.exos_events e
       SET reminder_24h_sent_at = now()
     WHERE e.status = 'published'
       AND e.reminder_24h_sent_at IS NULL
       AND e.starts_at >  now() + interval '2 hours'
       AND e.starts_at <= now() + interval '24 hours'
    RETURNING e.id
  LOOP
    v_mails := v_mails + public.exos_queue_event_reminder(v_id, NULL);
    v_24h := v_24h + 1;
    EXIT WHEN clock_timestamp() - v_start > interval '20 seconds';
  END LOOP;

  -- T-2h: inside 2h and not started. Also marks 24h as done so an event that
  -- was published inside the last 24h doesn't get two mails minutes apart.
  FOR v_id IN
    UPDATE public.exos_events e
       SET reminder_2h_sent_at  = now(),
           reminder_24h_sent_at = coalesce(e.reminder_24h_sent_at, now())
     WHERE e.status = 'published'
       AND e.reminder_2h_sent_at IS NULL
       AND e.starts_at >  now()
       AND e.starts_at <= now() + interval '2 hours'
    RETURNING e.id
  LOOP
    v_mails := v_mails + public.exos_queue_event_reminder(v_id, NULL);
    v_2h := v_2h + 1;
    EXIT WHEN clock_timestamp() - v_start > interval '20 seconds';
  END LOOP;

  RETURN QUERY SELECT v_24h, v_2h, v_mails;
END $$;
REVOKE ALL ON FUNCTION public.exos_send_event_reminders() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_send_event_reminders() TO service_role;

-- ---------------------------------------------------------------------------
-- 5. Staff entry point: "Send reminder now" (owner/manager/admin), 6h cooldown.
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
    FROM public.exos_events WHERE id = p_event_id;
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
      date_trunc('minute', now() - v_last), to_char(v_last + interval '6 hours', 'HH24:MI "UTC"');
  END IF;

  UPDATE public.exos_events SET reminder_manual_sent_at = now() WHERE id = p_event_id;
  v_n := public.exos_queue_event_reminder(p_event_id, auth.uid());
  RETURN v_n;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_send_event_reminder_now(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_send_event_reminder_now(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- 6. Postponed events get a fresh cycle: when starts_at moves LATER than the
--    window a reminder was already sent for, clear that marker.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_reminder_reset()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.starts_at IS DISTINCT FROM OLD.starts_at AND NEW.starts_at IS NOT NULL THEN
    IF NEW.starts_at > now() + interval '24 hours' THEN
      NEW.reminder_24h_sent_at := NULL;
    END IF;
    IF NEW.starts_at > now() + interval '2 hours' THEN
      NEW.reminder_2h_sent_at := NULL;
    END IF;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS exos_events_reminder_reset ON public.exos_events;
CREATE TRIGGER exos_events_reminder_reset
  BEFORE UPDATE OF starts_at ON public.exos_events
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_reminder_reset();

-- ---------------------------------------------------------------------------
-- 7. Cron. Guarded so a preview branch / CI Postgres without pg_cron applies.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos_send_event_reminders') THEN
      PERFORM cron.unschedule('exos_send_event_reminders');
    END IF;
    PERFORM cron.schedule('exos_send_event_reminders', '11,26,41,56 * * * *',
                          $cron$SELECT * FROM public.exos_send_event_reminders();$cron$);
  END IF;
END $$;
