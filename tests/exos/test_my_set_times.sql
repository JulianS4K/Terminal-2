-- ============================================================================
-- Focused DDL test for migration 20260713150000 (optional set_times). The
-- migration's public-events view references the full event column lineage, so
-- this synthesizes an exos_events carrying exactly those columns + the roles,
-- applies the migration (via run_set_times.sh), then asserts: column present +
-- default, array-only CHECK, view exposure, anon column grant, round-trip.
-- ============================================================================

-- Roles the migration GRANTs to.
DO $r$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $r$;

-- Synthetic exos_events with every column the migration's view + grant name.
CREATE TABLE public.exos_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid, name text, slug text, description text,
  occurs_at_local text, starts_at timestamptz, doors_at timestamptz, ends_at timestamptz,
  timezone text, currency text, venue_name text, venue_location text, venue_address jsonb,
  primary_performer_name text, performer_names text[], artist_links jsonb DEFAULT '[]'::jsonb,
  event_type text, category text, genres text[], subgenres text[], image_url text,
  branding jsonb, purchase_limits jsonb, total_tickets int, tickets_sold int,
  status text NOT NULL DEFAULT 'published'
);
