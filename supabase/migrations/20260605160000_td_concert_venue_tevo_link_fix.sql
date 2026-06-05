-- ============================================================================
-- MIG 20260605160000 — TD concert venue: follow direct tevo_event_id link
--
-- Fixes a gap in mig 20260605140000. The concert_venues CTE in
-- td_target_events() reached aq_event_map only via
-- sg_events_canonical → aq_event_map.sg_event_id. But 19 of the concert
-- events are aq_curated rows linked DIRECTLY by aq_event_map.tevo_event_id
-- with sg_event_id = NULL (and sh_event_id/vivid_event_id already populated).
-- The sg-only join silently skipped them.
--
-- No AQ-mapper run was needed: these events are already fully mapped
-- (aq_curated, direct marketplace IDs present). The only fix required is to
-- have td_target_events() also follow the tevo_event_id link.
--
-- This rewrites concert_venues as the UNION of both link paths:
--   (a) direct:  aq_event_map.tevo_event_id  = events.id
--   (b) via SG:  aq_event_map.sg_event_id    = sg_events_canonical.sg_event_id
--                                            → tevo_event_id = events.id
--
-- Out of scope (no mapping exists to apply): BOK Center "NBA Preseason -
-- New Orleans Pelicans at Oklahoma City Thunder" (tevo 3349508, 2026-10-07)
-- — not in aq_event_map and no venue+date candidate to match. It will be
-- picked up automatically once the SG matcher creates its canonical row.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.td_target_events()
 RETURNS TABLE(aq_short_event_id text, sh_event_id bigint, vivid_event_id bigint, sg_event_id bigint)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH yankees AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_name ILIKE '%at New York Yankees%'
      AND aem.event_name NOT ILIKE '%parking%'
      AND aem.event_date > now()
    ORDER BY aem.event_date ASC
    LIMIT 20
  ),
  knicks AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_name ILIKE '%knicks%'
      AND aem.event_date > now()
      AND aem.event_name NOT ILIKE '%parking%'
      AND aem.event_name NOT ILIKE '%season ticket%'
      AND ( aem.event_name ILIKE '%finals%'
         OR aem.event_name ILIKE '%playoff%'
         OR aem.event_name ILIKE '%round %'
         OR aem.event_name ILIKE '%conference%'
         OR aem.event_name ILIKE '%if necessary%'
         OR aem.event_name ~* 'game [0-9]' )
  ),
  -- Events at the 15 concert venues added in mig 20260605120000, reached via
  -- BOTH aq_event_map link paths (direct tevo_event_id + via sg canonical).
  concert_venues AS (
    -- (a) direct tevo_event_id link — aq_curated rows, sg_event_id often NULL
    SELECT DISTINCT
      aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    JOIN public.events e ON e.id = aem.tevo_event_id
    WHERE e.venue_id IN (1290,520,1366,996,8000,4603,33,5118,103,33737,2407,2839,7425,38485,228)
      AND e.occurs_at_local IS NOT NULL
      AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
    UNION
    -- (b) via sg_events_canonical — events matched through the SG matcher
    SELECT DISTINCT
      aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    JOIN public.events e                ON e.id = sgc.tevo_event_id
    WHERE e.venue_id IN (1290,520,1366,996,8000,4603,33,5118,103,33737,2407,2839,7425,38485,228)
      AND e.occurs_at_local IS NOT NULL
      AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  )
  SELECT y.aq_short_event_id, y.sh_event_id, y.vivid_event_id, y.sg_event_id FROM yankees y
  UNION
  SELECT k.aq_short_event_id, k.sh_event_id, k.vivid_event_id, k.sg_event_id FROM knicks k
  UNION
  SELECT cv.aq_short_event_id, cv.sh_event_id, cv.vivid_event_id, cv.sg_event_id FROM concert_venues cv;
$function$;

REVOKE ALL ON FUNCTION public.td_target_events() FROM PUBLIC;
COMMENT ON FUNCTION public.td_target_events() IS
  'Canonical TD tracking target set: Yankees (next 20 home), Knicks '
  '(playoff/finals), + future events at the 15 concert venues added '
  '2026-06-05. Concert venues reached via BOTH aq_event_map link paths '
  '(direct tevo_event_id and via sg_events_canonical) so aq_curated rows '
  'with NULL sg_event_id are not skipped.';

-- Activate the newly-reachable concert xref rows immediately.
SELECT public.td_apply_targets();

-- Seed td_pull_queue for the events the sg-only join previously missed.
INSERT INTO public.td_pull_queue
  (event_id, platform, event_url, interval_tag, created_at)
SELECT x.event_id, x.platform, x.event_url, 'concert_venue_tevo_seed', now()
FROM public.ticketsdata_event_xref x
JOIN public.aq_event_map aem ON aem.aq_short_event_id = x.aq_short_event_id
JOIN public.events e         ON e.id = aem.tevo_event_id
WHERE e.venue_id IN (1290,520,1366,996,8000,4603,33,5118,103,33737,2407,2839,7425,38485,228)
  AND x.active     = true
  AND x.event_url  IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM public.td_pull_queue q
    WHERE q.event_id   = x.event_id
      AND q.platform   = x.platform
      AND q.resolved_at IS NULL
  );

COMMIT;
