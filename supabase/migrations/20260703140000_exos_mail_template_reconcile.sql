-- ============================================================================
-- Migration 20260703140000 — Exos (Bridge / D4): reconcile exos_mail template allowlist
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_mail (constraint: exos_mail_template_check → complete union)
-- Pre-reqs: 20260520160000 (exos_mail), 20260523200000 ('event-announce'),
--            20260523210000 ('ticket-issued'), 20260703121000 ('event-announcement'),
--            20260703124000 ('event-rescheduled').
--
-- DRIFT FIX (repo↔prod parity). The template allowlist grew additively through
-- 0523200000 ('event-announce', used by exos_announce_to_followers) and
-- 0523210000 ('ticket-issued', used by exos_queue_ticket_issued /
-- exos_issue_ticket_to_email). But 20260703121000 (announcements) and
-- 20260703124000 (reschedule) each rebuilt the CHECK from "base + their own new
-- value", unaware of those two — so as committed they DROP both 'event-announce'
-- and 'ticket-issued', which would reject two live mail paths.
--
-- When those two migrations were applied to prod (2026-07-03) they were applied
-- with the UNION instead, preserving both live templates. This migration codifies
-- that union so a from-zero build (CI) ends at the same allowlist prod already
-- has. Idempotent: DROP IF EXISTS + re-ADD the full set.
--
-- Complete set = base 5 + 'event-announce' + 'ticket-issued' (0523 additions)
--              + 'event-announcement' (0703121000) + 'event-rescheduled' (0703124000).
--
-- D4 authors; A1/operator applies. Already live on prod (hzrizjeaxlqcxfrtczpq)
-- via the reconciled 0703121000/0703124000 applies — this only aligns the repo.
-- ============================================================================

ALTER TABLE public.exos_mail DROP CONSTRAINT IF EXISTS exos_mail_template_check;
ALTER TABLE public.exos_mail ADD CONSTRAINT exos_mail_template_check CHECK (template IN (
  'transfer-initiated','transfer-claimed','org-invite',
  'event-cancelled','event-updated',
  'event-announce','ticket-issued',
  'event-announcement','event-rescheduled'));
