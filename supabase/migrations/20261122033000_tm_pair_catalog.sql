-- Migration 20261122033000 · level:data-collection · lane:A1 (data plane — mapping program) · writes:tm_pair_catalog()(new),cron:tm_pair_catalog_hourly(new) · reads:tm_discovery_event,vivid_catalog_venue,tickpick_catalog_venue,axs_export_event,performer_metadata,aq_performer_map,seatgeek_performer_xref,events · pre:20261122015530
--
-- Operator 2026-11-22: "Focus on updating venue and performer mappers" for the Ticketmaster catalogue.
--
-- TM venue + performer pairing today lives in tm_discovery_match and is thin:
--   * venues: one rule (equal normalised name + same city/state, unique) + learn-from-matched-events → 2,823/4,878.
--   * performers: ONE rule, matched against aq_performer_map — which yields ZERO unique matches on prod
--     (that table's performer_name is not a usable reference here) → 336/14,680 (2%).
-- The real TEvo performer reference is performer_metadata (17,147 performers); matching TM attraction names to it
-- pairs 6,523 at once. The sibling catalogues (Vivid / TickPick / AXS) have already resolved 557 of the TM venues
-- that tm_discovery_match leaves unpaired.
--
-- This adds tm_pair_catalog(p_apply): an additive, FILL-ONLY, audited pass that only ever sets a NULL xref, never
-- overwrites tm_discovery_match's work. It complements that function rather than replacing it.
--   VENUES     — sibling_catalog: a TM venue takes the TEvo venue that Vivid / TickPick / AXS already resolved for
--                the same normalised name in the same city + state, when that is unique.
--   PERFORMERS — name_metadata: TM attraction name → TEvo performer by normalised name, unique, across
--                performer_metadata ∪ aq_performer_map ∪ seatgeek_performer_xref.
--              — matched_events: a TM event already matched to a TEvo event, with a single attraction and a single
--                TEvo primary performer across ≥2 such events → learn that attraction's performer.
-- p_apply=false is a dry run: it reports what it would pair and writes nothing. GET only upstream is not touched.

BEGIN;
SET LOCAL lock_timeout = '10s';

CREATE OR REPLACE FUNCTION public.tm_pair_catalog(p_apply boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
 SET client_min_messages TO 'warning'
AS $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_v int := 0; v_pn int := 0; v_pl int := 0;
BEGIN
  IF NOT pg_try_advisory_xact_lock(hashtext('tm_pair_catalog')) THEN
    RETURN jsonb_build_object('skipped', 'another tm_pair_catalog is running');
  END IF;

  -- make sure every catalogue venue / attraction has an xref row to fill (same seed tm_discovery_match uses)
  INSERT INTO public.tm_venue_xref (tm_venue_id, name, city, state, country)
  SELECT DISTINCT ON (tm_venue_id) tm_venue_id, venue_name, venue_city, venue_state, venue_country
    FROM public.tm_discovery_event WHERE tm_venue_id IS NOT NULL ORDER BY tm_venue_id, last_seen_at DESC
  ON CONFLICT (tm_venue_id) DO NOTHING;
  INSERT INTO public.tm_attraction_xref (tm_attraction_id, name)
  SELECT DISTINCT a->>'id', a->>'name'
    FROM public.tm_discovery_event d, jsonb_array_elements(coalesce(d.attractions, '[]'::jsonb)) a
   WHERE coalesce(a->>'id', '') <> ''
  ON CONFLICT (tm_attraction_id) DO NOTHING;

  -- ---- VENUE picks: the sibling catalogues' resolved TEvo venue, unique by norm+city+state ----
  DROP TABLE IF EXISTS _tp_vpick;
  CREATE TEMP TABLE _tp_vpick ON COMMIT DROP AS
  WITH sib AS (
    SELECT public.catalog_venue_norm(name, city, state, true) AS norm,
           lower(trim(city)) AS city, upper(trim(state)) AS st,
           min(tevo_venue_id) AS tevo_venue_id, count(DISTINCT tevo_venue_id) AS n
      FROM ( SELECT name, city, state, tevo_venue_id FROM public.vivid_catalog_venue WHERE tevo_venue_id IS NOT NULL
             UNION ALL SELECT name, city, state, tevo_venue_id FROM public.tickpick_catalog_venue WHERE tevo_venue_id IS NOT NULL
             UNION ALL SELECT venue_name, venue_city, venue_state, tevo_venue_id FROM public.axs_export_event
                        WHERE tevo_venue_id IS NOT NULL AND gone_at IS NULL ) z
     WHERE coalesce(state, '') <> '' AND coalesce(name, '') <> ''
     GROUP BY 1, 2, 3)
  SELECT x.tm_venue_id, s.tevo_venue_id
    FROM public.tm_venue_xref x
    JOIN sib s ON s.n = 1 AND s.norm <> '' AND s.st = upper(trim(x.state)) AND s.city = lower(trim(x.city))
              AND s.norm = public.catalog_venue_norm(x.name, x.city, x.state, true)
   WHERE x.tevo_venue_id IS NULL AND coalesce(x.state, '') <> '' AND coalesce(x.country, 'US') IN ('US', 'CA', 'MX');

  -- ---- PERFORMER picks (name): TM attraction name → TEvo performer, unique across the three references ----
  DROP TABLE IF EXISTS _tp_ppick;
  CREATE TEMP TABLE _tp_ppick ON COMMIT DROP AS
  WITH ref AS (
    SELECT nm, min(pid) AS pid, count(DISTINCT pid) AS n FROM (
      SELECT public.event_mapper_norm_name(name) AS nm, performer_id AS pid FROM public.performer_metadata WHERE coalesce(name, '') <> ''
      UNION SELECT public.event_mapper_norm_name(performer_name), tevo_performer_id FROM public.aq_performer_map WHERE tevo_performer_id IS NOT NULL AND coalesce(performer_name, '') <> ''
      UNION SELECT public.event_mapper_norm_name(sg_performer_name), tevo_performer_id FROM public.seatgeek_performer_xref WHERE tevo_performer_id IS NOT NULL AND coalesce(sg_performer_name, '') <> ''
    ) z WHERE nm <> '' GROUP BY nm)
  SELECT x.tm_attraction_id, r.pid AS tevo_performer_id
    FROM public.tm_attraction_xref x
    JOIN ref r ON r.n = 1 AND r.nm = public.event_mapper_norm_name(x.name)
   WHERE x.tevo_performer_id IS NULL AND coalesce(x.name, '') <> '';

  -- ---- PERFORMER picks (learned): single-attraction TM events matched to a TEvo event with one primary performer ----
  DROP TABLE IF EXISTS _tp_lpick;
  CREATE TEMP TABLE _tp_lpick ON COMMIT DROP AS
  WITH learn AS (
    SELECT d.attractions->0->>'id' AS aid, min(e.primary_performer_id) AS pid, count(DISTINCT e.primary_performer_id) AS n
      FROM public.tm_discovery_event d JOIN public.events e ON e.id = d.tevo_event_id
     WHERE d.tevo_event_id IS NOT NULL AND jsonb_array_length(coalesce(d.attractions, '[]'::jsonb)) = 1
       AND e.primary_performer_id IS NOT NULL AND coalesce(d.attractions->0->>'id', '') <> ''
     GROUP BY 1 HAVING count(DISTINCT e.primary_performer_id) = 1 AND count(*) >= 2)
  SELECT l.aid AS tm_attraction_id, l.pid AS tevo_performer_id
    FROM learn l JOIN public.tm_attraction_xref x ON x.tm_attraction_id = l.aid
   WHERE x.tevo_performer_id IS NULL AND NOT EXISTS (SELECT 1 FROM _tp_ppick p WHERE p.tm_attraction_id = l.aid);

  IF p_apply THEN
    WITH upd AS (
      UPDATE public.tm_venue_xref x SET tevo_venue_id = v.tevo_venue_id, method = 'sibling_catalog', derived_at = now()
        FROM _tp_vpick v WHERE v.tm_venue_id = x.tm_venue_id AND x.tevo_venue_id IS NULL
      RETURNING x.tm_venue_id, x.tevo_venue_id)
    INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'venue_xref', 'tm_venue_xref', u.tm_venue_id, 'tevo_venue ' || u.tevo_venue_id || ' via sibling_catalog' FROM upd u;
    GET DIAGNOSTICS v_v = ROW_COUNT;

    WITH upd AS (
      UPDATE public.tm_attraction_xref x SET tevo_performer_id = p.tevo_performer_id, method = 'name_metadata', derived_at = now()
        FROM _tp_ppick p WHERE p.tm_attraction_id = x.tm_attraction_id AND x.tevo_performer_id IS NULL
      RETURNING x.tm_attraction_id, x.tevo_performer_id)
    INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'attraction_xref', 'tm_attraction_xref', u.tm_attraction_id, 'tevo_performer ' || u.tevo_performer_id || ' via name_metadata' FROM upd u;
    GET DIAGNOSTICS v_pn = ROW_COUNT;

    WITH upd AS (
      UPDATE public.tm_attraction_xref x SET tevo_performer_id = p.tevo_performer_id, method = 'matched_events', derived_at = now()
        FROM _tp_lpick p WHERE p.tm_attraction_id = x.tm_attraction_id AND x.tevo_performer_id IS NULL
      RETURNING x.tm_attraction_id, x.tevo_performer_id)
    INSERT INTO public.tm_discovery_audit (run_id, action, target, target_key, note)
    SELECT v_run, 'attraction_xref', 'tm_attraction_xref', u.tm_attraction_id, 'tevo_performer ' || u.tevo_performer_id || ' via matched_events' FROM upd u;
    GET DIAGNOSTICS v_pl = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'run_id', v_run, 'applied', p_apply,
    'venues_would_pair', (SELECT count(*) FROM _tp_vpick),
    'performers_would_pair_name', (SELECT count(*) FROM _tp_ppick),
    'performers_would_pair_learned', (SELECT count(*) FROM _tp_lpick),
    'venues_written', v_v, 'performers_written_name', v_pn, 'performers_written_learned', v_pl,
    'venue_total', (SELECT count(*) FILTER (WHERE tevo_venue_id IS NOT NULL) || '/' || count(*) FROM public.tm_venue_xref),
    'performer_total', (SELECT count(*) FILTER (WHERE tevo_performer_id IS NOT NULL) || '/' || count(*) FROM public.tm_attraction_xref));
END $function$;

REVOKE ALL ON FUNCTION public.tm_pair_catalog(boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.tm_pair_catalog(boolean) TO service_role;

DO $$ BEGIN
  PERFORM cron.unschedule('tm_pair_catalog_hourly') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'tm_pair_catalog_hourly');
  PERFORM cron.schedule('tm_pair_catalog_hourly', '15 * * * *',
    $cmd$BEGIN; SET LOCAL statement_timeout = '300s'; SELECT public.tm_pair_catalog(true); COMMIT;$cmd$);
END $$;

COMMIT;

-- VERIFY (dry run, then the hourly cron at :15 or a manual apply backfills):
--   SELECT public.tm_pair_catalog(false);   -- venues_would_pair ~557, performers_would_pair_name ~6500
--   SELECT count(*) FILTER (WHERE tevo_venue_id IS NOT NULL)||'/'||count(*) FROM tm_venue_xref;
--   SELECT count(*) FILTER (WHERE tevo_performer_id IS NOT NULL)||'/'||count(*) FROM tm_attraction_xref;
-- ROLLBACK: SELECT cron.unschedule('tm_pair_catalog_hourly'); DROP FUNCTION public.tm_pair_catalog(boolean);
--   (xref rows it set carry method IN ('sibling_catalog','name_metadata','matched_events') if a revert must unset them.)
