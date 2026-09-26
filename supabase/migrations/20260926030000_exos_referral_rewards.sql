-- ============================================================================
-- Migration 20260926030000 — Exos (Bridge / D4): fan referral rewards
--                            ("bring 3 friends, get in free")
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_referral_reward_rules, exos_referral_rewards (new),
--              exos_vouchers (rows: reward vouchers are minted / expired here),
--              exos_tickets + exos_ticket_tiers + exos_events (reward redemption
--              mints one free ticket, same shape as exos_claim_free_tickets),
--              FUNCTION exos_rr_tier_price, exos_rr_counted_tickets,
--              exos_referral_rewards_sync, exos_tg_referral_rewards,
--              exos_tg_referral_reward_deleted, exos_rr_mask_email (internal),
--              exos_set_referral_reward_rule, exos_delete_referral_reward_rule,
--              exos_get_referral_reward_rule, exos_referral_leaderboard,
--              exos_my_referral_progress, exos_redeem_referral_reward (new),
--              TRIGGER exos_tickets_referral_rewards_ins / _upd,
--              exos_referral_rewards_deleted
--           R: exos_fan_referrals, exos_checkout_sessions, exos_org_memberships,
--              exos_profiles (only if present), auth.users (email + confirmed)
-- Pre-reqs: 20260924234500 (fan referrals), 20260925012000 (voucher codes)
--
-- Turns the referral count from 20260924234500 into rewards (operator
-- decision pending in EXP docs/social.md; this ships it off by default:
-- nothing is issued until an organizer saves a rule).
--
--   * exos_referral_reward_rules: one rule per event, plus an optional org
--     default (event_id NULL) used by events without their own rule. "Every
--     N counted referred tickets earns a reward", up to max_rewards_per_fan
--     per fan per event. The reward is a single-use voucher on a tier of this
--     event or a later event of the same org:
--       reward_kind 'price'       reward_value = price in cents (0 = free)
--                   'percent_off' reward_value = 1..100 (% off the tier)
--                   'amount_off'  reward_value = cents off the tier
--     Vouchers only pin a price (price_override, dollars), so % / amount off
--     are turned into a pinned price from the tier's scheduled price at the
--     moment of issuance. A pinned price between 0 and $0.50 (Stripe's
--     minimum charge) becomes free. reward_tier_id is required except for a
--     'price' reward, where NULL means "any ticket type of the reward event".
--     A disabled event rule means "no rewards for this event" (it does not
--     fall back to the org default).
--   * What counts: tickets carrying the fan's referral_code, status active /
--     used / transferred (not voided / refunded / released), whose buyer is
--     not the referrer (same user id, or the same email on the ticket or the
--     buyer's account). count_free_claims = false counts paid tickets only
--     (price_paid > 0).
--   * Issuance (exos_referral_rewards_sync, run by a trigger on exos_tickets
--     and again by the fan's progress RPC): milestone m is earned at
--     m * N counted tickets. Each milestone gets one voucher bound to the
--     referrer's CONFIRMED auth email; no confirmed email, no reward (the
--     next sync after they confirm catches up). UNIQUE (code, milestone) +
--     an advisory lock per code make it idempotent.
--   * Revocation: when counted tickets drop below a milestone's threshold
--     (void / refund / release), an unused reward is revoked (its voucher is
--     expired, so exos_check_voucher says "expired") and reinstated if the
--     count comes back. A reward whose voucher was already used, or is on a
--     pending checkout, is KEPT: the fan earned it in good faith and the
--     ticket exists; the organizer can void that ticket by hand.
--   * Free rewards: checkout refuses a $0 order and the free-claim path only
--     serves free tiers, so a $0 reward is claimed with
--     exos_redeem_referral_reward (mints one ticket, consumes the voucher).
--     Discount rewards use the code in the normal voucher field at checkout.
--   * No email in v1 (the exos_mail template constraint is untouched): the
--     fan sees rewards and codes in-app via exos_my_referral_progress.
--   * The trigger never blocks a sale: a sync error is downgraded to a
--     WARNING and the next sync catches up.
--   * Account deletion (20260926010000) deletes exos_fan_referrals, which
--     cascades to the rewards; their vouchers are then expired and lose the
--     reserved email (exos_tg_referral_reward_deleted).
--
-- Idempotent. D4 authors; applying to prod is operator-gated.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_referral_reward_rules (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id              uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  event_id            uuid REFERENCES public.exos_events (id) ON DELETE CASCADE,   -- NULL = org default
  enabled             boolean NOT NULL DEFAULT true,
  every_n             int  NOT NULL CHECK (every_n BETWEEN 1 AND 100),
  max_rewards_per_fan int  NOT NULL DEFAULT 1 CHECK (max_rewards_per_fan BETWEEN 1 AND 20),
  count_free_claims   boolean NOT NULL DEFAULT true,
  -- NULL = the referral's own event. Deleting the reward event / tier drops
  -- the rule rather than silently widening it.
  reward_event_id     uuid REFERENCES public.exos_events (id) ON DELETE CASCADE,
  reward_tier_id      uuid REFERENCES public.exos_ticket_tiers (id) ON DELETE CASCADE,
  reward_kind         text NOT NULL DEFAULT 'price' CHECK (reward_kind IN ('price', 'percent_off', 'amount_off')),
  reward_value        int  NOT NULL DEFAULT 0 CHECK (reward_value >= 0 AND reward_value <= 10000000),
  bypass_capacity     boolean NOT NULL DEFAULT false,
  created_by          uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT exos_rr_rules_percent CHECK (reward_kind <> 'percent_off' OR reward_value BETWEEN 1 AND 100),
  CONSTRAINT exos_rr_rules_amount  CHECK (reward_kind <> 'amount_off' OR reward_value >= 1),
  CONSTRAINT exos_rr_rules_tier    CHECK (reward_kind = 'price' OR reward_tier_id IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS exos_rr_rules_event_uq ON public.exos_referral_reward_rules (event_id) WHERE event_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS exos_rr_rules_org_default_uq ON public.exos_referral_reward_rules (org_id) WHERE event_id IS NULL;
CREATE INDEX IF NOT EXISTS exos_rr_rules_reward_event_idx ON public.exos_referral_reward_rules (reward_event_id) WHERE reward_event_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_rr_rules_reward_tier_idx ON public.exos_referral_reward_rules (reward_tier_id) WHERE reward_tier_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_rr_rules_created_by_idx ON public.exos_referral_reward_rules (created_by) WHERE created_by IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.exos_referral_rewards (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  referral_code   text NOT NULL REFERENCES public.exos_fan_referrals (code) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  milestone       int  NOT NULL CHECK (milestone >= 1),
  threshold       int  NOT NULL CHECK (threshold >= 1),
  rule_id         uuid REFERENCES public.exos_referral_reward_rules (id) ON DELETE SET NULL,
  reward_event_id uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  voucher_id      uuid REFERENCES public.exos_vouchers (id) ON DELETE SET NULL,
  status          text NOT NULL DEFAULT 'issued' CHECK (status IN ('issued', 'revoked')),
  issued_at       timestamptz NOT NULL DEFAULT now(),
  revoked_at      timestamptz,
  UNIQUE (referral_code, milestone)
);
CREATE INDEX IF NOT EXISTS exos_rr_rewards_user_idx ON public.exos_referral_rewards (user_id);
CREATE INDEX IF NOT EXISTS exos_rr_rewards_event_idx ON public.exos_referral_rewards (event_id);
CREATE INDEX IF NOT EXISTS exos_rr_rewards_reward_event_idx ON public.exos_referral_rewards (reward_event_id);
CREATE INDEX IF NOT EXISTS exos_rr_rewards_voucher_idx ON public.exos_referral_rewards (voucher_id) WHERE voucher_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS exos_rr_rewards_rule_idx ON public.exos_referral_rewards (rule_id) WHERE rule_id IS NOT NULL;

-- Both tables are RPC-only: no client grants, no policies.
ALTER TABLE public.exos_referral_reward_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_referral_rewards      ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_referral_reward_rules FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.exos_referral_rewards      FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_referral_reward_rules TO service_role;
GRANT ALL ON public.exos_referral_rewards      TO service_role;
DO $$
DECLARE r text; t text;
BEGIN
  FOREACH r IN ARRAY ARRAY['coworker_readonly','analyst_ro'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH t IN ARRAY ARRAY['exos_referral_reward_rules','exos_referral_rewards'] LOOP
        EXECUTE format('REVOKE ALL ON public.%I FROM %I', t, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

DROP TRIGGER IF EXISTS exos_referral_reward_rules_touch ON public.exos_referral_reward_rules;
CREATE TRIGGER exos_referral_reward_rules_touch BEFORE UPDATE ON public.exos_referral_reward_rules
  FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();

-- ---------------------------------------------------------------------------
-- 2. Internal helpers (not client-callable)
-- ---------------------------------------------------------------------------

-- A tier's price right now: the latest price_schedule step already started,
-- else the base price (same rule as src/lib/pricing.ts effectiveTierPrice).
CREATE OR REPLACE FUNCTION public.exos_rr_tier_price(p_tier_id uuid)
RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_base numeric; v_sched jsonb; v_step numeric;
BEGIN
  SELECT price, price_schedule INTO v_base, v_sched FROM public.exos_ticket_tiers WHERE id = p_tier_id;
  BEGIN
    SELECT (s->>'price')::numeric INTO v_step
      FROM jsonb_array_elements(coalesce(v_sched, '[]'::jsonb)) s
     WHERE jsonb_typeof(s->'price') = 'number' AND (s->>'price')::numeric >= 0
       AND (s->>'startsAt')::timestamptz <= now()
     ORDER BY (s->>'startsAt')::timestamptz DESC
     LIMIT 1;
  EXCEPTION WHEN OTHERS THEN v_step := NULL;   -- malformed schedule: base price
  END;
  RETURN coalesce(v_step, v_base, 0);
END $$;
REVOKE ALL ON FUNCTION public.exos_rr_tier_price(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_rr_tier_price(uuid) TO service_role;

-- Referred tickets that count toward rewards for one code.
CREATE OR REPLACE FUNCTION public.exos_rr_counted_tickets(p_code text, p_count_free boolean)
RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT count(*)::int
  FROM public.exos_fan_referrals r
  JOIN public.exos_tickets t ON t.referral_code = r.code AND t.event_id = r.event_id
  LEFT JOIN auth.users ru ON ru.id = r.user_id
  LEFT JOIN auth.users bu ON bu.id = t.buyer_id
  WHERE r.code = p_code
    AND t.status IN ('active', 'used', 'transferred')
    AND t.buyer_id IS DISTINCT FROM r.user_id
    AND (ru.email IS NULL OR (
          lower(coalesce(nullif(t.buyer_email, ''), '')) <> lower(ru.email)
      AND lower(coalesce(bu.email, '')) <> lower(ru.email)))
    AND (p_count_free OR t.price_paid > 0);
$$;
REVOKE ALL ON FUNCTION public.exos_rr_counted_tickets(text, boolean) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_rr_counted_tickets(text, boolean) TO service_role;

-- "julian@s4kent.com" -> "ju***@s***.com". Staff-facing leaderboards only.
CREATE OR REPLACE FUNCTION public.exos_rr_mask_email(p_email text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT CASE
    WHEN p_email IS NULL OR position('@' in p_email) < 2 THEN NULL
    ELSE left(split_part(lower(p_email), '@', 1), CASE WHEN length(split_part(p_email, '@', 1)) > 3 THEN 2 ELSE 1 END)
         || '***@'
         || left(split_part(lower(p_email), '@', 2), 1) || '***'
         || coalesce(substring(lower(split_part(p_email, '@', 2)) from '(\.[a-z0-9-]+)$'), '')
  END;
$$;
REVOKE ALL ON FUNCTION public.exos_rr_mask_email(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_rr_mask_email(text) TO service_role;

-- The rule that applies to an event: its own row (even if disabled), else
-- the org default.
CREATE OR REPLACE FUNCTION public.exos_rr_effective_rule(p_event_id uuid)
RETURNS public.exos_referral_reward_rules
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT x.* FROM public.exos_referral_reward_rules x
  JOIN public.exos_events e ON e.id = p_event_id
  WHERE x.event_id = e.id OR (x.event_id IS NULL AND x.org_id = e.org_id)
  ORDER BY (x.event_id IS NOT NULL) DESC
  LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.exos_rr_effective_rule(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_rr_effective_rule(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. Sync: issue / revoke / reinstate rewards for one referral code.
--    Returns the number of reward rows changed. Idempotent.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_referral_rewards_sync(p_code text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  fr        public.exos_fan_referrals%ROWTYPE;
  rule      public.exos_referral_reward_rules%ROWTYPE;
  v_email   text;
  v_cnt     int;
  v_target  int;
  v_changed int := 0;
  v_rw      record;
  v_used    boolean;
  v_rev     uuid;
  v_tier    uuid;
  v_price   numeric;
  v_code    text;
  v_vid     uuid;
  v_exists  boolean;
  m         int;
  i         int;
BEGIN
  IF p_code IS NULL THEN RETURN 0; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('exos_referral_rewards:' || p_code));
  SELECT * INTO fr FROM public.exos_fan_referrals WHERE code = p_code;
  IF NOT FOUND THEN RETURN 0; END IF;

  rule := public.exos_rr_effective_rule(fr.event_id);
  SELECT lower(u.email) INTO v_email FROM auth.users u
   WHERE u.id = fr.user_id AND u.email_confirmed_at IS NOT NULL AND nullif(u.email, '') IS NOT NULL;
  v_cnt := public.exos_rr_counted_tickets(p_code, coalesce(rule.count_free_claims, true));

  -- Revoke unused rewards whose threshold is no longer met.
  FOR v_rw IN
    SELECT rr.id, rr.voucher_id, coalesce(v.used_count, 0) AS used_count
      FROM public.exos_referral_rewards rr
      LEFT JOIN public.exos_vouchers v ON v.id = rr.voucher_id
     WHERE rr.referral_code = p_code AND rr.status = 'issued' AND rr.threshold > v_cnt
     FOR UPDATE OF rr
  LOOP
    v_used := v_rw.used_count > 0 OR EXISTS (
      SELECT 1 FROM public.exos_checkout_sessions s
       WHERE s.voucher_id = v_rw.voucher_id AND s.status = 'pending');
    CONTINUE WHEN v_used;
    -- exos_check_voucher treats valid_until < now() as expired.
    UPDATE public.exos_vouchers SET valid_until = now() - interval '1 second' WHERE id = v_rw.voucher_id;
    UPDATE public.exos_referral_rewards SET status = 'revoked', revoked_at = now() WHERE id = v_rw.id;
    v_changed := v_changed + 1;
  END LOOP;

  IF rule.id IS NULL OR NOT rule.enabled OR v_email IS NULL THEN
    RETURN v_changed;
  END IF;

  v_target := least(v_cnt / rule.every_n, rule.max_rewards_per_fan);
  v_rev := coalesce(rule.reward_event_id, fr.event_id);
  FOR m IN 1..v_target LOOP
    SELECT rr.id, rr.status, rr.voucher_id, v.used_count INTO v_rw
      FROM public.exos_referral_rewards rr
      LEFT JOIN public.exos_vouchers v ON v.id = rr.voucher_id
     WHERE rr.referral_code = p_code AND rr.milestone = m;
    v_exists := FOUND;
    IF v_exists AND v_rw.status = 'issued' THEN
      CONTINUE;
    END IF;
    IF v_exists AND v_rw.voucher_id IS NOT NULL THEN
      -- Revoked earlier and earned again: reopen the same code.
      UPDATE public.exos_vouchers SET valid_until = NULL, reserved_email = v_email WHERE id = v_rw.voucher_id;
      UPDATE public.exos_referral_rewards
         SET status = 'issued', revoked_at = NULL, threshold = m * rule.every_n
       WHERE id = v_rw.id;
      v_changed := v_changed + 1;
      CONTINUE;
    END IF;

    -- Mint a voucher. Reward tier must still be on the reward event.
    v_tier := rule.reward_tier_id;
    IF v_tier IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM public.exos_ticket_tiers WHERE id = v_tier AND event_id = v_rev) THEN
      RETURN v_changed;
    END IF;
    IF rule.reward_kind = 'price' THEN
      v_price := rule.reward_value / 100.0;
    ELSIF rule.reward_kind = 'percent_off' THEN
      v_price := round(public.exos_rr_tier_price(v_tier) * (100 - rule.reward_value) / 100.0, 2);
    ELSE
      v_price := greatest(0, public.exos_rr_tier_price(v_tier) - rule.reward_value / 100.0);
    END IF;
    IF v_price > 0 AND v_price < 0.50 THEN v_price := 0; END IF;

    v_vid := NULL;
    FOR i IN 1..5 LOOP
      v_code := 'FRIEND' || upper(encode(extensions.gen_random_bytes(5), 'hex'));
      BEGIN
        INSERT INTO public.exos_vouchers (event_id, code, tier_id, max_uses, bypass_capacity,
                    price_override, reserved_email, comment, created_by)
        VALUES (v_rev, v_code, v_tier, 1, rule.bypass_capacity, v_price, v_email,
                format('Referral reward %s (%s friends'' tickets)', m, m * rule.every_n), NULL)
        RETURNING id INTO v_vid;
        EXIT;
      EXCEPTION WHEN unique_violation THEN v_vid := NULL;
      END;
    END LOOP;
    IF v_vid IS NULL THEN RAISE EXCEPTION 'exos_referral_rewards_sync: could not allocate a voucher code'; END IF;

    IF v_exists THEN
      -- A revoked row whose voucher the organizer deleted: give it a new one.
      UPDATE public.exos_referral_rewards
         SET status = 'issued', revoked_at = NULL, voucher_id = v_vid, threshold = m * rule.every_n,
             rule_id = rule.id, reward_event_id = v_rev, issued_at = now()
       WHERE id = v_rw.id;
    ELSE
      INSERT INTO public.exos_referral_rewards
        (referral_code, user_id, event_id, milestone, threshold, rule_id, reward_event_id, voucher_id)
      VALUES (p_code, fr.user_id, fr.event_id, m, m * rule.every_n, rule.id, v_rev, v_vid)
      ON CONFLICT (referral_code, milestone) DO NOTHING;
    END IF;
    v_changed := v_changed + 1;
  END LOOP;
  RETURN v_changed;
END $$;
REVOKE ALL ON FUNCTION public.exos_referral_rewards_sync(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.exos_referral_rewards_sync(text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Triggers
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_tg_referral_rewards()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_codes text[]; c text;
BEGIN
  IF TG_OP = 'INSERT' OR OLD.referral_code IS NOT DISTINCT FROM NEW.referral_code THEN
    v_codes := ARRAY[NEW.referral_code];
  ELSE
    v_codes := ARRAY[NEW.referral_code, OLD.referral_code];
  END IF;
  FOREACH c IN ARRAY v_codes LOOP
    CONTINUE WHEN c IS NULL;
    BEGIN
      PERFORM public.exos_referral_rewards_sync(c);
    EXCEPTION WHEN OTHERS THEN
      -- Never block a sale or a void over a reward; the next sync catches up.
      RAISE WARNING 'exos_referral_rewards_sync(%) failed: %', c, SQLERRM;
    END;
  END LOOP;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_referral_rewards() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_tickets_referral_rewards_ins ON public.exos_tickets;
CREATE TRIGGER exos_tickets_referral_rewards_ins
  AFTER INSERT ON public.exos_tickets
  FOR EACH ROW WHEN (NEW.referral_code IS NOT NULL)
  EXECUTE FUNCTION public.exos_tg_referral_rewards();
DROP TRIGGER IF EXISTS exos_tickets_referral_rewards_upd ON public.exos_tickets;
CREATE TRIGGER exos_tickets_referral_rewards_upd
  AFTER UPDATE OF referral_code, status, buyer_id, buyer_email, price_paid ON public.exos_tickets
  FOR EACH ROW WHEN (
    (OLD.referral_code IS NOT NULL OR NEW.referral_code IS NOT NULL) AND (
      OLD.referral_code IS DISTINCT FROM NEW.referral_code OR OLD.status IS DISTINCT FROM NEW.status
      OR OLD.buyer_id IS DISTINCT FROM NEW.buyer_id OR OLD.buyer_email IS DISTINCT FROM NEW.buyer_email
      OR OLD.price_paid IS DISTINCT FROM NEW.price_paid))
  EXECUTE FUNCTION public.exos_tg_referral_rewards();

-- A deleted reward (account deletion cascades here) closes its voucher and
-- drops the reserved email.
CREATE OR REPLACE FUNCTION public.exos_tg_referral_reward_deleted()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF OLD.voucher_id IS NOT NULL THEN
    UPDATE public.exos_vouchers
       SET reserved_email = NULL,
           valid_until = CASE WHEN used_count < max_uses THEN least(coalesce(valid_until, now()), now() - interval '1 second') ELSE valid_until END
     WHERE id = OLD.voucher_id;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION public.exos_tg_referral_reward_deleted() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS exos_referral_rewards_deleted ON public.exos_referral_rewards;
CREATE TRIGGER exos_referral_rewards_deleted
  AFTER DELETE ON public.exos_referral_rewards
  FOR EACH ROW EXECUTE FUNCTION public.exos_tg_referral_reward_deleted();

-- ---------------------------------------------------------------------------
-- 5. Organizer RPCs
-- ---------------------------------------------------------------------------

-- Create or replace the rule for an event (p_event_id) or the org default
-- (p_event_id NULL, p_org_id set). Owner / manager. Re-syncs affected codes.
CREATE OR REPLACE FUNCTION public.exos_set_referral_reward_rule(
  p_event_id            uuid,
  p_org_id              uuid    DEFAULT NULL,
  p_enabled             boolean DEFAULT true,
  p_every_n             int     DEFAULT 3,
  p_max_rewards_per_fan int     DEFAULT 1,
  p_count_free_claims   boolean DEFAULT true,
  p_reward_event_id     uuid    DEFAULT NULL,
  p_reward_tier_id      uuid    DEFAULT NULL,
  p_reward_kind         text    DEFAULT 'price',
  p_reward_value        int     DEFAULT 0,
  p_bypass_capacity     boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_org   uuid;
  v_start timestamptz;
  v_rev   uuid;
  v_rorg  uuid;
  v_rstart timestamptz;
  v_rstat text;
  v_id    uuid;
  c       text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_set_referral_reward_rule: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_event_id IS NOT NULL THEN
    SELECT org_id, starts_at INTO v_org, v_start FROM public.exos_events WHERE id = p_event_id;
    IF v_org IS NULL THEN RAISE EXCEPTION 'exos_set_referral_reward_rule: event not found'; END IF;
    IF p_org_id IS NOT NULL AND p_org_id <> v_org THEN
      RAISE EXCEPTION 'exos_set_referral_reward_rule: event is not in that org' USING ERRCODE = '22023';
    END IF;
  ELSE
    v_org := p_org_id;
    IF v_org IS NULL THEN RAISE EXCEPTION 'exos_set_referral_reward_rule: pick an event or an org'; END IF;
  END IF;
  IF NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_referral_reward_rule: not authorized' USING ERRCODE = '42501';
  END IF;

  IF p_every_n IS NULL OR p_every_n NOT BETWEEN 1 AND 100 THEN
    RAISE EXCEPTION 'exos_set_referral_reward_rule: friends per reward must be 1-100' USING ERRCODE = '22023';
  END IF;
  IF p_max_rewards_per_fan IS NULL OR p_max_rewards_per_fan NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'exos_set_referral_reward_rule: rewards per fan must be 1-20' USING ERRCODE = '22023';
  END IF;
  IF p_reward_kind NOT IN ('price', 'percent_off', 'amount_off') THEN
    RAISE EXCEPTION 'exos_set_referral_reward_rule: unknown reward kind' USING ERRCODE = '22023';
  END IF;
  IF p_reward_value IS NULL OR p_reward_value < 0
     OR (p_reward_kind = 'percent_off' AND p_reward_value NOT BETWEEN 1 AND 100)
     OR (p_reward_kind = 'amount_off' AND p_reward_value < 1) THEN
    RAISE EXCEPTION 'exos_set_referral_reward_rule: reward value out of range' USING ERRCODE = '22023';
  END IF;

  -- Reward event: this event, or a later event of the same org.
  v_rev := coalesce(p_reward_event_id, p_event_id);
  IF p_reward_event_id IS NOT NULL THEN
    SELECT org_id, starts_at, status INTO v_rorg, v_rstart, v_rstat FROM public.exos_events WHERE id = p_reward_event_id;
    IF v_rorg IS NULL OR v_rorg <> v_org THEN
      RAISE EXCEPTION 'exos_set_referral_reward_rule: reward event must belong to this org' USING ERRCODE = '22023';
    END IF;
    IF v_rstat = 'cancelled' THEN
      RAISE EXCEPTION 'exos_set_referral_reward_rule: reward event is cancelled' USING ERRCODE = '22023';
    END IF;
    IF p_event_id IS NOT NULL AND p_reward_event_id <> p_event_id
       AND v_start IS NOT NULL AND v_rstart IS NOT NULL AND v_rstart < v_start THEN
      RAISE EXCEPTION 'exos_set_referral_reward_rule: reward event must be this one or a later one' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF p_reward_tier_id IS NOT NULL THEN
    IF v_rev IS NULL THEN
      RAISE EXCEPTION 'exos_set_referral_reward_rule: an org default with a ticket type needs a reward event' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.exos_ticket_tiers WHERE id = p_reward_tier_id AND event_id = v_rev) THEN
      RAISE EXCEPTION 'exos_set_referral_reward_rule: ticket type is not on the reward event' USING ERRCODE = '22023';
    END IF;
  ELSIF p_reward_kind <> 'price' THEN
    RAISE EXCEPTION 'exos_set_referral_reward_rule: a %% or amount off needs a ticket type' USING ERRCODE = '22023';
  END IF;

  IF p_event_id IS NOT NULL THEN
    INSERT INTO public.exos_referral_reward_rules AS x
      (org_id, event_id, enabled, every_n, max_rewards_per_fan, count_free_claims,
       reward_event_id, reward_tier_id, reward_kind, reward_value, bypass_capacity, created_by)
    VALUES (v_org, p_event_id, coalesce(p_enabled, true), p_every_n, p_max_rewards_per_fan,
            coalesce(p_count_free_claims, true), p_reward_event_id, p_reward_tier_id, p_reward_kind,
            p_reward_value, coalesce(p_bypass_capacity, false), v_uid)
    ON CONFLICT (event_id) WHERE event_id IS NOT NULL DO UPDATE SET
      enabled = EXCLUDED.enabled, every_n = EXCLUDED.every_n,
      max_rewards_per_fan = EXCLUDED.max_rewards_per_fan, count_free_claims = EXCLUDED.count_free_claims,
      reward_event_id = EXCLUDED.reward_event_id, reward_tier_id = EXCLUDED.reward_tier_id,
      reward_kind = EXCLUDED.reward_kind, reward_value = EXCLUDED.reward_value,
      bypass_capacity = EXCLUDED.bypass_capacity
    RETURNING x.id INTO v_id;
  ELSE
    INSERT INTO public.exos_referral_reward_rules AS x
      (org_id, event_id, enabled, every_n, max_rewards_per_fan, count_free_claims,
       reward_event_id, reward_tier_id, reward_kind, reward_value, bypass_capacity, created_by)
    VALUES (v_org, NULL, coalesce(p_enabled, true), p_every_n, p_max_rewards_per_fan,
            coalesce(p_count_free_claims, true), p_reward_event_id, p_reward_tier_id, p_reward_kind,
            p_reward_value, coalesce(p_bypass_capacity, false), v_uid)
    ON CONFLICT (org_id) WHERE event_id IS NULL DO UPDATE SET
      enabled = EXCLUDED.enabled, every_n = EXCLUDED.every_n,
      max_rewards_per_fan = EXCLUDED.max_rewards_per_fan, count_free_claims = EXCLUDED.count_free_claims,
      reward_event_id = EXCLUDED.reward_event_id, reward_tier_id = EXCLUDED.reward_tier_id,
      reward_kind = EXCLUDED.reward_kind, reward_value = EXCLUDED.reward_value,
      bypass_capacity = EXCLUDED.bypass_capacity
    RETURNING x.id INTO v_id;
  END IF;

  -- Fans who already qualify get their rewards now.
  FOR c IN
    SELECT fr.code FROM public.exos_fan_referrals fr
    JOIN public.exos_events e ON e.id = fr.event_id
    WHERE (p_event_id IS NOT NULL AND fr.event_id = p_event_id)
       OR (p_event_id IS NULL AND e.org_id = v_org
           AND NOT EXISTS (SELECT 1 FROM public.exos_referral_reward_rules x WHERE x.event_id = e.id))
  LOOP
    PERFORM public.exos_referral_rewards_sync(c);
  END LOOP;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_referral_reward_rule(uuid, uuid, boolean, int, int, boolean, uuid, uuid, text, int, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_referral_reward_rule(uuid, uuid, boolean, int, int, boolean, uuid, uuid, text, int, boolean) TO authenticated, service_role;

-- Remove an event's own rule (it falls back to the org default) or the org
-- default. Rewards already issued stay.
CREATE OR REPLACE FUNCTION public.exos_delete_referral_reward_rule(p_rule_id uuid)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_referral_reward_rules WHERE id = p_rule_id;
  IF v_org IS NULL THEN RETURN false; END IF;
  IF auth.uid() IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_delete_referral_reward_rule: not authorized' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_referral_reward_rules WHERE id = p_rule_id;
  RETURN true;
END $$;
REVOKE ALL ON FUNCTION public.exos_delete_referral_reward_rule(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_delete_referral_reward_rule(uuid) TO authenticated, service_role;

-- The editor's data: this event's rule, the org default, which applies, and
-- the events/tiers a reward can be on (this event and later, not cancelled).
CREATE OR REPLACE FUNCTION public.exos_get_referral_reward_rule(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_org uuid; v_start timestamptz; v_ev jsonb; v_def jsonb; v_opts jsonb;
BEGIN
  SELECT org_id, starts_at INTO v_org, v_start FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL
     OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_get_referral_reward_rule: not allowed' USING ERRCODE = '42501';
  END IF;
  SELECT to_jsonb(x) - 'created_by' INTO v_ev  FROM public.exos_referral_reward_rules x WHERE x.event_id = p_event_id;
  SELECT to_jsonb(x) - 'created_by' INTO v_def FROM public.exos_referral_reward_rules x WHERE x.org_id = v_org AND x.event_id IS NULL;
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'name', e.name, 'startsAt', e.starts_at,
           'tiers', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'id', t.id, 'name', t.name, 'price', t.price, 'visibility', t.visibility)
                        ORDER BY t.sort_order, t.name), '[]'::jsonb)
                     FROM public.exos_ticket_tiers t WHERE t.event_id = e.id))
         ORDER BY (e.id <> p_event_id), e.starts_at NULLS LAST), '[]'::jsonb)
    INTO v_opts
    FROM public.exos_events e
   WHERE e.org_id = v_org AND e.status <> 'cancelled'
     AND (e.id = p_event_id OR v_start IS NULL OR e.starts_at IS NULL OR e.starts_at >= v_start);
  RETURN jsonb_build_object(
    'eventRule', v_ev, 'orgDefault', v_def,
    'applies', CASE WHEN v_ev IS NOT NULL THEN 'event' WHEN v_def IS NOT NULL THEN 'org' END,
    'rewardOptions', v_opts);
END $$;
REVOKE ALL ON FUNCTION public.exos_get_referral_reward_rule(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_get_referral_reward_rule(uuid) TO authenticated, service_role;

-- Top referrers for an event. Staff see a display name (profile, else the
-- name on the fan's ticket) or a masked email, never the full address.
CREATE OR REPLACE FUNCTION public.exos_referral_leaderboard(p_event_id uuid, p_limit int DEFAULT 25)
RETURNS TABLE (rank int, label text, tickets int, friends int, rewards_issued int, rewards_redeemed int)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_org uuid; v_rule public.exos_referral_reward_rules%ROWTYPE; v_free boolean;
  v_has_profiles boolean := to_regclass('public.exos_profiles') IS NOT NULL;
  v_name text; r record; n int := 0;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_events WHERE id = p_event_id;
  IF v_org IS NULL OR auth.uid() IS NULL
     OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_referral_leaderboard: not allowed' USING ERRCODE = '42501';
  END IF;
  v_rule := public.exos_rr_effective_rule(p_event_id);
  v_free := coalesce(v_rule.count_free_claims, true);
  FOR r IN
    SELECT fr.code, fr.user_id, u.email,
           public.exos_rr_counted_tickets(fr.code, v_free) AS n_tickets,
           (SELECT count(DISTINCT t.buyer_id)::int FROM public.exos_tickets t
             WHERE t.referral_code = fr.code AND t.status IN ('active', 'used', 'transferred')
               AND t.buyer_id IS DISTINCT FROM fr.user_id) AS n_friends,
           (SELECT count(*)::int FROM public.exos_referral_rewards rr
             WHERE rr.referral_code = fr.code AND rr.status = 'issued') AS n_issued,
           (SELECT count(*)::int FROM public.exos_referral_rewards rr
              JOIN public.exos_vouchers v ON v.id = rr.voucher_id
             WHERE rr.referral_code = fr.code AND v.used_count > 0) AS n_redeemed,
           (SELECT t.attendee_name FROM public.exos_tickets t
             WHERE t.event_id = fr.event_id AND t.owner_id = fr.user_id AND t.attendee_name IS NOT NULL
             ORDER BY t.created_at DESC LIMIT 1) AS attendee_name
      FROM public.exos_fan_referrals fr
      LEFT JOIN auth.users u ON u.id = fr.user_id
     WHERE fr.event_id = p_event_id
     ORDER BY 4 DESC, 6 DESC, fr.created_at
  LOOP
    CONTINUE WHEN r.n_tickets = 0 AND r.n_issued = 0 AND r.n_redeemed = 0;
    n := n + 1;
    EXIT WHEN n > greatest(1, least(coalesce(p_limit, 25), 200));
    v_name := NULL;
    IF v_has_profiles THEN
      EXECUTE 'SELECT nullif(btrim(display_name), '''') FROM public.exos_profiles WHERE id = $1'
        INTO v_name USING r.user_id;
    END IF;
    -- A "display name" that is really an email is masked like one.
    IF v_name IS NOT NULL AND position('@' in v_name) > 0 THEN v_name := public.exos_rr_mask_email(v_name); END IF;
    rank := n;
    label := left(coalesce(v_name, nullif(btrim(r.attendee_name), ''), public.exos_rr_mask_email(r.email), 'Fan'), 60);
    tickets := r.n_tickets; friends := r.n_friends;
    rewards_issued := r.n_issued; rewards_redeemed := r.n_redeemed;
    RETURN NEXT;
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.exos_referral_leaderboard(uuid, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_referral_leaderboard(uuid, int) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Fan RPCs
-- ---------------------------------------------------------------------------

-- The caller's progress for an event: counted tickets, the next threshold,
-- and rewards with their codes. Runs a sync first (catches up after the fan
-- confirms their email). Doesn't create a referral code.
CREATE OR REPLACE FUNCTION public.exos_my_referral_progress(p_event_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_code text;
  rule public.exos_referral_reward_rules%ROWTYPE;
  v_cnt int := 0;
  v_confirmed boolean;
  v_earned int;
  v_next int;
  v_rewards jsonb;
  v_rule jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_my_referral_progress: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT code INTO v_code FROM public.exos_fan_referrals WHERE event_id = p_event_id AND user_id = v_uid;
  rule := public.exos_rr_effective_rule(p_event_id);
  SELECT (u.email_confirmed_at IS NOT NULL) INTO v_confirmed FROM auth.users u WHERE u.id = v_uid;
  IF v_code IS NOT NULL THEN
    PERFORM public.exos_referral_rewards_sync(v_code);
    v_cnt := public.exos_rr_counted_tickets(v_code, coalesce(rule.count_free_claims, true));
  END IF;

  IF rule.id IS NOT NULL AND rule.enabled THEN
    SELECT count(*)::int INTO v_earned FROM public.exos_referral_rewards
     WHERE referral_code = v_code AND status = 'issued';
    v_next := CASE WHEN v_earned >= rule.max_rewards_per_fan THEN NULL
                   ELSE ((v_cnt / rule.every_n) + 1) * rule.every_n END;
    SELECT jsonb_build_object(
             'everyN', rule.every_n, 'maxRewards', rule.max_rewards_per_fan,
             'countFreeClaims', rule.count_free_claims,
             'kind', rule.reward_kind, 'value', rule.reward_value,
             'rewardEventId', coalesce(rule.reward_event_id, p_event_id),
             'rewardEventName', (SELECT name FROM public.exos_events WHERE id = coalesce(rule.reward_event_id, p_event_id)),
             'rewardTierName', (SELECT name FROM public.exos_ticket_tiers WHERE id = rule.reward_tier_id))
      INTO v_rule;
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'id', rr.id, 'milestone', rr.milestone, 'threshold', rr.threshold, 'status', rr.status,
           'code', CASE WHEN rr.status = 'issued' THEN v.code END,
           'redeemed', coalesce(v.used_count, 0) > 0,
           'free', v.price_override = 0,
           'price', v.price_override,
           'tierId', v.tier_id,
           'tierName', (SELECT name FROM public.exos_ticket_tiers WHERE id = v.tier_id),
           'eventId', rr.reward_event_id,
           'eventName', (SELECT name FROM public.exos_events WHERE id = rr.reward_event_id),
           'issuedAt', rr.issued_at) ORDER BY rr.milestone), '[]'::jsonb)
    INTO v_rewards
    FROM public.exos_referral_rewards rr
    LEFT JOIN public.exos_vouchers v ON v.id = rr.voucher_id
   WHERE rr.referral_code = v_code AND rr.user_id = v_uid;

  RETURN jsonb_build_object(
    'code', v_code, 'counted', v_cnt, 'nextThreshold', v_next,
    'emailConfirmed', coalesce(v_confirmed, false),
    'rule', v_rule, 'rewards', v_rewards);
END $$;
REVOKE ALL ON FUNCTION public.exos_my_referral_progress(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_my_referral_progress(uuid) TO authenticated, service_role;

-- Claim a FREE reward: mints one ticket to the caller and uses the voucher.
-- p_tier_id matters only when the reward is valid on any ticket type (then
-- it must be a public tier; NULL picks the first public one). Discount
-- rewards go through checkout.
CREATE OR REPLACE FUNCTION public.exos_redeem_referral_reward(p_reward_id uuid, p_tier_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text;
  rw      public.exos_referral_rewards%ROWTYPE;
  v       public.exos_vouchers%ROWTYPE;
  ev      public.exos_events%ROWTYPE;
  tr      public.exos_ticket_tiers%ROWTYPE;
  v_ok    boolean;
  v_rows  int;
  v_id    uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT lower(email) INTO v_email FROM auth.users WHERE id = v_uid AND email_confirmed_at IS NOT NULL;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: confirm your email first' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO rw FROM public.exos_referral_rewards WHERE id = p_reward_id AND user_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: reward not found' USING ERRCODE = '42501';
  END IF;
  IF rw.status <> 'issued' OR rw.voucher_id IS NULL THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: this reward is no longer available' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v FROM public.exos_vouchers WHERE id = rw.voucher_id FOR UPDATE;
  SELECT c.is_valid INTO v_ok FROM public.exos_check_voucher(v.event_id, v.code, v_email) c;
  IF NOT coalesce(v_ok, false) THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: this reward was already used or has expired' USING ERRCODE = '42501';
  END IF;
  IF coalesce(v.price_override, -1) <> 0 THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: this reward is a discount, use the code at checkout' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO ev FROM public.exos_events WHERE id = v.event_id;
  IF ev.status <> 'published' THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: event not on sale' USING ERRCODE = '42501';
  END IF;
  IF coalesce(ev.ends_at, ev.starts_at) IS NOT NULL AND coalesce(ev.ends_at, ev.starts_at) < now() THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: event is over' USING ERRCODE = '42501';
  END IF;
  IF v.tier_id IS NULL AND p_tier_id IS NULL THEN
    -- "Any ticket type" and none picked: the first public tier.
    SELECT * INTO tr FROM public.exos_ticket_tiers
     WHERE event_id = v.event_id AND coalesce(visibility, 'public') = 'public'
     ORDER BY sort_order NULLS LAST, price, id LIMIT 1;
  ELSE
    SELECT * INTO tr FROM public.exos_ticket_tiers WHERE id = coalesce(v.tier_id, p_tier_id) AND event_id = v.event_id;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: pick a ticket type' USING ERRCODE = '22023';
  END IF;
  IF v.tier_id IS NULL AND tr.visibility IS NOT NULL AND tr.visibility <> 'public' THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: ticket type not available' USING ERRCODE = '42501';
  END IF;

  IF v.bypass_capacity THEN
    UPDATE public.exos_ticket_tiers SET sold = sold + 1 WHERE id = tr.id;
    UPDATE public.exos_events SET tickets_sold = tickets_sold + 1 WHERE id = ev.id;
  ELSE
    UPDATE public.exos_ticket_tiers SET sold = sold + 1
     WHERE id = tr.id AND (capacity = 0 OR sold + 1 <= capacity) AND public.exos_seats_available(tr.id, 1);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
      RAISE EXCEPTION 'exos_redeem_referral_reward: sold out' USING ERRCODE = '23514';
    END IF;
    UPDATE public.exos_events SET tickets_sold = tickets_sold + 1
     WHERE id = ev.id AND (total_tickets = 0 OR tickets_sold + 1 <= total_tickets);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows = 0 THEN
      RAISE EXCEPTION 'exos_redeem_referral_reward: sold out' USING ERRCODE = '23514';
    END IF;
  END IF;

  IF NOT public.exos_consume_voucher(v.id) THEN
    RAISE EXCEPTION 'exos_redeem_referral_reward: this reward was already used' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.exos_tickets (
    event_id, org_id, tier_id, tier_name, buyer_id, owner_id, buyer_email,
    status, barcode_secret, price_paid, order_ref, channel_source
  ) VALUES (
    ev.id, ev.org_id, tr.id, tr.name, v_uid, v_uid, v_email,
    'active', gen_random_uuid()::text, 0, 'referral_' || rw.id::text, 'referral_reward'
  ) RETURNING id INTO v_id;
  BEGIN
    PERFORM public.exos_queue_ticket_issued(v_id);
  EXCEPTION WHEN OTHERS THEN
    NULL;   -- confirmation mail is best-effort
  END;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_redeem_referral_reward(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_redeem_referral_reward(uuid, uuid) TO authenticated, service_role;
