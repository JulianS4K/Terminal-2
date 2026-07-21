-- 20260721120000_a1_enable_rls_public_athlete_zone_tables.sql
-- Lane: A1 (DB security — RLS/SECDEF, PROJECT_BIBLE §2.4).
--
-- Fixes the CRITICAL Supabase security-linter finding `rls_disabled_in_public`
-- (lint 0013) on five public tables. RLS was never enabled on them, so the
-- table-level GRANTs (see below) applied unchecked — anon could read every row
-- over PostgREST. This enables RLS on all five and pins access to exactly what
-- the tables were already granted: read-only for anon/authenticated, full
-- access for service_role (the backend, which uses SUPABASE_SERVICE_ROLE_KEY
-- and bypasses RLS regardless).
--
-- Behaviour-preserving: no new read exposure is added and no existing read
-- path is removed. The four athlete tables are public ESPN reference data
-- (same class as venue_assets — mig 20260508140000, whose pattern this
-- mirrors). zone_price_observations already granted anon+authenticated SELECT;
-- this migration keeps that grant explicit and, crucially, makes writes
-- impossible for anon/authenticated (no INSERT/UPDATE/DELETE policy).
--
-- Current grants at author time (anon/authenticated only; verified read-only
-- via information_schema.role_table_grants):
--   athlete_external_ids     anon:SELECT
--   athlete_pages            anon:SELECT
--   athlete_wikipedia        anon:SELECT
--   espn_athlete_brand       anon:SELECT
--   zone_price_observations  anon:SELECT, authenticated:SELECT
--
-- Touches (RLS only — no schema/data change): athlete_external_ids,
--   athlete_pages, athlete_wikipedia, espn_athlete_brand,
--   zone_price_observations.
--
-- Idempotent: ENABLE RLS is a no-op if already on; policies are DROP-then-CREATE.

-- ---------------------------------------------------------------------------
-- Athlete reference tables — public read (anon + authenticated), service write.
-- ---------------------------------------------------------------------------

ALTER TABLE public.athlete_pages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS athlete_pages_anon_read ON public.athlete_pages;
CREATE POLICY athlete_pages_anon_read ON public.athlete_pages FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS athlete_pages_service_all ON public.athlete_pages;
CREATE POLICY athlete_pages_service_all ON public.athlete_pages FOR ALL TO service_role USING (true) WITH CHECK (true);

ALTER TABLE public.athlete_external_ids ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS athlete_external_ids_anon_read ON public.athlete_external_ids;
CREATE POLICY athlete_external_ids_anon_read ON public.athlete_external_ids FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS athlete_external_ids_service_all ON public.athlete_external_ids;
CREATE POLICY athlete_external_ids_service_all ON public.athlete_external_ids FOR ALL TO service_role USING (true) WITH CHECK (true);

ALTER TABLE public.athlete_wikipedia ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS athlete_wikipedia_anon_read ON public.athlete_wikipedia;
CREATE POLICY athlete_wikipedia_anon_read ON public.athlete_wikipedia FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS athlete_wikipedia_service_all ON public.athlete_wikipedia;
CREATE POLICY athlete_wikipedia_service_all ON public.athlete_wikipedia FOR ALL TO service_role USING (true) WITH CHECK (true);

ALTER TABLE public.espn_athlete_brand ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS espn_athlete_brand_anon_read ON public.espn_athlete_brand;
CREATE POLICY espn_athlete_brand_anon_read ON public.espn_athlete_brand FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS espn_athlete_brand_service_all ON public.espn_athlete_brand;
CREATE POLICY espn_athlete_brand_service_all ON public.espn_athlete_brand FOR ALL TO service_role USING (true) WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- zone_price_observations — pricing feature store. Preserves the existing
-- anon+authenticated read grant; writes locked to service_role. If this data
-- should NOT be publicly readable, drop the *_anon_read policy below and the
-- anon/authenticated GRANT — the finding stays fixed either way.
-- ---------------------------------------------------------------------------

ALTER TABLE public.zone_price_observations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS zone_price_observations_anon_read ON public.zone_price_observations;
CREATE POLICY zone_price_observations_anon_read ON public.zone_price_observations FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS zone_price_observations_service_all ON public.zone_price_observations;
CREATE POLICY zone_price_observations_service_all ON public.zone_price_observations FOR ALL TO service_role USING (true) WITH CHECK (true);

-- Re-assert the grants the policies gate (no-ops if already present) so intent
-- is legible in one place.
GRANT SELECT ON public.athlete_pages           TO anon, authenticated;
GRANT SELECT ON public.athlete_external_ids     TO anon, authenticated;
GRANT SELECT ON public.athlete_wikipedia        TO anon, authenticated;
GRANT SELECT ON public.espn_athlete_brand       TO anon, authenticated;
GRANT SELECT ON public.zone_price_observations  TO anon, authenticated;

GRANT ALL ON public.athlete_pages           TO service_role;
GRANT ALL ON public.athlete_external_ids     TO service_role;
GRANT ALL ON public.athlete_wikipedia        TO service_role;
GRANT ALL ON public.espn_athlete_brand       TO service_role;
GRANT ALL ON public.zone_price_observations  TO service_role;
