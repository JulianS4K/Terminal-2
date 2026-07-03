-- ============================================================================
-- Migration 20260703121000 — Exos (Bridge / D4): organizer → attendee announcements
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_mail (W: +'event-announcement' template value),
--           exos_event_announcements (W, new),
--           exos_send_event_announcement() RPC (W, new)
-- Pre-reqs: 20260520130000 (exos_tickets), 20260520160000 (exos_mail),
--            20260523220000 (exos_notify_event_holders — the pattern mirrored here).
--
-- Two-sided feature. Sellers (org owner/manager) broadcast a free-text update to
-- everyone holding a (non-voided) ticket for an event — "doors moved to 7pm",
-- "merch pre-order", "parking note". Buyers receive it two ways:
--   * an email (one per distinct holder) via the existing exos_mail queue, and
--   * an in-app thread on their ticket (TicketDetail "Updates from the organizer").
--
-- The announcement text is PERSISTED (unlike the fixed event-cancelled/updated
-- templates) so buyers who miss the email still see the history in-app. Recipient
-- list is server-derived from ticket ownership (no open relay); the body is
-- tag-escaped before it ever lands in the mail html.
--
-- D4 authors; A1 applies.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Extend the exos_mail template allowlist with 'event-announcement'.
--    The original CHECK (mig 20260520160000) was an inline column constraint,
--    auto-named exos_mail_template_check. Drop + re-add with the new value.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template IN (
  'transfer-initiated','transfer-claimed','org-invite',
  'event-cancelled','event-updated','event-announcement'));

-- ---------------------------------------------------------------------------
-- 2. Persisted announcement log. One row per broadcast.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_event_announcements (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id          uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  subject         text NOT NULL CHECK (char_length(subject) BETWEEN 1 AND 160),
  body            text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 4000),
  sent_by         uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  recipient_count integer NOT NULL DEFAULT 0 CHECK (recipient_count >= 0),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_event_announcements_event_idx
  ON public.exos_event_announcements (event_id, created_at DESC);

ALTER TABLE public.exos_event_announcements ENABLE ROW LEVEL SECURITY;

-- Read side — TWO audiences, both SELECT-only:
--   * org staff (any role) + admins — to render the sent history on the report.
--   * ticket holders — a user who holds a non-voided ticket for the event may
--     read that event's announcements (the in-app buyer thread). This is the
--     ONLY cross-org read path, and it is scoped to events the user attends.
-- No INSERT/UPDATE/DELETE policy — writes go through the SECDEF RPC below so the
-- recipient fan-out and the persisted row are always created together.
CREATE POLICY exos_event_announcements_staff_sel ON public.exos_event_announcements
  FOR SELECT TO authenticated
  USING (
    exos_is_admin()
    OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content'])
  );
CREATE POLICY exos_event_announcements_holder_sel ON public.exos_event_announcements
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.exos_tickets t
    WHERE t.event_id = exos_event_announcements.event_id
      AND t.owner_id = auth.uid()
      AND t.status <> 'voided'
  ));

REVOKE ALL ON public.exos_event_announcements FROM anon, authenticated;
GRANT SELECT ON public.exos_event_announcements TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. exos_send_event_announcement(event, subject, body) — SECDEF RPC.
--    Org owner/manager (or admin) only. Persists the announcement AND queues one
--    email per distinct non-voided holder. Returns (announcement_id, count).
--    Mirrors exos_notify_event_holders (mig 20260523220000).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_send_event_announcement(
  p_event_id uuid,
  p_subject  text,
  p_body     text
) RETURNS TABLE(announcement_id uuid, recipient_count int)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid       uuid := auth.uid();
  v_org       uuid;
  v_name      text;
  v_subject   text;
  v_body      text;
  v_safe_name text;
  v_safe_body text;
  v_subj_line text;
  v_html      text;
  v_id        uuid;
  v_n         int := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_send_event_announcement: not authenticated' USING ERRCODE = '42501';
  END IF;

  -- Normalize + validate the organizer-supplied text (trim, bound length).
  v_subject := btrim(coalesce(p_subject, ''));
  v_body    := btrim(coalesce(p_body, ''));
  IF v_subject = '' OR char_length(v_subject) > 160 THEN
    RAISE EXCEPTION 'exos_send_event_announcement: subject must be 1..160 chars';
  END IF;
  IF v_body = '' OR char_length(v_body) > 4000 THEN
    RAISE EXCEPTION 'exos_send_event_announcement: body must be 1..4000 chars';
  END IF;

  SELECT org_id, name INTO v_org, v_name FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_send_event_announcement: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_send_event_announcement: not authorized' USING ERRCODE = '42501';
  END IF;

  -- Persist the announcement first so the in-app thread has it even if the mail
  -- queue insert is a no-op (zero holders).
  INSERT INTO public.exos_event_announcements (event_id, org_id, subject, body, sent_by)
  VALUES (p_event_id, v_org, v_subject, v_body, v_uid)
  RETURNING id INTO v_id;

  -- Tag-escape everything organizer-controlled before it enters the mail html.
  v_safe_name := replace(replace(coalesce(v_name, 'your event'), '<', '&lt;'), '>', '&gt;');
  v_safe_body := replace(replace(v_body, '<', '&lt;'), '>', '&gt;');
  v_subj_line := left('Update: ' || v_safe_name, 200);
  v_html := '<p><strong>' || v_safe_name || '</strong></p>'
         || '<p>' || replace(v_safe_body, chr(10), '<br>') || '</p>'
         || '<p style="color:#888;font-size:12px">Open the Bridge app for full event details.</p>';

  -- One email per distinct current holder (non-voided), even if they hold many.
  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  SELECT 'event-announcement', lower(u.email), v_subj_line, v_html, v_uid, 'pending'
  FROM (SELECT DISTINCT owner_id FROM public.exos_tickets
         WHERE event_id = p_event_id AND status <> 'voided') h
  JOIN auth.users u ON u.id = h.owner_id
  WHERE u.email IS NOT NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  UPDATE public.exos_event_announcements SET recipient_count = v_n WHERE id = v_id;

  announcement_id := v_id;
  recipient_count := v_n;
  RETURN NEXT;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_send_event_announcement(uuid, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_send_event_announcement(uuid, text, text) TO authenticated;

COMMENT ON FUNCTION public.exos_send_event_announcement(uuid, text, text) IS
  'D4 mig 20260703121000: org owner/manager (or admin) broadcasts a free-text
   update to non-voided ticket holders of an event. Persists the row (in-app
   thread) + queues one server-derived email per distinct holder. No open relay:
   recipients derived from ticket ownership, body tag-escaped.';
