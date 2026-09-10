-- Migration 20260908202400 · level:data-collection · lane:A1 · writes:cross_source_venue_map,cron.job · reads:events,sg_events_canonical,tickpick_orders,gotickets_event · pre:20260908195605
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction. Dry run
-- (p_apply=false) returned seatgeek 853 / tickpick 146 / conflicts 0; the apply
-- run returned venues_inserted 13, seatgeek ids_filled 846, tickpick ids_filled 4,
-- gotickets aliases_set 384, conflicts_not_overwritten 0. Spot-checked:
-- Fenway Park -> sg 21 / tp 273, Wrigley Field -> sg 11, Yankee Stadium -> sg 8.
-- NOTE the GoTickets alias block shipped here is superseded by the corrective
-- mig 20260908203500 — see that file. Re-running is idempotent (fill-only).
--
-- Cross-marketplace VENUE ID xref: derive venue identity from events we have
-- ALREADY matched, instead of matching venue names to each other.
--
-- WHY NOT A NEW TABLE. There are already six venue-xref surfaces, all partial:
--     cross_source_venue_map  1,246 rows · tevo 1,246 · sg 7    · tickpick 164
--     entity_venue_map        1,276 rows · tevo 1,276 · sg NAME only
--     aq_venue_map              712 rows · tevo 303   · sg 23   · tickpick 134
--     seatgeek_venue_xref        38 rows
--     seatdata_venue_xref         0 rows (empty)
--     v_canonical_venue        (view over entity_venue_map)
-- A seventh would be the drift generator, not the fix. cross_source_venue_map
-- is already keyed PRIMARY KEY (tevo_venue_id) and already carries
-- sg_venue_id / tickpick_venue_id / *_aliases — it IS the venue xref, it was
-- just never populated on the marketplace side. It is also the table
-- cross_source_venue_resolve() reads, and therefore what the AQ→TEvo bridge
-- resolves against, so filling it improves mapping immediately. Populate the
-- home that exists; do not open a rival. (v_canonical_venue's sg_venue_id is a
-- correlated subquery on lower(sg_venue_name) = lower(tevo_venue_name) — exact
-- name equality, the very failure mode this migration exists to avoid.)
--
-- THE UNLOCK. sg_events_canonical.sg_venue_id is populated on 114 of 12,767
-- rows, but the RAW payload carries a venue id on 8,148 rows across 1,293
-- distinct SeatGeek venues — the column was never backfilled from
-- raw_event_jsonb->'venue'->>'id'. 8,652 of those rows already carry a
-- tevo_event_id. So for every such event we hold BOTH marketplaces' venue ids
-- for the same physical venue, as an observation rather than a guess.
--
-- METHOD: identity by event agreement, not by name. For each tevo_venue_id,
-- collect the marketplace venue ids seen on events already mapped to it, and
-- accept only where every observation agrees (count(DISTINCT) = 1). This never
-- compares two venue strings, so none of the alias problems that block the
-- rest of this pipeline ("The Forum"/"Kia Forum") apply.
--
-- MEASURED (2026-09-08, dry run):
--   SeatGeek  853 unambiguous pairs (38 ambiguous, excluded) from 5,506 events
--             → 13 new rows, 833 fill an existing NULL, 7 agree, 0 CONFLICTS
--   TickPick  146 unambiguous pairs (3 ambiguous, excluded) from 2,058 orders
--             → 0 new rows, 4 fill a NULL, 142 agree, 0 CONFLICTS
-- The TickPick number is the validation that matters: the derivation
-- independently reproduces 142 of the 146 hand-built TickPick mappings and
-- contradicts none of them. SeatGeek goes 7 → 853, a 120x increase, from data
-- already on disk and zero API calls.
--
-- WHAT IS NOT DERIVABLE, and why the table stays honest about it:
--   * Vivid   — vivid_orders.raw_xml contains NO <venueId> element (checked:
--               0 of the book). Vivid publishes venue NAMES to us, not ids.
--               vivid_aliases (229 rows) stays the representation.
--   * GoTickets — gotickets_event has venue_name/city/state and NO venue id
--               column at all. But it does carry tevo_event_id, so the same
--               event-agreement method yields venue NAME aliases per
--               tevo_venue_id. Those go to the new gotickets_aliases column.
-- Recording an id we do not have would be worse than a NULL, so neither gets
-- a fabricated id column.
--
-- SAFETY. Every write is fill-only: a marketplace id is set ONLY where the
-- column IS NULL. An existing non-NULL that disagrees is never overwritten —
-- it is counted and reported as a conflict for a human to adjudicate. There
-- are 0 of those today, and the function is written so that if that ever
-- changes, the pre-existing value wins and the conflict surfaces rather than
-- being silently clobbered.
--
-- GENERATED COLUMNS: canonical_name and sources_count are GENERATED ALWAYS —
-- they must never appear in an INSERT column list (this bites; it bit the Gies
-- seed in mig 20260908184118). Note sources_count counts *_aliases, not ids,
-- so it deliberately does not move when an id is filled.
--
-- REVERSIBLE:
--   SELECT cron.unschedule('venue_xref_derive_daily');
--   UPDATE public.cross_source_venue_map
--      SET sg_venue_id = NULL WHERE id_provenance ? 'sg';
--   UPDATE public.cross_source_venue_map
--      SET tickpick_venue_id = NULL WHERE id_provenance ? 'tickpick';
-- (id_provenance records exactly which ids this function wrote, so a revert
-- cannot take out a hand-seeded value.)

ALTER TABLE public.cross_source_venue_map
  ADD COLUMN IF NOT EXISTS gotickets_aliases jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS id_provenance     jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.cross_source_venue_map.id_provenance IS
  'Per-source {method, events, derived_at} for ids written by venue_xref_derive_from_events(). Absent key = the id was seeded some other way; a revert must not touch those.';
COMMENT ON COLUMN public.cross_source_venue_map.gotickets_aliases IS
  'GoTickets venue NAME variants seen on events mapped to this tevo_venue_id. GoTickets publishes no venue id, so there is deliberately no gotickets_venue_id column.';

CREATE OR REPLACE FUNCTION public.venue_xref_derive_from_events(p_apply boolean DEFAULT true)
RETURNS TABLE(source text, action text, n integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_n integer; v_conflicts integer := 0; v_txt text;
BEGIN
  IF current_user NOT IN ('service_role', 'postgres', 'supabase_admin') THEN
    RAISE EXCEPTION 'venue_xref_derive_from_events: caller % not authorized', current_user
      USING ERRCODE = '42501';
  END IF;

  -- Marketplace venue ids observed on events already mapped to a TEvo venue.
  -- Accepted only where every observation for that venue agrees.
  CREATE TEMP TABLE _sg ON COMMIT DROP AS
    SELECT e.venue_id AS tevo_venue_id,
           min((sgc.raw_event_jsonb->'venue'->>'id')::bigint) AS mp_id,
           count(*)::int AS ev
      FROM public.sg_events_canonical sgc
      JOIN public.events e ON e.id = sgc.tevo_event_id
     WHERE sgc.tevo_event_id IS NOT NULL
       AND e.venue_id IS NOT NULL
       AND sgc.raw_event_jsonb->'venue'->>'id' ~ '^[0-9]+$'
     GROUP BY e.venue_id
    HAVING count(DISTINCT (sgc.raw_event_jsonb->'venue'->>'id')::bigint) = 1;

  CREATE TEMP TABLE _tp ON COMMIT DROP AS
    SELECT e.venue_id AS tevo_venue_id,
           min((o.raw->'venue'->>'id')::bigint) AS mp_id,
           count(*)::int AS ev
      FROM public.tickpick_orders o
      JOIN public.events e ON e.id = o.tevo_event_id
     WHERE o.tevo_event_id IS NOT NULL
       AND e.venue_id IS NOT NULL
       AND o.raw->'venue'->>'id' ~ '^[0-9]+$'
     GROUP BY e.venue_id
    HAVING count(DISTINCT (o.raw->'venue'->>'id')::bigint) = 1;

  -- A pre-existing id that disagrees is NEVER overwritten — report it instead.
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

  -- New venues. canonical_name / sources_count are GENERATED — never listed.
  WITH need AS (
    SELECT tevo_venue_id FROM _sg
    UNION
    SELECT tevo_venue_id FROM _tp
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
   WHERE m.tevo_venue_id = s.tevo_venue_id
     AND m.sg_venue_id IS NULL;          -- fill-only
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'seatgeek'::text, 'ids_filled'::text, v_n;

  UPDATE public.cross_source_venue_map m
     SET tickpick_venue_id = t.mp_id,
         id_provenance = m.id_provenance || jsonb_build_object('tickpick',
           jsonb_build_object('method','event_agreement','events',t.ev,'derived_at',now())),
         updated_at = now()
    FROM _tp t
   WHERE m.tevo_venue_id = t.tevo_venue_id
     AND m.tickpick_venue_id IS NULL;    -- fill-only
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN QUERY SELECT 'tickpick'::text, 'ids_filled'::text, v_n;

  -- GoTickets publishes no venue id — collect NAME aliases by the same
  -- event-agreement route so the row still says what GT calls this venue.
  WITH gt AS (
    SELECT e.venue_id AS tevo_venue_id,
           jsonb_agg(DISTINCT g.venue_name) AS aliases
      FROM public.gotickets_event g
      JOIN public.events e ON e.id = g.tevo_event_id
     WHERE g.tevo_event_id IS NOT NULL AND e.venue_id IS NOT NULL
       AND g.venue_name IS NOT NULL AND g.venue_name <> ''
     GROUP BY e.venue_id
  )
  UPDATE public.cross_source_venue_map m
     SET gotickets_aliases = gt.aliases, updated_at = now()
    FROM gt
   WHERE m.tevo_venue_id = gt.tevo_venue_id
     AND m.gotickets_aliases IS DISTINCT FROM gt.aliases;
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

-- The readable cross-marketplace view. Ids where the marketplace publishes
-- one, names where it does not — the shape is the honest state of the data.
CREATE OR REPLACE VIEW public.v_marketplace_venue_xref AS
SELECT m.tevo_venue_id,
       m.tevo_venue_name,
       m.canonical_name,
       m.city, m.state, m.country,
       m.sg_venue_id,
       m.tickpick_venue_id,
       m.sg_aliases,
       m.tickpick_aliases,
       m.vivid_aliases,        -- Vivid publishes no venue id (no <venueId> in the XML)
       m.gotickets_aliases,    -- GoTickets publishes no venue id
       (m.sg_venue_id IS NOT NULL)::int + (m.tickpick_venue_id IS NOT NULL)::int
         AS marketplace_ids_known,
       m.id_provenance,
       m.updated_at
  FROM public.cross_source_venue_map m;

COMMENT ON VIEW public.v_marketplace_venue_xref IS
  'Cross-marketplace venue xref keyed on tevo_venue_id. Ids are derived by EVENT AGREEMENT (venue ids seen on events already mapped to this TEvo venue, accepted only when every observation agrees) — never by comparing venue name strings. Vivid and GoTickets publish no venue id to us, so they appear as name aliases only.';

SELECT cron.schedule(
  'venue_xref_derive_daily',
  '23 6 * * *',
  $cron$
  SET statement_timeout='300s';
  SELECT public.venue_xref_derive_from_events(true);
  $cron$
);
