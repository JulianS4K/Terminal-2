-- ============================================================================
-- Migration 20260520140000 — Exos (Bridge / D4) phase-3: org follow graph
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_orgs (W: +description, +followers_count), exos_org_follows (W, new),
--           exos_public_orgs (view: +description, +followers_count)
-- Pre-reqs: 20260520120000 (phase-1: exos_orgs + exos_public_orgs view).
--
-- Backs OrganizerProfile (the followable org page). Maps "organizer" to an ORG
-- (org-centric model — events belong to orgs, not users), reusing exos_orgs +
-- the listPublicEventsForOrg seam. Only the follow LAYER is new:
--   * exos_orgs.description (public bio) + followers_count (denormalized counter)
--   * exos_org_follows(follower_uid, org_id) — the follow graph. A user reads
--     ONLY their own follow rows (privacy: follower lists are NOT public).
--   * exos_follow_org / exos_unfollow_org SECDEF RPCs — idempotent follow/unfollow
--     that maintain followers_count atomically. No direct client INSERT/DELETE,
--     so the denormalized counter can't drift.
--   * exos_public_orgs view gains description + followers_count (anon-readable).
--
-- ⚠ B1 review requested on the new follow-table RLS + counter RPCs before prod
-- apply. D4 authors; validate on a Supabase preview branch; A1 applies to prod.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. exos_orgs: public bio + denormalized follower counter
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS description text;
ALTER TABLE public.exos_orgs ADD COLUMN IF NOT EXISTS followers_count integer NOT NULL DEFAULT 0 CHECK (followers_count >= 0);

-- ---------------------------------------------------------------------------
-- 2. Follow graph. One row per (follower, org). PK makes follow idempotent.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_org_follows (
  follower_uid uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  org_id       uuid NOT NULL REFERENCES public.exos_orgs (id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_uid, org_id)
);
CREATE INDEX IF NOT EXISTS exos_org_follows_org_idx ON public.exos_org_follows (org_id);

ALTER TABLE public.exos_org_follows ENABLE ROW LEVEL SECURITY;

-- A user reads ONLY their own follow rows (to render isFollowing). Follower
-- lists are deliberately not public. No direct INSERT/DELETE policy — writes go
-- through the §4 RPCs so followers_count can never be desynced by a raw mutation.
CREATE POLICY exos_org_follows_sel ON public.exos_org_follows FOR SELECT TO authenticated
  USING (follower_uid = auth.uid());

-- Platform-default grants: REVOKE everything (incl. the auto-GRANT-ALL to anon),
-- then re-GRANT only SELECT to authenticated. (Same lesson as the phase-1 §8
-- base-table + view REVOKE.)
REVOKE ALL ON public.exos_org_follows FROM anon, authenticated;
GRANT SELECT ON public.exos_org_follows TO authenticated;

-- ---------------------------------------------------------------------------
-- 3. Public org projection gains the bio + follower count (anon-readable).
--    Owner-run view (the boundary). CREATE OR REPLACE preserves grants, but we
--    re-assert SELECT-only defensively per the §8 owner-run-view landmine
--    (auto-updatable views inherit GRANT ALL → anon if left unrevoked).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.exos_public_orgs AS
  SELECT id, name, slug, theme, description, followers_count
  FROM public.exos_orgs;
REVOKE ALL ON public.exos_public_orgs FROM anon, authenticated;
GRANT SELECT ON public.exos_public_orgs TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Follow / unfollow RPCs (SECURITY DEFINER). Idempotent; maintain the
--    counter only when a row actually lands/leaves (double-follow is a no-op,
--    never double-counts; unfollow when not following never under-counts).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_follow_org(p_org_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_rows int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_follow_org: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.exos_orgs WHERE id = p_org_id) THEN
    RAISE EXCEPTION 'exos_follow_org: org not found';
  END IF;
  INSERT INTO public.exos_org_follows (follower_uid, org_id)
  VALUES (v_uid, p_org_id)
  ON CONFLICT (follower_uid, org_id) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows > 0 THEN
    UPDATE public.exos_orgs SET followers_count = followers_count + 1 WHERE id = p_org_id;
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_follow_org(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_follow_org(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.exos_unfollow_org(p_org_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_rows int;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_unfollow_org: not authenticated' USING ERRCODE = '42501';
  END IF;
  DELETE FROM public.exos_org_follows WHERE follower_uid = v_uid AND org_id = p_org_id;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows > 0 THEN
    UPDATE public.exos_orgs SET followers_count = GREATEST(0, followers_count - 1) WHERE id = p_org_id;
  END IF;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_unfollow_org(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_unfollow_org(uuid) TO authenticated;
