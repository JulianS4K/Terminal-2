-- Migration 20260703140000 · lane:A1 (data plane — TicketsData polling target set)
--   writes (DDL): td_target_events() [CREATE OR REPLACE — add league/venue/SG/EVO buckets]
--   writes on run: (none here) — td_apply_targets() activates the expanded set separately
--   reads: event_xref, events, aq_event_map, sg_market_chart, evo_orders
--   pre: 20260702235000 (last td_target_events replace)
--   auth: operator directive 2026-07-03 (julian@s4kent.com) — a run of "pull all X":
--         MLB · MLS (by team) · NFL · WNBA · NHL · F1 · non-sport events at NFL/NBA
--         venues · all SeatGeek events we don't own · all MSG events · anything with
--         an EVO sale. Broad coverage while the surplus-burn window (→2026-07-09) is on.
--
-- ## Applied to prod 2026-07-03 via MCP (idempotent + reversible). Codification.
--
-- WHAT ────────────────────────────────────────────────────────────────────────
-- Extends td_target_events() (consumed by td_apply_targets → ticketsdata_event_xref)
-- with new UNION buckets on top of the existing curated floor (Yankees / Knicks
-- playoffs / concert venues). Every bucket requires an sh/vivid id (td_apply_targets
-- skips NULL platform ids) and excludes parking. UNION dedupes overlaps.
--
--   leagues          — event_xref.espn_league IN (MLB,NFL,WNBA,NHL,f1,MLS), upcoming
--   mls_teams        — home team ∈ the 28 MLS clubs (the espn_league='MLS' tag is
--                      incomplete — ~21 rows; matching by team catches ~222)
--   venue_nonsport   — events at NFL/NBA venues that are NOT NFL/NBA (concerts, etc.)
--   msg_venue        — everything at Madison Square Garden (venue_id 896)
--   sg_not_owned     — ALL SeatGeek events we don't hold (full sg_market_chart latest
--                      chart_date; supersedes the prior top-50 sg_selling bucket)
--   evo_sales        — any upcoming event we have an EVO order for (evo_orders)
--
-- Additive only (UNION) — nothing previously targeted is dropped; td_apply_targets's
-- deactivation sweep still preserves manual_opt_in rows. Cost is self-throttled by
-- the TD budget caps + td_pull_drain (enrolling more events spreads the daily cap
-- across them, it does not exceed it). Rollback: re-CREATE the mig 20260702235000 body.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.td_target_events()
 RETURNS TABLE(aq_short_event_id text, sh_event_id bigint, vivid_event_id bigint, sg_event_id bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
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
  concert_venues AS (
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
  ),
  -- ALL SeatGeek events we don't own (full chart, latest date) — supersedes top-50.
  sg_not_owned AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.sg_market_chart m
    JOIN public.aq_event_map aem ON aem.sg_event_id = m.sg_event_id
    WHERE m.chart_date = (SELECT max(chart_date) FROM public.sg_market_chart)
  ),
  -- League buckets via the ESPN league tag.
  leagues AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.event_xref ex
    JOIN public.events e         ON e.id = ex.tevo_event_id
    JOIN public.aq_event_map aem ON aem.tevo_event_id = ex.tevo_event_id
    WHERE ex.espn_league IN ('MLB','NFL','WNBA','NHL','f1','MLS')
      AND e.occurs_at_local IS NOT NULL
      AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored'
      AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  ),
  -- MLS by home team — the league tag is incomplete, so match the 28 clubs directly.
  mls_teams AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.events e
    JOIN public.aq_event_map aem ON aem.tevo_event_id = e.id
    WHERE e.primary_performer_name IN (
      'Atlanta United','Austin FC','CF Montreal','Charlotte FC','Chicago Fire FC','Colorado Rapids',
      'Columbus Crew SC','DC United','FC Cincinnati','Houston Dynamo FC','Inter Miami CF','Los Angeles FC',
      'Los Angeles Galaxy','Minnesota United FC','Nashville SC','New England Revolution','New York City FC',
      'New York Red Bulls','Orlando City SC','Philadelphia Union','Portland Timbers','Real Salt Lake',
      'San Diego FC','San Jose Earthquakes','Seattle Sounders FC','Sporting Kansas City','St. Louis City SC','Toronto FC')
      AND e.occurs_at_local IS NOT NULL
      AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored'
      AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  ),
  -- Non-sport events at venues that host NFL or NBA (concerts etc. at those stadiums/arenas).
  nfl_nba_venues AS (
    SELECT DISTINCT e.venue_id
    FROM public.event_xref ex JOIN public.events e ON e.id = ex.tevo_event_id
    WHERE ex.espn_league IN ('NFL','NBA') AND e.venue_id IS NOT NULL
  ),
  venue_nonsport AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.events e
    JOIN public.aq_event_map aem ON aem.tevo_event_id = e.id
    WHERE e.venue_id IN (SELECT venue_id FROM nfl_nba_venues)
      AND e.occurs_at_local IS NOT NULL
      AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored'
      AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
      AND NOT EXISTS (SELECT 1 FROM public.event_xref ex2
                      WHERE ex2.tevo_event_id = e.id AND ex2.espn_league IN ('NFL','NBA'))
  ),
  -- Everything at Madison Square Garden (venue_id 896).
  msg_venue AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.events e
    JOIN public.aq_event_map aem ON aem.tevo_event_id = e.id
    WHERE e.venue_id = 896
      AND e.occurs_at_local IS NOT NULL
      AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored'
      AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  ),
  -- Anything we have an EVO sale for (upcoming).
  evo_sales AS (
    SELECT DISTINCT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.evo_orders o
    JOIN public.aq_event_map aem ON aem.aq_short_event_id = o.aq_short_event_id
    WHERE aem.event_date > now()
      AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  )
  SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM yankees
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM knicks
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM concert_venues
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM sg_not_owned
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM leagues
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM mls_teams
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM venue_nonsport
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM msg_venue
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM evo_sales;
$function$;

COMMENT ON FUNCTION public.td_target_events() IS
  'Events the ticketsdata poller targets. Curated floor (Yankees / Knicks playoffs / '
  'concert venues) UNION leagues (MLB/NFL/WNBA/NHL/F1/MLS) + MLS-by-team + non-sport '
  'at NFL/NBA venues + MSG (venue 896) + all SeatGeek-not-owned (full sg_market_chart) '
  '+ any EVO-sale event. All buckets require an sh/vivid id + exclude parking. '
  'Consumed by td_apply_targets(). Mig 20260703140000.';
