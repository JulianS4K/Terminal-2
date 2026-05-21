-- ============================================================================
-- Migration 20260520120000 — Exos (Bridge / D4) phase-1 schema: orgs + events
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_profiles (W), exos_orgs (W), exos_org_secrets (W),
--           exos_org_memberships (W), exos_org_invites (W), exos_events (W),
--           exos_ticket_tiers (W), exos_discount_codes (W),
--           bridge_event_xref (W); reads aq_event_map (R, by-value xref only)
-- Pre-reqs: Supabase Auth enabled (auth.users); pgcrypto/gen_random_uuid()
--
-- Phase 1 of moving Exos persistence off Firestore onto Supabase (operator
-- directive 2026-05-20: incremental, Supabase Auth, same prod project, D4-owned
-- exos_* tables). Mirrors D0 `events` column shapes where they overlap
-- (name / occurs_at_local / venue_* / primary_performer_* / event_type) so an
-- Exos primary event is consistent with the catalog and linkable to the
-- canonical key via bridge_event_xref(aq_short_event_id). D4 NEVER writes D0
-- tables; consistency is via shape + by-value xref only.
--
-- RLS mirrors the Firestore ownership model (firestore.rules): deny-by-default,
-- public read of PUBLISHED events, org-staff writes via exos_has_org_role().
-- Org payment/distribution secrets are isolated in exos_org_secrets (owner-only).
-- Anon reads ONLY column-narrowed public views (exos_public_orgs/events/tiers, §7b),
-- never base tables — drops owner_uid + internal cols, hides non-public tiers.
-- ⚠ B1 review requested on the RLS model before prod apply (new auth surface;
-- charter §6.5). Tickets/transfers/check-ins land in phase-2 (20260520130000).
-- D4 authors; validate on a Supabase preview branch; A1 applies to prod.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- updated_at touch trigger (exos-scoped to avoid clobbering any global one)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ===========================================================================
-- 1. Profiles (display-only mirror of auth.users; email stays on the JWT)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_profiles (
  id           uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
  display_name text,
  photo_url    text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ===========================================================================
-- 2. Organizations (venue / promoter tenants). Public-readable branding.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_orgs (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text NOT NULL,
  slug       text NOT NULL UNIQUE,
  owner_uid  uuid NOT NULL REFERENCES auth.users (id),
  -- Public-facing white-label branding (logo/colors/customDomain).
  theme      jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Sensitive org config kept OUT of the public-readable row (mirrors the
-- Firestore "rules block all client reads" of distribution creds).
CREATE TABLE IF NOT EXISTS public.exos_org_secrets (
  org_id       uuid PRIMARY KEY REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- Stripe Connect: { connectedAccountId, onboardingComplete, chargesEnabled, payoutsEnabled }
  payments     jsonb,
  -- Lysted/Automatiq: { lystedSellerId, enabled } — opaque creds, never client-read.
  distribution jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ===========================================================================
-- 3. Memberships (RBAC) + email invites
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_org_memberships (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  user_id    uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  role       text NOT NULL CHECK (role IN ('owner','manager','finance','scanner','content')),
  added_by   uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  disabled   boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, user_id)
);
CREATE INDEX IF NOT EXISTS exos_org_memberships_user_idx ON public.exos_org_memberships (user_id);
CREATE INDEX IF NOT EXISTS exos_org_memberships_org_idx  ON public.exos_org_memberships (org_id);

CREATE TABLE IF NOT EXISTS public.exos_org_invites (
  token       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id      uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  email       text NOT NULL,                       -- lowercased invitee email
  role        text NOT NULL CHECK (role IN ('manager','finance','scanner','content')), -- never 'owner' from client
  created_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  status      text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','cancelled','expired')),
  expires_at  timestamptz,
  claimed_by  uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  claimed_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_org_invites_email_idx ON public.exos_org_invites (lower(email));
CREATE INDEX IF NOT EXISTS exos_org_invites_org_idx   ON public.exos_org_invites (org_id);

-- ---------------------------------------------------------------------------
-- RBAC helper. SECURITY DEFINER so RLS policies can check the CALLER's own
-- membership without recursing on exos_org_memberships' own RLS.
-- NOTE: deliberately NOT using the service-role-only body gate from the repo
-- SECDEF convention — this helper MUST be callable by `authenticated` inside
-- RLS. It only ever evaluates auth.uid()'s OWN membership, so it leaks nothing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_has_org_role(p_org_id uuid, p_roles text[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.exos_org_memberships m
    WHERE m.org_id = p_org_id
      AND m.user_id = auth.uid()
      AND m.disabled IS NOT TRUE
      AND m.role = ANY (p_roles)
  );
$$;
REVOKE EXECUTE ON FUNCTION public.exos_has_org_role(uuid, text[]) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_has_org_role(uuid, text[]) TO authenticated, service_role;

-- ===========================================================================
-- 4. Events. Mirrors D0 `events` shape where overlapping (name, occurs_at_local,
--    venue_*, primary_performer_*, event_type) + Exos primary-market fields.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.exos_events (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id                 uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  -- D0-aligned columns (same names/types as public.events) ------------------
  name                   text NOT NULL,
  occurs_at_local        text,            -- ISO local string, D0-consistent display key
  venue_id               bigint,          -- canonical/TEvo venue id when xref'd, else NULL
  venue_name             text,
  venue_location         text,
  primary_performer_id   bigint,          -- canonical/TEvo performer id when xref'd
  primary_performer_name text,
  event_type             text,            -- game / concert / comedy / show (D0 taxonomy)
  -- Exos primary-market fields (no D0 equivalent) ---------------------------
  slug                   text UNIQUE,
  description            text,
  status                 text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','cancelled')),
  starts_at              timestamptz,
  doors_at               timestamptz,
  ends_at                timestamptz,
  timezone               text,            -- IANA, e.g. America/New_York
  currency               text NOT NULL DEFAULT 'USD',
  venue_address          jsonb,           -- { street, city, region, country, postal }
  performer_names        text[],          -- organizer free-text lineup (max 10, app-enforced)
  category               text,
  genres                 text[],
  subgenres              text[],
  image_url              text,
  total_tickets          integer NOT NULL DEFAULT 0 CHECK (total_tickets >= 0),
  tickets_sold           integer NOT NULL DEFAULT 0 CHECK (tickets_sold >= 0),
  branding               jsonb,
  exclusivity            jsonb,
  purchase_limits        jsonb,
  distribution_networks  text[],
  automatiq_listing_id   text,
  sync_status            text CHECK (sync_status IS NULL OR sync_status IN ('synced','failed','pending')),
  cancelled_at           timestamptz,
  cancel_reason          text,
  created_by             uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_events_org_idx       ON public.exos_events (org_id);
CREATE INDEX IF NOT EXISTS exos_events_status_idx    ON public.exos_events (status);
CREATE INDEX IF NOT EXISTS exos_events_starts_at_idx ON public.exos_events (starts_at);

CREATE TABLE IF NOT EXISTS public.exos_ticket_tiers (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id     uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  name         text NOT NULL,
  description  text,
  price        numeric NOT NULL DEFAULT 0 CHECK (price >= 0),
  capacity     integer NOT NULL DEFAULT 0 CHECK (capacity >= 0),
  sold         integer NOT NULL DEFAULT 0 CHECK (sold >= 0),
  ticket_type  text NOT NULL DEFAULT 'paid' CHECK (ticket_type IN ('paid','free','donation')),
  visibility   text NOT NULL DEFAULT 'public' CHECK (visibility IN ('public','hidden')),
  sales_start  timestamptz,
  sales_end    timestamptz,
  sort_order   integer NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS exos_ticket_tiers_event_idx ON public.exos_ticket_tiers (event_id);

CREATE TABLE IF NOT EXISTS public.exos_discount_codes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id        uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  code            text NOT NULL,
  type            text NOT NULL CHECK (type IN ('percentage','fixed')),
  value           numeric NOT NULL CHECK (value >= 0),
  usage_limit     integer,
  used_count      integer NOT NULL DEFAULT 0 CHECK (used_count >= 0),
  expires_at      timestamptz,
  unlocks_tier_ids uuid[],
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (event_id, code)
);

-- ===========================================================================
-- 5. Canonical xref: link an Exos event to the universal aq_short_event_id.
--    By-value reference only (NO FK into aq_event_map — that table is A1-owned;
--    A1/canonical drift triggers handle propagation INTO aq_event_map later).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.bridge_event_xref (
  exos_event_id     uuid PRIMARY KEY REFERENCES public.exos_events (id) ON DELETE CASCADE,
  aq_short_event_id text,            -- → public.aq_event_map.aq_short_event_id (by value)
  tevo_event_id     bigint,          -- → public.events.id when matched
  sg_event_id       bigint,
  match_method      text,            -- 'manual' | 'venue_date' | 'matcher_v3' | ...
  matched_at        timestamptz,
  meta              jsonb,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bridge_event_xref_aq_idx   ON public.bridge_event_xref (aq_short_event_id);
CREATE INDEX IF NOT EXISTS bridge_event_xref_tevo_idx ON public.bridge_event_xref (tevo_event_id);

-- ===========================================================================
-- 6. updated_at triggers
-- ===========================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'exos_profiles','exos_orgs','exos_org_secrets','exos_org_memberships',
    'exos_org_invites','exos_events','exos_ticket_tiers','exos_discount_codes',
    'bridge_event_xref'
  ] LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS %I ON public.%I;', t || '_touch', t);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE UPDATE ON public.%I
         FOR EACH ROW EXECUTE FUNCTION public.exos_touch_updated_at();', t || '_touch', t);
  END LOOP;
END $$;

-- ===========================================================================
-- 7. Row-Level Security (deny-by-default; policies mirror firestore.rules)
-- ===========================================================================
ALTER TABLE public.exos_profiles         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_orgs             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_org_secrets      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_org_memberships  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_org_invites      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_events           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_ticket_tiers     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exos_discount_codes   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.bridge_event_xref     ENABLE ROW LEVEL SECURITY;

-- profiles: anyone signed-in can read display profiles; you write only your own.
CREATE POLICY exos_profiles_sel ON public.exos_profiles FOR SELECT TO authenticated USING (true);
CREATE POLICY exos_profiles_ins ON public.exos_profiles FOR INSERT TO authenticated WITH CHECK (id = auth.uid());
CREATE POLICY exos_profiles_upd ON public.exos_profiles FOR UPDATE TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());

-- orgs: authenticated reads org rows; ANON reads only exos_public_orgs (§7b)
-- so owner_uid is never exposed publicly. Owner manages.
-- NO direct INSERT policy (audit 2026-05-20): org creation goes ONLY through
-- exos_create_org() (§9), which atomically creates the org + owner membership.
-- A direct client INSERT would yield an org with no membership — an orphan the
-- creator couldn't even edit (exos_orgs_upd needs an owner role). So we forbid it.
CREATE POLICY exos_orgs_sel_public ON public.exos_orgs FOR SELECT TO authenticated USING (true);
CREATE POLICY exos_orgs_upd ON public.exos_orgs FOR UPDATE TO authenticated
  USING (exos_has_org_role(id, ARRAY['owner'])) WITH CHECK (exos_has_org_role(id, ARRAY['owner']));

-- org secrets: owner + finance read; owner writes. NEVER anon.
CREATE POLICY exos_org_secrets_sel ON public.exos_org_secrets FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','finance']));
CREATE POLICY exos_org_secrets_ins ON public.exos_org_secrets FOR INSERT TO authenticated
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner']));
CREATE POLICY exos_org_secrets_upd ON public.exos_org_secrets FOR UPDATE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner'])) WITH CHECK (exos_has_org_role(org_id, ARRAY['owner']));

-- memberships: you read your own rows; owners/managers read+manage the org's.
CREATE POLICY exos_memberships_sel ON public.exos_org_memberships FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR exos_has_org_role(org_id, ARRAY['owner','manager']));
CREATE POLICY exos_memberships_ins ON public.exos_org_memberships FOR INSERT TO authenticated
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner']));
CREATE POLICY exos_memberships_upd ON public.exos_org_memberships FOR UPDATE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner'])) WITH CHECK (exos_has_org_role(org_id, ARRAY['owner']));
CREATE POLICY exos_memberships_del ON public.exos_org_memberships FOR DELETE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner']));

-- invites: the invitee (email match) or org owner can read; owner manages.
CREATE POLICY exos_invites_sel ON public.exos_org_invites FOR SELECT TO authenticated
  USING (lower(email) = lower(coalesce(auth.jwt() ->> 'email','')) OR exos_has_org_role(org_id, ARRAY['owner']));
CREATE POLICY exos_invites_ins ON public.exos_org_invites FOR INSERT TO authenticated
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner']));
-- Owner manages invites. Invitee CLAIM (status->completed + membership insert)
-- goes through the SECURITY DEFINER exos_claim_invite() RPC (§9) — not a direct
-- invitee UPDATE (which RLS can't column-restrict safely).
CREATE POLICY exos_invites_upd ON public.exos_org_invites FOR UPDATE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner']))
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner']));

-- events: an org reads/writes ONLY its own events on the base table
-- (operator directive 2026-05-21: "read/write only events it creates, not
-- everything"). Cross-org browsing of OTHER orgs' PUBLISHED events goes
-- through the column-narrowed exos_public_events VIEW (§7b — granted to
-- anon+authenticated) which omits internal columns (created_by/automatiq/
-- sync/distribution). We deliberately do NOT grant a base-table "read any
-- published row" policy: that leaked every org's internal columns to any
-- logged-in user. Base-table SELECT is own-org (staff) only; the buyer/
-- browse surface is the view. App clients MUST read others' events via
-- exos_public_events, never the base table.
CREATE POLICY exos_events_sel_staff ON public.exos_events FOR SELECT TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager','finance','scanner','content']));
CREATE POLICY exos_events_ins ON public.exos_events FOR INSERT TO authenticated
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner','manager']));
-- Phase 1: owner/manager write events. 'content' role is read-only until
-- column-gated content editing lands (RLS can't restrict WHICH columns change;
-- needs a trigger/RPC). Flagged for phase-2 RLS refinement + B1 review.
CREATE POLICY exos_events_upd ON public.exos_events FOR UPDATE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner','manager']))
  WITH CHECK (exos_has_org_role(org_id, ARRAY['owner','manager']));
CREATE POLICY exos_events_del ON public.exos_events FOR DELETE TO authenticated
  USING (exos_has_org_role(org_id, ARRAY['owner']));

-- tiers: own-org base-table reads only (same scoping as events). Cross-org
-- tier browse for PUBLISHED events goes through exos_public_tiers (§7b,
-- excludes HIDDEN tiers). No base-table "read any published tier" policy —
-- it had the same cross-org leak as exos_events_sel_public (now removed).
CREATE POLICY exos_tiers_sel_staff ON public.exos_ticket_tiers FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager','finance','scanner','content'])));
CREATE POLICY exos_tiers_wr ON public.exos_ticket_tiers FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])));

-- discount codes: NOT publicly readable (codes are secret); org staff only.
CREATE POLICY exos_discounts_all ON public.exos_discount_codes FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager','finance'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])));

-- bridge xref: org staff of the linked event read/write (service_role bypasses).
CREATE POLICY exos_xref_all ON public.bridge_event_xref FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = exos_event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])))
  WITH CHECK (EXISTS (SELECT 1 FROM public.exos_events e WHERE e.id = exos_event_id
                 AND exos_has_org_role(e.org_id, ARRAY['owner','manager'])));

-- ===========================================================================
-- 7b. Public projections — anon-facing VIEWS (column-narrowed, row-filtered).
--     Owner-run (NOT security_invoker) so they bypass table RLS and act as the
--     curated public surface: anon has NO grant on the base tables and can read
--     ONLY these views. The WHERE clause is the row gate (published / public
--     tier); the column list is the column gate. Same pattern as D1's *_public
--     RPCs. (Supabase advisor flags owner-run views as "security definer" — that
--     is intentional here: the view IS the boundary. Flagged for B1.)
-- ===========================================================================
CREATE OR REPLACE VIEW public.exos_public_orgs AS
  SELECT id, name, slug, theme
  FROM public.exos_orgs;

CREATE OR REPLACE VIEW public.exos_public_events AS
  SELECT id, org_id, name, slug, description, occurs_at_local, starts_at, doors_at,
         ends_at, timezone, currency, venue_name, venue_location, venue_address,
         primary_performer_name, performer_names, event_type, category, genres,
         subgenres, image_url, branding, purchase_limits, total_tickets, tickets_sold
  FROM public.exos_events
  WHERE status = 'published';

CREATE OR REPLACE VIEW public.exos_public_tiers AS
  SELECT t.id, t.event_id, t.name, t.description, t.price, t.capacity, t.sold,
         t.ticket_type, t.sales_start, t.sales_end, t.sort_order
  FROM public.exos_ticket_tiers t
  JOIN public.exos_events e ON e.id = t.event_id
  WHERE t.visibility = 'public' AND e.status = 'published';

-- ===========================================================================
-- 8. Grants (RLS still gates row visibility; grants enable the API roles)
-- ===========================================================================
-- ⚠ B1 dirty-dozen finding (bot_chat #381): Supabase's platform DEFAULT
-- PRIVILEGES auto-GRANT every new public table to anon + authenticated. The §7b
-- narrowing scoped the read POLICIES to authenticated, but the base-table GRANTS
-- to anon were never removed. RLS still denies anon (no anon-applicable policy +
-- RLS enabled on all 9), but the privilege shouldn't exist at all — relying on
-- RLS-deny alone is fragile (one stray TO-public policy or an RLS toggle = leak).
-- REVOKE everything from anon (zero base-table access) AND from authenticated
-- (clears the broad TRUNCATE/REFERENCES/TRIGGER defaults — B1 SEC-LOW), then
-- re-GRANT only the CRUD authenticated needs. Anon's storefront reads go through
-- the §7b public views (owner-run — unaffected by this REVOKE).
REVOKE ALL ON
  public.exos_profiles, public.exos_orgs, public.exos_org_secrets,
  public.exos_org_memberships, public.exos_org_invites, public.exos_events,
  public.exos_ticket_tiers, public.exos_discount_codes, public.bridge_event_xref
FROM anon, authenticated;

-- The §7b VIEWS inherit the SAME platform-default GRANT ALL → anon/authenticated.
-- Because they are single-table, auto-updatable, OWNER-RUN views, an unrevoked
-- INSERT/UPDATE/DELETE lets a client mutate the base tables THROUGH the view,
-- bypassing RLS entirely (verified exploitable on a preview branch 2026-05-21:
-- anon UPDATE'd exos_orgs + DELETE'd a published event via these views). Lock the
-- views to SELECT-only too — same root cause as the base-table REVOKE above (#381),
-- new surface. exos_public_tiers has a JOIN (non-updatable) but is revoked for parity.
REVOKE ALL ON public.exos_public_orgs, public.exos_public_events, public.exos_public_tiers FROM anon, authenticated;
-- Anon touches NO base table — only the curated public views, SELECT only.
GRANT SELECT ON public.exos_public_orgs, public.exos_public_events, public.exos_public_tiers TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON
  public.exos_profiles, public.exos_orgs, public.exos_org_secrets,
  public.exos_org_memberships, public.exos_org_invites, public.exos_events,
  public.exos_ticket_tiers, public.exos_discount_codes, public.bridge_event_xref
TO authenticated;

-- ===========================================================================
-- 9. Bootstrap / claim RPCs (SECURITY DEFINER — RLS cannot express these).
--    Granted to `authenticated`; each enforces auth.uid() ownership internally.
--    ⚠ B1: these are the ONLY write paths that bypass the table policies, by
--    necessity (the first owner-membership can't satisfy the membership policy,
--    and an invitee isn't a member yet). Review alongside the RLS.
-- ===========================================================================

-- Create an org + bootstrap the caller as its owner, atomically. Slug
-- uniqueness is enforced by the UNIQUE constraint on exos_orgs.slug.
CREATE OR REPLACE FUNCTION public.exos_create_org(p_name text, p_slug text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_org_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_create_org: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_name IS NULL OR length(btrim(p_name)) = 0 OR length(p_name) > 100 THEN
    RAISE EXCEPTION 'exos_create_org: name must be 1-100 chars';
  END IF;
  IF p_slug !~ '^[a-z0-9][a-z0-9-]{0,79}$' THEN
    RAISE EXCEPTION 'exos_create_org: invalid slug %', p_slug;
  END IF;

  INSERT INTO public.exos_orgs (name, slug, owner_uid)
  VALUES (p_name, p_slug, v_uid)
  RETURNING id INTO v_org_id;

  INSERT INTO public.exos_org_memberships (org_id, user_id, role, added_by)
  VALUES (v_org_id, v_uid, 'owner', v_uid);

  RETURN v_org_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_create_org(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_create_org(text, text) TO authenticated;

-- Accept a pending org invite addressed to the caller's CONFIRMED email.
-- Inserts the membership + marks the invite completed.
CREATE OR REPLACE FUNCTION public.exos_claim_invite(p_token uuid)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_inv   public.exos_org_invites%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_claim_invite: not authenticated' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_inv FROM public.exos_org_invites WHERE token = p_token;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'exos_claim_invite: invite not found';
  END IF;
  IF v_inv.status <> 'pending' THEN
    RAISE EXCEPTION 'exos_claim_invite: invite is %', v_inv.status;
  END IF;
  IF v_inv.expires_at IS NOT NULL AND v_inv.expires_at < now() THEN
    UPDATE public.exos_org_invites SET status = 'expired' WHERE token = p_token;
    RAISE EXCEPTION 'exos_claim_invite: invite expired';
  END IF;
  IF v_email = '' OR lower(v_inv.email) <> v_email THEN
    RAISE EXCEPTION 'exos_claim_invite: invite email does not match caller';
  END IF;
  -- Email-verified gate (the analogue of the old Firestore email_verified rule).
  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.email_confirmed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'exos_claim_invite: email not verified';
  END IF;

  INSERT INTO public.exos_org_memberships (org_id, user_id, role, added_by)
  VALUES (v_inv.org_id, v_uid, v_inv.role, v_uid)
  ON CONFLICT (org_id, user_id) DO UPDATE SET role = EXCLUDED.role, disabled = false;

  UPDATE public.exos_org_invites
  SET status = 'completed', claimed_by = v_uid, claimed_at = now()
  WHERE token = p_token;

  RETURN v_inv.org_id;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_claim_invite(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_claim_invite(uuid) TO authenticated;
