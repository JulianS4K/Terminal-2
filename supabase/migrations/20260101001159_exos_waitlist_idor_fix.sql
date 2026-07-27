-- ============================================================================
-- Migration 20260702144607 — Exos (Bridge / D4): waitlist IDOR fix
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  REPLACE exos_join_waitlist, exos_leave_waitlist
-- Pre-reqs: 20260616180000 (waitlist), 20260616220000 (autoassign — unchanged)
--
-- SECURITY FIX (audit 2026-07-02, MED). Both waitlist RPCs keyed identity on a
-- CLIENT-SUPPLIED email, so anyone who knew a victim's email could:
--   * join: overwrite the victim's row (name/qty/meta), reactivate a cancelled
--     row, learn its uuid, and rebind an anon-created row to themselves;
--   * leave: cancel a victim's spot (client p_email overrode the JWT identity).
--
-- Fix:
--   * exos_join_waitlist — an AUTHENTICATED caller's identity is taken from the
--     JWT email (client p_email ignored for identity); an ANON caller may only
--     touch an UNCLAIMED row (user_id IS NULL). A row owned by a different
--     registered user is never mutated and its id is not disclosed.
--   * exos_leave_waitlist — identity is the JWT (uid or its email); the client
--     p_email can no longer override it. The param is kept for signature compat
--     but is not trusted. (Anon-without-session leave now needs a signed link —
--     out of scope; that unauthenticated email path was the vulnerability.)
-- D4 authors; A1 applies to prod.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.exos_join_waitlist(
  p_event_id uuid,
  p_email    text,
  p_tier_id  uuid    DEFAULT NULL,
  p_name     text    DEFAULT NULL,
  p_quantity integer DEFAULT 1,
  p_meta     jsonb   DEFAULT NULL
) RETURNS TABLE (waitlist_id uuid, queue_position integer)
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_jwt_mail text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));
  -- Authenticated callers can ONLY act as their own session email; anon callers
  -- fall back to the (unverified) client email.
  v_email    text := CASE WHEN v_uid IS NOT NULL THEN v_jwt_mail
                          ELSE lower(btrim(coalesce(p_email, ''))) END;
  v_qty      integer := greatest(1, least(50, coalesce(p_quantity, 1)));
  v_id       uuid;
  v_row_uid  uuid;
  v_pos      integer;
BEGIN
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'exos_join_waitlist: invalid email';
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

  SELECT w.id, w.user_id INTO v_id, v_row_uid FROM public.exos_waitlist w
  WHERE w.event_id = p_event_id AND w.email = v_email
    AND w.tier_id IS NOT DISTINCT FROM p_tier_id;

  IF v_id IS NULL THEN
    INSERT INTO public.exos_waitlist (event_id, tier_id, user_id, email, name, quantity, meta)
    VALUES (p_event_id, p_tier_id, v_uid, v_email, nullif(btrim(p_name), ''), v_qty, p_meta)
    RETURNING id INTO v_id;
  ELSIF v_uid IS NULL AND v_row_uid IS NOT NULL THEN
    -- Anon caller trying to touch a REGISTERED user's row. Refuse without
    -- disclosing the row id — closes the tamper + uuid-disclosure IDOR.
    RAISE EXCEPTION 'exos_join_waitlist: this email is registered — sign in to manage your waitlist entry';
  ELSE
    -- Safe to refresh: authenticated caller acting on their own email, or an
    -- anon caller on an unclaimed (user_id IS NULL) row.
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
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_join_waitlist(uuid, text, uuid, text, integer, jsonb) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_join_waitlist(uuid, text, uuid, text, integer, jsonb) TO anon, authenticated;

-- exos_leave_waitlist — identity is the JWT only; client p_email is ignored for
-- authorization (kept in the signature for compatibility).
CREATE OR REPLACE FUNCTION public.exos_leave_waitlist(p_id uuid, p_email text DEFAULT NULL)
RETURNS boolean
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text := lower(btrim(coalesce(auth.jwt() ->> 'email', '')));  -- JWT only, NOT p_email
  v_rows  integer;
BEGIN
  UPDATE public.exos_waitlist
  SET status = 'cancelled'
  WHERE id = p_id
    AND status <> 'converted'
    AND ( (v_uid IS NOT NULL AND user_id = v_uid)
       -- an unclaimed (anon-created) row whose email matches the caller's own
       -- verified session email — lets a user cancel a row they made before
       -- signing in. Still no client-supplied-email override.
       OR (v_email <> '' AND email = v_email AND user_id IS NULL) );
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_leave_waitlist(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_leave_waitlist(uuid, text) TO anon, authenticated;

-- ROLLBACK: recreate both functions from mig 20260616180000.
