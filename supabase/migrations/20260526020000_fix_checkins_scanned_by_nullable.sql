-- Migration: fix_checkins_scanned_by_nullable
-- Author: A1
-- Date: 2026-05-26
-- Description: Fix NOT NULL + ON DELETE SET NULL contradiction on
--   exos_event_checkins.scanned_by. The column was declared:
--     scanned_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE SET NULL
--   This is self-contradictory: Postgres cannot SET NULL on a NOT NULL column.
--   Any auth.users deletion that references an existing check-in row fails with
--   a FK constraint violation. Fix: drop NOT NULL so SET NULL can work.
-- Downstream: auth user deletion no longer errors for users who performed scans.
--   Existing check-in rows are unchanged. scanned_by may be NULL going forward
--   only if the scanner user is deleted — scanner identity is preserved for
--   active users.
-- Rollback: ALTER TABLE exos_event_checkins ALTER COLUMN scanned_by SET NOT NULL;
--   (Only safe if no scanner-deleted rows exist)

ALTER TABLE public.exos_event_checkins
  ALTER COLUMN scanned_by DROP NOT NULL;
