-- ============================================================================
-- Migration 20260703040000 — open-notebook: enable RLS lockdown on onb_* tables
--
-- Lane:     operator-directed (open-notebook subsystem hardening)
-- Touches:  onb_notebooks, onb_sources, onb_source_embeddings, onb_source_insights,
--           onb_notes, onb_notebook_sources, onb_notebook_notes, onb_transformations,
--           onb_chat_sessions, onb_chat_messages, onb_episode_profiles,
--           onb_speaker_profiles, onb_episodes, onb_jobs (W: ENABLE ROW LEVEL SECURITY)
-- Pre-reqs: 20260703030000 (onb_* tables)
--
-- WHY: the onb_* tables shipped in mig 20260703030000 without RLS. A public-schema
--   table without RLS is reachable through the Supabase REST API by the anon /
--   authenticated roles, which would bypass the FastAPI auth gate the subsystem
--   relies on. The service-role client the app uses has BYPASSRLS, so enabling RLS
--   with NO policies denies anon/authenticated while the app is unaffected. Plain
--   ENABLE (not FORCE) so the table owner / dashboard admin retains access.
--
-- Applied via MCP at 2026-07-03 (idempotent + additive); this file is the
-- codification. Re-apply against current prod state is a no-op.
-- ============================================================================

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'onb_notebooks','onb_sources','onb_source_embeddings','onb_source_insights',
    'onb_notes','onb_notebook_sources','onb_notebook_notes','onb_transformations',
    'onb_chat_sessions','onb_chat_messages','onb_episode_profiles',
    'onb_speaker_profiles','onb_episodes','onb_jobs'
  ] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
  END LOOP;
END $$;
