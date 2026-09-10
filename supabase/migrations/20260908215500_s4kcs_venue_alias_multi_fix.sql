-- Migration 20260908215500 · level:data-collection · lane:A1 · writes:cross_source_venue_map · reads:s4kcs_orders,events · pre:20260908214500
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. Re-run
-- reported venues_alias_updated 2, recovering exactly the two lost aliases.
-- Verified after: 602 Kia Forum carries ["The Forum","The Kia Forum"] and 43437
-- Las Vegas Strip Autodrome carries ["Las Vegas Street Circuit","Las Vegas Strip
-- Circuit"]; all ten strings resolve to the intended venue.
--
-- CORRECTIVE to 20260908214500. One venue can have MORE THAN ONE alias, and
-- the parent migration silently dropped all but one of them.
--
-- THE BUG. The alias write was:
--     UPDATE cross_source_venue_map m ... FROM _al a
--      WHERE m.tevo_venue_id = a.venue_id AND NOT (m.crm_aliases ? a.vk);
-- In Postgres, when an UPDATE ... FROM join matches a target row against
-- SEVERAL source rows, the target is updated ONCE using an ARBITRARILY CHOSEN
-- source row; the others are discarded without error. Two venues had two
-- aliases each, so two writes vanished:
--     602   Kia Forum                 got "The Forum" — LOST "The Kia Forum"        (137 orders)
--     43437 Las Vegas Strip Autodrome got "Las Vegas Street Circuit"
--                                     — LOST "Las Vegas Strip Circuit"              (35 orders)
-- The run reported `aliases_written 8` against 10 qualifying strings, which is
-- what exposed it. It is silent by construction: no error, no constraint, and
-- the count only looks wrong if you knew the expected number.
--
-- THE FIX. Aggregate to ONE row per venue before updating, so a venue's aliases
-- arrive as a set rather than competing for the same target row. The merge is
-- also made order-independent and duplicate-proof: existing and new aliases are
-- unioned through `jsonb_array_elements` + `DISTINCT`, so re-running cannot
-- append a duplicate and the column never grows unboundedly.
--
-- Everything else is unchanged from the parent: the agreement requirement
-- (`count(DISTINCT venue_id) = 1`), the two-distinct-events floor that
-- deliberately skips ambiguous names like bare "Indian Wells Tennis Garden",
-- the parking exclusions, and the refusal to move an alias another venue
-- already claims.
--
-- Applying this re-runs the derivation and picks up the two lost aliases.
--
-- REVERSIBLE: re-apply the parent migration's function definition.

CREATE OR REPLACE FUNCTION public.s4kcs_venue_alias_derive(p_apply boolean DEFAULT true)
RETURNS TABLE(action text, n integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 's4kcs_venue_alias_derive: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  CREATE TEMP TABLE _al ON COMMIT DROP AS
  WITH obs AS (
    SELECT split_part(s.venue_name, ' - ', 1) AS vk,
           e.venue_id,
           count(DISTINCT s.tevo_event_id) AS n_events
      FROM public.s4kcs_orders s
      JOIN public.events e ON e.id = s.tevo_event_id
     WHERE s.tevo_event_id IS NOT NULL
       AND e.venue_id IS NOT NULL
       AND s.venue_name IS NOT NULL
       AND s.event_name  !~* '^(parking|parking pass)'
       AND s.venue_name NOT ILIKE '%parking%'
     GROUP BY 1, 2
  )
  SELECT vk, min(venue_id) AS venue_id, sum(n_events)::int AS n_events
    FROM obs
   GROUP BY vk
  HAVING count(DISTINCT venue_id) = 1
     AND sum(n_events) >= 2;

  DELETE FROM _al a
   WHERE public.cross_source_venue_resolve(a.vk, NULL, NULL) = a.venue_id;

  SELECT count(*) INTO v_n
    FROM _al a
   WHERE EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                  WHERE m.tevo_venue_id <> a.venue_id
                    AND (m.crm_aliases ? a.vk OR m.sg_aliases ? a.vk
                         OR m.tickpick_aliases ? a.vk OR m.vivid_aliases ? a.vk));
  RETURN QUERY SELECT 'skipped_alias_claimed_elsewhere'::text, v_n;
  DELETE FROM _al a
   WHERE EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                  WHERE m.tevo_venue_id <> a.venue_id
                    AND (m.crm_aliases ? a.vk OR m.sg_aliases ? a.vk
                         OR m.tickpick_aliases ? a.vk OR m.vivid_aliases ? a.vk));

  IF NOT p_apply THEN
    RETURN QUERY SELECT 'would_write'::text, (SELECT count(*)::int FROM _al);
    RETURN;
  END IF;

  INSERT INTO public.cross_source_venue_map
        (tevo_venue_id, tevo_venue_name, tevo_venue_location, state)
  SELECT DISTINCT ON (e.venue_id) e.venue_id, e.venue_name, e.venue_location, e.state
    FROM public.events e
    JOIN _al a ON a.venue_id = e.venue_id
   WHERE e.venue_name IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                      WHERE m.tevo_venue_id = e.venue_id)
   ORDER BY e.venue_id, e.id DESC
  ON CONFLICT (tevo_venue_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venues_inserted'::text, v_n;

  -- ONE row per venue. Without this GROUP BY, a venue with two aliases keeps
  -- only one of them — see header.
  WITH agg AS (
    SELECT venue_id, jsonb_agg(DISTINCT vk) AS new_aliases
      FROM _al GROUP BY venue_id
  )
  UPDATE public.cross_source_venue_map m
     SET crm_aliases = COALESCE(
           (SELECT jsonb_agg(DISTINCT x)
              FROM jsonb_array_elements(m.crm_aliases || agg.new_aliases) x),
           '[]'::jsonb),
         id_provenance = m.id_provenance || jsonb_build_object('crm_aliases',
           jsonb_build_object('method','order_venue_agreement','derived_at',now())),
         updated_at = now()
    FROM agg
   WHERE m.tevo_venue_id = agg.venue_id
     AND NOT (m.crm_aliases @> agg.new_aliases);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'venues_alias_updated'::text, v_n;

  RETURN QUERY SELECT 'aliases_pending_total'::text, (SELECT count(*)::int FROM _al);
END $function$;

REVOKE ALL ON FUNCTION public.s4kcs_venue_alias_derive(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.s4kcs_venue_alias_derive(boolean) TO service_role;
