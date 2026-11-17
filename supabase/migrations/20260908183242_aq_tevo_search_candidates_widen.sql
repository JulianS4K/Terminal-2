-- Migration 20260908183242 · level:data-collection · lane:A1 · writes:none · reads:aq_event_map,aq_tevo_search_attempts · pre:20260908173624
-- Already applied to prod · via MCP 2026-09-08. Verified: eligible pool 42 -> 944;
-- three bridge runs after it returned matched 19/30, 10/35 and 12/30 with 0 errored
-- and 0 throttled, filling 41 hub rows that had been unreachable.
--
-- Widen aq_tevo_search_candidates() so hub rows with NO source id are eligible,
-- and exclude season-ticket packages.
--
-- WHY. The aq-to-tevo-search-bridge is the only mechanism that fills
-- aq_event_map.tevo_event_id, and it could only ever see 42 of the 2,389
-- future hub rows that lack one — under 2%. The blocking clause was:
--
--     AND COALESCE(m.tm_event_id, m.vivid_event_id, m.sh_event_id) IS NOT NULL
--
-- i.e. a row had to already carry a Ticketmaster / Vivid / ScoreBig id. Rows
-- seeded with no source id at all were in nobody's pool: not this bridge's
-- (no source id) and not the SG bridge's (no sg_event_id either). The
-- function's own `src` CASE already has an `ELSE 'OTHER'` branch that is
-- UNREACHABLE under that WHERE clause — the widening was anticipated when this
-- was written and never done.
--
-- WORKED EXAMPLE — Gies Memorial Stadium (TEvo venue 975). "Duke Blue Devils
-- at Illinois Fighting Illini Football" 2026-09-12 has SIX hub rows, all with
-- tevo_event_id NULL. Five are system_seed with no source ids (excluded: no
-- source id); the sixth is aq_curated carrying sg/gotickets/sh ids (excluded:
-- has sg_event_id, so it is the SG bridge's to own). TEvo has the event. The
-- CRM has 103 orders against it. Nothing could ever map it.
--
-- MEASURED (2026-09-08): eligible pool 42 -> 1,025 raw, 944 after the
-- season-ticket exclusion below. Includes all 17 Gies rows and 328 college
-- football rows — the segment carrying 65% of unmapped CRM orders.
--
-- SEASON TICKETS EXCLUDED. "2026-2027 Anaheim Ducks Season Tickets (Includes
-- Tickets To All Regular Season Home Games)" is a product, not an event: they
-- carry synthetic sentinel dates (every NHL package at 2026-10-01 12:55, every
-- NBA one at 2026-10-15 12:55) and TEvo has no single event to match, so they
-- return no_results forever while consuming a slot in every 30-row batch. 81
-- of them were about to flood the widened pool. This mirrors the parking /
-- cancelled / "if necessary" / "(date tbd)" exclusions already present — same
-- rule, one more unmappable product class. The bridge's v3 header records
-- "Buccaneers Season Tickets" -> "Bruno Mars" @ Raymond James as a real false
-- match from this class, so keeping them out is a correctness win too.
--
-- WHAT DOES NOT CHANGE. The sg_event_id exclusion stays: rows with an SG id
-- belong to sg-to-tevo-search-bridge, and claiming them here would duplicate
-- work and race it. Ordering (never-tried-first, then oldest attempt, then
-- soonest event), the backoff anti-join, the parking/cancelled filters, the
-- LIMIT clamp, STABLE/SECURITY DEFINER/search_path and the existing grants
-- (postgres + service_role EXECUTE, verified before authoring) are all
-- untouched.
--
-- SAFETY. This function only SELECTS — it decides what the bridge looks at,
-- never what it writes. Every acceptance guard stays where it is, in the edge
-- function: venue score >= 25, min_score (default 50), and >= 1 name/team
-- token overlap. Widening the pool cannot by itself produce a bad match.
--
-- KNOWN INTERACTION (not introduced here). Those six duplicate Gies rows will
-- each resolve to the same TEvo event, adding to the PROJECT_BIBLE §3
-- duplicate-rows-per-tevo_event_id count (592 as of today, up from 221 at the
-- 2026-06-01 audit). That is still strictly better than six NULLs — they ARE
-- the same event — but the hub's duplicate hygiene is a separate open problem.
--
-- REVERSIBLE: re-apply the prior definition (restore the COALESCE(...) IS NOT
-- NULL clause and drop the season-ticket line). No data is written by this.

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
    AND m.sg_event_id   IS NULL
    -- The source-id requirement is REMOVED here (see header): rows with no
    -- TM/Vivid/SH id were in no bridge's pool at all. `src` now genuinely
    -- returns 'OTHER' for them, as its CASE always intended.
    AND m.event_date >= now()::timestamp
    AND NOT (m.category IN ('Parking','parking')
             OR m.venue_name ILIKE '%parking%'
             OR m.event_name ILIKE '%parking%')
    AND NOT (m.event_name ~* '(cancelled|if necessary|\(date tbd\))')
    -- Season-ticket packages are products with sentinel dates, not events;
    -- TEvo has nothing to match and they burn a slot in every batch.
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
