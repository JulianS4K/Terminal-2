-- ============================================================================
-- Migration 20260523220000 — Exos (Bridge / D4): notify event holders
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_notify_event_holders() RPC (W, new)
-- Pre-reqs: 20260520130000 (exos_tickets), 20260520160000 (exos_mail)
--
-- D4-OPS-16 — the `event-cancelled` / `event-updated` mail templates existed but
-- nothing triggered them (cancelEvent only flips status; the EditEvent comment
-- about emailing holders was aspirational). This adds the per-holder notifier:
-- one email per DISTINCT non-voided ticket-holder of the event. Recipient + body
-- server-derived (no open relay; event name tag-escaped). Mirrors the
-- exos_announce_to_followers pattern (branch-verified 2026-05-23).
--
-- D4 authors; A1 applies.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.exos_notify_event_holders(
  p_event_id uuid,
  p_template text
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_name   text;
  v_safe   text;
  v_subj   text;
  v_body   text;
  v_n      int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_notify_event_holders: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_template NOT IN ('event-cancelled', 'event-updated') THEN
    RAISE EXCEPTION 'exos_notify_event_holders: template must be event-cancelled|event-updated';
  END IF;
  SELECT org_id, name INTO v_org, v_name FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_notify_event_holders: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_notify_event_holders: not authorized' USING ERRCODE = '42501';
  END IF;

  v_safe := replace(replace(coalesce(v_name, 'your event'), '<', '&lt;'), '>', '&gt;');
  IF p_template = 'event-cancelled' THEN
    v_subj := left('Cancelled: ' || v_safe, 200);
    v_body := '<p>We''re sorry — <strong>' || v_safe ||
              '</strong> has been cancelled. Open the app for details and any refund information.</p>';
  ELSE
    v_subj := left('Updated: ' || v_safe, 200);
    v_body := '<p><strong>' || v_safe ||
              '</strong> has been updated. Open the app for the latest details.</p>';
  END IF;

  -- One email per distinct current holder (non-voided), even if they hold many.
  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  SELECT p_template, lower(u.email), v_subj, v_body, auth.uid(), 'pending'
  FROM (SELECT DISTINCT owner_id FROM public.exos_tickets
         WHERE event_id = p_event_id AND status <> 'voided') h
  JOIN auth.users u ON u.id = h.owner_id
  WHERE u.email IS NOT NULL;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_notify_event_holders(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_notify_event_holders(uuid, text) TO authenticated;
