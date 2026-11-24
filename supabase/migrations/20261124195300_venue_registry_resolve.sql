-- Migration 20261124193000 · level:data-collection · lane:A1 (data plane — cross-source venues) · writes:venue_registry_resolve(),venue_registry_ids() · reads:venue_registry · pre:20261122210000,20261124051000
--
-- Pivot the venue mapper onto the registry, ADDITIVELY. The existing front door venue_map_resolve()
-- (mig 20261122210000) answers "which TEvo venue" and anchors everything on tevo_venue_id. Downstream
-- (events, pricing, venue_assets/weather) still key on tevo_venue_id, so this does NOT repoint them.
-- It adds a registry-anchored front door alongside: venue_registry_resolve() answers "which registry_id",
-- which also covers the 2,470 venues that have NO tevo_venue_id (TM/resale-only) and so cannot be named
-- by the tevo-anchored mapper at all. tevo_venue_id is still returned for compatibility.
--
-- Resolution order: (1) the source's own id against the registry's source-id column; (2) via tevo —
-- delegate to venue_map_resolve(), then tevo -> registry when that tevo is unique in the registry;
-- (3) exact canonical_name + state (+ city when both known), only when that pair is unique.

BEGIN;
SET LOCAL lock_timeout = '10s';

-- source-id lookup support (tm/mlb/axs/tevo already indexed; add the resale columns)
CREATE INDEX IF NOT EXISTS venue_registry_tickpick_idx ON public.venue_registry (tickpick_venue_id) WHERE tickpick_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS venue_registry_vivid_idx    ON public.venue_registry (vivid_venue_id)    WHERE vivid_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS venue_registry_sg_idx       ON public.venue_registry (sg_venue_id)       WHERE sg_venue_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS venue_registry_gt_idx       ON public.venue_registry (gt_venue_key)      WHERE gt_venue_key IS NOT NULL;

CREATE OR REPLACE FUNCTION public.venue_registry_resolve(
  p_source text DEFAULT NULL, p_source_venue_id text DEFAULT NULL,
  p_name text DEFAULT NULL, p_city text DEFAULT NULL, p_state text DEFAULT NULL)
 RETURNS TABLE(registry_id bigint, tevo_venue_id bigint, method text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_src   text := public.mapper_source(p_source);
  v_id    text := nullif(trim(coalesce(p_source_venue_id, '')), '');
  v_idnum bigint := NULL;
  v_name  text := nullif(trim(coalesce(p_name, '')), '');
  v_rid   bigint;
  v_tevo  bigint;
  v_n     int;
BEGIN
  IF p_source IS NOT NULL AND v_src IS NULL THEN
    RAISE EXCEPTION 'venue_registry_resolve: unknown source % (tickpick | vivid | gotickets | seatgeek | axs | mlb | ticketmaster)', p_source;
  END IF;
  IF v_id ~ '^\d+$' THEN v_idnum := v_id::bigint; END IF;

  -- 1. the source's own venue id, straight against the registry's source-id column
  IF v_src IS NOT NULL AND v_id IS NOT NULL THEN
    SELECT r.registry_id, r.tevo_venue_id INTO v_rid, v_tevo
      FROM public.venue_registry r
     WHERE (v_src = 'ticketmaster' AND r.tm_venue_id      = v_id)
        OR (v_src = 'gotickets'    AND r.gt_venue_key     = v_id)
        OR (v_src = 'axs'          AND r.axs_venue_id     = v_idnum)
        OR (v_src = 'tickpick'     AND r.tickpick_venue_id = v_idnum)
        OR (v_src = 'vivid'        AND r.vivid_venue_id    = v_idnum)
        OR (v_src = 'seatgeek'     AND r.sg_venue_id       = v_idnum)
        OR (v_src = 'mlb'          AND r.mlb_venue_id      = v_idnum::int)
     LIMIT 1;
    IF v_rid IS NOT NULL THEN
      registry_id := v_rid; tevo_venue_id := v_tevo; method := 'registry_id'; RETURN NEXT; RETURN;
    END IF;
  END IF;

  -- 2. via tevo: let the existing mapper resolve source -> tevo, then tevo -> registry (only when unique)
  SELECT m.tevo_venue_id INTO v_tevo
    FROM public.venue_map_resolve(p_source, p_source_venue_id, p_name, p_city, p_state) m
   WHERE m.tevo_venue_id IS NOT NULL
   LIMIT 1;
  IF v_tevo IS NOT NULL THEN
    SELECT count(*), min(r.registry_id) INTO v_n, v_rid
      FROM public.venue_registry r WHERE r.tevo_venue_id = v_tevo;
    IF v_n = 1 THEN
      registry_id := v_rid; tevo_venue_id := v_tevo; method := 'tevo'; RETURN NEXT; RETURN;
    END IF;
  END IF;

  -- 3. exact canonical name + state (+ city when both sides have it), only when that pair is unique
  IF v_name IS NOT NULL AND nullif(trim(coalesce(p_state, '')), '') IS NOT NULL THEN
    SELECT count(*), min(r.registry_id), min(r.tevo_venue_id) INTO v_n, v_rid, v_tevo
      FROM public.venue_registry r
     WHERE lower(trim(r.canonical_name)) = lower(v_name)
       AND upper(trim(r.state)) = upper(trim(p_state))
       AND (p_city IS NULL OR r.city IS NULL OR lower(trim(r.city)) = lower(trim(p_city)));
    IF v_n = 1 THEN
      registry_id := v_rid; tevo_venue_id := v_tevo; method := 'name'; RETURN NEXT; RETURN;
    END IF;
  END IF;
  RETURN;
END $function$;

-- reverse front door: a registry row's id on every source
CREATE OR REPLACE FUNCTION public.venue_registry_ids(p_registry_id bigint)
 RETURNS TABLE(registry_id bigint, canonical_name text, city text, state text, country text,
               latitude numeric, longitude numeric, tevo_venue_id bigint, tm_venue_id text,
               axs_venue_id bigint, sg_venue_id bigint, tickpick_venue_id bigint,
               vivid_venue_id bigint, gt_venue_key text, mlb_venue_id integer)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT registry_id, canonical_name, city, state, country, latitude, longitude,
         tevo_venue_id, tm_venue_id, axs_venue_id, sg_venue_id, tickpick_venue_id,
         vivid_venue_id, gt_venue_key, mlb_venue_id
    FROM public.venue_registry WHERE registry_id = p_registry_id;
$function$;

REVOKE ALL ON FUNCTION public.venue_registry_resolve(text,text,text,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_registry_resolve(text,text,text,text,text) TO service_role;
REVOKE ALL ON FUNCTION public.venue_registry_ids(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.venue_registry_ids(bigint) TO service_role;

COMMIT;

-- VERIFY:
--   SELECT * FROM venue_registry_resolve('ticketmaster', '<a no-tevo tm_venue_id>');  -- method registry_id, registry_id set, tevo NULL
--   SELECT * FROM venue_registry_resolve('tickpick', '<tp id>');                       -- method registry_id
--   SELECT * FROM venue_registry_resolve('vivid', NULL, 'Madison Square Garden', 'New York', 'NY'); -- method tevo or name
-- ROLLBACK: DROP FUNCTION venue_registry_resolve(text,text,text,text,text), venue_registry_ids(bigint); drop the 4 indexes.
