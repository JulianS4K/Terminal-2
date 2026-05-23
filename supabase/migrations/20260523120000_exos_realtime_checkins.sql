-- ============================================================================
-- Migration 20260523120000 — Exos (Bridge / D4): Realtime on exos_event_checkins
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  publication supabase_realtime (ADD TABLE exos_event_checkins)
-- Pre-reqs: 20260520130000 (exos_event_checkins + its RLS exos_checkins_sel)
--
-- D4-OPS-10 — multi-lane offline double-admit. The door scanner
-- (OrganizerCheckIn) now subscribes to INSERTs on exos_event_checkins for the
-- event it is checking in (lib/checkinChannel.ts, supabase-js postgres_changes).
-- Whenever ANY lane checks a ticket in — online, or via a reconnect replay of an
-- offline admit — the audit row insert is pushed to every other connected lane
-- within ~seconds, which marks the ticket used in their local registry so a
-- near-simultaneous scan elsewhere is refused.
--
-- For postgres_changes to fire, the table must be in the supabase_realtime
-- publication. RLS already gates SELECT to org staff (exos_checkins_sel), and
-- Realtime enforces that SAME RLS against each subscriber's JWT — so only org
-- staff receive the stream; a random authenticated user gets nothing. This is
-- why we use postgres_changes (authoritative + RLS-gated) rather than a raw
-- broadcast channel (which any authed client could spoof to deny entry).
--
-- We only subscribe to INSERT, so the default REPLICA IDENTITY (primary key) is
-- sufficient — INSERT always carries the full new row. Idempotent.
--
-- D4 authors; A1 applies to prod.
-- ============================================================================

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename  = 'exos_event_checkins'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.exos_event_checkins;
  END IF;
END $$;
