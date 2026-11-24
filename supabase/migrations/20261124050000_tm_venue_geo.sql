-- Migration 20261124050000 · level:data-collection · lane:A1 (data plane — cross-source venues) · writes:tm_venue_xref(+geo),tm_venue_geo_tick() · reads:tm_discovery_event · pre:20261122033000
--
-- Phase B prep for venue_registry: TM is a primary listing source with coordinates + ZIP, but
-- tm_venue_xref carried only name/city/state. The coords live in the Discovery feed's venue embed
-- (tm_discovery_event.raw #> '{_embedded,venues,0}' → location.latitude/longitude, postalCode,
-- address.line1). Scanning that raw jsonb across all ~123k events per refresh is far too slow
-- (a correlated read of raw for every event of a venue decompresses the TOASTed payload ~19×).
-- So we persist the geo once onto tm_venue_xref and maintain it incrementally: tm_venue_geo_tick()
-- fills only rows still missing coords (latitude IS NULL), bounded by p_limit, picking the latest
-- event per venue and reading raw exactly once for that one row (measured ~6ms/venue).

BEGIN;
SET LOCAL lock_timeout = '10s';

ALTER TABLE public.tm_venue_xref
  ADD COLUMN IF NOT EXISTS latitude    numeric,
  ADD COLUMN IF NOT EXISTS longitude   numeric,
  ADD COLUMN IF NOT EXISTS postal_code text,
  ADD COLUMN IF NOT EXISTS address     text,
  ADD COLUMN IF NOT EXISTS geo_at      timestamptz;

CREATE OR REPLACE FUNCTION public.tm_venue_geo_tick(p_limit integer DEFAULT 1500)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_done int := 0;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('tm_venue_geo_tick')) THEN
    RETURN jsonb_build_object('skipped', 'another tm_venue_geo_tick is running');
  END IF;

  -- pick the venues still missing coords, newest-activity first; read raw once per venue
  DROP TABLE IF EXISTS _tvg;
  CREATE TEMP TABLE _tvg ON COMMIT DROP AS
  WITH todo AS (
    SELECT x.tm_venue_id
      FROM public.tm_venue_xref x
     WHERE x.geo_at IS NULL
     ORDER BY coalesce(x.events, 0) DESC
     LIMIT greatest(p_limit, 0))
  SELECT t.tm_venue_id,
         e.v #>> '{location,latitude}'  AS lat,
         e.v #>> '{location,longitude}' AS lon,
         e.v #>> '{postalCode}'         AS zip,
         e.v #>> '{address,line1}'      AS addr
    FROM todo t
    CROSS JOIN LATERAL (
      SELECT d.raw #> '{_embedded,venues,0}' AS v
        FROM public.tm_discovery_event d
       WHERE d.tm_venue_id = t.tm_venue_id
       ORDER BY d.last_seen_at DESC NULLS LAST
       LIMIT 1) e;

  UPDATE public.tm_venue_xref x SET
    latitude    = CASE WHEN g.lat ~ '^-?\d+(\.\d+)?$' THEN g.lat::numeric END,
    longitude   = CASE WHEN g.lon ~ '^-?\d+(\.\d+)?$' THEN g.lon::numeric END,
    postal_code = nullif(g.zip, ''),
    address     = nullif(g.addr, ''),
    geo_at      = now()
  FROM _tvg g
  WHERE g.tm_venue_id = x.tm_venue_id;
  GET DIAGNOSTICS v_done = ROW_COUNT;

  RETURN jsonb_build_object(
    'processed', v_done,
    'remaining', (SELECT count(*) FROM public.tm_venue_xref WHERE geo_at IS NULL),
    'with_coords', (SELECT count(*) FROM public.tm_venue_xref WHERE latitude IS NOT NULL),
    'with_zip', (SELECT count(*) FROM public.tm_venue_xref WHERE postal_code IS NOT NULL));
END $function$;

REVOKE ALL ON FUNCTION public.tm_venue_geo_tick(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tm_venue_geo_tick(integer) TO service_role;

-- maintenance: fill geo for newly-seen TM venues daily (small batch; the backfill is run by hand)
DO $$ BEGIN
  PERFORM cron.unschedule('tm_venue_geo_daily') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tm_venue_geo_daily');
  PERFORM cron.schedule('tm_venue_geo_daily', '40 11 * * *',
    $cmd$BEGIN; SET LOCAL statement_timeout = '280s'; SELECT public.tm_venue_geo_tick(5000); COMMIT;$cmd$);
END $$;

COMMIT;

-- VERIFY: SELECT public.tm_venue_geo_tick(1500);  -- repeat until remaining=0 (~4,878 venues total).
-- ROLLBACK: DROP FUNCTION tm_venue_geo_tick(integer); ALTER TABLE tm_venue_xref DROP COLUMN latitude, ... ; SELECT cron.unschedule('tm_venue_geo_daily');
