-- 20260508110000_storage_chat_bucket.sql
-- Code-owned (auditor + storage layout for the 3-agent era).
--
-- Per user direction (2026-05-08):
--   "for supabase storage itself let all have access to it, as it's read only
--    mostly. create a chat folder that houses all chat files in event other
--    chats need to be created"
--
-- Decisions baked in:
--   1. DB writes are locked to code only (per the prod-write rule shipped with
--      the 3-agent split). Storage is treated separately — open to all 3
--      agents — because content there is mostly low-stakes static assets
--      (avatars, attachments) vs the data pipeline.
--   2. Bucket-per-feature pattern. The `chat` bucket holds everything
--      chatbot-related across variants.
--   3. Subfolder convention inside `chat`:
--        default/        retail Find Tickets chatbot (existing)
--        broker/         broker-side admin chat (future, terminal-embedded)
--        support/        customer support chat (future)
--        sales/          outbound sales chat (future)
--        _shared/        cross-variant assets (logos, default avatars)
--      Convention enforced via AGENTS.md + code's audit pass; Supabase
--      doesn't constrain folder structure at the bucket level.
--   4. public=true so chatbot UIs can render assets without an auth handshake.
--      Default Supabase RLS plus the implicit service_role bypass cover the
--      rest: all 3 agents access via service-role and can read/write freely.
--
-- Note on RLS: a richer policy set (anon read, authenticated write,
-- service_role all) was attempted but rejected because the migration role
-- is not the owner of `storage.objects`. The combination of public=true on
-- the bucket + service_role bypass is functionally equivalent for current
-- needs. If we later need finer-grained policies, do them via the Supabase
-- dashboard or a service-role-elevated migration.

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'chat', 'chat', true,
  5242880,  -- 5 MB per file (screenshots / short voice clips)
  ARRAY['image/png','image/jpeg','image/gif','image/webp','image/svg+xml',
        'audio/mpeg','audio/webm','audio/ogg',
        'application/pdf','text/plain']
) ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;
