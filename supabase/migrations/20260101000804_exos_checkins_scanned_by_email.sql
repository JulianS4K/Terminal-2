-- 20260526070000_exos_checkins_scanned_by_email.sql
--
-- B1-NEXT-62: durable door audit. exos_event_checkins.scanned_by is a uuid that
-- points at the scanning staff account; if that account is later removed the
-- audit trail loses the "who". Add a denormalized scanned_by_email captured at
-- scan time (populated by exos_check_in_ticket as of mig 20260526080000).
-- Nullable; existing rows stay NULL (no backfill — historical scans predate it).
--
-- D4 authors; A1 applies.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.exos_event_checkins
  ADD COLUMN IF NOT EXISTS scanned_by_email text;

-- ROLLBACK: ALTER TABLE public.exos_event_checkins DROP COLUMN IF EXISTS scanned_by_email;
