-- SeatGeek integration — third data source. Metadata + discovery only;
-- SG public API does NOT expose pricing or transacted sales (those are
-- TEvo + SeatData jobs). What SG adds:
--   1. Cross-validation of event/venue/performer naming + lat/lng
--   2. Section info for venues (canonical seating layouts)
--   3. Recommendations (related events/performers — affinity-scored,
--      better than our current string-similarity heuristic)
--   4. Performer images (4 sizes: huge/large/medium/small) for our metadata
--   5. SeatGeek's taxonomy tree (cross-reference with TEvo's classification)
--
-- Auth: SG public endpoints use ?client_id=X (query param). Some endpoints
-- accept HTTP Basic with client_id + client_secret. Both stored in Vault.
--
-- Wall: SeatGeek metadata is broker-safe. Performer images can also flow
-- to retail. Recommendations are broker-only for now since we use them
-- internally for "what events to add to watchlist" rather than user-facing.
--
-- This migration captures what was applied to prod 2026-05-09 ~04:30 UTC.

BEGIN;

-- 1. Writer RPC for app secrets — needed so PowerShell / scripts can push
-- a key without using the SQL editor. SECURITY DEFINER + service-role only.
CREATE OR REPLACE FUNCTION public.upsert_app_secret(p_name text, p_value text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, vault
AS $$
DECLARE
  v_id uuid;
  v_action text;
BEGIN
  -- Same whitelist as the reader fn — extend BOTH places to add a key.
  IF p_name NOT IN (
    'SEATDATA_API_KEY',
    'TEVO_API_TOKEN',
    'TEVO_SECRET',
    'SEATGEEK_API_TOKEN'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;

  SELECT id INTO v_id FROM vault.secrets WHERE name = p_name;
  IF v_id IS NULL THEN
    PERFORM vault.create_secret(p_value, p_name, 'Managed by upsert_app_secret RPC');
    v_action := 'created';
  ELSE
    PERFORM vault.update_secret(v_id, p_value);
    v_action := 'updated';
  END IF;

  RETURN jsonb_build_object('name', p_name, 'action', v_action);
END $$;

REVOKE ALL ON FUNCTION public.upsert_app_secret(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_app_secret(text, text) TO service_role;

COMMENT ON FUNCTION public.upsert_app_secret(text, text) IS
'Write/update an app secret in Supabase Vault. Whitelist-gated. Service-role only. Use from a scripted insert (PowerShell, curl) or another secure context.';

-- Update get_app_secret() whitelist to include SEATGEEK_* keys.
CREATE OR REPLACE FUNCTION public.get_app_secret(p_name text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, vault
AS $$
DECLARE
  v_value text;
BEGIN
  IF p_name NOT IN (
    'SEATDATA_API_KEY',
    'TEVO_API_TOKEN',
    'TEVO_SECRET',
    'SEATGEEK_API_TOKEN'
  ) THEN
    RAISE EXCEPTION 'secret % is not in the app whitelist', p_name USING ERRCODE = '42501';
  END IF;
  SELECT decrypted_secret INTO v_value FROM vault.decrypted_secrets WHERE name = p_name LIMIT 1;
  RETURN v_value;
END $$;

REVOKE ALL ON FUNCTION public.get_app_secret(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_app_secret(text) TO service_role;

-- 2. SeatGeek xref tables (TEvo↔SG mapping at event / venue / performer)
CREATE TABLE IF NOT EXISTS seatgeek_event_xref (
  tevo_event_id     bigint PRIMARY KEY,
  sg_event_id       bigint NOT NULL,
  sg_url            text,
  sg_short_title    text,
  sg_type           text,                  -- concert | sports | broadway | etc.
  sg_taxonomies     jsonb,                 -- [{id,name,parent_id}, ...]
  sg_score          numeric,
  sg_announce_date  timestamptz,
  matched_at        timestamptz NOT NULL DEFAULT NOW(),
  match_method      text NOT NULL DEFAULT 'manual',  -- manual | auto_date_venue | auto_id
  match_confidence  numeric,
  meta              jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sg_event_xref_sg ON seatgeek_event_xref(sg_event_id);

CREATE TABLE IF NOT EXISTS seatgeek_venue_xref (
  tevo_venue_id     bigint PRIMARY KEY,
  sg_venue_id       bigint NOT NULL,
  sg_name           text,
  sg_url            text,
  sg_address        text,
  sg_city           text,
  sg_state          text,
  sg_country        text,
  sg_postal_code    text,
  sg_lat            numeric,
  sg_lng            numeric,
  matched_at        timestamptz NOT NULL DEFAULT NOW(),
  match_method      text NOT NULL DEFAULT 'manual',
  match_confidence  numeric,
  meta              jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sg_venue_xref_sg ON seatgeek_venue_xref(sg_venue_id);

CREATE TABLE IF NOT EXISTS seatgeek_performer_xref (
  tevo_performer_id bigint PRIMARY KEY,
  sg_performer_id   bigint NOT NULL,
  sg_slug           text,
  sg_name           text,
  sg_short_name     text,
  sg_type           text,                  -- band | mlb | nba | etc.
  sg_url            text,
  sg_image_url      text,                  -- "huge" preferred, falls back to large
  sg_images         jsonb,                 -- {huge, large, medium, small}
  sg_taxonomies     jsonb,
  matched_at        timestamptz NOT NULL DEFAULT NOW(),
  match_method      text NOT NULL DEFAULT 'manual',
  match_confidence  numeric,
  meta              jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sg_perf_xref_sg ON seatgeek_performer_xref(sg_performer_id);
CREATE INDEX IF NOT EXISTS idx_sg_perf_xref_slug ON seatgeek_performer_xref(sg_slug);

-- 3. Cached lookups — these don't change often. Refresh weekly or on demand.

-- SeatGeek's full taxonomy tree (sports/concerts/broadway/comedy/...).
-- Our TEvo events already have tevo classifications; SG taxonomies are a
-- complementary categorization. Useful for cross-source consistency checks.
CREATE TABLE IF NOT EXISTS seatgeek_taxonomies (
  sg_id        bigint PRIMARY KEY,
  name         text NOT NULL,
  parent_id    bigint,
  pulled_at    timestamptz NOT NULL DEFAULT NOW(),
  raw          jsonb
);

-- Section info per event — venue layout per SG. Sections is a JSONB map of
-- { section_name: [row_label, row_label, ...] } — useful for our zone/section
-- mapping system. Rarely changes for a given event, so cache aggressively.
CREATE TABLE IF NOT EXISTS seatgeek_event_sections (
  sg_event_id   bigint PRIMARY KEY,
  tevo_event_id bigint,                     -- back-ref for convenience
  sections      jsonb NOT NULL,             -- {section_name: [row, row, ...]}
  section_count int,
  total_rows    int,
  pulled_at     timestamptz NOT NULL DEFAULT NOW(),
  refreshed_at  timestamptz
);
CREATE INDEX IF NOT EXISTS idx_sg_sections_tevo ON seatgeek_event_sections(tevo_event_id);

-- Recommendations cache. Affinity-scored related events or performers from
-- a seed (event_id OR performer_id). Used for: "what events should we be
-- watchlisting next" + "who else might draw at this venue?".
CREATE TABLE IF NOT EXISTS seatgeek_recommendations (
  id              bigserial PRIMARY KEY,
  seed_type       text NOT NULL,            -- 'event' | 'performer'
  seed_sg_id      bigint NOT NULL,          -- SG id of the seed
  rec_type        text NOT NULL,            -- 'event' | 'performer'
  rec_sg_id       bigint NOT NULL,          -- SG id of the recommended item
  affinity_score  numeric NOT NULL,
  rec_payload     jsonb NOT NULL,           -- full SG entity for display
  pulled_at       timestamptz NOT NULL DEFAULT NOW(),
  CONSTRAINT seatgeek_rec_unique UNIQUE (seed_type, seed_sg_id, rec_type, rec_sg_id)
);
CREATE INDEX IF NOT EXISTS idx_sg_rec_seed ON seatgeek_recommendations(seed_type, seed_sg_id);

-- 4. Audit / pull log
CREATE TABLE IF NOT EXISTS seatgeek_pull_log (
  id              bigserial PRIMARY KEY,
  called_at       timestamptz NOT NULL DEFAULT NOW(),
  endpoint        text NOT NULL,              -- 'events.search' | 'venues.show' | etc.
  http_status     int,
  rows_returned   int,
  error_message   text,
  request_meta    jsonb DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS idx_sg_log_called_at ON seatgeek_pull_log(called_at DESC);

GRANT SELECT, INSERT, UPDATE ON seatgeek_event_xref      TO service_role;
GRANT SELECT, INSERT, UPDATE ON seatgeek_venue_xref      TO service_role;
GRANT SELECT, INSERT, UPDATE ON seatgeek_performer_xref  TO service_role;
GRANT SELECT, INSERT, UPDATE ON seatgeek_taxonomies      TO service_role;
GRANT SELECT, INSERT, UPDATE ON seatgeek_event_sections  TO service_role;
GRANT SELECT, INSERT, UPDATE ON seatgeek_recommendations TO service_role;
GRANT SELECT, INSERT          ON seatgeek_pull_log       TO service_role;

GRANT SELECT ON seatgeek_event_xref      TO authenticated;
GRANT SELECT ON seatgeek_venue_xref      TO authenticated;
GRANT SELECT ON seatgeek_performer_xref  TO authenticated;
GRANT SELECT ON seatgeek_taxonomies      TO authenticated;
GRANT SELECT ON seatgeek_event_sections  TO authenticated;
GRANT SELECT ON seatgeek_recommendations TO authenticated;

COMMIT;
