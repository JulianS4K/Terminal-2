-- backfill_aq_maps steps 1 & 3 (sg_event_id -> tevo copy): add NAME guard
--
-- Comprehensive audit revealed the deeper root of the MLB/NHL wrong-opponent binds:
-- backfill steps 1 & 3 copy sg_events_canonical.tevo_event_id onto aq_event_map via the
-- sg_event_id link with NO name check. For ~12 rows the aq.sg_event_id is CORRECT but
-- sg_events_canonical.tevo_event_id is itself WRONG (the SG->TEvo matcher mislinked it,
-- e.g. SG "Atlanta Braves at San Francisco Giants" -> tevo "Athletics at San Francisco
-- Giants"). backfill faithfully propagated that error into the canonical hub, re-binding
-- rows the prior migrations had cleaned.
--
-- Defense at this layer: name-guard the sg->tevo copy (steps 1 & 3) so aq_event_map cannot
-- inherit an SG mislink. league guard from 20260601181500 retained; step-2 name guard from
-- 20260601173000 retained.
--
-- Cleanup: unbind name/league-inconsistent tevo bindings (all dates) + null the 2 sg_event_id
-- links that are themselves name-inconsistent (2VD9NWM->BTS, 7Y29744P->Phoenix Mercury).
--
-- UPSTREAM follow-up (KANBAN A1-OPS-23): sg_events_canonical.tevo_event_id carries the SAME
-- false-match disease (SG matcher binds venue+date, wrong opponent). Needs the name/league
-- guard applied to sg_attempt_event_xref_v3 / auto_match_sg_canonical_v3. Out of scope here;
-- this migration only stops aq_event_map from inheriting it.
--
-- ## Already applied to prod  Applied via MCP 2026-06-01

CREATE OR REPLACE FUNCTION public.backfill_aq_maps()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_ev_tevo  int := 0;
  v_ev_sg    int := 0;
  v_ev_vsid  int := 0;
  v_venue    int := 0;
  v_perf     int := 0;
BEGIN
  UPDATE public.aq_event_map aem
  SET tevo_event_id = e.tevo_event_id
  FROM public.sg_events_canonical e
  JOIN public.events ev ON ev.id = e.tevo_event_id
  WHERE e.sg_event_id = aem.sg_event_id
    AND e.tevo_event_id IS NOT NULL AND aem.tevo_event_id IS NULL
    AND public.aq_league_consistent(e.tevo_event_id, aem.category)
    AND public.aq_name_consistent(ev.name, aem.event_name);
  GET DIAGNOSTICS v_ev_tevo = ROW_COUNT;

  UPDATE public.aq_event_map aem
  SET sg_event_id = sub.sg_event_id
  FROM (
    SELECT DISTINCT ON (aem2.aq_short_event_id)
      aem2.aq_short_event_id, e.sg_event_id
    FROM public.aq_event_map aem2
    JOIN public.sg_events_canonical e
      ON lower(trim(e.sg_venue_name)) = lower(trim(aem2.venue_name))
      AND aem2.event_date::timestamptz
          BETWEEN e.sg_datetime_utc - interval '4 hours' AND e.sg_datetime_utc + interval '4 hours'
      AND public.aq_name_consistent(e.sg_event_name, aem2.event_name)
    WHERE aem2.sg_event_id IS NULL AND e.sg_event_id IS NOT NULL
    ORDER BY aem2.aq_short_event_id,
      abs(extract(epoch FROM (aem2.event_date::timestamptz - e.sg_datetime_utc)))
  ) sub
  WHERE aem.aq_short_event_id = sub.aq_short_event_id;
  GET DIAGNOSTICS v_ev_sg = ROW_COUNT;

  UPDATE public.aq_event_map aem
  SET tevo_event_id = e.tevo_event_id
  FROM public.sg_events_canonical e
  JOIN public.events ev ON ev.id = e.tevo_event_id
  WHERE e.sg_event_id = aem.sg_event_id
    AND e.tevo_event_id IS NOT NULL AND aem.tevo_event_id IS NULL
    AND public.aq_league_consistent(e.tevo_event_id, aem.category)
    AND public.aq_name_consistent(ev.name, aem.event_name);

  UPDATE public.aq_event_map aem
  SET venue_short_id = sub.venue_short_id
  FROM (
    SELECT DISTINCT ON (aem2.aq_short_event_id)
      aem2.aq_short_event_id, avm.venue_short_id
    FROM public.aq_event_map aem2
    JOIN public.aq_venue_map avm ON lower(trim(avm.venue_name)) = lower(trim(aem2.venue_name))
    WHERE aem2.venue_short_id IS NULL AND aem2.venue_name IS NOT NULL
    ORDER BY aem2.aq_short_event_id
  ) sub
  WHERE aem.aq_short_event_id = sub.aq_short_event_id;
  GET DIAGNOSTICS v_ev_vsid = ROW_COUNT;

  WITH bpn AS (
    SELECT DISTINCT ON (lower(trim(venue_name)))
      lower(trim(venue_name)) AS vname_lower, venue_id
    FROM (SELECT venue_name, venue_id, COUNT(*) AS n FROM public.events
          WHERE venue_id IS NOT NULL AND venue_name IS NOT NULL
          GROUP BY venue_name, venue_id) cnt
    ORDER BY lower(trim(venue_name)), n DESC, venue_id
  ),
  avail AS (
    SELECT vname_lower, venue_id FROM bpn
    WHERE NOT EXISTS (SELECT 1 FROM public.aq_venue_map ex WHERE ex.tevo_venue_id = bpn.venue_id)
  ),
  bm AS (
    SELECT DISTINCT ON (a.venue_id) avm.venue_short_id, a.venue_id AS tevo_venue_id
    FROM public.aq_venue_map avm
    JOIN avail a ON lower(trim(avm.venue_name)) = a.vname_lower
    WHERE avm.tevo_venue_id IS NULL
    ORDER BY a.venue_id, avm.venue_short_id
  )
  UPDATE public.aq_venue_map avm SET tevo_venue_id = bm.tevo_venue_id
  FROM bm WHERE avm.venue_short_id = bm.venue_short_id;
  GET DIAGNOSTICS v_venue = ROW_COUNT;

  WITH bpn AS (
    SELECT DISTINCT ON (lower(trim(primary_performer_name)))
      lower(trim(primary_performer_name)) AS pname_lower, primary_performer_id AS performer_id
    FROM (SELECT primary_performer_name, primary_performer_id, COUNT(*) AS n FROM public.events
          WHERE primary_performer_id IS NOT NULL AND primary_performer_name IS NOT NULL
          GROUP BY primary_performer_name, primary_performer_id) cnt
    ORDER BY lower(trim(primary_performer_name)), n DESC, primary_performer_id
  ),
  avail AS (
    SELECT pname_lower, performer_id FROM bpn
    WHERE NOT EXISTS (SELECT 1 FROM public.aq_performer_map ex WHERE ex.tevo_performer_id = bpn.performer_id)
  ),
  bm AS (
    SELECT DISTINCT ON (a.performer_id) apm.performer_short_id, a.performer_id AS tevo_performer_id
    FROM public.aq_performer_map apm
    JOIN avail a ON lower(trim(apm.performer_name)) = a.pname_lower
    WHERE apm.tevo_performer_id IS NULL
    ORDER BY a.performer_id, apm.performer_short_id
  )
  UPDATE public.aq_performer_map apm SET tevo_performer_id = bm.tevo_performer_id
  FROM bm WHERE apm.performer_short_id = bm.performer_short_id;
  GET DIAGNOSTICS v_perf = ROW_COUNT;

  RETURN jsonb_build_object(
    'ev_tevo_id',    v_ev_tevo,
    'ev_sg_id',      v_ev_sg,
    'ev_venue_sid',  v_ev_vsid,
    'venue_tevo_id', v_venue,
    'perf_tevo_id',  v_perf
  );
END;
$function$;

-- Cleanup: unbind inconsistent tevo bindings (all dates)
UPDATE public.aq_event_map a
SET tevo_event_id = NULL
FROM public.events e
WHERE e.id = a.tevo_event_id
  AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'
  AND ( NOT public.aq_name_consistent(e.name, a.event_name)
        OR NOT public.aq_league_consistent(a.tevo_event_id, a.category) );

-- Cleanup: null sg_event_id links that are themselves name-inconsistent with the aq row
UPDATE public.aq_event_map a
SET sg_event_id = NULL
FROM public.sg_events_canonical sgc
WHERE sgc.sg_event_id = a.sg_event_id
  AND NOT public.aq_name_consistent(sgc.sg_event_name, a.event_name);
