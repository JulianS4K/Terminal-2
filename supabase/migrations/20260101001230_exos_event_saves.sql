-- ============================================================================
-- Migration 20260703120000 — Exos (Bridge / D4): buyer saved-events (wishlist)
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_event_saves (W, new)
-- Pre-reqs: 20260520120000 (exos_events), Supabase Auth (auth.users).
--
-- Buyer-side wishlist. A signed-in attendee saves an event to revisit later; the
-- Bridge "My Tickets → Saved" section reads them back and the event page renders
-- the heart in its saved state. One row per (user, event) — the PK makes save
-- idempotent (double-save is a no-op).
--
-- Unlike the org follow-graph (mig 20260520140000) there is NO denormalized
-- counter to protect, so writes go through plain RLS-gated INSERT/DELETE
-- (user_id = auth.uid()) rather than SECDEF RPCs — simpler, and a raw mutation
-- can't desync anything. Reads are self-only: a user sees ONLY their own saves,
-- never anyone else's (a wishlist is private).
--
-- D4 authors; A1 applies.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.exos_event_saves (
  user_id    uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
  event_id   uuid NOT NULL REFERENCES public.exos_events (id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, event_id)
);

-- "My saves, newest first" is the only read pattern (the My Tickets section).
CREATE INDEX IF NOT EXISTS exos_event_saves_user_idx
  ON public.exos_event_saves (user_id, created_at DESC);

ALTER TABLE public.exos_event_saves ENABLE ROW LEVEL SECURITY;

-- A user reads / writes ONLY their own save rows. Save lists are private (never
-- surfaced as social proof), so there is deliberately no cross-user SELECT.
CREATE POLICY exos_event_saves_sel ON public.exos_event_saves FOR SELECT TO authenticated
  USING (user_id = auth.uid());
CREATE POLICY exos_event_saves_ins ON public.exos_event_saves FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());
CREATE POLICY exos_event_saves_del ON public.exos_event_saves FOR DELETE TO authenticated
  USING (user_id = auth.uid());

-- Platform-default grants: REVOKE everything (incl. the auto-GRANT-ALL to anon),
-- then re-GRANT only the three verbs the RLS policies gate. (Same lesson as the
-- phase-1 base-table + view REVOKE.)
REVOKE ALL ON public.exos_event_saves FROM anon, authenticated;
GRANT SELECT, INSERT, DELETE ON public.exos_event_saves TO authenticated;

COMMENT ON TABLE public.exos_event_saves IS
  'D4 mig 20260703120000: buyer wishlist — one row per (user, event). Private to
   the owner (RLS user_id = auth.uid()); no counter, so direct RLS-gated writes.';
