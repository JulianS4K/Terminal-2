-- ============================================================================
-- Migration 20260703124000 — Exos (Bridge / D4): reschedule an event
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_mail (W: +'event-rescheduled' template value),
--           exos_event_reschedules (W, new),
--           exos_reschedule_event() RPC (W, new; UPDATEs exos_events timing)
-- Pre-reqs: 20260520120000 (exos_events), 20260520130000 (exos_tickets),
--            20260520160000 (exos_mail), 20260703121000 (mail template allowlist).
--
-- A first-class "postpone / move" action, distinct from a silent EditEvent field
-- change: it moves the event's date/time, PERSISTS the old→new change (audit +
-- buyer-facing "rescheduled from X to Y"), and notifies every non-voided holder
-- with the NEW date in the message. Tickets stay valid (same event id) — this is
-- reschedule, not cancel (cancel already exists, mig 20260523220000).
--
-- The new local wall-clock (occurs_at_local) is recomputed by the caller and
-- passed in, mirroring createEvent/updateEvent's catalog-consistency (D0 read
-- across catalog + exos events keys on occurs_at_local). The holder email body
-- is server-rendered from the event's own timezone — no client-supplied HTML.
--
-- D4 authors; A1 applies.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Extend the exos_mail template allowlist with 'event-rescheduled'
--    (re-adds the full set the prior migrations established).
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template IN (
  'transfer-initiated','transfer-claimed','org-invite',
  'event-cancelled','event-updated','event-announcement','event-rescheduled'));

-- ---------------------------------------------------------------------------
-- 2. Reschedule log — one row per move. Buyers see the from→to on their ticket.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_event_reschedules (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  old_starts_at   timestamptz,
  new_starts_at   timestamptz NOT NULL,
  reason          text CHECK (reason IS NULL OR char_length(reason) <= 500),
  rescheduled_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  recipient_count integer NOT NULL DEFAULT 0 CHECK (recipient_count >= 0),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_reschedules_event_idx
  ON public.exos_event_reschedules (event_id, created_at DESC);

ALTER TABLE public.exos_event_reschedules ENABLE ROW LEVEL SECURITY;

-- Read side mirrors announcements (mig 20260703121000): org staff + admins see
-- the history; a ticket holder sees reschedules for events they hold a non-voided
-- ticket for (the in-app notice). No client write policy — the SECDEF RPC is the
-- only writer, so the event move + the log row + the fan-out stay atomic.
CREATE POLICY exos_event_reschedules_staff_sel ON public.exos_event_reschedules
  FOR SELECT TO authenticated
  USING (
    exos_is_admin()
    OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content'])
  );
CREATE POLICY exos_event_reschedules_holder_sel ON public.exos_event_reschedules
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.exos_tickets t
    WHERE t.event_id = exos_event_reschedules.event_id
      AND t.owner_id = auth.uid()
      AND t.status <> 'voided'
  ));

REVOKE ALL ON public.exos_event_reschedules FROM anon, authenticated;
GRANT SELECT ON public.exos_event_reschedules TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. exos_reschedule_event(...) — SECDEF. Owner/manager (or admin). Moves the
--    event's timing, logs the old→new, and emails every non-voided holder with
--    the new date. Returns (reschedule_id, recipient_count).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_reschedule_event(
  p_event_id        uuid,
  p_new_starts_at   timestamptz,
  p_new_doors_at    timestamptz DEFAULT NULL,
  p_new_ends_at     timestamptz DEFAULT NULL,
  p_occurs_at_local text        DEFAULT NULL,
  p_reason          text        DEFAULT NULL
) RETURNS TABLE(reschedule_id uuid, recipient_count int)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_org    uuid;
  v_name   text;
  v_tz     text;
  v_old    timestamptz;
  v_reason text;
  v_safe   text;
  v_when   text;
  v_subj   text;
  v_html   text;
  v_id     uuid;
  v_n      int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_reschedule_event: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_new_starts_at IS NULL THEN
    RAISE EXCEPTION 'exos_reschedule_event: new start time is required';
  END IF;
  v_reason := btrim(coalesce(p_reason, ''));
  IF char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'exos_reschedule_event: reason too long (max 500)';
  END IF;

  SELECT org_id, name, timezone, starts_at
    INTO v_org, v_name, v_tz, v_old
    FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_reschedule_event: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_reschedule_event: not authorized' USING ERRCODE = '42501';
  END IF;

  -- Move the event. occurs_at_local is recomputed by the caller (catalog
  -- consistency); doors/ends are only overwritten when supplied.
  UPDATE public.exos_events
     SET starts_at       = p_new_starts_at,
         doors_at        = COALESCE(p_new_doors_at, doors_at),
         ends_at         = COALESCE(p_new_ends_at, ends_at),
         occurs_at_local = COALESCE(p_occurs_at_local, occurs_at_local),
         updated_at      = now()
   WHERE id = p_event_id;

  INSERT INTO public.exos_event_reschedules
    (event_id, org_id, old_starts_at, new_starts_at, reason, rescheduled_by)
  VALUES (p_event_id, v_org, v_old, p_new_starts_at, NULLIF(v_reason, ''), v_uid)
  RETURNING id INTO v_id;

  -- Server-render the notice in the EVENT's timezone (what the organizer means).
  v_safe := replace(replace(coalesce(v_name, 'your event'), '<', '&lt;'), '>', '&gt;');
  v_when := to_char(p_new_starts_at AT TIME ZONE COALESCE(v_tz, 'UTC'), 'FMDay, FMMon FMDD, YYYY "at" HH12:MI AM');
  v_subj := left('Rescheduled: ' || v_safe, 200);
  v_html := '<p><strong>' || v_safe || '</strong> has been rescheduled.</p>'
         || '<p>New date: <strong>' || v_when || '</strong>'
         || CASE WHEN v_tz IS NOT NULL THEN ' (' || v_tz || ')' ELSE '' END || '.</p>'
         || CASE WHEN v_reason <> '' THEN '<p>' || replace(replace(v_reason, '<', '&lt;'), '>', '&gt;') || '</p>' ELSE '' END
         || '<p>Your existing ticket stays valid — no action needed. Open the Bridge app for details.</p>';

  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  SELECT 'event-rescheduled', lower(u.email), v_subj, v_html, v_uid, 'pending'
  FROM (SELECT DISTINCT owner_id FROM public.exos_tickets
         WHERE event_id = p_event_id AND status <> 'voided') h
  JOIN auth.users u ON u.id = h.owner_id
  WHERE u.email IS NOT NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  UPDATE public.exos_event_reschedules SET recipient_count = v_n WHERE id = v_id;

  reschedule_id := v_id;
  recipient_count := v_n;
  RETURN NEXT;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_reschedule_event(uuid, timestamptz, timestamptz, timestamptz, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_reschedule_event(uuid, timestamptz, timestamptz, timestamptz, text, text) TO authenticated;

COMMENT ON FUNCTION public.exos_reschedule_event(uuid, timestamptz, timestamptz, timestamptz, text, text) IS
  'D4 mig 20260703124000: owner/manager (or admin) postpones/moves an event —
   updates timing, logs old→new (exos_event_reschedules), emails non-voided
   holders the new date (server-rendered in the event tz). Tickets stay valid.';
