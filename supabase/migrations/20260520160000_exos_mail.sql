-- ============================================================================
-- Migration 20260520160000 — Exos (Bridge / D4) phase-5: transactional mail queue
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_mail (W, new), exos_queue_mail() RPC (W, new)
-- Pre-reqs: 20260520120000 (exos_org_memberships, exos_org_invites),
--            20260520130000 (exos_transfers, exos_tickets).
--
-- Replaces the Firestore `mail` collection + Firebase "Trigger Email" extension.
-- A downstream drainer (edge function / cron + email provider) reads pending rows,
-- sends them, and flips status. Until wired, rows accumulate as 'pending'.
--
-- B1 SEC-HIGH fix (bot_chat #438): original design allowed any authenticated
-- user to supply arbitrary to_email + html (open mail relay risk). Fixed by:
--   • Removing the client INSERT policy + GRANT entirely.
--   • Adding exos_queue_mail(p_template, p_ref_id) SECDEF RPC that SERVER-DERIVES
--     to_email from the related record (transfer/invite/ticket) and renders the
--     html body server-side from the template. Client supplies only template name
--     + a ref_id for the related record — no recipient or body.
--   • Only service_role (the drainer) can touch the table directly.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_mail (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  to_email   text NOT NULL CHECK (to_email = lower(to_email) AND char_length(to_email) <= 320),
  template   text NOT NULL CHECK (template IN (
               'transfer-initiated','transfer-claimed','org-invite',
               'event-cancelled','event-updated')),
  subject    text NOT NULL CHECK (char_length(subject) <= 200),
  html       text NOT NULL CHECK (char_length(html) <= 20000),
  status     text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','failed')),
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at    timestamptz,
  error      text
);

-- Drainer reads oldest pending first.
CREATE INDEX IF NOT EXISTS exos_mail_pending_idx ON public.exos_mail (created_at) WHERE status = 'pending';

ALTER TABLE public.exos_mail ENABLE ROW LEVEL SECURITY;

-- No client INSERT/SELECT/UPDATE/DELETE policies. Only service_role (the drainer)
-- touches this table directly. Clients queue mail via exos_queue_mail() RPC below.
REVOKE ALL ON public.exos_mail FROM anon, authenticated;

-- ============================================================================
-- exos_queue_mail(p_template, p_ref_id) — SECDEF RPC
--
-- Clients call this to queue a transactional email. The recipient and body are
-- SERVER-DERIVED from the related record; the client cannot supply either.
--
-- Supported templates and their ref_id:
--   transfer-initiated  → p_ref_id = exos_transfers.id (caller must be sender)
--   transfer-claimed    → p_ref_id = exos_transfers.id (caller = verified receiver; notifies sender)
--   org-invite          → p_ref_id = exos_org_invites.token (caller must be inviter)
--   event-cancelled     → p_ref_id = exos_tickets.id (caller must be org staff)
--   event-updated       → p_ref_id = exos_tickets.id (caller must be org staff)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.exos_queue_mail(
  p_template text,
  p_ref_id   uuid DEFAULT NULL
) RETURNS uuid
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_to_email text;
  v_subject  text;
  v_html     text;
  v_id       uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  CASE p_template

  WHEN 'transfer-initiated' THEN
    -- Sender notifies receiver when initiating a transfer.
    -- Derives recipient from the transfer row (caller must own it).
    SELECT lower(trim(t.receiver_email)),
           'Someone sent you a ticket',
           '<p>You have a pending ticket transfer waiting for you in the Bridge app. Open the app to claim it.</p>'
    INTO v_to_email, v_subject, v_html
    FROM public.exos_transfers t
    WHERE t.id = p_ref_id
      AND t.sender_id = v_uid
      AND t.status = 'pending';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Transfer not found or not authorized (id=%)', p_ref_id;
    END IF;

  WHEN 'transfer-claimed' THEN
    -- Receiver (claimer) notifies the sender that their transfer was picked up.
    -- p_ref_id = exos_transfers.id. Caller must be the verified receiver.
    -- Looks up the SENDER's email from the transfer row.
    SELECT lower(trim(sender.email)),
           'Your ticket transfer was claimed',
           '<p>Good news — someone claimed the ticket you transferred. The transfer is complete and the new owner''s ticket is now active.</p>'
    INTO v_to_email, v_subject, v_html
    FROM public.exos_transfers t
    JOIN auth.users sender ON sender.id = t.sender_id
    JOIN auth.users caller ON caller.id = v_uid
    WHERE t.id = p_ref_id
      AND lower(trim(t.receiver_email)) = lower(trim(caller.email))
      AND t.status IN ('pending', 'completed');
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Transfer not found or not authorized for claim notification (id=%)', p_ref_id;
    END IF;

  WHEN 'org-invite' THEN
    -- Org staff invites someone; mail goes to the invitee's email.
    -- Derives recipient from the invite row (caller must have sent the invite).
    SELECT lower(trim(i.email)),
           'You have been invited to join an organization',
           '<p>You have been invited to join an organization on Bridge. Open the app to accept.</p>'
    INTO v_to_email, v_subject, v_html
    FROM public.exos_org_invites i
    WHERE i.token = p_ref_id
      AND i.created_by = v_uid
      AND i.status = 'pending';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Invite not found or not authorized (id=%)', p_ref_id;
    END IF;

  WHEN 'event-cancelled', 'event-updated' THEN
    -- Org staff notifies a ticket holder about a change. p_ref_id = exos_ticket.id.
    -- Derives recipient from the ticket's owner in auth.users.
    -- Caller must be org staff (owner/manager) for the event's org.
    SELECT lower(trim(u.email)),
           CASE p_template
             WHEN 'event-cancelled' THEN 'Your event has been cancelled'
             ELSE                        'Your event has been updated'
           END,
           CASE p_template
             WHEN 'event-cancelled' THEN '<p>We are sorry to inform you that the event associated with your ticket has been cancelled. Please check the Bridge app for details and refund information.</p>'
             ELSE                        '<p>The event associated with your ticket has been updated. Please check the Bridge app for the latest details.</p>'
           END
    INTO v_to_email, v_subject, v_html
    FROM public.exos_tickets tkt
    JOIN auth.users u ON u.id = tkt.owner_id
    WHERE tkt.id = p_ref_id
      AND EXISTS (
        SELECT 1
        FROM public.exos_org_memberships m
        JOIN public.exos_events ev ON ev.org_id = m.org_id
        WHERE m.user_id = v_uid
          AND m.disabled IS NOT TRUE
          AND m.role IN ('owner', 'manager')
          AND ev.id = tkt.event_id
      );
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ticket not found or caller lacks org-staff access (id=%)', p_ref_id;
    END IF;

  ELSE
    RAISE EXCEPTION 'Unknown template: %', p_template;
  END CASE;

  IF v_to_email IS NULL THEN
    RAISE EXCEPTION 'Could not derive recipient for template %', p_template;
  END IF;

  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  VALUES (p_template, v_to_email, v_subject, v_html, v_uid, 'pending')
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

REVOKE ALL ON FUNCTION public.exos_queue_mail(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_queue_mail(text, uuid) TO authenticated;

COMMENT ON FUNCTION public.exos_queue_mail(text, uuid) IS
  'D4 mig 20260520160000: queue transactional mail via server-derived recipient.
   Client supplies template name + ref_id for the related record. to_email and
   html body are derived server-side — no open relay. SECDEF; only service_role
   reads the exos_mail table directly (the drainer). B1 SEC-HIGH fix (bot_chat #438).';
