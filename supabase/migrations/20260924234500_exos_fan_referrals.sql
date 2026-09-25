-- ============================================================================
-- Migration 20260924234500 — Exos (Bridge / D4): fan referrals ("bring your
--                            friends"), tracking only
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_fan_referrals (new), exos_tickets (+referral_code),
--              FUNCTION exos_my_referral_code, exos_my_referral_stats,
--              exos_attach_referral (new), exos_fulfill_checkout (patched in place)
--           R: exos_events, exos_checkout_sessions
-- Pre-reqs: 20260924223000 (fulfill carries promoter_id; this extends the same insert)
--
-- A ticket holder gets a personal code per event and shares ?ref=<code>.
-- Friends who buy through it are counted, so a fan can see "3 friends are
-- coming because of you" and an organizer can later reward it. No reward is
-- issued here: that's a product decision (EXP docs/social.md).
--   * exos_fan_referrals: one code per (event, user), 10 chars of [a-z0-9].
--     Only someone holding a ticket to the event can get one.
--   * exos_tickets.referral_code: set at fulfillment from the checkout
--     session's attribution (paid), or by exos_attach_referral right after a
--     free claim (the SPA knows the claim's order_ref). Self-referral is
--     ignored in both paths.
--   * exos_my_referral_stats: the fan's own count of friends (distinct buyers).
-- Referral and promoter credit are independent: a ticket can carry both.
--
-- Idempotent. D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_fan_referrals (
  code       text PRIMARY KEY CHECK (code ~ '^[a-z0-9]{10}$'),
  event_id   uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, user_id)
);
ALTER TABLE public.exos_fan_referrals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_fan_referrals FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_fan_referrals TO service_role;
-- Prod's default privileges also hand new tables to the read-only analytics
-- roles; referral codes are per-fan identifiers, so take that back where they exist.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly','analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE ALL ON public.%s FROM %I', 'exos_fan_referrals', r);
    END IF;
  END LOOP;
END $$;

ALTER TABLE public.exos_tickets ADD COLUMN IF NOT EXISTS referral_code text
  CHECK (referral_code IS NULL OR referral_code ~ '^[a-z0-9]{10}$');
CREATE INDEX IF NOT EXISTS exos_tickets_referral_idx ON public.exos_tickets (referral_code) WHERE referral_code IS NOT NULL;
-- exos_tickets uses column-level SELECT grants: a new column is unreadable to
-- clients until granted (same fix as attendee_name in 20260924200848).
GRANT SELECT (referral_code) ON public.exos_tickets TO authenticated;

-- The caller's code for an event, created on first ask. Needs a ticket.
CREATE OR REPLACE FUNCTION public.exos_my_referral_code(p_event_id uuid)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); v_code text; i int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_my_referral_code: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT code INTO v_code FROM public.exos_fan_referrals WHERE event_id = p_event_id AND user_id = v_uid;
  IF v_code IS NOT NULL THEN RETURN v_code; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_tickets
                  WHERE event_id = p_event_id AND owner_id = v_uid AND status IN ('active', 'used')) THEN
    RAISE EXCEPTION 'exos_my_referral_code: you need a ticket to this event' USING ERRCODE = '42501';
  END IF;
  FOR i IN 1..5 LOOP
    v_code := substr(encode(extensions.gen_random_bytes(8), 'hex'), 1, 10);
    BEGIN
      INSERT INTO public.exos_fan_referrals (code, event_id, user_id) VALUES (v_code, p_event_id, v_uid);
      RETURN v_code;
    EXCEPTION WHEN unique_violation THEN
      -- Lost a race for our own row, or a code collision: re-read, else retry.
      SELECT code INTO v_code FROM public.exos_fan_referrals WHERE event_id = p_event_id AND user_id = v_uid;
      IF v_code IS NOT NULL THEN RETURN v_code; END IF;
    END;
  END LOOP;
  RAISE EXCEPTION 'exos_my_referral_code: could not allocate a code';
END $$;
REVOKE ALL ON FUNCTION public.exos_my_referral_code(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_my_referral_code(uuid) TO authenticated, service_role;

-- How many friends bought through the caller's link for an event.
CREATE OR REPLACE FUNCTION public.exos_my_referral_stats(p_event_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'code', r.code,
    'friends', (SELECT count(DISTINCT t.buyer_id) FROM public.exos_tickets t
                 WHERE t.referral_code = r.code AND t.status IN ('active', 'used', 'transferred')),
    'tickets', (SELECT count(*) FROM public.exos_tickets t
                 WHERE t.referral_code = r.code AND t.status IN ('active', 'used', 'transferred')))
  FROM public.exos_fan_referrals r
  WHERE r.event_id = p_event_id AND r.user_id = auth.uid();
$$;
REVOKE ALL ON FUNCTION public.exos_my_referral_stats(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_my_referral_stats(uuid) TO authenticated, service_role;

-- Credit a fresh free claim to the fan whose link brought the buyer. Only the
-- caller's own tickets from that order, only once, only within 30 minutes,
-- never to the caller's own code. Returns tickets credited.
CREATE OR REPLACE FUNCTION public.exos_attach_referral(p_order_ref text, p_code text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_uid uuid := auth.uid(); v_n int;
BEGIN
  IF v_uid IS NULL OR coalesce(p_order_ref, '') = '' THEN RETURN 0; END IF;
  UPDATE public.exos_tickets t
     SET referral_code = r.code
    FROM public.exos_fan_referrals r
   WHERE r.code = p_code
     AND r.event_id = t.event_id
     AND r.user_id <> v_uid
     AND t.order_ref = p_order_ref
     AND t.owner_id = v_uid AND t.buyer_id = v_uid
     AND t.referral_code IS NULL
     AND t.created_at > now() - interval '30 minutes';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_attach_referral(text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_attach_referral(text, text) TO authenticated, service_role;

-- (Alias `fr`, not `r`: the function declares a record variable r.)
-- Paid tickets: fulfillment copies the session's ?ref= (if it's a real code
-- for this event and not the buyer's own) onto every minted ticket.
DO $$
DECLARE
  v_def  text := pg_get_functiondef('public.exos_fulfill_checkout(text)'::regprocedure);
  v_col_old text := 'channel_source, promoter_id' || chr(10);
  v_col_new text := 'channel_source, promoter_id, referral_code' || chr(10);
  v_val_old text := 'p_session_id, ''stripe'', s.promoter_id' || chr(10);
  v_val_new text := 'p_session_id, ''stripe'', s.promoter_id,' || chr(10) ||
    '        (SELECT fr.code FROM public.exos_fan_referrals fr WHERE fr.code = s.attribution->>''ref''' ||
    ' AND fr.event_id = s.event_id AND fr.user_id IS DISTINCT FROM s.buyer_uid)' || chr(10);
  v_hits int;
BEGIN
  IF position('referral_code' in v_def) > 0 THEN
    RETURN;   -- already patched
  END IF;
  IF position(v_val_old in v_def) = 0 THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: apply 20260924223000 first';
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, v_col_old, ''))) / length(v_col_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: expected one ticket column list, found %', v_hits;
  END IF;
  v_hits := (length(v_def) - length(replace(v_def, v_val_old, ''))) / length(v_val_old);
  IF v_hits <> 1 THEN
    RAISE EXCEPTION 'exos_fulfill_checkout: expected one ticket values tail, found %', v_hits;
  END IF;
  EXECUTE replace(replace(v_def, v_col_old, v_col_new), v_val_old, v_val_new);
END $$;
