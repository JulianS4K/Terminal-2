-- Migration 20260908203500 · level:data-collection · lane:A1 · writes:cross_source_venue_map · reads:gotickets_event,events,sg_events_canonical,tickpick_orders · pre:20260908202400
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. The
-- re-run corrected 47 alias sets and touched no ids (0 refills — the id logic is
-- unchanged and fill-only). Verified the two named cases: tevo 5725 Yankee
-- Stadium is now ["Yankee Stadium"] and tevo 414 is ["Uniqlo Field at Dodger
-- Stadium", "Uniqlo Field at Dodger Stadium Parking"], while tevo 488 correctly
-- KEEPS "Fenway Park Parking" — the guard drops wrong venues, not real variants.
--
-- CORRECTIVE to 20260908202400. Guard the GoTickets alias derivation.
--
-- WHAT WENT WRONG. The id derivations in the parent migration require every
-- observation for a venue to agree (`HAVING count(DISTINCT ...) = 1`), so a
-- single mis-mapped event cannot write an id. The GoTickets ALIAS block had no
-- such guard — it did a bare `jsonb_agg(DISTINCT g.venue_name)` over every GT
-- event carrying that tevo_event_id. GoTickets' own event→TEvo mapping has
-- errors, and those errors flowed straight into the alias set:
--     tevo 5725 "Yankee Stadium"                  <- "Woodbridge Center Lot"
--     tevo  414 "Uniqlo Field at Dodger Stadium"  <- "Boxing and Tennis Stadium
--                                                    at Dignity Health Sports Park"
-- An alias list is a venue-identity claim. A wrong entry there is worse than an
-- empty list, because the next name-matching consumer will believe it.
--
-- THE GUARD. Keep a GT name only if it shares a >=4-char token with the TEvo
-- venue name, EXCLUDING generic venue words. The stop-list is load-bearing: on
-- a bare token overlap "Boxing and Tennis Stadium at Dignity Health Sports
-- Park" and "Uniqlo Field at Dodger Stadium" share "stadium" and the bad alias
-- survives. With generic words removed they share nothing and it is rejected,
-- while real variants still pass on their distinctive token:
--     "Fenway Park Parking"                    keeps on "fenway"
--     "Uniqlo Field at Dodger Stadium Parking" keeps on "uniqlo"/"dodger"
--     "Woodbridge Center Lot" vs "Yankee Stadium"  -> no shared token, rejected
--
-- MEASURED (2026-09-08): 456 distinct (venue, GT name) pairs, 383 kept across
-- 369 venues, 73 rejected — 16% of the alias set was contaminated.
--
-- The rewrite is a full replacement rather than fill-only: a venue whose every
-- alias is now rejected must go back to '[]', so the update covers rows that
-- currently hold a non-empty set as well as rows in the new derivation. Nothing
-- hand-seeded is at risk — gotickets_aliases was created by the parent
-- migration and has only ever been written by this function.
--
-- The SeatGeek/TickPick id logic is byte-identical to the parent migration.
--
-- REVERSIBLE: re-apply the parent migration's function definition.

CREATE OR REPLACE FUNCTION public.venue_xref_derive_from_events(p_apply boolean DEFAULT true)
RETURNS TABLE(source text, action text, n integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer; v_conflicts integer := 0;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'venue_xref_derive_from_events: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  CREATE TEMP TABLE _sg ON COMMIT DROP AS
    SELECT e.venue_id AS tevo_venue_id,
           min((sgc.raw_event_jsonb->'venue'->>'id')::bigint) AS mp_id,
           count(*)::int AS ev
      FROM public.sg_events_canonical sgc
      JOIN public.events e ON e.id = sgc.tevo_event_id
     WHERE sgc.tevo_event_id IS NOT NULL AND e.venue_id IS NOT NULL
       AND sgc.raw_event_jsonb->'venue'->>'id' ~ '^[0-9]+$'
     GROUP BY e.venue_id
    HAVING count(DISTINCT (sgc.raw_event_jsonb->'venue'->>'id')::bigint) = 1;

  CREATE TEMP TABLE _tp ON COMMIT DROP AS
    SELECT e.venue_id AS tevo_venue_id,
           min((o.raw->'venue'->>'id')::bigint) AS mp_id,
           count(*)::int AS ev
      FROM public.tickpick_orders o
      JOIN public.events e ON e.id = o.tevo_event_id
     WHERE o.tevo_event_id IS NOT NULL AND e.venue_id IS NOT NULL
       AND o.raw->'venue'->>'id' ~ '^[0-9]+$'
     GROUP BY e.venue_id
    HAVING count(DISTINCT (o.raw->'venue'->>'id')::bigint) = 1;

  SELECT count(*) INTO v_conflicts
    FROM (
      SELECT 1 FROM _sg s JOIN public.cross_source_venue_map m USING (tevo_venue_id)
        WHERE m.sg_venue_id IS NOT NULL AND m.sg_venue_id <> s.mp_id
      UNION ALL
      SELECT 1 FROM _tp t JOIN public.cross_source_venue_map m USING (tevo_venue_id)
        WHERE m.tickpick_venue_id IS NOT NULL AND m.tickpick_venue_id <> t.mp_id
    ) c;

  IF NOT p_apply THEN
    RETURN QUERY SELECT 'seatgeek'::text, 'derivable'::text, (SELECT count(*)::int FROM _sg);
    RETURN QUERY SELECT 'tickpick'::text, 'derivable'::text, (SELECT count(*)::int FROM _tp);
    RETURN QUERY SELECT 'all'::text,      'conflicts'::text, v_conflicts;
    RETURN;
  END IF;

  WITH need AS (
    SELECT tevo_venue_id FROM _sg UNION SELECT tevo_venue_id FROM _tp
  ), src AS (
    SELECT DISTINCT ON (e.venue_id)
           e.venue_id AS tevo_venue_id, e.venue_name, e.venue_location, e.state
      FROM public.events e JOIN need n ON n.tevo_venue_id = e.venue_id
     WHERE e.venue_name IS NOT NULL
     ORDER BY e.venue_id, e.id DESC
  )
  INSERT INTO public.cross_source_venue_map
        (tevo_venue_id, tevo_venue_name, tevo_venue_location, state)
  SELECT s.tevo_venue_id, s.venue_name, s.venue_location, s.state
    FROM src s
   WHERE NOT EXISTS (SELECT 1 FROM public.cross_source_venue_map m
                      WHERE m.tevo_venue_id = s.tevo_venue_id)
  ON CONFLICT (tevo_venue_id) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'all'::text, 'venues_inserted'::text, v_n;

  UPDATE public.cross_source_venue_map m
     SET sg_venue_id = s.mp_id,
         id_provenance = m.id_provenance || jsonb_build_object('sg',
           jsonb_build_object('method','event_agreement','events',s.ev,'derived_at',now())),
         updated_at = now()
    FROM _sg s
   WHERE m.tevo_venue_id = s.tevo_venue_id AND m.sg_venue_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'seatgeek'::text, 'ids_filled'::text, v_n;

  UPDATE public.cross_source_venue_map m
     SET tickpick_venue_id = t.mp_id,
         id_provenance = m.id_provenance || jsonb_build_object('tickpick',
           jsonb_build_object('method','event_agreement','events',t.ev,'derived_at',now())),
         updated_at = now()
    FROM _tp t
   WHERE m.tevo_venue_id = t.tevo_venue_id AND m.tickpick_venue_id IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'tickpick'::text, 'ids_filled'::text, v_n;

  -- GoTickets NAME aliases, guarded (see header). Full replacement so a venue
  -- whose aliases are all rejected returns to '[]'.
  WITH gt AS (
    SELECT e.venue_id AS tevo_venue_id, jsonb_agg(DISTINCT g.venue_name) AS aliases
      FROM public.gotickets_event g
      JOIN public.events e ON e.id = g.tevo_event_id
     WHERE g.tevo_event_id IS NOT NULL AND e.venue_id IS NOT NULL
       AND g.venue_name IS NOT NULL AND g.venue_name <> ''
       AND e.venue_name IS NOT NULL
       AND EXISTS (
         SELECT 1
           FROM unnest(regexp_split_to_array(
                  regexp_replace(lower(g.venue_name), '[^a-z0-9]+', ' ', 'g'), '\s+')) tok
          WHERE length(tok) >= 4
            AND tok NOT IN ('stadium','park','arena','center','centre','field','theatre',
                            'theater','hall','parking','coliseum','pavilion','amphitheatre',
                            'amphitheater','garden','gardens','court','courts','sports',
                            'complex','grounds','club')
            AND tok = ANY(regexp_split_to_array(
                  regexp_replace(lower(e.venue_name), '[^a-z0-9]+', ' ', 'g'), '\s+'))
       )
     GROUP BY e.venue_id
  ), target AS (
    SELECT tevo_venue_id FROM public.cross_source_venue_map WHERE gotickets_aliases <> '[]'::jsonb
    UNION
    SELECT tevo_venue_id FROM gt
  )
  UPDATE public.cross_source_venue_map m
     SET gotickets_aliases = coalesce(gt.aliases, '[]'::jsonb), updated_at = now()
    FROM target t LEFT JOIN gt ON gt.tevo_venue_id = t.tevo_venue_id
   WHERE m.tevo_venue_id = t.tevo_venue_id
     AND m.gotickets_aliases IS DISTINCT FROM coalesce(gt.aliases, '[]'::jsonb);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'gotickets'::text, 'aliases_set'::text, v_n;

  RETURN QUERY SELECT 'all'::text, 'conflicts_not_overwritten'::text, v_conflicts;

  IF v_conflicts > 0 THEN
    PERFORM public.bot_chat_log(
      p_level      => 'data-collection',
      p_lane       => 'A1',
      p_event_type => 'flag',
      p_message    => format('venue_xref_derive_from_events: %s marketplace venue id(s) '
                          || 'disagree with a value already in cross_source_venue_map. The existing '
                          || 'value was KEPT. Adjudicate before trusting either.', v_conflicts));
  END IF;
END $function$;

REVOKE ALL ON FUNCTION public.venue_xref_derive_from_events(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.venue_xref_derive_from_events(boolean) TO service_role;
