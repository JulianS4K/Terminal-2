-- Migration 20260516080000 · admin · ESPN→TEvo→AQ→SG multi-sport bridge · pre:20260516070000
--
-- Extends the NFL bridge (20260516070000) to MLB / MLS / WNBA / NBA / NHL using the
-- same ESPN→TEvo→AQ→SG pattern. Coverage census 2026-05-16 found 819 ESPN games
-- matchable via entity_performer_map but not yet bridged in event_xref:
--   MLB: 759 candidates (471 already xref'd; gap = matcher just hasn't kept up)
--   MLS: 41   candidates (7 already xref'd)
--   WNBA: 12  candidates (18 already xref'd)
--   NBA: 6    candidates (4 already xref'd)
--   NHL: 1    candidate  (1 already xref'd)
--
-- This migration:
-- 1. INSERT into event_xref for ESPN games NOT yet bridged (filtered out via
--    LEFT JOIN existence check). match_method='a1_espn_multi_perfid_date_2026_05_16'.
-- 2. Conditionally create SYS- AQ rows ONLY for events without any existing AQ match
--    (probed via match_to_aq_event_id which uses all 4 matcher tiers). Avoids
--    duplicate SYS- entries when aq_curated rows already exist (mostly MLB).
-- 3. AQ→SG match probe + INSERT for events where SG has the game.
--
-- Idempotent via ON CONFLICT clauses + WHERE NOT EXISTS guards.
--
-- ## Already applied to prod  Applied via MCP 2026-05-16.
-- Result counts:
--   event_xref:       MLB 654 + MLS 42 + WNBA 12 + NBA 6 + NHL 1 = 715 new bridges
--   aq_event_map:     470 SYS- rows (excluding 245 events with existing AQ matches)
--   seatgeek_xref:    MLB 347 + MLS 10 + NFL 3 + WNBA 2 = 362 new SG bridges
-- Combined with 20260516070000 NFL: 1,007 ESPN xrefs + 470 AQ rows + 365 SG xrefs

-- ============================================================
-- Step 1: ESPN→TEvo bridge for ALL non-NFL leagues
-- ============================================================
WITH matched AS (
  SELECT DISTINCT ON (e.id)
    e.id AS tevo_event_id,
    eg.espn_event_id,
    eg.espn_league,
    abs(EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - eg.game_at_utc))) AS time_delta
  FROM public.espn_event_date_lookup eg
  JOIN public.entity_performer_map pm_home
    ON pm_home.espn_team_id = eg.home_team_id AND pm_home.espn_league = eg.espn_league
  JOIN public.events e
    ON e.primary_performer_id = pm_home.tevo_performer_id
    AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
    AND abs(EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - eg.game_at_utc))) < 21600
  LEFT JOIN public.event_xref ex_existing
    ON ex_existing.tevo_event_id = e.id
  WHERE eg.game_at_utc > now()
    AND eg.espn_league IN ('MLB','MLS','WNBA','NBA','NHL')
    AND ex_existing.tevo_event_id IS NULL
  ORDER BY e.id, abs(EXTRACT(epoch FROM (e.occurs_at_local::timestamptz - eg.game_at_utc)))
)
INSERT INTO public.event_xref AS m
  (tevo_event_id, espn_event_id, espn_league, espn_slug, matched_at, match_method, meta)
SELECT
  tevo_event_id, espn_event_id, espn_league,
  lower(espn_league) || '-' || espn_event_id,
  now(),
  'a1_espn_multi_perfid_date_2026_05_16',
  jsonb_build_object('time_delta_sec', time_delta)
FROM matched;

-- ============================================================
-- Step 2: Conditional AQ row creation (skip when existing AQ match)
-- ============================================================
DO $$
DECLARE
  r RECORD;
  v_existing text;
  v_created int := 0;
  v_skipped int := 0;
BEGIN
  FOR r IN
    SELECT e.id, e.name, e.venue_name, e.occurs_at_local, ex.espn_league
    FROM public.event_xref ex
    JOIN public.events e ON e.id = ex.tevo_event_id
    WHERE ex.match_method = 'a1_espn_multi_perfid_date_2026_05_16'
      AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
  LOOP
    SELECT aq_short_event_id INTO v_existing
    FROM public.match_to_aq_event_id(
      'evo', NULL, r.name, r.venue_name, r.occurs_at_local::timestamptz, NULL, NULL, NULL)
    LIMIT 1;

    IF v_existing IS NULL THEN
      PERFORM public.create_system_aq_event(
        'espn_' || lower(r.espn_league) || '_derived',
        r.name, r.venue_name, r.occurs_at_local::timestamptz);
      v_created := v_created + 1;
    ELSE
      v_skipped := v_skipped + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'multi-sport AQ rows: % created, % skipped (already had AQ)', v_created, v_skipped;
END $$;

-- ============================================================
-- Step 3: AQ→SG match across all newly-bridged events
-- ============================================================
WITH our_bridged AS (
  SELECT e.id AS tevo_event_id, e.name, e.venue_name,
         e.occurs_at_local::timestamptz AS event_at, ex.espn_league
  FROM public.event_xref ex
  JOIN public.events e ON e.id = ex.tevo_event_id
  WHERE ex.match_method IN ('a1_espn_nfl_perfid_date_2026_05_16',
                             'a1_espn_multi_perfid_date_2026_05_16')
    AND e.occurs_at_local ~ '^\d{4}-\d{2}-\d{2}'
),
sg_matched AS (
  SELECT DISTINCT ON (n.tevo_event_id)
    n.tevo_event_id, n.espn_league,
    c.sg_event_id, c.sg_event_name, c.sg_venue_name, c.sg_datetime_utc
  FROM our_bridged n
  JOIN public.sg_events_canonical c
    ON lower(trim(c.sg_venue_name)) = lower(trim(n.venue_name))
    AND abs(EXTRACT(epoch FROM (c.sg_datetime_utc - n.event_at))) < 21600
  LEFT JOIN public.seatgeek_event_xref sgx_existing
    ON sgx_existing.tevo_event_id = n.tevo_event_id
  WHERE sgx_existing.tevo_event_id IS NULL
  ORDER BY n.tevo_event_id, abs(EXTRACT(epoch FROM (c.sg_datetime_utc - n.event_at)))
)
INSERT INTO public.seatgeek_event_xref AS x
  (tevo_event_id, sg_event_id, sg_event_name, sg_event_location, sg_start_data,
   matched_at, match_method, match_confidence)
SELECT
  tevo_event_id, sg_event_id, sg_event_name, sg_venue_name, sg_datetime_utc,
  now(), 'a1_espn_multi_bridge_2026_05_16', 0.95
FROM sg_matched
ON CONFLICT (tevo_event_id) DO UPDATE SET
  sg_event_id   = EXCLUDED.sg_event_id,
  sg_event_name = EXCLUDED.sg_event_name,
  matched_at    = now(),
  match_method  = EXCLUDED.match_method;
