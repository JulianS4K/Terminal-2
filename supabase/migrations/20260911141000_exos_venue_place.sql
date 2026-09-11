-- ============================================================================
-- Migration 20260911141000 — Exos (Bridge / D4): venue Place ID + geo for Google surfaces
--
-- Lane:     d4 (exos / bridge ticketing infra)
-- Touches:  exos_events (W: +google_place_id, +venue_lat, +venue_lng),
--           exos_public_events (VIEW replaced: +google_place_id, +venue_lat,
--           +venue_lng, +updated_at; only where the view exists — re-asserts
--           security_invoker + grants + the anon column grant)
-- Pre-reqs: 20260911133000 (current exos_public_events column list incl. series_id)
--
-- Stage 5 (organizer side) item 2 — "selling via Google Maps". Google's Events
-- rich result (Search + Maps) is fed by Event JSON-LD whose `location` carries
-- a postal address AND, ideally, `geo` — and "Get directions" / the Maps pin
-- resolve cleanly only when the venue is a known Place. Three columns:
--
--   google_place_id  the Places ID the organizer pastes (or picks, once a
--                    Places key is configured) — links the event to the exact
--                    listing on Maps
--   venue_lat/lng    coordinates for JSON-LD `geo` + map links; NUMERIC(9,6)
--                    (≈ 10 cm), CHECKed to the valid ranges
--   updated_at       now projected on the public view so the events sitemap
--                    can emit <lastmod>
--
-- The public view is the SEO source for the server-side pre-render
-- (routers/pages.py D4 block) and the sitemap, so the new columns must be
-- readable by anon: the base-table column grant is extended (security_invoker).
--
-- ROLLBACK: ALTER TABLE exos_events DROP COLUMN google_place_id, DROP COLUMN
--   venue_lat, DROP COLUMN venue_lng; re-create exos_public_events from
--   20260911133000.
-- ============================================================================

ALTER TABLE public.exos_events
  ADD COLUMN IF NOT EXISTS google_place_id text
    CHECK (google_place_id IS NULL OR char_length(google_place_id) BETWEEN 5 AND 300),
  ADD COLUMN IF NOT EXISTS venue_lat numeric(9,6)
    CHECK (venue_lat IS NULL OR venue_lat BETWEEN -90 AND 90),
  ADD COLUMN IF NOT EXISTS venue_lng numeric(9,6)
    CHECK (venue_lng IS NULL OR venue_lng BETWEEN -180 AND 180);
COMMENT ON COLUMN public.exos_events.google_place_id IS
  'Google Places ID of the venue (organizer-supplied). Feeds Maps deep links + the Event JSON-LD location.';
COMMENT ON COLUMN public.exos_events.venue_lat IS 'Venue latitude for JSON-LD geo + map links.';
COMMENT ON COLUMN public.exos_events.venue_lng IS 'Venue longitude for JSON-LD geo + map links.';

DO $$
BEGIN
  IF to_regclass('public.exos_public_events') IS NOT NULL THEN
    EXECUTE $v$
      CREATE OR REPLACE VIEW public.exos_public_events AS
        SELECT id, org_id, name, slug, description, occurs_at_local, starts_at, doors_at,
               ends_at, timezone, currency, venue_name, venue_location, venue_address,
               primary_performer_name, performer_names, artist_links, event_type, category,
               genres, subgenres, image_url, branding, purchase_limits, total_tickets,
               tickets_sold, series_id, series_index,
               google_place_id, venue_lat, venue_lng, updated_at
        FROM public.exos_events
        WHERE status = 'published'
    $v$;
    EXECUTE 'ALTER VIEW public.exos_public_events SET (security_invoker = true)';
    EXECUTE 'REVOKE ALL ON public.exos_public_events FROM anon, authenticated';
    EXECUTE 'GRANT SELECT ON public.exos_public_events TO anon, authenticated';
    EXECUTE 'GRANT SELECT (google_place_id, venue_lat, venue_lng, updated_at) ON public.exos_events TO anon, authenticated';
  END IF;
END $$;
