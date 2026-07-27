-- ============================================================================
-- Migration 20260702123030 — Exos (Bridge / D4): shared quotas
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_quotas (W, new), exos_quota_tiers (W, new),
--           exos_quota_available() / exos_effective_available() /
--           exos_assert_quota() (W, new); reads exos_events / exos_ticket_tiers /
--           exos_tickets / exos_cart_holds.
-- Pre-reqs: 20260520120000 (orgs/events/tiers), 20260520130000 (helpers/tickets),
--           20260702123000 (exos_cart_holds + exos_tier_available)
--
-- TIER-1 pretix-parity feature #2 (CLEAN-ROOM — see the holds migration header
-- for the AGPL fence; this is an original implementation of the *concept*, no
-- pretix code). A quota is a capacity pool that one OR MORE tiers draw from —
-- GA + VIP both counting against one room-capacity number, or a workshop capped
-- separately from its parent event. Today exos has only a per-tier `capacity`
-- and a per-event `total_tickets`; a shared pool is impossible to express.
--
-- WHY NOW: shared quotas are one of the first asks from a real venue, and
--   retrofitting a pool AFTER orders exist means reconciling live counts against
--   a number that didn't exist when those orders were placed. Landing the SHAPE
--   before the first real order is the cheap moment (the analysis's point).
--
-- SEMANTICS (pretix-style, reimplemented): a ticket in a tier consumes one unit
--   from EVERY quota that tier is mapped to. quota availability =
--     size - (sold tickets in the quota's tiers) - (live holds on those tiers).
--   size IS NULL      → unlimited pool (no constraint).
--   closed = true     → hard 0 regardless of size (organizer pause).
--   A tier with no quota mapping is governed solely by its own `capacity`
--   (backward compatible — every existing tier keeps working unchanged).
--
-- ENFORCEMENT: exos_effective_available() = LEAST(tier-local avail, every mapped
--   quota's avail) is the number the storefront should show. exos_assert_quota()
--   is the atomic gate fulfillment/mint call BEFORE minting. Wiring it into
--   exos_fulfill_checkout()/exos_mint_tickets() + swapping exos_create_hold() to
--   the quota-aware check is a follow-up under B1 review (documented, not done
--   here) so this migration stays purely additive.
--
-- D4 authors; validate on a Supabase preview branch; A1 applies to prod.
-- ⚠ B1 review requested on the RLS model.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Quota pools + the tier↔quota mapping (many-to-many: a quota feeds many
--    tiers; a tier may draw from many quotas — the intersection is the cap).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_quotas (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id   uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id)   ON DELETE CASCADE, -- denormalized for RLS
  name       text NOT NULL,
  size       integer CHECK (size IS NULL OR size >= 0),   -- NULL = unlimited pool
  closed     boolean NOT NULL DEFAULT false,              -- organizer hard-pause
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_quotas_event_idx ON public.exos_quotas (event_id);

CREATE TABLE IF NOT EXISTS public.exos_quota_tiers (
  quota_id   uuid NOT NULL REFERENCES public.exos_quotas (id)       ON DELETE CASCADE,
  tier_id    uuid NOT NULL REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (quota_id, tier_id)
);
CREATE INDEX IF NOT EXISTS exos_quota_tiers_tier_idx ON public.exos_quota_tiers (tier_id);

DROP TRIGGER IF EXISTS exos_quotas_touch ON public.exos_quotas;
CREATE TRIGGER exos_quotas_touch BEFORE UPDATE ON public.exos_quotas
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Quota availability. size - (minted in mapped tiers) - (live holds on them).
--    SECURITY DEFINER so the storefront can read the number without base-table
--    grants. Returns NULL for an unlimited (size IS NULL) pool; 0 when closed.
--    "minted" counts tickets that hold inventory (active|used|transferred);
--    'voided' frees its unit back (matches exos_refund_checkout decrementing sold).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_quota_available(p_quota_id uuid)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_size   int;
  v_closed boolean;
  v_used   int;
  v_held   int;
BEGIN
  SELECT size, closed INTO v_size, v_closed FROM public.exos_quotas WHERE id = p_quota_id;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_closed THEN
    RETURN 0;
  END IF;
  IF v_size IS NULL THEN
    RETURN NULL;               -- unlimited pool
  END IF;

  SELECT COUNT(*) INTO v_used
    FROM public.exos_tickets t
   WHERE t.tier_id IN (SELECT tier_id FROM public.exos_quota_tiers WHERE quota_id = p_quota_id)
     AND t.status IN ('active','used','transferred');

  SELECT COALESCE(SUM(h.quantity), 0) INTO v_held
    FROM public.exos_cart_holds h
   WHERE h.tier_id IN (SELECT tier_id FROM public.exos_quota_tiers WHERE quota_id = p_quota_id)
     AND h.status = 'active' AND h.expires_at > now();

  RETURN GREATEST(0, v_size - v_used - v_held);
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_quota_available(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_quota_available(uuid) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Effective availability for a tier = LEAST(tier-local capacity avail, every
--    mapped quota's avail). NULL from any input means "no constraint from that
--    source" and is skipped; if ALL sources are unlimited the result is NULL.
--    This is the single number the storefront + a quota-aware exos_create_hold
--    should consult. SECURITY DEFINER for the same anon-read reason.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_effective_available(p_tier_id uuid)
RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_min  int := public.exos_tier_available(p_tier_id);   -- tier-local (NULL = uncapped)
  v_qav  int;
  r      record;
BEGIN
  FOR r IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id LOOP
    v_qav := public.exos_quota_available(r.quota_id);
    IF v_qav IS NOT NULL THEN
      v_min := LEAST(COALESCE(v_min, v_qav), v_qav);
    END IF;
  END LOOP;
  RETURN v_min;   -- NULL only if tier is uncapped AND every mapped quota is unlimited
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_effective_available(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_effective_available(uuid) TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Atomic quota gate for fulfillment/mint. Locks every quota the tier maps to
--    (FOR UPDATE serializes concurrent claims against a shared pool), then
--    re-derives availability under the lock and RAISES if any pool lacks room.
--    Call it inside the minting transaction BEFORE inserting tickets; the RAISE
--    rolls the whole mint back (no partial state), same discipline as the tier
--    capacity claim in exos_mint_tickets. service_role only (it's an internal
--    fulfillment primitive, not a client call).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_assert_quota(p_tier_id uuid, p_quantity int)
RETURNS void
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
DECLARE
  r      record;
  v_lock int;
BEGIN
  IF current_user NOT IN ('service_role','postgres','supabase_admin') THEN
    RAISE EXCEPTION 'exos_assert_quota: service role only' USING ERRCODE = '42501';
  END IF;
  IF p_quantity < 1 THEN
    RAISE EXCEPTION 'exos_assert_quota: quantity must be >= 1';
  END IF;

  FOR r IN SELECT quota_id FROM public.exos_quota_tiers WHERE tier_id = p_tier_id LOOP
    -- Take the row lock (serialize), then check the derived number under it.
    PERFORM 1 FROM public.exos_quotas WHERE id = r.quota_id FOR UPDATE;
    v_lock := public.exos_quota_available(r.quota_id);   -- NULL = unlimited
    IF v_lock IS NOT NULL AND v_lock < p_quantity THEN
      RAISE EXCEPTION 'exos_assert_quota: quota % exhausted (avail %, need %)',
        r.quota_id, v_lock, p_quantity USING ERRCODE = '23514';
    END IF;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_assert_quota(uuid, int) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_assert_quota(uuid, int) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. RLS. Quotas are organizer inventory config (like tiers / discount codes):
--    org staff read+manage their org's; not public on the base table. The
--    storefront reads availability through the SECDEF fns above, never these
--    rows. anon: nothing.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_quotas      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_quota_tiers ENABLE ROW LEVEL SECURITY;

CREATE POLICY exos_quotas_sel ON public.exos_quotas FOR SELECT TO authenticated
  USING (exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
CREATE POLICY exos_quotas_wr ON public.exos_quotas FOR ALL TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager']))
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner','manager']));

-- mapping rows: gated via the parent quota's org.
CREATE POLICY exos_quota_tiers_sel ON public.exos_quota_tiers FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_quotas q WHERE q.id = quota_id
                 AND (exos_is_admin() OR exos_has_org_role(q.org_id,
                      ARRAY['owner','manager','finance','scanner','content']))));
CREATE POLICY exos_quota_tiers_wr ON public.exos_quota_tiers FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_quotas q WHERE q.id = quota_id
                 AND exos_has_org_role(q.org_id, ARRAY['owner','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.exos_quotas q WHERE q.id = quota_id
                 AND exos_has_org_role(q.org_id, ARRAY['owner','manager'])));

REVOKE ALL ON public.exos_quotas, public.exos_quota_tiers FROM anon, authenticated;
GRANT  SELECT, INSERT, UPDATE, DELETE ON public.exos_quotas, public.exos_quota_tiers TO authenticated;
