-- ============================================================================
-- Migration 20260925013000 — Exos (Bridge / D4): door staff can't read buyer
--                            emails
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: VIEW exos_ticket_buyer_emails (new); column grant
--              exos_tickets.buyer_email (revoked from authenticated)
-- Pre-reqs: 20260702123000 (the same pattern for barcode_secret)
--
-- Operator decision 2026-09-25: scanners (and content staff) must not see
-- buyers' email addresses. RLS lets every org role read ticket rows, so the
-- column itself is withdrawn from clients, exactly like barcode_secret:
--   * exos_tickets.buyer_email loses its column-level SELECT for authenticated;
--   * exos_ticket_buyer_emails(ticket_id, buyer_email) returns it only to the
--     ticket's owner or buyer, org owner / manager / finance, or an admin.
-- Server-side code (service role, SECURITY DEFINER functions) is unaffected.
--
-- ⚠ DEPLOY ORDER. The live /bridge bundle (built 07-27) selects buyer_email
-- directly from exos_tickets; after this migration that select is refused and
-- ticket pages break. Apply it only AFTER a bundle built from EXP with
-- src/lib/tickets.ts reading emails through the view is deployed.
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE OR REPLACE VIEW public.exos_ticket_buyer_emails
  WITH (security_barrier = true) AS
  SELECT t.id AS ticket_id, t.buyer_email
    FROM public.exos_tickets t
   WHERE t.owner_id = auth.uid()
      OR t.buyer_id = auth.uid()
      OR public.exos_is_admin()
      OR public.exos_has_org_role(t.org_id, ARRAY['owner', 'manager', 'finance']);
REVOKE ALL ON public.exos_ticket_buyer_emails FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.exos_ticket_buyer_emails TO authenticated, service_role;
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly', 'analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.exos_ticket_buyer_emails FROM %I', r);
    END IF;
  END LOOP;
END $$;

REVOKE SELECT (buyer_email) ON public.exos_tickets FROM authenticated;
