-- ============================================================================
-- Migration 20260926010000 — Exos (Bridge / D4): waitlist needs sign-in;
--                            users can delete their Exos account
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: FUNCTION exos_join_waitlist (replaced; anon EXECUTE revoked);
--              FUNCTION exos_delete_my_account (new, authenticated)
--           W (inside exos_delete_my_account, for the caller only):
--              exos_tickets, exos_checkout_sessions, exos_cart_holds,
--              exos_invoices, exos_transfers, exos_waitlist,
--              exos_org_memberships, exos_org_follows, exos_event_saves,
--              exos_notification_reads, exos_fan_referrals, exos_profiles,
--              exos_mail, exos_promoters, exos_org_invites;
--              auth.users / auth.identities / auth.sessions / auth.refresh_tokens
-- Pre-reqs: 20260925021000
--
-- Operator decisions 2026-09-26 (production-readiness pass):
--
-- 1. Joining a waitlist requires a signed-in account with a confirmed email.
--    Anonymous joins let anyone put any address on a sold-out show's list:
--    returned seats were then offered (and held) for junk addresses, and
--    "waitlist open" mail went to strangers. Holds and free claims already
--    need a confirmed email; the waitlist now matches.
--
-- 2. Account deletion ("Delete my account" on the profile page). A hard
--    DELETE of auth.users is NOT safe here: exos_tickets (buyer_id, owner_id),
--    exos_checkout_sessions and exos_transfers reference it ON DELETE CASCADE,
--    so the organizer's sales and payment records would vanish with the user.
--    Instead the account is closed and anonymised:
--      * personal data is removed (emails, attendee names, profile, follows,
--        saves, waitlist entries, memberships, queued mail);
--      * order rows the organizer needs stay, with no personal data on them;
--      * the login is disabled for good: email replaced by a tombstone,
--        metadata cleared, identities/sessions/refresh tokens deleted, and the
--        user banned indefinitely.
--    Refused (with a clear message) for platform admins, org owners (transfer
--    ownership first), and while the caller holds tickets for an event that
--    hasn't ended or has a transfer pending, so nobody loses a ticket they're
--    about to use. The database's auth users are shared with Terminal-2, whose
--    staff sign in on the operator's email domain; admins are refused and the
--    function only ever acts on auth.uid().
--
-- Re-run safe. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- 1. Waitlist: signed-in, confirmed email ---------------------------------------

CREATE OR REPLACE FUNCTION public.exos_join_waitlist(
  p_event_id uuid, p_email text, p_tier_id uuid DEFAULT NULL::uuid, p_name text DEFAULT NULL::text,
  p_quantity integer DEFAULT 1, p_meta jsonb DEFAULT NULL::jsonb)
RETURNS TABLE(waitlist_id uuid, queue_position integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  -- Always the session's own email; p_email is kept for signature compatibility.
  v_email text;
  v_qty   integer := greatest(1, least(50, coalesce(p_quantity, 1)));
  v_id    uuid;
  v_pos   integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_join_waitlist: sign in to join the waitlist' USING ERRCODE = '42501';
  END IF;
  SELECT lower(btrim(u.email)) INTO v_email FROM auth.users u
   WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'exos_join_waitlist: confirm your email before joining the waitlist' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e
                 WHERE e.id = p_event_id AND e.status = 'published') THEN
    RAISE EXCEPTION 'exos_join_waitlist: event not found or not published';
  END IF;
  IF p_tier_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_ticket_tiers t
       WHERE t.id = p_tier_id AND t.event_id = p_event_id) THEN
    RAISE EXCEPTION 'exos_join_waitlist: tier does not belong to event';
  END IF;

  SELECT w.id INTO v_id FROM public.exos_waitlist w
   WHERE w.event_id = p_event_id AND w.email = v_email
     AND w.tier_id IS NOT DISTINCT FROM p_tier_id;

  IF v_id IS NULL THEN
    INSERT INTO public.exos_waitlist (event_id, tier_id, user_id, email, name, quantity, meta)
    VALUES (p_event_id, p_tier_id, v_uid, v_email, nullif(btrim(p_name), ''), v_qty, p_meta)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.exos_waitlist
       SET name     = coalesce(nullif(btrim(p_name), ''), name),
           quantity = v_qty,
           user_id  = coalesce(user_id, v_uid),
           meta     = coalesce(p_meta, meta),
           status   = CASE WHEN status = 'cancelled' THEN 'waiting' ELSE status END
     WHERE id = v_id;
  END IF;

  SELECT count(*) + 1 INTO v_pos
    FROM public.exos_waitlist w
   WHERE w.event_id = p_event_id
     AND w.tier_id IS NOT DISTINCT FROM p_tier_id
     AND w.status = 'waiting'
     AND w.created_at < (SELECT created_at FROM public.exos_waitlist WHERE id = v_id);

  RETURN QUERY SELECT v_id, v_pos;
END $function$;

REVOKE ALL ON FUNCTION public.exos_join_waitlist(uuid, text, uuid, text, integer, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_join_waitlist(uuid, text, uuid, text, integer, jsonb) TO authenticated, service_role;

-- 2. Delete my account -------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.exos_delete_my_account()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text;
  v_tomb  text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_delete_my_account: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF public.exos_is_admin() THEN
    RAISE EXCEPTION 'exos_delete_my_account: platform admin accounts can''t be deleted here' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_orgs o WHERE o.owner_uid = v_uid) THEN
    RAISE EXCEPTION 'exos_delete_my_account: you own an organization — transfer ownership before deleting your account'
      USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (
       SELECT 1 FROM public.exos_tickets t
         JOIN public.exos_events e ON e.id = t.event_id
        WHERE t.owner_id = v_uid AND t.status = 'active'
          AND (coalesce(e.ends_at, e.starts_at) IS NULL
               OR coalesce(e.ends_at, e.starts_at + interval '6 hours') > now())) THEN
    RAISE EXCEPTION 'exos_delete_my_account: you have tickets for an upcoming event — transfer them or wait until after the event'
      USING ERRCODE = 'P0001';
  END IF;
  IF EXISTS (SELECT 1 FROM public.exos_transfers tr WHERE tr.sender_id = v_uid AND tr.status = 'pending') THEN
    RAISE EXCEPTION 'exos_delete_my_account: you have a ticket transfer pending — cancel it first' USING ERRCODE = 'P0001';
  END IF;

  SELECT lower(btrim(u.email)) INTO v_email FROM auth.users u WHERE u.id = v_uid;
  v_tomb := 'deleted+' || v_uid::text || '@deleted.invalid';

  -- Order records stay for the organizer, without personal data.
  UPDATE public.exos_tickets SET buyer_email = NULL, attendee_name = NULL
   WHERE owner_id = v_uid OR buyer_id = v_uid;
  UPDATE public.exos_checkout_sessions SET buyer_email = NULL WHERE buyer_uid = v_uid;
  UPDATE public.exos_invoices SET buyer_email = NULL WHERE buyer_id = v_uid;
  UPDATE public.exos_transfers SET sender_email = NULL WHERE sender_id = v_uid;
  IF v_email IS NOT NULL AND v_email <> '' THEN
    UPDATE public.exos_transfers SET receiver_email = v_tomb WHERE lower(receiver_email) = v_email;
    UPDATE public.exos_promoters SET email = NULL WHERE lower(email) = v_email;
    DELETE FROM public.exos_org_invites WHERE lower(email) = v_email AND claimed_by IS NULL;
    DELETE FROM public.exos_mail WHERE lower(to_email) = v_email AND status IN ('pending', 'sending');
    UPDATE public.exos_mail SET to_email = v_tomb WHERE lower(to_email) = v_email;
  END IF;

  -- Personal data that has no record-keeping value.
  DELETE FROM public.exos_cart_holds       WHERE buyer_uid = v_uid;
  DELETE FROM public.exos_waitlist         WHERE user_id = v_uid OR (v_email <> '' AND lower(email) = v_email);
  DELETE FROM public.exos_org_memberships  WHERE user_id = v_uid;
  DELETE FROM public.exos_org_follows      WHERE follower_uid = v_uid;
  DELETE FROM public.exos_event_saves      WHERE user_id = v_uid;
  DELETE FROM public.exos_notification_reads WHERE uid = v_uid;
  DELETE FROM public.exos_fan_referrals    WHERE user_id = v_uid;
  DELETE FROM public.exos_profiles         WHERE id = v_uid;

  -- Close the login for good (the row stays so order history keeps its keys).
  UPDATE auth.users
     SET email = v_tomb, phone = NULL,
         raw_user_meta_data = '{}'::jsonb,
         banned_until = 'infinity'::timestamptz,
         updated_at = now()
   WHERE id = v_uid;
  DELETE FROM auth.identities     WHERE user_id = v_uid;
  DELETE FROM auth.sessions       WHERE user_id = v_uid;
  DELETE FROM auth.refresh_tokens WHERE user_id = v_uid::text;

  RETURN jsonb_build_object('ok', true);
END $function$;

REVOKE ALL ON FUNCTION public.exos_delete_my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.exos_delete_my_account() TO authenticated, service_role;
