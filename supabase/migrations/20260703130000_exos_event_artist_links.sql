-- ============================================================================
-- Migration 20260703130000 — Exos (Bridge / D4): per-artist social/streaming links
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_events (W: +artist_links jsonb),
--           exos_public_events (view: +artist_links column, security_invoker),
--           anon column-grant on exos_events (+artist_links)
-- Pre-reqs: 20260520120000 (exos_events + exos_public_events),
--            20260622210000 (public views → security_invoker + anon column grants).
--
-- Buyer-facing discovery: lets an organizer attach an artist's streaming +
-- social destinations (Spotify, Apple Music, Bandsintown, Instagram, X, TikTok,
-- YouTube, website) so the event page can link out to each performer. Purely
-- additive to the existing performer_names text[] lineup — that stays the
-- canonical name list (emails, CSV, D0 catalog primary_performer_name); this
-- column carries OPTIONAL link metadata keyed by artist name.
--
-- Shape: ordered array of
--   {name, spotify?, appleMusic?, bandsintown?, instagram?, x?, tiktok?,
--    youtube?, website?}
-- The CHECK only guarantees array-ness; per-entry shape + URL/handle
-- normalization are validated by the editor and the render helper
-- (lib/artistLinks.ts) — a malformed entry is simply skipped client-side.
--
-- Reads are public: buyers need the links on the event page, so the column
-- rides the exos_public_events boundary. Writes go through the existing
-- org-staff RLS on exos_events (the event editor already UPDATEs the row) —
-- no new RPC. No secrets: these are public handles/URLs only.
--
-- D4 authors; A1 applies (public storefront read boundary — D4 + A1 review).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. The links column. Array of per-artist link objects (see header). The
--    CHECK guarantees array-ness; per-entry shape is validated client-side.
-- ---------------------------------------------------------------------------
ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS artist_links jsonb NOT NULL DEFAULT '[]'::jsonb
  CONSTRAINT exos_events_artist_links_is_array
    CHECK (jsonb_typeof(artist_links) = 'array');

-- ---------------------------------------------------------------------------
-- 2. Expose it through the public events view. The view is security_invoker
--    (mig 20260622210000): row visibility comes from the base-table RLS
--    (exos_events_public_read) and anon reads via a COLUMN-scoped grant, so the
--    new column must be added to that grant too. authenticated has table-wide
--    SELECT on the base table, so it needs no column change.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.exos_public_events AS
  SELECT id, org_id, name, slug, description, occurs_at_local, starts_at, doors_at,
         ends_at, timezone, currency, venue_name, venue_location, venue_address,
         primary_performer_name, performer_names, artist_links, event_type, category,
         genres, subgenres, image_url, branding, purchase_limits, total_tickets,
         tickets_sold
  FROM public.exos_events
  WHERE status = 'published';

-- CREATE OR REPLACE can reset view options — re-assert security_invoker so the
-- base-table RLS keeps running as the caller (not the view owner).
ALTER VIEW public.exos_public_events SET (security_invoker = true);

-- Re-assert the SELECT-only view grant (owner-run-view landmine: auto GRANT ALL
-- → anon on replace). Whole-view SELECT is correct — every projected column is
-- public storefront data.
REVOKE ALL ON public.exos_public_events FROM anon, authenticated;
GRANT SELECT ON public.exos_public_events TO anon, authenticated;

-- Extend the anon column-scoped grant on the base table with artist_links
-- (idempotent — re-granting the full set the security_invoker migration set,
-- plus the new column).
GRANT SELECT (id, org_id, name, slug, description, occurs_at_local, starts_at,
              doors_at, ends_at, timezone, currency, venue_name, venue_location,
              venue_address, primary_performer_name, performer_names, artist_links,
              event_type, category, genres, subgenres, image_url, branding,
              purchase_limits, total_tickets, tickets_sold, status)
  ON public.exos_events TO anon;

COMMENT ON COLUMN public.exos_events.artist_links IS
  'D4 mig 20260703130000: optional [{name,spotify,appleMusic,bandsintown,instagram,
   x,tiktok,youtube,website}] per-artist link metadata, keyed by performer name.
   Public handles/URLs only — no secrets. Additive to performer_names (canonical
   lineup). Rendered on the event page (lib/artistLinks.ts + ArtistLinks.tsx).';
