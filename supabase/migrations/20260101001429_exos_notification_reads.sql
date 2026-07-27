-- ============================================================================
-- Migration 20260709120000 — Exos (Bridge / D4): notification read-state
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_notification_reads (W, new), exos_mark_notifications_read (fn, new)
-- Pre-reqs: 20260520140000 (exos org follow graph — establishes the exos_*
--           SECDEF/RLS/grant conventions this migration mirrors).
--
-- Backs the /alerts feed (views/Notifications.tsx + lib/notifications.ts). The
-- feed is DERIVED from transfer signals, so a notification has no server row —
-- only its read-state needs persisting. One row per (user, synthetic notif id
-- like "in-<transferId>"); mark-read is idempotent. Read-state is private: a
-- user sees ONLY their own rows. No direct client INSERT — writes go through
-- the SECDEF RPC so uid can't be spoofed.
--
-- ⚠ D4 authors; validate on a Supabase preview branch; apply to prod is the
-- gated Applier step (CLAUDE.md Rule 1). Not yet applied to prod.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Read-state table. PK makes mark-read idempotent (double-mark is a no-op).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exos_notification_reads (
  uid       uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  notif_id  text NOT NULL,
  read_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (uid, notif_id)
);

ALTER TABLE public.exos_notification_reads ENABLE ROW LEVEL SECURITY;

-- A user reads ONLY their own read-state (to grey-out already-seen alerts).
-- No INSERT/DELETE policy — writes go through exos_mark_notifications_read so
-- uid always == auth.uid().
CREATE POLICY exos_notification_reads_sel ON public.exos_notification_reads
  FOR SELECT TO authenticated
  USING (uid = auth.uid());

-- Platform-default grants: REVOKE everything (incl. the auto-GRANT to anon),
-- then re-GRANT only SELECT to authenticated (same lesson as exos_org_follows).
REVOKE ALL ON public.exos_notification_reads FROM anon, authenticated;
GRANT SELECT ON public.exos_notification_reads TO authenticated;

-- ---------------------------------------------------------------------------
-- 2. Mark-read RPC (SECURITY DEFINER). Upserts read rows for the caller.
--    Idempotent: re-marking an already-read id is a no-op.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.exos_mark_notifications_read(p_ids text[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'exos_mark_notifications_read: not authenticated' USING ERRCODE = '42501';
  END IF;
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
    RETURN;
  END IF;
  INSERT INTO public.exos_notification_reads (uid, notif_id)
  SELECT v_uid, unnest(p_ids)
  ON CONFLICT (uid, notif_id) DO NOTHING;
END $$;
REVOKE EXECUTE ON FUNCTION public.exos_mark_notifications_read(text[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.exos_mark_notifications_read(text[]) TO authenticated;
