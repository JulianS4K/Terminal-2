-- aq_event_map cross-league guard + comprehensive false-match cleanup
--
-- Follow-up to 20260601173000 (name guard). Comprehensive audit (2026-06-01) found a
-- residual class the name guard cannot catch: same-city cross-LEAGUE collisions where the
-- away side is "TBD" and the home city token matches. Both live cases are Minnesota
-- NBA<->WNBA (Timberwolves placeholder <-> Lynx game). League is the only reliable
-- discriminator, so we add a league guard keyed on event_xref.espn_league.
--
-- Also cleans the 4 PAST name-guard false matches the prior (upcoming-only) cleanup left:
--   Avalanche@Ducks(NHL)->Rangers@Angels(MLB); LA Galaxy@Sounders(MLS)->Padres@Mariners(MLB);
--   TBD@Dallas Stars(NHL)->Demi Lovato; TBD@Avalanche->TBD@Nuggets placeholder collision.
--
-- aq_league_consistent() is PERMISSIVE: returns true unless BOTH a derivable aq league AND a
-- non-NULL event_xref.espn_league exist and disagree. It can only PREVENT cross-league binds,
-- never block a same-league or league-unknown match.
--
-- Not in scope (tracked KANBAN A1-OPS-22): 211 duplicate-row events / 16 with conflicting
-- sg_event_id (mostly main + parking pseudo-event or doubleheaders) — needs a consolidation sweep.
--
-- ## Already applied to prod  Applied via MCP 2026-06-01

-- 1) League-consistency guard ----------------------------------------------
CREATE OR REPLACE FUNCTION public.aq_league_consistent(p_tevo bigint, p_aq_category text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
  WITH aql AS (
    SELECT CASE
      WHEN p_aq_category ~* 'wnba' THEN 'WNBA'
      WHEN p_aq_category ~* 'nba'  THEN 'NBA'
      WHEN p_aq_category ~* 'nfl'  THEN 'NFL'
      WHEN p_aq_category ~* 'nhl|hockey' THEN 'NHL'
      WHEN p_aq_category ~* 'mlb|baseball' THEN 'MLB'
      WHEN p_aq_category ~* 'mls'  THEN 'MLS'
      ELSE NULL END AS lg
  )
  SELECT NOT EXISTS (
    SELECT 1 FROM public.event_xref x, aql
    WHERE x.tevo_event_id = p_tevo AND x.espn_league IS NOT NULL
      AND aql.lg IS NOT NULL
      AND upper(x.espn_league) <> aql.lg
  );
$function$;

-- 2a) resolve_aq_tevo_from_sources: name guard (from prior mig) + league guard ----
CREATE OR REPLACE FUNCTION public.resolve_aq_tevo_from_sources()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  WITH sig AS (
    SELECT o.aq_short_event_id AS aq,
           split_part((o.raw->'venue'->>'name'),' - ',1) AS venue,
           left(o.raw->'event'->>'event_date',19) AS dt
    FROM public.tickpick_orders o
    JOIN public.aq_event_map a ON a.aq_short_event_id = o.aq_short_event_id
    WHERE a.tevo_event_id IS NULL
      AND (o.raw->'event'->>'event_date') IS NOT NULL AND (o.raw->'venue'->>'name') IS NOT NULL
    UNION ALL
    SELECT o.aq_short_event_id,
           split_part(substring(o.raw_xml from '<venue>([^<]+)</venue>'),' - ',1),
           replace(substring(o.raw_xml from '<eventDate>([^<]+)</eventDate>'),' ','T')
    FROM public.vivid_orders o
    JOIN public.aq_event_map a ON a.aq_short_event_id = o.aq_short_event_id
    WHERE a.tevo_event_id IS NULL AND o.raw_xml IS NOT NULL
  ),
  matched AS (
    SELECT s.aq, max(e.id) AS tevo
    FROM sig s
    JOIN public.aq_event_map a2 ON a2.aq_short_event_id = s.aq
    JOIN public.events e ON e.venue_name = s.venue AND left(e.occurs_at_local,19) = s.dt
    WHERE s.venue IS NOT NULL AND s.venue <> '' AND s.dt IS NOT NULL
      AND public.aq_name_consistent(e.name, a2.event_name)
      AND public.aq_league_consistent(e.id, a2.category)
    GROUP BY s.aq HAVING count(DISTINCT e.id) = 1
  )
  UPDATE public.aq_event_map a SET tevo_event_id = m.tevo
  FROM matched m WHERE a.aq_short_event_id = m.aq AND a.tevo_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

-- 2b) backfill_aq_maps: keep step-2 name guard + add league guard to sg->tevo copies (steps 1 & 3)
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
  WHERE e.sg_event_id = aem.sg_event_id
    AND e.tevo_event_id IS NOT NULL AND aem.tevo_event_id IS NULL
    AND public.aq_league_consistent(e.tevo_event_id, aem.category);
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
  WHERE e.sg_event_id = aem.sg_event_id
    AND e.tevo_event_id IS NOT NULL AND aem.tevo_event_id IS NULL
    AND public.aq_league_consistent(e.tevo_event_id, aem.category);

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

-- 3) Comprehensive cleanup: unbind any bound row that is name- OR league-inconsistent (all dates)
UPDATE public.aq_event_map a
SET tevo_event_id = NULL
FROM public.events e
WHERE e.id = a.tevo_event_id
  AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}T'
  AND ( NOT public.aq_name_consistent(e.name, a.event_name)
        OR NOT public.aq_league_consistent(a.tevo_event_id, a.category) );
