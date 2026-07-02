-- Minimal Supabase-like prerequisites for the Exos TICKET-LIFECYCLE test
-- (tests/exos/test_exos_lifecycle.sql). Unlike prereq.sql — which hand-stubs a
-- frozen copy of the ticket schema for the phase-3 platform test — this file
-- stubs ONLY what Supabase provides (roles, auth, pgcrypto) and then the real
-- phase-1/phase-2/hardening migrations create the ticket/transfer/check-in
-- surface. That is the whole point: the lifecycle test runs the ACTUAL migrated
-- RPC bodies, so mint/scan/transfer/claim/void/reissue can't drift from prod.
--
-- auth.uid()/auth.jwt() read GUCs (app.uid / app.jwt) so the test can act as
-- different signed-in users — same convention as prereq.sql.

DO $r$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon')          THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='service_role')  THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $r$;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions;  -- extensions.hmac for barcode verify

CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY,
  email text,
  email_confirmed_at timestamptz
);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.uid', true), '')::uuid
$$;
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('app.jwt', true), '')::jsonb, '{}'::jsonb)
$$;
