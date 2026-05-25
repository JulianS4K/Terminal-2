-- ============================================================================
-- Migration 20260523210000 — Exos (Bridge / D4): ticket-issued / order mail
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_mail (template CHECK +ticket-issued),
--           exos_queue_ticket_issued() RPC (W, new)
-- Pre-reqs: 20260520160000 (exos_mail + drainer), 20260523200000 (event-announce)
--
-- Mail audit (2026-05-23): transfers + org-invite + cancel/update templates
-- existed, but there was NO mail for TICKET ISSUANCE / PURCHASE confirmation
-- (a ticket landing in your wallet sent nothing). This adds the "your ticket is
-- ready" confirmation — used by issuance, free claims, and (when live) the
-- Stripe purchase path.
--
-- Dedicated single-purpose RPC (not folded into exos_queue_mail) to keep the
-- relay-sensitive function untouched + the addition small/auditable (B1).
-- Server-derives recipient from the ticket's owner — no client-supplied
-- recipient/body (no open relay). Caller must be the owner OR org staff.
--
-- D4 authors; A1 applies.
-- ============================================================================

ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
ALTER TABLE public.exos_mail ADD  CONSTRAINT exos_mail_template_check
  CHECK (template IN ('transfer-initiated','transfer-claimed','org-invite',
                      'event-cancelled','event-updated','event-announce',
                      'ticket-issued'));

CREATE OR REPLACE FUNCTION public.exos_queue_ticket_issued(p_ticket_id uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_owner  uuid;
  v_org    uuid;
  v_to     text;
  v_evname text;
  v_tier   text;
  v_safe   text;
  v_id     uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_queue_ticket_issued: not authenticated' USING ERRCODE = '42501';
  END IF;

  SELECT t.owner_id, t.org_id, t.tier_name, lower(u.email), e.name
    INTO v_owner, v_org, v_tier, v_to, v_evname
  FROM public.exos_tickets t
  JOIN auth.users u        ON u.id = t.owner_id
  JOIN public.exos_events e ON e.id = t.event_id
  WHERE t.id = p_ticket_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'exos_queue_ticket_issued: ticket not found';
  END IF;
  -- Owner (their own confirmation), org staff (issuance), or admin.
  IF NOT (v_owner = v_uid OR exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_queue_ticket_issued: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_to IS NULL THEN
    RAISE EXCEPTION 'exos_queue_ticket_issued: owner has no email';
  END IF;

  v_safe := replace(replace(coalesce(v_evname, 'your event'), '<', '&lt;'), '>', '&gt;');

  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  VALUES (
    'ticket-issued', v_to,
    left('Your ticket for ' || v_safe || ' is ready', 200),
    '<p>Your ticket' ||
      CASE WHEN v_tier IS NOT NULL
           THEN ' (' || replace(replace(v_tier, '<', '&lt;'), '>', '&gt;') || ')'
           ELSE '' END ||
      ' for <strong>' || v_safe || '</strong> is in your wallet. Open the app to show your QR at the door.</p>',
    v_uid, 'pending'
  ) RETURNING id INTO v_id;

  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_queue_ticket_issued(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_queue_ticket_issued(uuid) TO authenticated;
