-- Migration 20261124041500 · level:data-collection · lane:A1 (data plane — cross-source venues) · writes:venue_registry_tick() · reads:axs_export_event,axs_venue_catalog,tm_venue_xref,mlb_venue_xref,tickpick_catalog_venue,vivid_catalog_venue,evo_gt_venue_link · pre:20261122040040
--
-- Perf fix for venue_registry_tick (mig 20261122040000). The AXS seed put the SG-id lookup in a correlated
-- subquery inside a DISTINCT ON over all ~161k axs_export_event rows, so it was evaluated per input row and the
-- backfill took ~6-7 minutes — past the hourly cron's 300s statement_timeout, so every refresh would time out and
-- roll back. This rewrite dedupes AXS venues first (161k -> ~4,600), then looks up the SG id with a scalar
-- subquery over that small set (not a LEFT JOIN, which fans out because axs_venue_catalog has duplicate
-- axs_venue_id rows). Measured ~10s on prod. Logic otherwise unchanged (fill-only, audited, attach-by-TEvo).

BEGIN;
SET LOCAL lock_timeout = '10s';

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

    INSERT INTO public.venue_registry_audit (run_id, action, note)
    VALUES (v_run, 'seed', format('axs seed upserted %s rows', v_seed));
  END IF;

  RETURN jsonb_build_object('run_id', v_run, 'applied', p_apply,
    'axs_seed_candidates', (SELECT count(*) FROM _vr_axs),
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

COMMIT;

-- VERIFY: SELECT public.venue_registry_tick(true);  -- ~10s on prod; registry ~4,577 rows, 99% geocoded.
