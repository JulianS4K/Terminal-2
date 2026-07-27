-- ============================================================================
-- Migration 20260616180000 — Exos (Bridge / D4): event/tier waitlist
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_waitlist (W, new), exos_mail template CHECK (+'waitlist-open'),
--           exos_join_waitlist / exos_leave_waitlist / exos_notify_waitlist /
--           exos_waitlist_summary (W, new RPCs); reads exos_events,
--           exos_ticket_tiers, exos_org_memberships (R)
-- Pre-reqs: 20260520120000 (exos_events/tiers/has_org_role), 20260520160000
--           (exos_mail + drainer), pgcrypto/gen_random_uuid()
--
-- Feature parity with Hi.Events' "join the waitlist" on a sold-out event/tier
-- (audit 2026-06-16). A buyer (anon OR authenticated) registers interest for a
-- sold-out event — optionally a specific tier — and is emailed if the organizer
-- releases capacity. Mirrors the phase-1 security model exactly:
--   * deny-by-default RLS; org staff read/manage their event's list; a signed-in
--     buyer reads only their OWN rows (by user_id). Anon reads NOTHING directly.
--   * the public JOIN path is a SECDEF RPC (anon-callable) — base table carries
--     no anon grant — so a sold-out public event can capture demand without a
--     login, but the row is server-validated (event must be published).
--   * notifications reuse the exos_mail drainer with a server-DERIVED recipient
--     (the waitlist row's own email) — no client-supplied address, no open relay.
-- D4 authors; validate on a Supabase preview branch; A1 applies to prod.
-- ⚠ B1: new buyer-PII surface (email + name on a public-insert RPC). RLS +
-- anon-insert-only-via-RPC mirror the org-invite model already reviewed; flag
-- for the same retention/GDPR pass as the rest of the buyer-data capture (charter §6.5).
-- ============================================================================

-- ===========================================================================
-- 1. Waitlist table. One row = one buyer's interest in an event (tier optional).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_waitlist (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id    uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  -- NULL = "any tier / general admission" waitlist; else a specific sold-out tier.
  tier_id     uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  -- Buyer identity. user_id is set when the joiner is signed in (lets them see
  -- + cancel their own entry); email is always captured (the notify target).
  user_id     uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  email       text NOT NULL CHECK (email = lower(email) AND char_length(email) BETWEEN 3 AND 320),
  name        text CHECK (name IS NULL OR char_length(name) <= 120),
  quantity    integer NOT NULL DEFAULT 1 CHECK (quantity BETWEEN 1 AND 50),
  status      text NOT NULL DEFAULT 'waiting'
                CHECK (status IN ('waiting','notified','converted','cancelled')),
  notified_at timestamptz,
  meta        jsonb,                 -- campaign attribution etc. (UTM off the join URL)
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_waitlist_event_idx  ON public.exos_waitlist (event_id);
CREATE INDEX IF NOT EXISTS exos_waitlist_user_idx   ON public.exos_waitlist (user_id);
-- Queue order: oldest waiting first, per event/tier. Drives position + notify.
CREATE INDEX IF NOT EXISTS exos_waitlist_queue_idx
  ON public.exos_waitlist (event_id, tier_id, created_at) WHERE status = 'waiting';
-- Dedupe one email per event (tier-level) and per event (general). Two partial
-- uniques because a NULL tier_id is "distinct" under a plain UNIQUE — that would
-- let the same email pile up general-admission rows. The join RPC also upserts
-- by hand, but these are the hard backstop.
CREATE UNIQUE INDEX IF NOT EXISTS exos_waitlist_uniq_tier
  ON public.exos_waitlist (event_id, tier_id, email) WHERE tier_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_waitlist_uniq_general
  ON public.exos_waitlist (event_id, email) WHERE tier_id IS NULL;

DROP TRIGGER IF EXISTS exos_waitlist_touch ON public.exos_waitlist;
CREATE TRIGGER exos_waitlist_touch BEFORE UPDATE ON public.exos_waitlist
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ===========================================================================
-- 2. RLS — deny-by-default. Org staff manage their event's list; a signed-in
--    buyer reads their own rows. Anon: nothing direct (join is via RPC).
-- ===========================================================================
ALTER TABLE public.exos_waitlist ENABLE ROW LEVEL SECURITY;

-- Buyer reads own rows (by user_id); org staff read the whole event's list.
CREATE POLICY exos_waitlist_sel ON public.exos_waitlist FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
               AND exos_has_org_role(e.org_id, ARRAY['owner','manager','finance']))
  );
-- Buyer cancels their OWN entry (set status='cancelled'); org staff manage too.
-- No client INSERT policy — joining goes only through exos_join_waitlist() so
-- the event-published + dedupe + (optional) anon path is server-enforced.
CREATE POLICY exos_waitlist_upd ON public.exos_waitlist FOR UPDATE TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
               AND exos_has_org_role(e.org_id, ARRAY['owner','manager']))
  )
  WITH CHECK (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
               AND exos_has_org_role(e.org_id, ARRAY['owner','manager']))
  );
CREATE POLICY exos_waitlist_del ON public.exos_waitlist FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])));

-- Platform default-privileges auto-grant new tables to anon+authenticated; strip
-- both, then re-grant only what authenticated needs (RLS still gates rows). Anon
-- touches the table ONLY through the SECDEF join RPC. (Same pattern as phase-1 §8.)
REVOKE ALL ON public.exos_waitlist FROM anon, authenticated;
GRANT SELECT, UPDATE ON public.exos_waitlist TO authenticated;

-- ===========================================================================
-- 3. Mail template — add 'waitlist-open' (preserve all existing values).
--    Current set per mig 20260523210000.
-- ===========================================================================
ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
ALTER TABLE public.exos_mail ADD  CONSTRAINT exos_mail_template_check
  CHECK (template IN ('transfer-initiated','transfer-claimed','org-invite',
                      'event-cancelled','event-updated','event-announce',
                      'ticket-issued','waitlist-open'));

-- ===========================================================================
-- 4. exos_join_waitlist — public (anon OR authenticated) join.
--    Validates the event is published; dedupes by (event, tier, email); returns
--    the row id + the joiner's 1-based queue position.
-- ===========================================================================
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
  v_uid   uuid := auth.uid();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_qty   integer := greatest(1, least(50, coalesce(p_quantity, 1)));
  v_id    uuid;
  v_pos   integer;
BEGIN
  IF v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION 'exos_join_waitlist: invalid email';
  END IF;
  -- Event must exist and be published (matches the public storefront surface).
  IF NOT EXISTS (SELECT 1 FROM public.exos_events e
                 WHERE e.id = p_event_id AND e.status = 'published') THEN
    RAISE EXCEPTION 'exos_join_waitlist: event not found or not published';
  END IF;
  -- Tier (if given) must belong to the event.
  IF p_tier_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM public.exos_ticket_tiers t
       WHERE t.id = p_tier_id AND t.event_id = p_event_id) THEN
    RAISE EXCEPTION 'exos_join_waitlist: tier does not belong to event';
  END IF;

  -- Manual upsert (two partial uniques can't drive a single ON CONFLICT target).
  -- Re-joining refreshes name/qty/user binding and reactivates a cancelled row.
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

  -- 1-based position among still-waiting rows for the same event/tier.
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

-- ===========================================================================
-- 5. exos_leave_waitlist — joiner cancels their own entry (by id).
--    Works for anon-created rows too IF the caller proves the email (anon has no
--    uid to match) — so we require either user_id match or an email match.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_leave_waitlist(p_id uuid, p_email text DEFAULT NULL)
RETURNS boolean
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text := lower(btrim(coalesce(p_email, coalesce(auth.jwt() ->> 'email', ''))));
  v_rows  integer;
BEGIN
  UPDATE public.exos_waitlist
  SET status = 'cancelled'
  WHERE id = p_id
    AND status <> 'converted'
    AND ((v_uid IS NOT NULL AND user_id = v_uid) OR (v_email <> '' AND email = v_email));
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows > 0;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_leave_waitlist(uuid, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_leave_waitlist(uuid, text) TO anon, authenticated;

-- ===========================================================================
-- 6. exos_notify_waitlist — org staff release N spots: flip the oldest waiting
--    rows to 'notified' and queue a 'waitlist-open' email to each (recipient
--    server-DERIVED from the row's own email — no client address). Returns the
--    number notified. Idempotent-ish: only 'waiting' rows are eligible.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_notify_waitlist(
  p_event_id uuid,
  p_limit    integer DEFAULT 10,
  p_tier_id  uuid    DEFAULT NULL
) RETURNS integer
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_org_id  uuid;
  v_name    text;
  v_count   integer := 0;
  v_lim     integer := greatest(1, least(500, coalesce(p_limit, 10)));
  r         record;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_notify_waitlist: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT e.org_id, e.name INTO v_org_id, v_name
  FROM public.exos_events e WHERE e.id = p_event_id;
  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'exos_notify_waitlist: event not found';
  END IF;
  IF NOT exos_has_org_role(v_org_id, ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'exos_notify_waitlist: caller lacks org-staff access' USING ERRCODE = '42501';
  END IF;

  FOR r IN
    SELECT id, email FROM public.exos_waitlist
    WHERE event_id = p_event_id
      AND status = 'waiting'
      AND (p_tier_id IS NULL OR tier_id = p_tier_id)
    ORDER BY created_at
    LIMIT v_lim
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.exos_waitlist
    SET status = 'notified', notified_at = now()
    WHERE id = r.id;

    INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
    VALUES (
      'waitlist-open', r.email,
      'A spot just opened up: ' || left(coalesce(v_name, 'your event'), 120),
      '<p>Good news — a spot just opened up for <strong>' ||
        replace(replace(coalesce(v_name, 'an event'), '<', '&lt;'), '>', '&gt;') ||
        '</strong>.</p><p>Tickets are limited and released first-come — open the Bridge app to grab yours before they''re gone.</p>',
      v_uid, 'pending'
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_notify_waitlist(uuid, integer, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_notify_waitlist(uuid, integer, uuid) TO authenticated;

-- ===========================================================================
-- 7. exos_waitlist_summary — staff dashboard counts for an event (waiting /
--    notified / converted, total requested quantity). SECDEF + org-staff gate.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.exos_waitlist_summary(p_event_id uuid)
RETURNS TABLE (waiting integer, notified integer, converted integer, total_quantity integer)
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path = public, pg_temp
AS $$
DECLARE v_org_id uuid;
BEGIN
  SELECT org_id INTO v_org_id FROM public.exos_events WHERE id = p_event_id;
  IF v_org_id IS NULL OR NOT exos_has_org_role(v_org_id, ARRAY['owner','manager','finance']) THEN
    RAISE EXCEPTION 'exos_waitlist_summary: not authorized' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
  SELECT
    count(*) FILTER (WHERE status = 'waiting')::int,
    count(*) FILTER (WHERE status = 'notified')::int,
    count(*) FILTER (WHERE status = 'converted')::int,
    coalesce(sum(quantity) FILTER (WHERE status IN ('waiting','notified')), 0)::int
  FROM public.exos_waitlist WHERE event_id = p_event_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_waitlist_summary(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_waitlist_summary(uuid) TO authenticated;

COMMENT ON TABLE public.exos_waitlist IS
  'D4 mig 20260616180000: sold-out event/tier waitlist (Hi.Events parity). Buyer joins
   via exos_join_waitlist (anon-callable, SECDEF); org staff release spots via
   exos_notify_waitlist (queues server-derived waitlist-open mail). RLS deny-by-default.';
