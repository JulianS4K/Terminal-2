-- Migration 20260909004500 · level:data-collection · lane:A1 · writes:none · reads:aq_event_map,aq_tevo_search_attempts,seatgeek_event_xref,sg_events_canonical · pre:20260909000500
--
-- Already applied to prod · via MCP 2026-09-08 under operator direction.
-- Verified: candidate pool jumped to the 200 cap with the four blocked Texas
-- rows in it; the next bridge run attempted 60, matched 24, errored 0,
-- throttled 0. Of the newly-admitted SG-owned rows specifically: 24 matched,
-- 32 no_results, 1 low_score — i.e. every one of that run's matches came from
-- rows this migration unblocked. Future CRM order coverage 87.0% -> 87.7%
-- (24,260/27,668, +190 orders).
--
-- Let the AQ→TEvo bridge see SG-owned hub rows that the SG pipeline has NOT
-- resolved. This is the fix for ~295 future hub rows, ~1,084 CRM orders.
--
-- WHAT THE EXCLUSION WAS FOR. aq_tevo_search_candidates() has always had
-- `AND m.sg_event_id IS NULL`, so a hub row carrying a SeatGeek id belongs to
-- sg-to-tevo-search-bridge and this bridge leaves it alone. That is the right
-- instinct — two bridges racing for the same TEvo request is waste at best and
-- conflicting writes at worst.
--
-- WHY IT IS WRONG HERE. Measured over the 295 SG-owned unmapped future hub rows:
--     sg_events_canonical rows carrying a tevo_event_id ...... 0
--     seatgeek_event_xref rows for those sg_event_ids ........ 0
--     not present in sg_events_canonical at all ............ 126
-- The SG pipeline has resolved ZERO of them. sg_to_tevo_search_bridge_30min
-- (job 228) is active and running, so these are not abandoned — it simply is not
-- succeeding on them. The exclusion was protecting a race that is not happening.
--
-- AND THE EVENTS EXIST. This was checked against TEvo directly rather than
-- assumed. Texas resolves to venue 1546, our `events` mirror holds exactly ONE
-- future event there, and Texas plays ~7 home games — so it looked like an
-- unfixable mirror gap. It is not. GET /v9/events?venue_id=1546 over
-- 2026-10-20..11-25 returns three events:
--     Ole Miss Rebels at Texas Longhorns Football        2026-10-24
--     Mississippi State Bulldogs at Texas Longhorns      2026-10-31
--     Arkansas Razorbacks at Texas Longhorns Football    2026-11-21
-- which are precisely the unmapped hub rows. They are missing from our MIRROR
-- but present in TEvo's API, and this bridge is the thing that fetches from the
-- API and upserts into `events` — so admitting these rows fixes the mirror gap
-- as a side effect, not just the mapping.
--
-- THE RACE GUARD. Rather than dropping the exclusion, it is narrowed: an
-- SG-owned row is admitted ONLY while the SG side shows no resolution at all —
-- no `seatgeek_event_xref` row and no `tevo_event_id` in `sg_events_canonical`.
-- The instant SG resolves one, it leaves this pool again. So the two bridges
-- can never be searching for the same event, and the SG bridge keeps first
-- claim on everything it is actually working.
--
-- WHAT DOES NOT CHANGE. Every acceptance guard stays in the edge function
-- (venue score >= 25, min_score, >= 1 name/team token overlap); the parking /
-- cancelled / season-ticket exclusions, the backoff anti-join, the
-- never-tried-first ordering, the LIMIT clamp, STABLE/SECURITY DEFINER/
-- search_path and the grants are all untouched. Widening what the bridge LOOKS
-- at cannot by itself produce a bad match.
--
-- REVERSIBLE: restore `AND m.sg_event_id IS NULL` in place of the new clause.

CREATE OR REPLACE FUNCTION public.aq_tevo_search_candidates(p_limit integer DEFAULT 30, p_backoff_hours integer DEFAULT 24)
RETURNS TABLE(aq_id bigint, event_name text, venue_name text, city text, state text, performer text, category text, event_date timestamp without time zone, src text, last_result text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    m.id,
    m.event_name,
    m.venue_name,
    m.city,
    m.state,
    m.performer,
    m.category,
    m.event_date,
    CASE
      WHEN m.tm_event_id    IS NOT NULL THEN 'TM'
      WHEN m.vivid_event_id IS NOT NULL THEN 'VIVID'
      WHEN m.sh_event_id    IS NOT NULL THEN 'SH'
      ELSE 'OTHER'
    END                                 AS src,
    a.result                            AS last_result
  FROM public.aq_event_map m
  LEFT JOIN public.aq_tevo_search_attempts a ON a.aq_id = m.id
  WHERE m.tevo_event_id IS NULL
    -- SG-owned rows are admitted ONLY while the SG pipeline has not resolved
    -- them. The moment SG writes a tevo_event_id or an xref row, the row leaves
    -- this pool again, so the two bridges cannot race for the same event.
    AND (
      m.sg_event_id IS NULL
      OR (
        NOT EXISTS (SELECT 1 FROM public.seatgeek_event_xref x
                     WHERE x.sg_event_id = m.sg_event_id)
        AND NOT EXISTS (SELECT 1 FROM public.sg_events_canonical c
                         WHERE c.sg_event_id = m.sg_event_id
                           AND c.tevo_event_id IS NOT NULL)
      )
    )
    AND m.event_date >= now()::timestamp
    AND NOT (m.category IN ('Parking','parking')
             OR m.venue_name ILIKE '%parking%'
             OR m.event_name ILIKE '%parking%')
    AND NOT (m.event_name ~* '(cancelled|if necessary|\(date tbd\))')
    AND NOT (m.event_name ~* 'season tickets?')
    AND (
      a.aq_id IS NULL
      OR a.attempted_at < now() - make_interval(hours => p_backoff_hours)
    )
  ORDER BY
    (a.aq_id IS NULL) DESC,
    a.attempted_at ASC NULLS FIRST,
    m.event_date ASC
  LIMIT GREATEST(1, LEAST(200, p_limit));
$function$;

REVOKE ALL ON FUNCTION public.aq_tevo_search_candidates(integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.aq_tevo_search_candidates(integer, integer) TO service_role;
