-- ============================================================================
-- Migration 20260713150000 — Exos (Bridge / D4): optional per-event set times
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_events (W: +set_times jsonb),
--           exos_public_events (view: +set_times column, security_invoker),
--           anon column-grant on exos_events (+set_times)
-- Pre-reqs: 20260520120000 (exos_events + exos_public_events),
--           20260622210000 (public views → security_invoker + anon column grants),
--           20260703130000 (artist_links — the pattern this mirrors).
--
-- Lets a venue/promoter enter an OPTIONAL lineup schedule — opener 8:00,
-- headliner 9:30, etc. Additive and fully optional: most events have none
-- (default '[]'). Powers the evolving ticket-pass countdown, which after doors
-- + show-start advances through these set times (TicketPhaseCountdown), and can
-- be shown on the public event page.
--
-- Shape: ordered array of { label: text, at: text(ISO-8601 UTC) }. The CHECK
-- only guarantees array-ness; per-entry shape (non-empty label, valid instant),
-- venue-tz→UTC conversion, ordering, and count/length caps are enforced by the
-- editor + normalizer (lib/setTimes.ts) — a malformed entry is skipped
-- client-side, same contract as artist_links.
--
-- Reads are public: ticket holders (and the event page) need the schedule, so
-- the column rides the exos_public_events boundary. Writes go through the
-- existing org-staff RLS on exos_events (the event editor already UPDATEs the
-- row) — no new RPC. No secrets: labels + public showtimes only.
--
-- D4 authors; validate on a Supabase preview branch; A1 applies (public
-- storefront read boundary — D4 + A1 review). NOT APPLIED by this change.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The set-times column. Array of { label, at }. CHECK guarantees array-ness;
--    per-entry shape is validated client-side (lib/setTimes.ts).
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS set_times jsonb NOT NULL DEFAULT '[]'::jsonb
  CONSTRAINT exos_events_set_times_is_array
    CHECK (jsonb_typeof(set_times) = 'array');

-- ---------------------------------------------------------------------------
-- 2. Expose it through the public events view (security_invoker, mig
--    20260622210000): row visibility comes from base-table RLS + the anon
--    column grant, so the new column must be added to both. Mirrors the
--    artist_links rollout (20260703130000) exactly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.exos_public_events AS
  SELECT id, org_id, name, slug, description, occurs_at_local, starts_at, doors_at,
         ends_at, timezone, currency, venue_name, venue_location, venue_address,
         primary_performer_name, performer_names, artist_links, set_times, event_type,
         category, genres, subgenres, image_url, branding, purchase_limits,
         total_tickets, tickets_sold
  FROM public.exos_events
  WHERE status = 'published';

ALTER VIEW public.exos_public_events SET (security_invoker = true);

REVOKE ALL ON public.exos_public_events FROM anon, authenticated;
GRANT SELECT ON public.exos_public_events TO anon, authenticated;

-- Extend the anon column-scoped grant on the base table with set_times
-- (idempotent — re-grants the full published set plus the new column).
GRANT SELECT (id, org_id, name, slug, description, occurs_at_local, starts_at,
              doors_at, ends_at, timezone, currency, venue_name, venue_location,
              venue_address, primary_performer_name, performer_names, artist_links,
              set_times, event_type, category, genres, subgenres, image_url, branding,
              purchase_limits, total_tickets, tickets_sold, status)
  ON public.exos_events TO anon;

COMMENT ON COLUMN public.exos_events.set_times IS
  'D4 mig 20260713150000: optional ordered [{label,at}] lineup/set-time schedule
   (at = ISO-8601 UTC). Organizer-entered, fully optional (default []). Public
   showtimes only — no secrets. Drives the ticket-pass countdown
   (TicketPhaseCountdown) + event page. Normalized by lib/setTimes.ts.';

-- ROLLBACK:
--   Recreate exos_public_events without set_times + re-grant (mig 20260703130000
--   column set), then:  ALTER TABLE public.exos_events DROP COLUMN IF EXISTS set_times;
