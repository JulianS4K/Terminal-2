-- Minimal Supabase-like prerequisite schema to test the exos feature migrations.
-- Mirrors the column shapes the migrations depend on (not the full prod schema).

DO $r$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $r$;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions;  -- digest, gen_random_bytes, hmac

-- auth schema + uid()/jwt() driven by GUCs so tests can simulate users.
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE auth.users (
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

-- updated_at touch (from phase-1).
CREATE OR REPLACE FUNCTION public.exos_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$;

CREATE TABLE public.exos_orgs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text, slug text UNIQUE, owner_uid uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.exos_org_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL, user_id uuid NOT NULL,
  role text NOT NULL, disabled boolean NOT NULL DEFAULT false,
  UNIQUE (org_id, user_id)
);
CREATE OR REPLACE FUNCTION public.exos_has_org_role(p_org_id uuid, p_roles text[])
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM public.exos_org_memberships m
    WHERE m.org_id = p_org_id AND m.user_id = auth.uid()
      AND m.disabled IS NOT TRUE AND m.role = ANY (p_roles));
$$;

CREATE TABLE public.exos_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL, name text, slug text, status text NOT NULL DEFAULT 'draft',
  starts_at timestamptz, doors_at timestamptz, currency text DEFAULT 'usd',
  total_tickets integer NOT NULL DEFAULT 0, tickets_sold integer NOT NULL DEFAULT 0,
  purchase_limits jsonb,
  occurs_at_local text, venue_name text, venue_location text,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
-- exos_is_admin() stub (prod: phase-1 SECDEF role check). Tests never grant
-- platform-admin, so a constant false is the faithful default.
CREATE OR REPLACE FUNCTION public.exos_is_admin() RETURNS boolean
  LANGUAGE sql STABLE AS $$ SELECT false $$;
CREATE TABLE public.exos_ticket_tiers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL, name text, description text, price numeric NOT NULL DEFAULT 0,
  capacity integer NOT NULL DEFAULT 0, sold integer NOT NULL DEFAULT 0,
  ticket_type text DEFAULT 'paid', visibility text DEFAULT 'public',
  sales_start timestamptz, sales_end timestamptz, sort_order integer DEFAULT 0
);
CREATE TABLE public.exos_tickets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL, org_id uuid NOT NULL, tier_id uuid, tier_name text,
  buyer_id uuid, owner_id uuid, buyer_email text, status text NOT NULL DEFAULT 'active',
  barcode_secret text, price_paid numeric NOT NULL DEFAULT 0, order_ref text,
  channel_source text NOT NULL DEFAULT 'vibepass', check_in_at timestamptz,
  pending_transfer_id uuid, transfer_id uuid, last_reissue_at timestamptz,
  voided_at timestamptz, voided_reason text,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.exos_transfers (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ticket_id uuid NOT NULL, org_id uuid NOT NULL, sender_id uuid,
  receiver_email text, status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.exos_event_checkins (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL, ticket_id uuid NOT NULL, org_id uuid NOT NULL,
  scanned_by uuid, scanned_by_email text, source text, verification text,
  scanned_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.exos_checkout_sessions (
  session_id text PRIMARY KEY, event_id uuid NOT NULL, tier_id uuid, org_id uuid NOT NULL,
  buyer_uid uuid NOT NULL, buyer_email text, quantity int NOT NULL,
  amount_cents int NOT NULL, currency text NOT NULL DEFAULT 'usd',
  status text NOT NULL DEFAULT 'pending', ticket_ids uuid[], payment_intent text,
  failure_reason text, created_at timestamptz NOT NULL DEFAULT now(), fulfilled_at timestamptz
);
CREATE TABLE public.exos_mail (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  to_email text NOT NULL, template text NOT NULL, subject text NOT NULL, html text NOT NULL,
  status text NOT NULL DEFAULT 'pending', created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(), sent_at timestamptz, error text
);
ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check
  CHECK (template IN ('transfer-initiated','transfer-claimed','org-invite',
                      'event-cancelled','event-updated','event-announce','ticket-issued'));
