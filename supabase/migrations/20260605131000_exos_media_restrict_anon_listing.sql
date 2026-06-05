-- 20260526060000_exos_media_restrict_anon_listing.sql
--
-- Close anon enumeration of the exos-media bucket (bot_chat #539 SEC-MED;
-- Supabase advisor `public_bucket_allows_listing`). The bucket is public AND
-- its SELECT policy applied to ALL roles, so an anon caller could LIST every
-- object (enumerate org logos / event images / draft uploads).
--
-- Public-by-URL rendering is UNAFFECTED: public=true serves the
-- /storage/v1/object/public/... endpoint without consulting RLS, and
-- d4_bridge/src/lib/storage.ts renders only via getPublicUrl() (it never calls
-- .list() or createSignedUrl() for cross-user objects). So scoping the SELECT
-- policy to the object owner removes the anon LIST capability with no UX loss.
--
-- D4 authors; A1/operator applies (storage.* DDL is prod-gated). Keep public=true.
-- ─────────────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS exos_media_read ON storage.objects;

CREATE POLICY exos_media_read ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'exos-media' AND owner = auth.uid());

-- ROLLBACK (restores the prior world-readable policy):
--   DROP POLICY exos_media_read ON storage.objects;
--   CREATE POLICY exos_media_read ON storage.objects
--     FOR SELECT USING (bucket_id = 'exos-media');
