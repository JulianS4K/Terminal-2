-- Migration 20260703143000 · lane:A1 (data plane — TicketsData polling scope + budget)
--   writes (DDL): td_target_events() [add all_us_matched bucket],
--                 td_daily_budget_ok() [8000→8500], td_monthly_budget_ok() [248000→255000]
--   writes on run: (none here) — td_apply_targets() activates separately
--   reads: aq_event_map (+ existing bucket sources)
--   pre: 20260703140000 (target expansion), 20260703141xxx (enrollment), 20260609150000 (poll policy)
--   auth: operator directive 2026-07-03 (julian@s4kent.com — "poll all matched events in
--         aq that are in usa" + "get me to 200k monthly")
--
-- ## Applied to prod 2026-07-03 via MCP (idempotent + reversible). Codification.
--
-- WHAT ────────────────────────────────────────────────────────────────────────
-- 1. td_target_events(): add an `all_us_matched` bucket — every upcoming aq_event_map
--    row that is MATCHED (has a StubHub and/or Vivid id) and located in the USA
--    (aem.state ∈ the 50 states + DC; excludes the cross-border league cities
--    ON/QC/BC etc.). This is the broad "poll all US matched events" scope; the prior
--    curated + league/venue/SG/EVO buckets stay (UNION dedupes; they also carry the
--    few non-US league events + the GT/TP platform logic).
--    Result: ~2,674 US matched events targeted (SH/VD).
--
-- 2. Budget caps raised to permit ~200k credits/month steady-state. The gates use a
--    ×1.276 projection factor, so the effective ceilings were daily 8000/1.276≈6,270/day
--    (188k/mo) and monthly 248000/1.276≈194k/mo — both below the 200k target. Raise to
--    daily 8500 (≈6,661/day) and monthly 255000 (≈199.8k/mo actual). Burn-window caps
--    (40000/day, 300000/mo until 2026-07-09) unchanged. This targets ~200k of the
--    ~250k plan (≈20% headroom retained). Spend still self-throttles: the tier cadences
--    (td_poll_policy) only demand ~144k/mo at today's tier mix, rising toward the 200k
--    ceiling as events mature toward their dates.
--
-- ROLLBACK: restore the mig 20260703140000 td_target_events body (drop all_us_matched)
-- and reset the two budget thresholds to 8000 / 248000.
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
      AND aem.event_name NOT ILIKE '%parking%' AND aem.event_date > now()
    ORDER BY aem.event_date ASC LIMIT 20
  ),
  knicks AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_name ILIKE '%knicks%' AND aem.event_date > now()
      AND aem.event_name NOT ILIKE '%parking%' AND aem.event_name NOT ILIKE '%season ticket%'
      AND ( aem.event_name ILIKE '%finals%' OR aem.event_name ILIKE '%playoff%'
         OR aem.event_name ILIKE '%round %' OR aem.event_name ILIKE '%conference%'
         OR aem.event_name ILIKE '%if necessary%' OR aem.event_name ~* 'game [0-9]' )
  ),
  concert_venues AS (
    SELECT DISTINCT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem JOIN public.events e ON e.id = aem.tevo_event_id
    WHERE e.venue_id IN (1290,520,1366,996,8000,4603,33,5118,103,33737,2407,2839,7425,38485,228)
      AND e.occurs_at_local IS NOT NULL AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
    UNION
    SELECT DISTINCT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    JOIN public.sg_events_canonical sgc ON sgc.sg_event_id = aem.sg_event_id
    JOIN public.events e                ON e.id = sgc.tevo_event_id
    WHERE e.venue_id IN (1290,520,1366,996,8000,4603,33,5118,103,33737,2407,2839,7425,38485,228)
      AND e.occurs_at_local IS NOT NULL AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  ),
  sg_not_owned AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.sg_market_chart m
    JOIN public.aq_event_map aem ON aem.sg_event_id = m.sg_event_id
    WHERE m.chart_date = (SELECT max(chart_date) FROM public.sg_market_chart)
  ),
  leagues AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.event_xref ex
    JOIN public.events e         ON e.id = ex.tevo_event_id
    JOIN public.aq_event_map aem ON aem.tevo_event_id = ex.tevo_event_id
    WHERE ex.espn_league IN ('MLB','NFL','WNBA','NHL','f1','MLS')
      AND e.occurs_at_local IS NOT NULL AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored' AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  ),
  mls_teams AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.events e JOIN public.aq_event_map aem ON aem.tevo_event_id = e.id
    WHERE e.primary_performer_name IN (
      'Atlanta United','Austin FC','CF Montreal','Charlotte FC','Chicago Fire FC','Colorado Rapids',
      'Columbus Crew SC','DC United','FC Cincinnati','Houston Dynamo FC','Inter Miami CF','Los Angeles FC',
      'Los Angeles Galaxy','Minnesota United FC','Nashville SC','New England Revolution','New York City FC',
      'New York Red Bulls','Orlando City SC','Philadelphia Union','Portland Timbers','Real Salt Lake',
      'San Diego FC','San Jose Earthquakes','Seattle Sounders FC','Sporting Kansas City','St. Louis City SC','Toronto FC')
      AND e.occurs_at_local IS NOT NULL AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored' AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  ),
  nfl_nba_venues AS (
    SELECT DISTINCT e.venue_id FROM public.event_xref ex JOIN public.events e ON e.id = ex.tevo_event_id
    WHERE ex.espn_league IN ('NFL','NBA') AND e.venue_id IS NOT NULL
  ),
  venue_nonsport AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.events e JOIN public.aq_event_map aem ON aem.tevo_event_id = e.id
    WHERE e.venue_id IN (SELECT venue_id FROM nfl_nba_venues)
      AND e.occurs_at_local IS NOT NULL AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored' AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
      AND NOT EXISTS (SELECT 1 FROM public.event_xref ex2 WHERE ex2.tevo_event_id = e.id AND ex2.espn_league IN ('NFL','NBA'))
  ),
  msg_venue AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.events e JOIN public.aq_event_map aem ON aem.tevo_event_id = e.id
    WHERE e.venue_id = 896
      AND e.occurs_at_local IS NOT NULL AND e.occurs_at_local::timestamptz > now()
      AND COALESCE(e.state, 'shown') <> 'ignored' AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  ),
  evo_sales AS (
    SELECT DISTINCT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.evo_orders o JOIN public.aq_event_map aem ON aem.aq_short_event_id = o.aq_short_event_id
    WHERE aem.event_date > now() AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
  ),
  -- NEW: every matched US event (has sh/vivid + US state). The broad scope.
  all_us_matched AS (
    SELECT aem.aq_short_event_id, aem.sh_event_id, aem.vivid_event_id, aem.sg_event_id
    FROM public.aq_event_map aem
    WHERE aem.event_date > now()
      AND aem.event_name NOT ILIKE '%parking%'
      AND (aem.sh_event_id IS NOT NULL OR aem.vivid_event_id IS NOT NULL)
      AND aem.state IN ('AL','AK','AZ','AR','CA','CO','CT','DE','FL','GA','HI','ID','IL','IN','IA','KS',
                        'KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH','NJ','NM','NY',
                        'NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT','VT','VA','WA','WV','WI','WY','DC')
  )
  SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM yankees
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM knicks
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM concert_venues
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM sg_not_owned
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM leagues
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM mls_teams
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM venue_nonsport
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM msg_venue
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM evo_sales
  UNION SELECT aq_short_event_id, sh_event_id, vivid_event_id, sg_event_id FROM all_us_matched;
$function$;

-- Budget caps → target ~200k credits/month steady-state (burn-window caps unchanged).
CREATE OR REPLACE FUNCTION public.td_daily_budget_ok()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (public.td_credits_today()::numeric * 1.276)
         < CASE WHEN now() < timestamptz '2026-07-09' THEN 40000 ELSE 8500 END;
$function$;

CREATE OR REPLACE FUNCTION public.td_monthly_budget_ok()
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT (public.td_credits_this_cycle()::numeric * 1.276)
         < CASE WHEN now() < timestamptz '2026-07-09' THEN 300000 ELSE 255000 END;
$function$;
