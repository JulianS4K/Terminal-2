-- Migration 20261122040000 · level:data-collection · lane:A1 (data plane — cross-source venues) · writes:venue_registry(new),venue_registry_audit(new),venue_registry_tick()(new),cron:venue_registry_hourly(new) · reads:axs_export_event,axs_venue_catalog,tm_venue_xref,mlb_venue_xref,tickpick_catalog_venue,vivid_catalog_venue,evo_gt_venue_link · pre:20261122015530
--
-- Operator 2026-11-22: build an AXS-seeded canonical venue registry as a NEW table alongside aq_venue_map.
--
-- WHY A NEW REGISTRY. aq_venue_map is fed by an external "aq" ingest we do not control: 4,875 venues, last
-- refreshed two days ago, against 13-20k venues in each resale catalogue — it cannot grow to cover everything.
-- AXS is our strongest LIVE, geocoded source: 160,549 of 161,215 export rows carry coordinates (99.6%), refreshed
-- hourly, with zip + address + city + state. So venue_registry is seeded from AXS (coordinates = the reliable
-- identity) and every other source's venue id is attached to it.
--
-- PHASE A (this migration): seed one registry row per AXS venue (its coordinates, zip, name, and the TEvo + SG ids
-- AXS already resolved), then attach the other sources' venue ids through the TEvo id they share with the AXS row
-- (fill-only, only where that TEvo id maps to exactly one registry row). This unifies, around AXS coordinates,
-- every cross-source venue link already known — the primaries first (AXS seed, TM, MLB), then the resale catalogues
-- (TickPick, Vivid, GoTickets). It does NOT yet create rows for venues absent from AXS, or match by name/coordinate
-- — that is Phase B (TM coordinates from the feed, then geocoding the resale-only tail).
--
-- Fill-only + audited. Reads our own tables; no upstream calls.

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE TABLE IF NOT EXISTS public.venue_registry (
  registry_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  canonical_name     text,
  city               text,
  state              text,
  country            text,
  postal_code        text,
  latitude           numeric,
  longitude          numeric,
  axs_venue_id       bigint UNIQUE,          -- the seed anchor: one registry row per AXS venue
  tevo_venue_id      bigint,
  sg_venue_id        bigint,
  tm_venue_id        text,
  mlb_venue_id       integer,
  tickpick_venue_id  bigint,
  vivid_venue_id     bigint,
  gt_venue_key       text,
  seed_source        text NOT NULL DEFAULT 'axs',
  methods            jsonb NOT NULL DEFAULT '{}'::jsonb,
  first_seen_at      timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS venue_registry_tevo_idx ON public.venue_registry (tevo_venue_id) WHERE tevo_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS venue_registry_geo_idx  ON public.venue_registry (latitude, longitude) WHERE latitude IS NOT NULL;
CREATE INDEX IF NOT EXISTS venue_registry_tm_idx   ON public.venue_registry (tm_venue_id) WHERE tm_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS venue_registry_city_idx ON public.venue_registry (state, city);

CREATE TABLE IF NOT EXISTS public.venue_registry_audit (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT now(),
  run_id      uuid,
  action      text,
  registry_id bigint,
  note        text
);
CREATE INDEX IF NOT EXISTS venue_registry_audit_at_idx ON public.venue_registry_audit (at);

ALTER TABLE public.venue_registry       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.venue_registry_audit ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.venue_registry, public.venue_registry_audit FROM anon, authenticated;
GRANT SELECT ON public.venue_registry, public.venue_registry_audit TO service_role;

CREATE OR REPLACE FUNCTION public.venue_registry_tick(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run   uuid := gen_random_uuid();
  v_seed  int := 0;
  v_out   jsonb := '{}'::jsonb;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('venue_registry_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another venue_registry_tick is running');
  END IF;

  -- one geo row per AXS venue (latest export), US/CA, with coordinates
  DROP TABLE IF EXISTS _vr_axs;
  CREATE TEMP TABLE _vr_axs ON COMMIT DROP AS
  SELECT DISTINCT ON (a.venue_id)
         a.venue_id AS axs_venue_id, a.venue_name, a.venue_city, a.venue_state,
         upper(left(coalesce(a.venue_country, 'US'), 2)) AS country,
         a.venue_postal_code, a.venue_lat, a.venue_lon, a.tevo_venue_id,
         (SELECT (c.sg_venue_ids)[1] FROM public.axs_venue_catalog c WHERE c.axs_venue_id = a.venue_id::text LIMIT 1) AS sg_venue_id
    FROM public.axs_export_event a
   WHERE a.venue_id IS NOT NULL AND coalesce(a.venue_name, '') <> ''
     AND upper(coalesce(a.venue_country, 'US')) IN ('US', 'CA', 'USA', 'CANADA')
   ORDER BY a.venue_id, a.last_seen_utc DESC NULLS LAST;

  IF p_apply THEN
    INSERT INTO public.venue_registry AS r
      (canonical_name, city, state, country, postal_code, latitude, longitude, axs_venue_id, tevo_venue_id, sg_venue_id, seed_source, methods)
    SELECT venue_name, venue_city, venue_state,
           CASE WHEN country IN ('US', 'US') THEN 'US' WHEN country IN ('CA') THEN 'CA' ELSE country END,
           venue_postal_code, venue_lat, venue_lon, axs_venue_id, tevo_venue_id,
           CASE WHEN sg_venue_id::text ~ '^\d+$' THEN sg_venue_id::text::bigint END,
           'axs', jsonb_build_object('axs', 'seed')
      FROM _vr_axs
    ON CONFLICT (axs_venue_id) DO UPDATE SET
      canonical_name = EXCLUDED.canonical_name, city = EXCLUDED.city, state = EXCLUDED.state,
      country = EXCLUDED.country, postal_code = EXCLUDED.postal_code,
      latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude,
      tevo_venue_id = coalesce(r.tevo_venue_id, EXCLUDED.tevo_venue_id),
      sg_venue_id = coalesce(r.sg_venue_id, EXCLUDED.sg_venue_id),
      updated_at = now();
    GET DIAGNOSTICS v_seed = ROW_COUNT;

    -- TEvo ids that map to exactly one registry row: the safe join key for attaching the other sources
    DROP TABLE IF EXISTS _vr_tevo1;
    CREATE TEMP TABLE _vr_tevo1 ON COMMIT DROP AS
    SELECT tevo_venue_id, min(registry_id) AS registry_id
      FROM public.venue_registry WHERE tevo_venue_id IS NOT NULL
     GROUP BY tevo_venue_id HAVING count(*) = 1;
    CREATE INDEX ON _vr_tevo1 (tevo_venue_id);

    -- attach each source's venue id through the shared TEvo id (fill-only)
    UPDATE public.venue_registry r SET tm_venue_id = s.tm_venue_id, methods = r.methods || jsonb_build_object('tm', 'via_tevo'), updated_at = now()
      FROM (SELECT DISTINCT ON (tevo_venue_id) tevo_venue_id, tm_venue_id FROM public.tm_venue_xref WHERE tevo_venue_id IS NOT NULL ORDER BY tevo_venue_id, derived_at DESC NULLS LAST) s
      JOIN _vr_tevo1 t ON t.tevo_venue_id = s.tevo_venue_id
     WHERE r.registry_id = t.registry_id AND r.tm_venue_id IS NULL;

    UPDATE public.venue_registry r SET mlb_venue_id = s.mlb_venue_id, methods = r.methods || jsonb_build_object('mlb', 'via_tevo'), updated_at = now()
      FROM (SELECT DISTINCT ON (tevo_venue_id) tevo_venue_id, mlb_venue_id FROM public.mlb_venue_xref WHERE tevo_venue_id IS NOT NULL ORDER BY tevo_venue_id) s
      JOIN _vr_tevo1 t ON t.tevo_venue_id = s.tevo_venue_id
     WHERE r.registry_id = t.registry_id AND r.mlb_venue_id IS NULL;

    UPDATE public.venue_registry r SET tickpick_venue_id = s.tp_venue_id, methods = r.methods || jsonb_build_object('tickpick', 'via_tevo'), updated_at = now()
      FROM (SELECT DISTINCT ON (tevo_venue_id) tevo_venue_id, tp_venue_id FROM public.tickpick_catalog_venue WHERE tevo_venue_id IS NOT NULL ORDER BY tevo_venue_id) s
      JOIN _vr_tevo1 t ON t.tevo_venue_id = s.tevo_venue_id
     WHERE r.registry_id = t.registry_id AND r.tickpick_venue_id IS NULL;

    UPDATE public.venue_registry r SET vivid_venue_id = s.vivid_venue_id, methods = r.methods || jsonb_build_object('vivid', 'via_tevo'), updated_at = now()
      FROM (SELECT DISTINCT ON (tevo_venue_id) tevo_venue_id, vivid_venue_id FROM public.vivid_catalog_venue WHERE tevo_venue_id IS NOT NULL ORDER BY tevo_venue_id) s
      JOIN _vr_tevo1 t ON t.tevo_venue_id = s.tevo_venue_id
     WHERE r.registry_id = t.registry_id AND r.vivid_venue_id IS NULL;

    UPDATE public.venue_registry r SET gt_venue_key = s.gt_venue_key, methods = r.methods || jsonb_build_object('gotickets', 'via_tevo'), updated_at = now()
      FROM (SELECT DISTINCT ON (tevo_venue_id) tevo_venue_id, gt_venue_key FROM public.evo_gt_venue_link WHERE tevo_venue_id IS NOT NULL ORDER BY tevo_venue_id, built_at DESC NULLS LAST) s
      JOIN _vr_tevo1 t ON t.tevo_venue_id = s.tevo_venue_id
     WHERE r.registry_id = t.registry_id AND r.gt_venue_key IS NULL;

    INSERT INTO public.venue_registry_audit (run_id, action, note)
    VALUES (v_run, 'seed', format('axs seed upserted %s rows', v_seed));
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply,
    'axs_seed_candidates', (SELECT count(*) FROM _vr_axs),
    'axs_seed_with_coords', (SELECT count(*) FROM _vr_axs WHERE venue_lat IS NOT NULL),
    'registry_rows', (SELECT count(*) FROM public.venue_registry),
    'with_coords', (SELECT count(*) FROM public.venue_registry WHERE latitude IS NOT NULL),
    'by_source', jsonb_build_object(
      'tevo', (SELECT count(tevo_venue_id) FROM public.venue_registry),
      'sg',   (SELECT count(sg_venue_id) FROM public.venue_registry),
      'tm',   (SELECT count(tm_venue_id) FROM public.venue_registry),
      'mlb',  (SELECT count(mlb_venue_id) FROM public.venue_registry),
      'tickpick', (SELECT count(tickpick_venue_id) FROM public.venue_registry),
      'vivid',(SELECT count(vivid_venue_id) FROM public.venue_registry),
      'gotickets', (SELECT count(gt_venue_key) FROM public.venue_registry)));
END $function$;

REVOKE ALL ON FUNCTION public.venue_registry_tick(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_registry_tick(boolean) TO service_role;

DO $$ BEGIN
  PERFORM cron.unschedule('venue_registry_hourly') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'venue_registry_hourly');
  PERFORM cron.schedule('venue_registry_hourly', '50 * * * *',
    $cmd$BEGIN; SET LOCAL statement_timeout = '300s'; SELECT public.venue_registry_tick(true); COMMIT;$cmd$);
END $$;

COMMIT;

-- VERIFY: SELECT public.venue_registry_tick(false);   -- dry run, shows projected seed + source counts
--   SELECT public.venue_registry_tick(true);          -- backfill
--   SELECT count(*), count(latitude), count(tm_venue_id), count(mlb_venue_id) FROM venue_registry;
-- ROLLBACK: SELECT cron.unschedule('venue_registry_hourly'); DROP FUNCTION venue_registry_tick(boolean);
--   DROP TABLE venue_registry_audit, venue_registry;
