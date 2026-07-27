-- ============================================================================
-- 20260511000000 — security: revoke LOGIN on coworker_readonly
--
-- Background: migration 20260509460000 created `coworker_readonly` with a
-- placeholder password ('CHANGE_ME_BEFORE_HANDOFF') hardcoded in DDL. If that
-- migration ran in prod and the post-handoff rotation didn't happen, the
-- placeholder is the live password — and anyone with the public repo can read
-- it.
--
-- This migration revokes LOGIN until a human re-issues a real password
-- out-of-band. It is idempotent and safe to run repeatedly.
--
-- Recovery procedure (post-merge, human-driven):
--   1. Pick a strong random value (32+ bytes).
--   2. ALTER ROLE coworker_readonly WITH PASSWORD '<new value>' LOGIN;
--   3. Deliver the new password to the UI coworker out-of-band.
--
-- Filed by: A1 · 2026-05-11 security chat · SEC-CRIT entry in KANBAN.md.
-- ============================================================================

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'coworker_readonly') THEN
    ALTER ROLE coworker_readonly NOLOGIN;
    COMMENT ON ROLE coworker_readonly IS
      'UI coworker role — LOGIN revoked 2026-05-11 pending password rotation. '
      'See migration 20260511000000 + SECURITY BACKLOG in KANBAN.md.';
  END IF;
END $$;
