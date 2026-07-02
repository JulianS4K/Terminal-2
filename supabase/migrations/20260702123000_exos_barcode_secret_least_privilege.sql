-- ============================================================================
-- Migration 20260702123000 — Exos (Bridge / D4): scope barcode_secret out of
--                            the finance/content read path (least privilege)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  REVOKE/GRANT column privileges on exos_tickets (authenticated),
--           NEW exos_can_read_ticket_secret(uuid),
--           NEW VIEW exos_ticket_barcode_secrets
-- Pre-reqs: 20260520130000 (tickets + exos_tickets_sel + exos_has_org_role +
--           exos_is_admin)
--
-- SECURITY FIX (audit 2026-07-02, MEDIUM-HIGH). The exos_tickets_sel RLS policy
-- (mig 20260520130000 §6) admits the `finance` and `content` org roles to a
-- row SELECT. RLS is row-level, not column-level, so passing the policy reads
-- EVERY column — including barcode_secret, the per-ticket HMAC key. A finance
-- clerk or content editor could therefore read the secret for any ticket in the
-- org (e.g. via the event report / org sales reads, which `SELECT *`), sign a
-- valid rotating barcode for someone else's ticket, and walk into the event as
-- that attendee. Only owner/manager/scanner staff need the secret (for door
-- verification), plus the ticket's own owner/buyer (to render their pass).
--
-- Why this can't be a plain "grant it back selectively": every app user shares
-- the single Postgres `authenticated` role — the finance-vs-scanner distinction
-- is an APP role (exos_has_org_role), invisible to Postgres column grants. So
-- the split has to be app logic. This migration:
--
--   1. Revokes barcode_secret from the base-table read surface for
--      `authenticated` (table-level SELECT implies all columns, so we drop the
--      table grant and re-grant every column EXCEPT barcode_secret). No client
--      — finance, content, scanner, owner, or buyer — can read the column off
--      exos_tickets anymore. The SECURITY DEFINER RPCs (mint / check-in verify /
--      claim / void) and service_role are unaffected: they read the column as
--      the function/table owner, not as `authenticated`.
--
--   2. Re-exposes the secret ONLY to authorized readers through a row/role-
--      gated view (exos_ticket_barcode_secrets). The frontend fetches the
--      secret from this view for the two paths that legitimately need it:
--      the owner/buyer wallet render and the scanner offline registry.
--
-- Report / dashboard reads (event report, org sales) keep reading exos_tickets
-- and simply no longer receive the secret column — which is the fix.
--
-- No table data changes; privilege + view only. Idempotent (CREATE OR REPLACE /
-- REVOKE+GRANT are safe to re-run).
--
-- ⚠ B1 review requested on the privilege model before prod apply (mirrors the
-- phase-2 note). D4 authors; validate on a Supabase preview branch; A1 applies.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Who may read a ticket's barcode secret? SECURITY DEFINER so it can read
--    exos_tickets to resolve ownership/org regardless of the caller's own RLS,
--    while auth.uid()/exos_has_org_role still reflect the CALLER (JWT/GUCs).
--    Deliberately NOT finance/content — that is the whole point of this fix.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_can_read_ticket_secret(p_ticket_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_tickets t
    WHERE t.id = p_ticket_id
      AND (
        t.owner_id = auth.uid()
        OR t.buyer_id = auth.uid()
        OR public.exos_is_admin()
        OR public.exos_has_org_role(t.org_id, ARRAY['owner','manager','scanner'])
      )
  );
$$;
REVOKE EXECUTE ON FUNCTION public.exos_can_read_ticket_secret(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_can_read_ticket_secret(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_can_read_ticket_secret(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. The gated read surface for the secret. Runs with the view owner's rights
--    (security_invoker = false, the default) so it can read barcode_secret even
--    though `authenticated` no longer can on the base table; the WHERE clause is
--    the access gate. Only rows the caller may read are returned at all, so it
--    doesn't leak ticket-id existence either.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.exos_ticket_barcode_secrets AS
  SELECT t.id AS ticket_id, t.barcode_secret
  FROM public.exos_tickets t
  WHERE public.exos_can_read_ticket_secret(t.id);
ALTER VIEW public.exos_ticket_barcode_secrets SET (security_invoker = false);

REVOKE ALL    ON public.exos_ticket_barcode_secrets FROM anon, authenticated;
GRANT  SELECT ON public.exos_ticket_barcode_secrets TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Remove barcode_secret from the base-table read surface for clients.
--    A table-level SELECT grant covers every column, so a column-level REVOKE
--    on top of it is a no-op — the only way to hide one column is to drop the
--    table grant and re-grant the remaining columns explicitly. This is the
--    full exos_tickets column set from mig 20260520130000 §1, minus
--    barcode_secret. (No later migration ALTERs exos_tickets, so this list is
--    complete; if a column is ever added, add it here too.)
-- ---------------------------------------------------------------------------
REVOKE SELECT ON public.exos_tickets FROM authenticated;
GRANT  SELECT (
  id, event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
  status, price_paid, order_ref, channel_source, promoter_id,
  pending_transfer_id, transfer_id, voided_at, voided_by, voided_reason,
  check_in_at, last_reissue_at, created_at, updated_at
) ON public.exos_tickets TO authenticated;

-- ROLLBACK:
--   GRANT SELECT ON public.exos_tickets TO authenticated;   -- restore full-row read
--   DROP VIEW IF EXISTS public.exos_ticket_barcode_secrets;
--   DROP FUNCTION IF EXISTS public.exos_can_read_ticket_secret(uuid);
