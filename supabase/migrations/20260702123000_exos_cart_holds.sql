-- ============================================================================
-- Migration 20260702123000 — Exos (Bridge / D4): cart holds (inventory reservation)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_cart_holds (W, new), exos_tier_available() (W, new),
--           exos_create_hold() / exos_release_hold() /
--           exos_consume_holds_for_session() / exos_expire_holds() (W, new);
--           reads exos_events / exos_ticket_tiers.
-- Pre-reqs: 20260520120000 (orgs/events/tiers), 20260520130000 (exos_has_org_role,
--           exos_is_admin, exos_touch_updated_at), 20260523170000 (exos_checkout_sessions)
--
-- TIER-1 pretix-parity feature #1 (CLEAN-ROOM). pretix is AGPLv3 + additional
-- terms that forbid using it (or derivatives) to run a ticketing SaaS on behalf
-- of third parties — Bridge's exact model — so NO pretix code is used here. This
-- is an original implementation of the *concept* (reserve inventory for a TTL
-- during checkout); concepts/data-model shapes are not copyrightable.
--
-- WHY: exos-checkout currently does a READ-THEN-CHARGE availability check
--   (`tier.sold + qty > tier.capacity` at session-create, index.ts line ~86).
--   Two buyers can both pass it, both get a Stripe session, both PAY, and at
--   fulfillment one hits `status='failed'` (exos_fulfill_checkout) — charged with
--   no inventory, needing a manual/swept refund. A hold RESERVES the inventory
--   for a TTL the moment checkout starts, and reservations count against
--   availability, so the second buyer is refused BEFORE paying.
--
-- MODEL: `sold` is still only incremented at fulfillment (mint). A hold is a
--   separate reservation layer. Availability = capacity - sold - active-holds.
--   At fulfillment the session's hold is CONSUMED (stops counting) in the same
--   breath that `sold` is bumped, so there is never a double-count window.
--
-- INTEGRATION (follow-up, D4-owned edge code — NOT in this schema migration):
--   1. exos-checkout: replace the naive line-86 check with
--        SELECT exos_create_hold(event_id, tier_id, quantity)  -- raises if sold out
--      then, after the Stripe session is created,
--        UPDATE exos_cart_holds SET checkout_session_id = <sid> WHERE id = <hold>;
--      on Stripe failure, exos_release_hold(<hold>).
--   2. exos_fulfill_checkout(): add `PERFORM exos_consume_holds_for_session(p_session_id);`
--      just before/after the mint (idempotent — safe on webhook retry).
--   Left as documented wiring so this migration is purely additive and the hot
--   fulfillment path is changed under separate B1 review.
--
-- D4 authors; validate on a Supabase preview branch; A1 applies to prod
-- (incl. the cleanup cron in §5). ⚠ B1 review requested on the RLS + RPC model.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The reservation ledger. One row = a buyer's in-flight reservation of N
--    seats in one tier, alive until expires_at. status is the lifecycle:
--      active   → counts against availability
--      consumed → fulfilled into real tickets (mint happened)
--      released → buyer abandoned / Stripe session create failed
--      expired  → TTL lapsed (flipped by the cleanup cron; see §5)
--    Availability counting (§2) treats a row as live only when
--    status='active' AND expires_at > now(), so correctness does NOT depend on
--    the cron having run — the cron is just housekeeping.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_cart_holds (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id            uuid NOT NULL REFERENCES public.exos_events (id)       ON DELETE CASCADE,
  tier_id             uuid NOT NULL REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  org_id              uuid NOT NULL REFERENCES public.exos_orgs (id)         ON DELETE CASCADE, -- denormalized for staff RLS w/o a join
  buyer_uid           uuid REFERENCES auth.users (id) ON DELETE CASCADE,      -- the reserving buyer
  buyer_email         text,                                                   -- lowercased, denormalized
  quantity            int  NOT NULL CHECK (quantity BETWEEN 1 AND 10),
  status              text NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active','consumed','released','expired')),
  checkout_session_id text REFERENCES public.exos_checkout_sessions (session_id) ON DELETE SET NULL,
  expires_at          timestamptz NOT NULL,
  consumed_at         timestamptz,
  released_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);
-- Partial index on the hot path: summing LIVE holds per tier for availability.
CREATE INDEX IF NOT EXISTS exos_cart_holds_live_tier_idx
  ON public.exos_cart_holds (tier_id) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS exos_cart_holds_event_idx   ON public.exos_cart_holds (event_id);
CREATE INDEX IF NOT EXISTS exos_cart_holds_buyer_idx   ON public.exos_cart_holds (buyer_uid);
CREATE INDEX IF NOT EXISTS exos_cart_holds_session_idx ON public.exos_cart_holds (checkout_session_id);
CREATE INDEX IF NOT EXISTS exos_cart_holds_expiry_idx  ON public.exos_cart_holds (expires_at) WHERE status = 'active';

DROP TRIGGER IF EXISTS exos_cart_holds_touch ON public.exos_cart_holds;
CREATE TRIGGER exos_cart_holds_touch BEFORE UPDATE ON public.exos_cart_holds
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Tier availability = capacity - sold - live-holds. SECURITY DEFINER so the
--    storefront (anon) can read a single availability integer without a grant on
--    the base tables (it returns only a number, leaks nothing). Semantics mirror
--    the rest of exos: tier.capacity = 0 means UNCAPPED → returns NULL. A capped
--    tier never returns below 0.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tier_available(p_tier_id uuid)
RETURNS integer
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT CASE
           WHEN t.capacity = 0 THEN NULL                       -- uncapped
           ELSE GREATEST(0, t.capacity - t.sold - COALESCE(h.held, 0))
         END
  FROM public.exos_ticket_tiers t
  LEFT JOIN (
    SELECT tier_id, SUM(quantity) AS held
    FROM public.exos_cart_holds
    WHERE tier_id = p_tier_id AND status = 'active' AND expires_at > now()
    GROUP BY tier_id
  ) h ON h.tier_id = t.id
  WHERE t.id = p_tier_id;
$$;
REVOKE EXECUTE ON FUNCTION public.exos_tier_available(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_tier_available(uuid) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Create a hold. Authenticated buyer reserves for THEMSELVES (auth.uid()).
--    Atomicity: we lock the tier row FOR UPDATE, so concurrent hold creations on
--    the same tier serialize; the live-hold sum is then computed under the lock
--    and the reservation is refused if it would breach capacity. p_ttl_seconds
--    defaults to 30 min (pretix's default reservation window).
--
--    NOTE this enforces only the TIER-LOCAL cap. Shared-quota enforcement is
--    layered on top by the quotas migration (20260702123030) via
--    exos_effective_available()/exos_assert_quota(); once that lands, this fn is
--    replaced to also honor quotas. Kept tier-local here so holds ship
--    independently of quotas.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_create_hold(
  p_event_id     uuid,
  p_tier_id      uuid,
  p_quantity     int DEFAULT 1,
  p_ttl_seconds  int DEFAULT 1800
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_email  text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_org    uuid;
  v_status text;
  v_cap    int;
  v_sold   int;
  v_held   int;
  v_sstart timestamptz;
  v_send   timestamptz;
  v_ttl    int := LEAST(GREATEST(coalesce(p_ttl_seconds, 1800), 60), 3600);  -- clamp 1min..1hr
  v_id     uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_hold: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_quantity < 1 OR p_quantity > 10 THEN
    RAISE EXCEPTION 'exos_create_hold: quantity must be 1-10';
  END IF;

  SELECT org_id, status INTO v_org, v_status FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL THEN
    RAISE EXCEPTION 'exos_create_hold: event not found';
  END IF;
  IF v_status <> 'published' THEN
    RAISE EXCEPTION 'exos_create_hold: event not on sale' USING ERRCODE = '23514';
  END IF;

  -- Lock the tier row → serializes concurrent holds/claims for this tier.
  SELECT capacity, sold, sales_start, sales_end
    INTO v_cap, v_sold, v_sstart, v_send
    FROM public.exos_ticket_tiers
   WHERE id = p_tier_id AND event_id = p_event_id
   FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_create_hold: tier not found for this event';
  END IF;
  IF v_sstart IS NOT NULL AND now() < v_sstart THEN
    RAISE EXCEPTION 'exos_create_hold: sales have not started for this tier' USING ERRCODE = '23514';
  END IF;
  IF v_send IS NOT NULL AND now() > v_send THEN
    RAISE EXCEPTION 'exos_create_hold: sales have ended for this tier' USING ERRCODE = '23514';
  END IF;

  -- Capacity check under the lock (capacity = 0 = uncapped → skip).
  IF v_cap > 0 THEN
    SELECT COALESCE(SUM(quantity), 0) INTO v_held
      FROM public.exos_cart_holds
     WHERE tier_id = p_tier_id AND status = 'active' AND expires_at > now();
    IF v_sold + v_held + p_quantity > v_cap THEN
      RAISE EXCEPTION 'exos_create_hold: not enough tickets available in this tier'
        USING ERRCODE = '23514';
    END IF;
  END IF;

  INSERT INTO public.exos_cart_holds (event_id, tier_id, org_id, buyer_uid, buyer_email, quantity, expires_at)
  VALUES (p_event_id, p_tier_id, v_org, v_uid, NULLIF(v_email, ''), p_quantity, now() + make_interval(secs => v_ttl))
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_create_hold(uuid, uuid, int, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_create_hold(uuid, uuid, int, int) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_create_hold(uuid, uuid, int, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Release a hold (buyer abandoned, or the Stripe session failed to create).
--    The reserving buyer or org staff may release. Idempotent: only an 'active'
--    row transitions; a second call is a no-op. Returns true iff it flipped one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_release_hold(p_hold_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_org  uuid;
  v_buy  uuid;
  v_n    int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_release_hold: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT org_id, buyer_uid INTO v_org, v_buy FROM public.exos_cart_holds WHERE id = p_hold_id;
  IF v_org IS NULL THEN
    RETURN false;                       -- unknown hold → nothing to do
  END IF;
  IF NOT (v_buy = v_uid OR exos_is_admin() OR exos_has_org_role(v_org, ARRAY['owner','manager'])) THEN
    RAISE EXCEPTION 'exos_release_hold: not authorized' USING ERRCODE = '42501';
  END IF;

  UPDATE public.exos_cart_holds
     SET status = 'released', released_at = now()
   WHERE id = p_hold_id AND status = 'active';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n > 0;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_release_hold(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.exos_release_hold(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.exos_release_hold(uuid) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Consume a session's holds at fulfillment. service_role only (called from
--    exos_fulfill_checkout / the webhook). Flips every active hold tied to the
--    session to 'consumed' so it stops counting against availability — the mint
--    bumps `sold` in the same transaction, so total reserved+sold is conserved.
--    Idempotent (webhook retry): re-running consumes nothing new and returns 0.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_consume_holds_for_session(p_session_id text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_consume_holds_for_session: service role only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_cart_holds
     SET status = 'consumed', consumed_at = now()
   WHERE checkout_session_id = p_session_id AND status = 'active';
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_consume_holds_for_session(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_consume_holds_for_session(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 6. Cleanup sweep. Flips lapsed active holds to 'expired'. Availability already
--    ignores expired-by-clock holds (§2), so this is housekeeping that keeps the
--    table tidy + makes state legible. service_role only. Returns the count.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_expire_holds()
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_n int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_expire_holds: service role only' USING ERRCODE = '42501';
  END IF;
  UPDATE public.exos_cart_holds
     SET status = 'expired'
   WHERE status = 'active' AND expires_at <= now();
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;
REVOKE ALL ON FUNCTION public.exos_expire_holds() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_expire_holds() TO service_role;

-- Cleanup cron (every 5 min, offset to :03,:08,… — avoids the round-hour
-- stampede AND the saturated :02/:05/:07 marks the PR checklist calls out,
-- MIGRATION_CONVENTIONS §5). Guarded so a preview branch without pg_cron still
-- applies cleanly; A1 owns cron application in prod.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'exos_expire_holds') THEN
      PERFORM cron.unschedule('exos_expire_holds');
    END IF;
    PERFORM cron.schedule('exos_expire_holds', '3-58/5 * * * *',
                          $cron$SELECT public.exos_expire_holds();$cron$);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 7. RLS. Buyer reads their own holds; org staff read their org's. No client
--    writes — all mutations go through the §3-§6 RPCs. anon: nothing (the
--    storefront reads availability via exos_tier_available, not these rows).
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_cart_holds ENABLE ROW LEVEL SECURITY;

CREATE POLICY exos_cart_holds_sel ON public.exos_cart_holds FOR SELECT TO authenticated
  USING (buyer_uid = auth.uid()
         OR exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance']));

REVOKE ALL ON public.exos_cart_holds FROM anon, authenticated;
GRANT  SELECT ON public.exos_cart_holds TO authenticated;
