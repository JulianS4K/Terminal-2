-- Migration 20260702130000 · level:security · lane:A1 (DB security, RULE-2) · writes:d0_s4kent_gate_health() + COMMENT ON POLICY d0_s4kent_read (×10) · reads:auth.users, pg_policies · pre:20260519300000 · auth:PENDING — file-only, NOT YET APPLIED; A1 applies to prod after review (git push ≠ DB apply, PROJECT_BIBLE §push-protocol)
--
-- Actions D0 code-review item #2 (RLS email-claim ↔ auth-config coupling),
-- routed to A1 as the DB-security lane owner (RULE-2).
--
-- THE COUPLING
-- ------------
-- The D0 read wall is the policy `d0_s4kent_read` on 10 tables (mig
-- 20260515320000, initplan-fixed 20260519300000):
--     USING (coalesce((select auth.jwt())->>'email','') LIKE '%@s4kent.com')
-- It trusts ONLY the JWT email claim + domain. That is sound *only while* two
-- Supabase-Auth config facts hold:
--   (a) email confirmation is MANDATORY, and
--   (b) uncontrolled password signup is DISABLED.
-- If either lapses, someone can register `anything@s4kent.com`, and the email
-- claim exists on their JWT *before* the address is verified — so the gate
-- opens for an account nobody at s4kent controls. The policy and the auth
-- config were coupled with nothing surfacing a drift between them. This
-- migration pins the assumption in the catalog (COMMENT ON POLICY) and adds a
-- health RPC that makes a breach observable.
--
-- WHY NOT just add `email_verified` to the policy USING clause: that is a
-- behavioural change to the live wall (10 policies) and risks locking out
-- legitimate sessions whose JWT lacks the claim shape we assume — a separate,
-- higher-blast-radius decision. This migration is documentation + detection
-- only; hardening the USING clause is left as an explicit follow-up.

-- ---------------------------------------------------------------------------
-- 1. Pin the coupling AT THE POLICY (COMMENT ON POLICY, catalog-durable).
--    Wrapped in a defensive loop so it is idempotent and skips any table where
--    the policy is absent (branch envs), mirroring the source migration's
--    skip-missing behaviour. (Supabase runs PG15+, where COMMENT ON POLICY is
--    supported — the 2026-05-15 "not portable" note predates confirming the
--    engine version.)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  t text;
  tables text[] := ARRAY[
    'events','event_xref','sg_events_canonical','aq_event_map','aq_venue_map',
    'aq_performer_map','performer_metadata','venue_assets','cron_policy','cron_gate_decisions'
  ];
  v_doc text :=
    'D0 read wall. Trusts auth.jwt()->>''email'' LIKE ''%@s4kent.com'' ALONE. '
    'SAFE ONLY IF Supabase Auth keeps (a) email confirmation mandatory and '
    '(b) uncontrolled password signup disabled — else an unconfirmed '
    '@s4kent.com signup satisfies this gate. Monitor via '
    'public.d0_s4kent_gate_health() (mig 20260702130000).';
BEGIN
  FOREACH t IN ARRAY tables LOOP
    IF EXISTS (
      SELECT 1 FROM pg_policies
      WHERE schemaname='public' AND tablename=t AND policyname='d0_s4kent_read'
    ) THEN
      EXECUTE format('COMMENT ON POLICY d0_s4kent_read ON public.%I IS %L', t, v_doc);
    ELSE
      RAISE NOTICE 's4kent_gate_coupling_doc: skipping missing policy on public.%', t;
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 2. Periodic config check — makes the coupling observable.
--    Surfaces the empirically-detectable half of the risk: @s4kent.com auth
--    users that exist but are UNCONFIRMED (email_confirmed_at IS NULL) — the
--    exact accounts that could satisfy the email gate without verified control
--    of the address. coupling_ok=false ⇒ investigate immediately.
--    The config half (is password signup enabled?) lives in GoTrue config, not
--    queryable via SQL on hosted Supabase, so it is called out as a manual
--    operator check in the return payload rather than asserted here.
--    SECURITY DEFINER so it can read auth.users; @s4kent.com body-gated;
--    STABLE; auth.users fully-qualified (auth NOT on search_path).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.d0_s4kent_gate_health()
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $func$
DECLARE
  v_email       text;
  v_total       int;
  v_unconfirmed int;
  v_samples     jsonb;
BEGIN
  -- auth gate (mirrors sibling SECDEF RPCs, e.g. get_event_td_pull_health)
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  SELECT count(*),
         count(*) FILTER (WHERE u.email_confirmed_at IS NULL)
    INTO v_total, v_unconfirmed
  FROM auth.users u
  WHERE u.email ILIKE '%@s4kent.com';

  SELECT coalesce(jsonb_agg(u.email ORDER BY u.created_at DESC), '[]'::jsonb)
    INTO v_samples
  FROM (
    SELECT email, created_at
    FROM auth.users
    WHERE email ILIKE '%@s4kent.com' AND email_confirmed_at IS NULL
    ORDER BY created_at DESC
    LIMIT 20
  ) u;

  RETURN jsonb_build_object(
    'generated_at',            to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    's4kent_users_total',      v_total,
    's4kent_users_unconfirmed', v_unconfirmed,
    'unconfirmed_samples',     v_samples,
    -- The RLS gate is safe iff no unconfirmed s4kent account can present the
    -- email claim. Any unconfirmed s4kent user is a live coupling breach.
    'coupling_ok',             (v_unconfirmed = 0),
    'manual_check',            'Verify in Supabase Auth: email confirmation is mandatory AND uncontrolled password signup is disabled. Not queryable from SQL; audit on config change.'
  );
END $func$;

REVOKE ALL ON FUNCTION public.d0_s4kent_gate_health() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.d0_s4kent_gate_health() TO authenticated;

COMMENT ON FUNCTION public.d0_s4kent_gate_health() IS
  'Health check for the d0_s4kent_read RLS coupling (code-review #2). Returns counts of @s4kent.com auth.users, how many are UNCONFIRMED (email_confirmed_at IS NULL), a capped sample, and coupling_ok=(unconfirmed=0). An unconfirmed s4kent account can satisfy the email-claim gate without verified address control. Email-gated @s4kent.com, SECDEF, STABLE. A1-authored; A1 applies. Callable from the D0 health page.';

-- ============================================================
-- POST-APPLY VERIFICATION (read-only)
-- ============================================================
-- 1) Comments landed on all present policies:
--    SELECT tablename, obj_description(oid) FROM pg_policies pol
--      JOIN pg_policy p ON p.polname=pol.policyname
--    -- (or) SELECT tablename FROM pg_policies WHERE policyname='d0_s4kent_read';
-- 2) As an @s4kent.com authenticated user:  SELECT public.d0_s4kent_gate_health();
--    Expect coupling_ok=true and s4kent_users_unconfirmed=0 in a healthy state.
-- 3) As a non-s4kent / anon caller: expect ERRCODE 42501 (forbidden).
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.d0_s4kent_gate_health();
--   -- COMMENT ON POLICY d0_s4kent_read ON public.<t> IS NULL;  (per table, to clear)
