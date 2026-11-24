-- Migration 20261124051000 · level:data-collection · lane:A1 (data plane — cross-source venues) · writes:venue_registry,venue_registry_tick() · reads:tm_venue_xref,mlb_venue_xref,venue_assets · pre:20261124050000
--
-- Phase B of venue_registry. Phase A seeded from AXS and attached other sources by shared tevo_venue_id.
-- Here we add the primary-source venues that exist in Ticketmaster / MLB but not in AXS:
--   • fill any registry row still missing coords from venue_assets (the geocode hub, keyed tevo_venue_id);
--   • seed TM venues not yet represented — coords from venue_assets when the tevo venue is geocoded,
--     else the TM Discovery feed (now persisted on tm_venue_xref by mig 20261124050000). A TM venue whose
--     tevo is already on a registry row is skipped (a single tm_venue_id column can't hold a second TM id),
--     and fresh tevo ids are deduped to one row each so the tevo-attach's unique-tevo rule keeps holding;
--   • seed MLB venues not yet represented, coords from venue_assets by tevo.
-- All seeds are fill-only + audited, and idempotent: once a venue is in the registry the NOT EXISTS guards
-- drop it from the candidate set on the next tick. Resale sources (vivid/tickpick/sg/gt/evo) store no
-- coordinates, so they stay attached by tevo/name (unchanged) — coordinate matching only bridges AXS/TM/geo.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- unique anchors so TM/MLB seeds upsert cleanly and never duplicate a source id (verified no existing dups)
CREATE UNIQUE INDEX IF NOT EXISTS venue_registry_tm_uniq  ON public.venue_registry (tm_venue_id)  WHERE tm_venue_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS venue_registry_mlb_uniq ON public.venue_registry (mlb_venue_id) WHERE mlb_venue_id IS NOT NULL;

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
  v_cf    int := 0;
  v_tm    int := 0;
  v_mlb   int := 0;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('venue_registry_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another venue_registry_tick is running');
  END IF;

  -- dedupe AXS venues first (161k -> ~4,600), then look up the SG id per venue (scalar subquery on the small set)
  DROP TABLE IF EXISTS _vr_axs;
  CREATE TEMP TABLE _vr_axs ON COMMIT DROP AS
  WITH latest AS (
    SELECT DISTINCT ON (a.venue_id)
           a.venue_id AS axs_venue_id, a.venue_name, a.venue_city, a.venue_state,
           upper(left(coalesce(a.venue_country, 'US'), 2)) AS country,
           a.venue_postal_code, a.venue_lat, a.venue_lon, a.tevo_venue_id
      FROM public.axs_export_event a
     WHERE a.venue_id IS NOT NULL AND coalesce(a.venue_name, '') <> ''
       AND upper(coalesce(a.venue_country, 'US')) IN ('US', 'CA', 'USA', 'CANADA')
     ORDER BY a.venue_id, a.last_seen_utc DESC NULLS LAST)
  SELECT l.*,
         (SELECT (c.sg_venue_ids)[1] FROM public.axs_venue_catalog c
           WHERE c.axs_venue_id = l.axs_venue_id::text AND c.sg_venue_ids IS NOT NULL LIMIT 1) AS sg_venue_id
    FROM latest l;

  IF p_apply THEN
    INSERT INTO public.venue_registry AS r
      (canonical_name, city, state, country, postal_code, latitude, longitude, axs_venue_id, tevo_venue_id, sg_venue_id, seed_source, methods)
    SELECT venue_name, venue_city, venue_state,
           CASE WHEN country = 'US' THEN 'US' WHEN country = 'CA' THEN 'CA' ELSE country END,
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

    DROP TABLE IF EXISTS _vr_tevo1;
    CREATE TEMP TABLE _vr_tevo1 ON COMMIT DROP AS
    SELECT tevo_venue_id, min(registry_id) AS registry_id
      FROM public.venue_registry WHERE tevo_venue_id IS NOT NULL
     GROUP BY tevo_venue_id HAVING count(*) = 1;
    CREATE INDEX ON _vr_tevo1 (tevo_venue_id);

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

    -- ---- Phase B.0: fill any row still missing coords from the geocode hub (keyed tevo_venue_id) ----
    UPDATE public.venue_registry r
       SET latitude = a.latitude, longitude = a.longitude,
           methods = r.methods || jsonb_build_object('coords', 'venue_assets'), updated_at = now()
      FROM public.venue_assets a
     WHERE a.tevo_venue_id = r.tevo_venue_id AND a.latitude IS NOT NULL
       AND r.latitude IS NULL AND r.tevo_venue_id IS NOT NULL;
    GET DIAGNOSTICS v_cf = ROW_COUNT;

    -- ---- Phase B.1: seed TM venues not yet represented (no dup tevo), coords from venue_assets else TM feed ----
    DROP TABLE IF EXISTS _vr_tm;
    CREATE TEMP TABLE _vr_tm ON COMMIT DROP AS
    WITH cand AS (
      SELECT x.tm_venue_id, x.tevo_venue_id, x.name, x.city, x.state,
             upper(left(coalesce(x.country, 'US'), 2)) AS country,
             x.postal_code, x.latitude, x.longitude, coalesce(x.events, 0) AS events
        FROM public.tm_venue_xref x
       WHERE upper(coalesce(x.country, 'US')) IN ('US', 'CA', 'USA', 'CANADA')
         AND NOT EXISTS (SELECT 1 FROM public.venue_registry r WHERE r.tm_venue_id = x.tm_venue_id)
         AND (x.tevo_venue_id IS NULL
              OR NOT EXISTS (SELECT 1 FROM public.venue_registry r WHERE r.tevo_venue_id = x.tevo_venue_id)))
    SELECT DISTINCT ON (coalesce(tevo_venue_id::text, 'tm:' || tm_venue_id))
           tm_venue_id, tevo_venue_id, name, city, state, country, postal_code, latitude, longitude
      FROM cand
     ORDER BY coalesce(tevo_venue_id::text, 'tm:' || tm_venue_id), events DESC;

    INSERT INTO public.venue_registry AS r
      (canonical_name, city, state, country, postal_code, latitude, longitude, tevo_venue_id, tm_venue_id, seed_source, methods)
    SELECT t.name, t.city, t.state, t.country, t.postal_code,
           coalesce(a.latitude, t.latitude), coalesce(a.longitude, t.longitude),
           t.tevo_venue_id, t.tm_venue_id, 'tm',
           jsonb_build_object('tm', 'seed') ||
           CASE WHEN a.latitude IS NOT NULL THEN jsonb_build_object('coords', 'venue_assets')
                WHEN t.latitude IS NOT NULL THEN jsonb_build_object('coords', 'tm_feed')
                ELSE '{}'::jsonb END
      FROM _vr_tm t
      LEFT JOIN public.venue_assets a ON a.tevo_venue_id = t.tevo_venue_id AND a.latitude IS NOT NULL
    ON CONFLICT (tm_venue_id) WHERE tm_venue_id IS NOT NULL DO NOTHING;
    GET DIAGNOSTICS v_tm = ROW_COUNT;

    -- ---- Phase B.2: seed MLB venues not yet represented, coords from venue_assets by tevo ----
    DROP TABLE IF EXISTS _vr_mlb;
    CREATE TEMP TABLE _vr_mlb ON COMMIT DROP AS
    SELECT DISTINCT ON (coalesce(m.tevo_venue_id::text, 'mlb:' || m.mlb_venue_id))
           m.mlb_venue_id, m.tevo_venue_id, m.venue_name, m.venue_city
      FROM public.mlb_venue_xref m
     WHERE NOT EXISTS (SELECT 1 FROM public.venue_registry r WHERE r.mlb_venue_id = m.mlb_venue_id)
       AND (m.tevo_venue_id IS NULL
            OR NOT EXISTS (SELECT 1 FROM public.venue_registry r WHERE r.tevo_venue_id = m.tevo_venue_id))
     ORDER BY coalesce(m.tevo_venue_id::text, 'mlb:' || m.mlb_venue_id), coalesce(m.games, 0) DESC;

    INSERT INTO public.venue_registry AS r
      (canonical_name, city, country, latitude, longitude, tevo_venue_id, mlb_venue_id, seed_source, methods)
    SELECT mm.venue_name, mm.venue_city,
           CASE WHEN mm.venue_city ILIKE 'toronto%' THEN 'CA' ELSE 'US' END,
           a.latitude, a.longitude, mm.tevo_venue_id, mm.mlb_venue_id, 'mlb',
           jsonb_build_object('mlb', 'seed') ||
           CASE WHEN a.latitude IS NOT NULL THEN jsonb_build_object('coords', 'venue_assets') ELSE '{}'::jsonb END
      FROM _vr_mlb mm
      LEFT JOIN public.venue_assets a ON a.tevo_venue_id = mm.tevo_venue_id AND a.latitude IS NOT NULL
    ON CONFLICT (mlb_venue_id) WHERE mlb_venue_id IS NOT NULL DO NOTHING;
    GET DIAGNOSTICS v_mlb = ROW_COUNT;

    INSERT INTO public.venue_registry_audit (run_id, action, note)
    VALUES (v_run, 'seed', format('axs upserted %s, coords filled %s, tm seeded %s, mlb seeded %s', v_seed, v_cf, v_tm, v_mlb));
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply,
    'axs_seed_candidates', (SELECT count(*) FROM _vr_axs),
    'coords_filled', v_cf, 'tm_seeded', v_tm, 'mlb_seeded', v_mlb,
    'registry_rows', (SELECT count(*) FROM public.venue_registry),
    'with_coords', (SELECT count(*) FROM public.venue_registry WHERE latitude IS NOT NULL),
    'by_seed', (SELECT jsonb_object_agg(seed_source, n) FROM (SELECT seed_source, count(*) n FROM public.venue_registry GROUP BY 1) z),
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

COMMIT;

-- VERIFY: SELECT public.venue_registry_tick(true);  -- tm_seeded ~2,625, mlb_seeded ~22 on first run, then 0.
-- ROLLBACK: re-apply 20261124041500's venue_registry_tick(); DROP the two unique indexes;
--           DELETE FROM venue_registry WHERE seed_source IN ('tm','mlb');
