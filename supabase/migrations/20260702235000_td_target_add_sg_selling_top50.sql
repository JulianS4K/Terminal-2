-- ============================================================================
-- Migration 20260702235000 — td polling: add the top-50 "SG SELLING, WE'RE NOT
--   IN" chart events to the ticketsdata target set
--
-- Lane:     A1 (data plane) — td (ticketsdata/StubHub·Vivid) polling target set
-- Touches:  td_target_events() (W, CREATE OR REPLACE)
-- Reads:    sg_market_chart, aq_event_map (+ existing aq_event_map/events/sgc)
--
-- WHY (operator directive 2026-07-02): the D0 home "TOP 50 — SG SELLING, WE'RE
--   NOT IN" chart surfaces the events SeatGeek is selling hardest that we hold
--   NO EVO inventory in — prime entry candidates. Turn on StubHub/Vivid td
--   polling for those top-50 so we can watch the full cross-source market on
--   them (not just SG). Verified 2026-07-02: all 50 of today's top rows map to
--   aq_event_map, 50 have a Vivid id + 48 a StubHub id → 50/50 pollable.
--
-- SCOPE: this is the SG-selling half of the "scout cheap, confirm expensive"
--   td-targeting plan. The movers-hot half (top-100 EVO price-movers, capped)
--   is a fast-follow once the movers scout (refresh_event_movers_agg) is fixed —
--   it currently times out, so a movers-hot feed can't be trusted yet.
--
-- The curated pins (Yankees / Knicks playoffs / concert venues) stay as an
--   always-on FLOOR — this only ADDS the SG-selling set (UNION), never removes.
--   Downstream: td_apply_targets() activates SH/VD xref rows for whatever
--   td_target_events() returns (NULL platform ids are skipped there), and
--   deactivates events that drop out (manual_opt_in rows are preserved).
--
-- Read-only vs upstream: only reads our tables; the actual StubHub/Vivid pulls
--   are GET-only via the existing td pull queue (RULE 2 N/A). Cost is bounded —
--   +50 events on the existing 10-min peak cadence, rate-limited by td_pull_drain.
-- ============================================================================

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
  -- NEW: top-50 "SG SELLING, WE'RE NOT IN" chart events (sg_market_chart, latest
  -- chart_date, ranked). Take the top-50 chart rows first, then map to their
  -- StubHub/Vivid ids via aq_event_map (td_apply_targets skips NULL platform ids).
  sg_selling AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM (
      SELECT m.sg_event_id
      FROM public.sg_market_chart m
      WHERE m.chart_date = (SELECT max(chart_date) FROM public.sg_market_chart)
      ORDER BY m.rank
      LIMIT 50
    ) top
    JOIN public.aq_event_map aem ON aem.sg_event_id = top.sg_event_id
  )
  SELECT y.aq_short_event_id, y.sh_event_id, y.vivid_event_id, y.sg_event_id FROM yankees y
  UNION
  SELECT k.aq_short_event_id, k.sh_event_id, k.vivid_event_id, k.sg_event_id FROM knicks k
  UNION
  SELECT cv.aq_short_event_id, cv.sh_event_id, cv.vivid_event_id, cv.sg_event_id FROM concert_venues cv
  UNION
  SELECT sg.aq_short_event_id, sg.sh_event_id, sg.vivid_event_id, sg.sg_event_id FROM sg_selling sg;
$function$;

COMMENT ON FUNCTION public.td_target_events() IS
  'Events the ticketsdata (StubHub/Vivid/etc.) poller targets. Curated floor '
  '(Yankees / Knicks playoffs / concert venues) UNION the top-50 "SG SELLING, '
  'WE''RE NOT IN" chart (sg_market_chart, latest chart_date). Consumed by '
  'td_apply_targets(). Movers-hot top-100 is a planned fast-follow.';
