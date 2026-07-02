-- Regression test for migration 20260702123000 (barcode_secret least
-- privilege). Self-contained: builds the minimal real exos_tickets shape +
-- the phase-2 RLS policy/grants, applies the migration, and asserts that
-- finance/content org roles cannot read barcode_secret (base table OR the
-- gated view) while owner/buyer/scanner can. Unlike test_exos_platform.sql
-- this exercises RLS + column privileges, so it SET ROLEs to `authenticated`.
--
-- Run against a throwaway Postgres (no prereq.sql needed):
--   createdb bc_rls && psql -d bc_rls -f tests/exos/test_barcode_secret_rls.sql
-- ============================================================================
-- Faithful repro of the exos_tickets secret-visibility model + this migration.
\set ON_ERROR_STOP on

-- ---- roles + auth shim (mirror tests/exos/prereq.sql) ----------------------
DO $r$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $r$;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

CREATE SCHEMA IF NOT EXISTS auth;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.uid', true), '')::uuid $$;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('app.jwt', true), '')::jsonb, '{}'::jsonb) $$;

-- ---- org scaffolding + role helper (from prereq.sql) -----------------------
CREATE TABLE public.exos_org_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL, user_id uuid NOT NULL,
  role text NOT NULL, disabled boolean NOT NULL DEFAULT false,
  UNIQUE (org_id, user_id));
CREATE OR REPLACE FUNCTION public.exos_has_org_role(p_org_id uuid, p_roles text[])
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_org_memberships m
    WHERE m.org_id = p_org_id AND m.user_id = auth.uid()
      AND m.disabled IS NOT TRUE AND m.role = ANY (p_roles)); $$;
CREATE OR REPLACE FUNCTION public.exos_is_admin() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT false $$;

-- ---- REAL exos_tickets (full column set from mig 20260520130000 §1) --------
CREATE TABLE public.exos_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL, org_id uuid NOT NULL, tier_id uuid, tier_name text,
  buyer_id uuid NOT NULL, owner_id uuid NOT NULL, buyer_email text,
  status text NOT NULL DEFAULT 'active', barcode_secret text NOT NULL,
  price_paid numeric NOT NULL DEFAULT 0, order_ref text,
  channel_source text NOT NULL DEFAULT 'vibepass', promoter_id text,
  pending_transfer_id uuid, transfer_id uuid,
  voided_at timestamptz, voided_by uuid, voided_reason text,
  check_in_at timestamptz, last_reissue_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());

-- REAL policy + grants (mig 20260520130000 §6) -------------------------------
ALTER TABLE public.exos_tickets ENABLE ROW LEVEL SECURITY;
CREATE POLICY exos_tickets_sel ON public.exos_tickets FOR SELECT TO authenticated
  USING (owner_id = auth.uid() OR buyer_id = auth.uid() OR exos_is_admin()
         OR exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
REVOKE ALL ON public.exos_tickets FROM anon, authenticated;
GRANT SELECT ON public.exos_tickets TO authenticated;

-- ---- seed: one org, one ticket, five staff identities ----------------------
\set org   '''00000000-0000-0000-0000-0000000000a1'''
\set owner '''00000000-0000-0000-0000-000000000001'''
\set buyer '''00000000-0000-0000-0000-000000000002'''
\set fin   '''00000000-0000-0000-0000-000000000003'''
\set cont  '''00000000-0000-0000-0000-000000000004'''
\set scan  '''00000000-0000-0000-0000-000000000005'''
\set tkt   '''00000000-0000-0000-0000-0000000000f1'''

INSERT INTO public.exos_org_memberships(org_id,user_id,role) VALUES
  (:org,:fin,'finance'), (:org,:cont,'content'), (:org,:scan,'scanner');
INSERT INTO public.exos_tickets(id,event_id,org_id,buyer_id,owner_id,barcode_secret,status)
  VALUES (:tkt,'00000000-0000-0000-0000-0000000000e1',:org,:buyer,:owner,'SUPERSECRET','active');

-- ===========================================================================
-- APPLY THE MIGRATION UNDER TEST
-- ===========================================================================
\ir ../../supabase/migrations/20260702123000_exos_barcode_secret_least_privilege.sql

-- ===========================================================================
-- ASSERTIONS (run as the shared `authenticated` role; identity via app.uid)
-- ===========================================================================
SET ROLE authenticated;

-- 1. finance passes the row policy (reads non-secret columns) ...
SET app.uid = '00000000-0000-0000-0000-000000000003';
DO $$ DECLARE n int; BEGIN
  SELECT count(*) INTO n FROM public.exos_tickets;   -- id/status/etc. allowed
  ASSERT n = 1, 'finance should still read ticket rows (non-secret cols)';
  RAISE NOTICE 'OK  finance reads non-secret columns (% row)', n;
END $$;

-- 2. ... but CANNOT read barcode_secret off the base table (column revoked).
DO $$ BEGIN
  PERFORM barcode_secret FROM public.exos_tickets;
  RAISE EXCEPTION 'FAIL: finance read barcode_secret off base table';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK  finance denied barcode_secret on base table (%)', SQLERRM;
END $$;

-- 3. ... and the gated view returns NOTHING for finance.
DO $$ DECLARE s text; BEGIN
  SELECT barcode_secret INTO s FROM public.exos_ticket_barcode_secrets
   WHERE ticket_id = '00000000-0000-0000-0000-0000000000f1';
  ASSERT s IS NULL, 'finance must not get the secret via the view';
  RAISE NOTICE 'OK  finance gets no secret from the gated view';
END $$;

-- 4. content role: same denial via the view.
SET app.uid = '00000000-0000-0000-0000-000000000004';
DO $$ DECLARE s text; BEGIN
  SELECT barcode_secret INTO s FROM public.exos_ticket_barcode_secrets
   WHERE ticket_id = '00000000-0000-0000-0000-0000000000f1';
  ASSERT s IS NULL, 'content must not get the secret via the view';
  RAISE NOTICE 'OK  content gets no secret from the gated view';
END $$;

-- 5. scanner staff DO get the secret via the view.
SET app.uid = '00000000-0000-0000-0000-000000000005';
DO $$ DECLARE s text; BEGIN
  SELECT barcode_secret INTO s FROM public.exos_ticket_barcode_secrets
   WHERE ticket_id = '00000000-0000-0000-0000-0000000000f1';
  ASSERT s = 'SUPERSECRET', 'scanner should read the secret via the view';
  RAISE NOTICE 'OK  scanner reads secret via the view';
END $$;

-- 6. the ticket owner gets the secret (to render their pass).
SET app.uid = '00000000-0000-0000-0000-000000000001';
DO $$ DECLARE s text; BEGIN
  SELECT barcode_secret INTO s FROM public.exos_ticket_barcode_secrets
   WHERE ticket_id = '00000000-0000-0000-0000-0000000000f1';
  ASSERT s = 'SUPERSECRET', 'owner should read their own secret via the view';
  RAISE NOTICE 'OK  owner reads own secret via the view';
END $$;

-- 7. the buyer gets the secret too.
SET app.uid = '00000000-0000-0000-0000-000000000002';
DO $$ DECLARE s text; BEGIN
  SELECT barcode_secret INTO s FROM public.exos_ticket_barcode_secrets
   WHERE ticket_id = '00000000-0000-0000-0000-0000000000f1';
  ASSERT s = 'SUPERSECRET', 'buyer should read the secret via the view';
  RAISE NOTICE 'OK  buyer reads secret via the view';
END $$;

-- 8. a random authenticated user (no relation) gets nothing.
SET app.uid = '00000000-0000-0000-0000-0000000000ff';
DO $$ DECLARE s text; BEGIN
  SELECT barcode_secret INTO s FROM public.exos_ticket_barcode_secrets
   WHERE ticket_id = '00000000-0000-0000-0000-0000000000f1';
  ASSERT s IS NULL, 'unrelated user must not get the secret';
  RAISE NOTICE 'OK  unrelated user gets no secret';
END $$;

RESET ROLE;
SELECT '*** barcode_secret least-privilege: ALL ASSERTIONS PASSED ***' AS result;
