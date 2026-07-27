-- ============================================================================
-- Migration 20260520150000 — Exos (Bridge / D4) phase-4: media storage bucket
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  storage.buckets (W: exos-media), storage.objects (RLS policies)
-- Pre-reqs: 20260520120000 (phase-1: exos_org_memberships for the org-logo gate).
--
-- Replaces Firebase Storage (the last Firebase subsystem). One PUBLIC bucket
-- `exos-media` holds event images + org logos under stable path prefixes:
--   * event-images/{uid}/{uuid}.{ext}     — uploaded by the event creator
--   * org-logos/{orgId}/logo-{epoch}.{ext} — uploaded by org staff
-- Public bucket → getPublicUrl yields a stable CDN URL (the analogue of
-- Firebase getDownloadURL) that gets stored on the exos_events / exos_orgs row.
--
-- RLS on storage.objects (mirrors the old storage.rules intent):
--   * read  — public (bucket is public; explicit SELECT policy lets the client
--             list/inspect object rows too).
--   * upload — authenticated, scoped: event-images only under your OWN uid
--             folder; org-logos only under a folder for an org you're a member
--             of. Bucket-level file_size_limit (5 MB) + allowed_mime_types
--             enforce the size/type caps the Firebase rules used to.
--   * update/delete — the object OWNER only (storage sets owner = uploader).
--
-- ⚠ B1: new storage RLS surface. D4 authors; validate on a preview branch;
-- A1 applies to prod. (Creating policies on storage.objects requires the
-- migration role's privilege on the storage schema — standard Supabase path.)
-- ============================================================================

-- 1. The bucket (idempotent). 5 MB cap; image mime-types only.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'exos-media', 'exos-media', true, 5242880,
  ARRAY['image/png','image/jpeg','image/webp','image/gif']
  -- image/svg+xml excluded: SVG carries executable script; on a public bucket
  -- a direct object URL executes in the storage origin (hosted XSS). B1 SEC-MED
  -- (bot_chat #438). Drop if vector-art org logos are needed in future.
)
ON CONFLICT (id) DO UPDATE
  SET public = EXCLUDED.public,
      file_size_limit = EXCLUDED.file_size_limit,
      allowed_mime_types = EXCLUDED.allowed_mime_types;

-- 2. Public read (bucket is public; the policy lets metadata/list calls work).
DROP POLICY IF EXISTS exos_media_read ON storage.objects;
CREATE POLICY exos_media_read ON storage.objects FOR SELECT
  USING (bucket_id = 'exos-media');

-- 3. Upload — authenticated, path-scoped. event-images under own uid folder;
--    org-logos under an org the caller belongs to. (org_id::text avoids a
--    text→uuid cast that could throw on a malformed path.)
DROP POLICY IF EXISTS exos_media_insert ON storage.objects;
CREATE POLICY exos_media_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'exos-media' AND (
      ( (storage.foldername(name))[1] = 'event-images'
        AND (storage.foldername(name))[2] = auth.uid()::text )
      OR
      ( (storage.foldername(name))[1] = 'org-logos'
        AND EXISTS (
          SELECT 1 FROM public.exos_org_memberships m
          WHERE m.user_id = auth.uid()
            AND m.disabled IS NOT TRUE
            AND m.org_id::text = (storage.foldername(name))[2]
        ) )
    )
  );

-- 4. Update / delete — object owner only (storage sets owner = uploader uid).
DROP POLICY IF EXISTS exos_media_update ON storage.objects;
CREATE POLICY exos_media_update ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'exos-media' AND owner = auth.uid())
  WITH CHECK (bucket_id = 'exos-media' AND owner = auth.uid());

DROP POLICY IF EXISTS exos_media_delete ON storage.objects;
CREATE POLICY exos_media_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'exos-media' AND owner = auth.uid());
