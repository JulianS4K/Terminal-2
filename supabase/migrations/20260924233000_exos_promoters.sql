-- ============================================================================
-- Migration 20260924233000 — Exos (Bridge / D4): promoters as a real record,
--                            with a private kit and their own sales
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  W: TABLE exos_promoters (new), FUNCTION exos_upsert_promoter,
--              exos_set_promoter_status, exos_promoter_kit, exos_org_promoter_stats (new)
--              exos_public_promoter (new, link-in-bio card)
--           R: exos_orgs, exos_events, exos_tickets, exos_org_memberships
-- Pre-reqs: 20260924223000 (paid tickets carry promoter_id)
--
-- Until now a "promoter" was only the text code in ?promoter= (stamped on
-- exos_tickets.promoter_id). That meant a promoter couldn't see their own
-- sales, and anyone could guess another's kit URL (/promoter/:event/:code).
-- Modeled on hi.events' affiliates (name, code, email, status), but per ORG
-- rather than per event, because NYC promoters work many of one organizer's
-- nights:
--   * exos_promoters: code unique per org (same charset as ?promoter=), plus
--     an unguessable kit_token for the promoter's private page.
--   * exos_promoter_kit(token): the promoter's page data (anon-callable, but
--     only with the token): their name/code, the org, and their tickets sold
--     + gross per published event. Only their own code's sales.
--   * exos_org_promoter_stats(org): the organizer's leaderboard (owner /
--     manager / finance).
-- Sales still attribute by code, so links already shared keep counting once
-- a promoter record with that code exists. A paused promoter's kit is closed;
-- their past sales stay attributed.
--
-- Idempotent. D4 authors; applying to prod is operator-gated.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_promoters (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id     uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  code       text NOT NULL CHECK (code ~ '^[A-Za-z0-9_-]{1,64}$'),
  name       text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 120),
  email      text CHECK (email IS NULL OR (length(email) <= 254 AND email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')),
  status     text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused')),
  kit_token  uuid NOT NULL DEFAULT gen_random_uuid() UNIQUE,
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, code)
);
CREATE INDEX IF NOT EXISTS exos_promoters_org_idx ON public.exos_promoters (org_id);
CREATE INDEX IF NOT EXISTS exos_tickets_promoter_idx ON public.exos_tickets (promoter_id) WHERE promoter_id IS NOT NULL;

ALTER TABLE public.exos_promoters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exos_promoters FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.exos_promoters TO service_role;
-- Org staff read their promoters (kit tokens included: they send the links).
GRANT SELECT ON public.exos_promoters TO authenticated;
DROP POLICY IF EXISTS exos_promoters_staff_read ON public.exos_promoters;
CREATE POLICY exos_promoters_staff_read ON public.exos_promoters
  FOR SELECT TO authenticated
  USING (public.exos_has_org_role(org_id, ARRAY['owner', 'manager', 'finance', 'content']));

-- Create or update a promoter (owner / manager). Returns the row id.
CREATE OR REPLACE FUNCTION public.exos_upsert_promoter(
  p_org_id uuid, p_code text, p_name text, p_email text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_id uuid;
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_upsert_promoter: not allowed' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.exos_promoters AS p (org_id, code, name, email, created_by)
  VALUES (p_org_id, btrim(p_code), btrim(p_name), NULLIF(lower(btrim(coalesce(p_email, ''))), ''), auth.uid())
  ON CONFLICT (org_id, code) DO UPDATE SET
    name = EXCLUDED.name, email = EXCLUDED.email, updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_upsert_promoter(uuid, text, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_upsert_promoter(uuid, text, text, text) TO authenticated, service_role;

-- Pause / reactivate, or rotate the kit link (owner / manager).
CREATE OR REPLACE FUNCTION public.exos_set_promoter_status(
  p_promoter_id uuid, p_status text, p_rotate_token boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_org uuid;
BEGIN
  SELECT org_id INTO v_org FROM public.exos_promoters WHERE id = p_promoter_id;
  IF v_org IS NULL OR NOT public.exos_has_org_role(v_org, ARRAY['owner', 'manager']) THEN
    RAISE EXCEPTION 'exos_set_promoter_status: not allowed' USING ERRCODE = '42501';
  END IF;
  IF p_status NOT IN ('active', 'paused') THEN
    RAISE EXCEPTION 'exos_set_promoter_status: bad status %', p_status;
  END IF;
  UPDATE public.exos_promoters
     SET status = p_status,
         kit_token = CASE WHEN p_rotate_token THEN gen_random_uuid() ELSE kit_token END,
         updated_at = now()
   WHERE id = p_promoter_id;
END $$;
REVOKE ALL ON FUNCTION public.exos_set_promoter_status(uuid, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_set_promoter_status(uuid, text, boolean) TO authenticated, service_role;

-- The promoter's private page. Anyone holding the token (it's the secret in
-- the kit link) gets that promoter's own numbers; a wrong or paused token
-- gets nothing.
CREATE OR REPLACE FUNCTION public.exos_promoter_kit(p_token uuid)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'promoter', jsonb_build_object('name', p.name, 'code', p.code),
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug),
    'events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'event_id', e.id, 'name', e.name, 'starts_at', e.starts_at,
               'tickets', COALESCE(s.tickets, 0), 'gross', COALESCE(s.gross, 0), 'currency', e.currency)
             ORDER BY e.starts_at NULLS LAST)
      FROM public.exos_events e
      LEFT JOIN LATERAL (
        SELECT count(*) AS tickets, sum(t.price_paid) AS gross
        FROM public.exos_tickets t
        WHERE t.event_id = e.id AND t.promoter_id = p.code
          AND t.status IN ('active', 'used', 'transferred')
      ) s ON true
      WHERE e.org_id = p.org_id AND e.status = 'published'
        AND (e.starts_at IS NULL OR e.starts_at > now() - interval '30 days')
    ), '[]'::jsonb)
  )
  FROM public.exos_promoters p
  JOIN public.exos_orgs o ON o.id = p.org_id
  WHERE p.kit_token = p_token AND p.status = 'active';
$$;
REVOKE ALL ON FUNCTION public.exos_promoter_kit(uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_promoter_kit(uuid) TO anon, authenticated, service_role;

-- Organizer leaderboard: every registered promoter's tickets + gross, all
-- time or for one event.
CREATE OR REPLACE FUNCTION public.exos_org_promoter_stats(p_org_id uuid, p_event_id uuid DEFAULT NULL)
RETURNS TABLE (promoter_id uuid, code text, name text, status text, tickets bigint, gross numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.exos_has_org_role(p_org_id, ARRAY['owner', 'manager', 'finance']) THEN
    RAISE EXCEPTION 'exos_org_promoter_stats: not allowed' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY
    SELECT p.id, p.code, p.name, p.status,
           count(t.id) AS tickets, COALESCE(sum(t.price_paid), 0) AS gross
    FROM public.exos_promoters p
    LEFT JOIN public.exos_events e ON e.org_id = p.org_id AND (p_event_id IS NULL OR e.id = p_event_id)
    LEFT JOIN public.exos_tickets t ON t.event_id = e.id AND t.promoter_id = p.code
         AND t.status IN ('active', 'used', 'transferred')
    WHERE p.org_id = p_org_id
    GROUP BY p.id, p.code, p.name, p.status
    ORDER BY tickets DESC, p.name;
END $$;
REVOKE ALL ON FUNCTION public.exos_org_promoter_stats(uuid, uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_org_promoter_stats(uuid, uuid) TO authenticated, service_role;

-- Public card for a promoter's link-in-bio page (/l/:orgSlug/:code): just the
-- display name, and only while active. Codes already travel in public links,
-- so this reveals nothing beyond the name the promoter chose to go by.
CREATE OR REPLACE FUNCTION public.exos_public_promoter(p_org_slug text, p_code text)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT jsonb_build_object(
    'promoter', jsonb_build_object('name', p.name, 'code', p.code),
    'org', jsonb_build_object('id', o.id, 'name', o.name, 'slug', o.slug))
  FROM public.exos_promoters p
  JOIN public.exos_orgs o ON o.id = p.org_id
  WHERE o.slug = p_org_slug AND p.code = p_code AND p.status = 'active';
$$;
REVOKE ALL ON FUNCTION public.exos_public_promoter(text, text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.exos_public_promoter(text, text) TO anon, authenticated, service_role;
