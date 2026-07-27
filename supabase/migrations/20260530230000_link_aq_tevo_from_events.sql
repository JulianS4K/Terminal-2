-- ============================================================
-- Tier-1 "local link": map unmapped AQ rows to a TEvo event that ALREADY exists
-- in our `events` table, by exact name + venue + date (+/-1 day), UNIQUE-match only.
--
-- A1 2026-05-30. Discovered via the NFL mapping test (operator: "pick any random
-- nfl team and attempt the map ... backfill"): 85% of unmapped NFL games -- and 456
-- rows across all sports -- already had their TEvo event ingested in `events`; the
-- aq_event_map row was simply never linked to it. The source-keyed resolvers
-- (sg-to-tevo bridge, resolve_aq_tevo_from_sources) cannot reach these rows because
-- they are schedule-skeleton (espn_*_derived) with NO source id. This links directly.
--
-- Cheapest tier of the cross-source mapping methodology (see D0_BIBLE section 3h):
--   tier 1  THIS           aq.name+venue+date      -> existing events row  (no API)
--   tier 2  per-source id  listing/order native id -> aq.<source>_event_id
--   tier 3  evo-search     /v9/events venue+date | /v9/performers -> ingest + link
--
-- SAFE BY CONSTRUCTION: exact name + exact venue, a +/-1 day window (absorbs the
-- UTC-vs-local-date skew on night games), and count(DISTINCT e.id)=1 so any
-- ambiguous match is SKIPPED, never mis-mapped (the Forrest-Frank guard). Fills
-- NULL only, so it is idempotent and re-runnable. One-time backfill run below.
--
-- NOT cron-scheduled here (cron changes need separate operator sign-off). To make
-- it self-healing, either schedule it hourly or fold the call into the existing
-- :35 resolve-aq-tevo-from-sources-hourly job.
-- ============================================================
CREATE OR REPLACE FUNCTION public.link_aq_tevo_from_events()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_temp'
AS $function$
DECLARE n integer;
BEGIN
  WITH cand AS (
    SELECT a.aq_short_event_id AS aq, e.id AS tevo
    FROM public.aq_event_map a
    JOIN public.events e
      ON e.venue_name = a.venue_name
     AND e.name       = a.event_name
     AND left(e.occurs_at_local,10)::date BETWEEN (a.event_date::date - 1) AND (a.event_date::date + 1)
    WHERE a.tevo_event_id IS NULL
      AND a.venue_name IS NOT NULL AND a.event_name IS NOT NULL AND a.event_date IS NOT NULL
  ),
  uniq AS (
    SELECT aq, max(tevo) AS tevo
    FROM cand GROUP BY aq HAVING count(DISTINCT tevo) = 1
  )
  UPDATE public.aq_event_map a SET tevo_event_id = u.tevo
  FROM uniq u WHERE a.aq_short_event_id = u.aq AND a.tevo_event_id IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

REVOKE ALL ON FUNCTION public.link_aq_tevo_from_events() FROM anon, PUBLIC;

-- One-time backfill on apply.
SELECT public.link_aq_tevo_from_events();
