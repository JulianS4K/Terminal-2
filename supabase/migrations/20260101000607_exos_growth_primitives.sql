-- ============================================================================
-- Migration 20260523200000 — Exos (Bridge / D4): growth / marketing primitives
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_distribution_listings (channel CHECK +bandsintown/google_events),
--           exos_orgs (+marketing jsonb), exos_mail (template +event-announce),
--           exos_redeem_discount_code() (W,new), exos_announce_to_followers() (W,new)
-- Pre-reqs: 20260520120000 (exos_orgs, exos_discount_codes, exos_org_follows),
--            20260520160000 (exos_mail + drainer), 20260523190000 (distribution)
--
-- The venue/promoter GROWTH layer — LIVE, in-lane pieces only. Gated pieces
-- (publishing to Bandsintown/Google = upstream write → Hard-Rule-2; rendering
-- 3rd-party pixels/JSON-LD on public pages = CSP + consent → B1) are NOT here;
-- this migration only adds the data model + the non-gated primitives.
--
-- D4 authors; A1 applies. (Building does not require A1; applying to prod does.)
-- ============================================================================

-- 1. Syndication channels — extend the existing distribution model to cover the
--    discovery networks. Publishing to them stays GATED + inert in exos-distribute
--    (upstream write); this only enables the channel values.
ALTER TABLE public.exos_distribution_listings DROP CONSTRAINT IF EXISTS exos_distribution_listings_channel_check;
ALTER TABLE public.exos_distribution_listings ADD  CONSTRAINT exos_distribution_listings_channel_check
  CHECK (channel IN ('automatiq','evo','seatgeek','stubhub','vivid','tickpick','bandsintown','google_events'));

-- 2. Org marketing config (owner-writable via existing exos_orgs_upd RLS).
--    Shape: { socials:{instagram,facebook,tiktok,x,website},
--             pixels:{meta,ga4,tiktok}, shareImageUrl }
--    Public exposure (for rendering pixels/socials on public pages) is a later
--    CSP/B1-gated step — add to exos_public_orgs then, not now.
ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS marketing jsonb;

-- 3. exos_mail: allow the follower-announcement template.
ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
ALTER TABLE public.exos_mail ADD  CONSTRAINT exos_mail_template_check
  CHECK (template IN ('transfer-initiated','transfer-claimed','org-invite',
                      'event-cancelled','event-updated','event-announce'));

-- 4. Redeem/validate a promo or access code. SECDEF so a buyer can check a code
--    WITHOUT read access to the staff-only exos_discount_codes table. Read-only
--    (no consumption) — returns validity + what it unlocks; consumption happens
--    at issuance time. Public/access codes use unlocks_tier_ids (e.g. presale).
CREATE OR REPLACE FUNCTION public.exos_redeem_discount_code(
  p_event_id uuid,
  p_code     text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE c public.exos_discount_codes%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_redeem_discount_code: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO c FROM public.exos_discount_codes
   WHERE event_id = p_event_id AND lower(code) = lower(btrim(p_code));
  IF NOT FOUND THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'not-found');
  END IF;
  IF c.expires_at IS NOT NULL AND c.expires_at < now() THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'expired');
  END IF;
  IF c.usage_limit IS NOT NULL AND c.used_count >= c.usage_limit THEN
    RETURN jsonb_build_object('valid', false, 'reason', 'usage-exhausted');
  END IF;
  RETURN jsonb_build_object(
    'valid', true,
    'type', c.type, 'value', c.value,
    'unlocks_tier_ids', coalesce(c.unlocks_tier_ids, '{}'),
    'remaining', CASE WHEN c.usage_limit IS NULL THEN NULL ELSE c.usage_limit - c.used_count END
  );
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_redeem_discount_code(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_redeem_discount_code(uuid, text) TO authenticated;

-- 5. Announce a published event to the org's followers (owned-audience marketing).
--    Server-derives each recipient from exos_org_follows → auth.users (no open
--    relay; no client-supplied recipient/body). Queues into exos_mail; the
--    existing drainer sends. Event name is tag-escaped before HTML interpolation.
CREATE OR REPLACE FUNCTION public.exos_announce_to_followers(p_event_id uuid)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_org    uuid;
  v_status text;
  v_name   text;
  v_safe   text;
  v_n      int := 0;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'exos_announce_to_followers: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, status, name INTO v_org, v_status, v_name FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_announce_to_followers: event not found';
  END IF;
  IF NOT (exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_announce_to_followers: not authorized' USING ERRCODE = '42501';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_announce_to_followers: event must be published (is %)', v_status;
  END IF;

  v_safe := replace(replace(coalesce(v_name, 'an event'), '<', '&lt;'), '>', '&gt;');

  INSERT INTO public.exos_mail (template, to_email, subject, html, created_by, status)
  SELECT 'event-announce',
         lower(u.email),
         left('New event: ' || v_safe, 200),
         '<p>An organization you follow just announced <strong>' || v_safe ||
           '</strong>. Open the app for details and tickets.</p>',
         auth.uid(), 'pending'
  FROM public.exos_org_follows f
  JOIN auth.users u ON u.id = f.follower_uid
  WHERE f.org_id = v_org AND u.email IS NOT NULL;

  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_announce_to_followers(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_announce_to_followers(uuid) TO authenticated;
