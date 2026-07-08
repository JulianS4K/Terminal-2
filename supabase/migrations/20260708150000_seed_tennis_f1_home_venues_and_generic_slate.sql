-- ============================================================================
-- Migration 20260708150000 — Tennis + F1 in the Leagues hub (performers,
--                            venues, future events) via the existing
--                            performer_home_venues "lights-up-automatically"
--                            seam + a generic get_league_slate anchor.
--
-- Lane:     A1 data plane (SECDEF read RPC + reference seed; consumed by the
--           D0 Leagues hub — leagues.html Tennis league + Racing/F1 series).
-- Touches:  performer_home_venues (W/seed rows), get_league_slate (W/function)
-- Reads:    events (dominant-venue derivation), league_team_divisions,
--           broadway_show_ref, performer_home_venues, latest_event_metrics
-- Pre:      20260708130050 (get_league_slate), 20260508050000 (performer_home_venues)
--
-- WHY. Tennis + racing were picker-only "ingest pending" placeholders: the hub
-- reads performers from get_performers_by_league() ← performer_home_venues, and
-- the per-event slate from get_league_slate(). Tennis tournaments (US Open,
-- Cincinnati, Miami Open, …) and F1 Grands Prix (US GP, Vegas, Miami, Mexico)
-- already live in `events` as TEvo tournament performers with real venues +
-- upcoming sessions (ingested by tournament_search_process, mig 20260509480000)
-- — they were simply never mapped into performer_home_venues, so the hub had no
-- roster to anchor on. This migration:
--   (1) seeds performer_home_venues for those tournament/GP performers (league
--       'Tennis' / 'F1'), each pinned to its DATA-DERIVED dominant venue, so
--       get_performers_by_league('Tennis'|'F1') returns a roster + the
--       PERFORMERS / demand panels light up with zero FE data-source change; and
--   (2) generalizes get_league_slate() with a third anchor — performer_home_venues
--       for any league NOT covered by league_team_divisions — so the same
--       tournament/GP performers produce a per-event future slate (venue,
--       get-in, market/owned) exactly like a team league's game slate.
--
-- Curated performer set (hand-maintained, same pattern as
-- tournament_search_queries): add a new tournament/series by INSERTing a row.
-- Venue is NOT hard-coded — it's the performer's most-frequent venue in `events`,
-- so it self-corrects as the schedule shifts.
--
-- SAFETY. The new slate anchor is gated `WHERE NOT EXISTS (league_team_divisions
-- rows for p_league)`, so the five team-sport slates (NBA/MLB/MLS/NFL/NHL) are
-- byte-for-byte unchanged; only leagues with no division map (Tennis, F1, WNBA)
-- gain the performer_home_venues anchor. The anchor CTE GROUP BYs on performer
-- id, so a performer present in two source tables can never double its events.
--
-- ROLLBACK: DELETE FROM performer_home_venues WHERE source='curated_tournament';
--           re-create get_league_slate from mig 20260708130050.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- (1) Seed tournament / Grand Prix performers into performer_home_venues.
--     Venue is derived: the performer's most-frequent (venue_id) across all its
--     events, with its name/location. source tag lets rollback target only these.
-- ----------------------------------------------------------------------------
INSERT INTO public.performer_home_venues
  (performer_id, performer_name, venue_id, venue_name, venue_location, league, source, set_at)
SELECT s.performer_id, dv.performer_name, dv.venue_id, dv.venue_name, dv.venue_location,
       s.league, 'curated_tournament', now()
FROM (VALUES
  -- Tennis (ATP/WTA + Grand Slams, North America) — tournament performers
  (30079::bigint,  'Tennis'),   -- US Open Tennis Championship
  (15418::bigint,  'Tennis'),   -- BNP Paribas Open (Indian Wells)
  (103810::bigint, 'Tennis'),   -- Cincinnati Open
  (30082::bigint,  'Tennis'),   -- Miami Open Tennis
  (15455::bigint,  'Tennis'),   -- National Bank Open — Men (Canada)
  (14402::bigint,  'Tennis'),   -- National Bank Open — Women (Canada)
  (102612::bigint, 'Tennis'),   -- Mubadala Citi DC Open
  -- Formula 1 (North American Grands Prix) — race performers
  (44750::bigint,  'F1'),       -- United States Grand Prix (COTA, Austin)
  (84556::bigint,  'F1'),       -- Las Vegas Grand Prix
  (85162::bigint,  'F1'),       -- Mexico Grand Prix
  (13813::bigint,  'F1')        -- Miami Grand Prix
) AS s(performer_id, league)
JOIN LATERAL (
  SELECT e.venue_id,
         max(e.venue_name)              AS venue_name,
         max(e.venue_location)          AS venue_location,
         max(e.primary_performer_name)  AS performer_name
  FROM public.events e
  WHERE e.primary_performer_id = s.performer_id
    AND e.venue_id IS NOT NULL
  GROUP BY e.venue_id
  ORDER BY count(*) DESC, max(e.occurs_at_local) DESC
  LIMIT 1
) dv ON true
ON CONFLICT (performer_id) DO UPDATE SET
  performer_name = COALESCE(EXCLUDED.performer_name, public.performer_home_venues.performer_name),
  venue_id       = EXCLUDED.venue_id,
  venue_name     = EXCLUDED.venue_name,
  venue_location = EXCLUDED.venue_location,
  league         = EXCLUDED.league,
  source         = 'curated_tournament',
  set_at         = now();

-- ----------------------------------------------------------------------------
-- (2) get_league_slate — add the generic performer_home_venues anchor.
--     Signature + return shape unchanged from mig 20260708130050; only the
--     anchor CTE gains a third UNION branch (+ a dedup GROUP BY).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_league_slate(
  p_league text,
  p_days   integer DEFAULT 30,
  p_limit  integer DEFAULT 200
)
RETURNS TABLE (
  event_id            bigint,
  event_name          text,
  occurs_at_local     text,
  venue_name          text,
  performer_id        bigint,
  performer_name      text,
  conference          text,
  division            text,
  tickets_count       integer,
  retail_median       numeric,
  getin_price         numeric,
  owned_tickets_count integer,
  owned_share         numeric,
  owned_median_retail numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $func$
DECLARE
  v_email text;
  v_days  integer := greatest(1, least(coalesce(p_days, 30), 400));
  v_limit integer := greatest(1, least(coalesce(p_limit, 200), 500));
BEGIN
  v_email := coalesce(auth.jwt()->>'email', '');
  IF v_email NOT LIKE '%@s4kent.com' THEN
    RAISE EXCEPTION 'forbidden: % is not an @s4kent.com email', v_email USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH anchor AS (
    -- Dedup on performer id: a performer present in >1 source anchors ONCE, so
    -- its events are never doubled. conference/division survive via max().
    SELECT u.pid AS performer_id,
           max(u.conference) AS conference,
           max(u.division)   AS division
    FROM (
      -- Sports leagues: home team -> one row per league game.
      SELECT ltd.tevo_performer_id AS pid, ltd.conference, ltd.division
      FROM public.league_team_divisions ltd
      WHERE ltd.league = p_league
      UNION ALL
      -- Broadway: the show as performer -> its upcoming performances.
      SELECT bsr.tevo_performer_id, NULL::text, NULL::text
      FROM public.broadway_show_ref bsr
      WHERE p_league = 'Broadway' AND bsr.tevo_performer_id IS NOT NULL
      UNION ALL
      -- Generic: tournament / racing / any not-yet-divisioned league whose
      -- performers are mapped in performer_home_venues (Tennis, F1, WNBA, ...).
      -- Gated so a league already anchored by league_team_divisions is untouched.
      SELECT phv.performer_id, NULL::text, NULL::text
      FROM public.performer_home_venues phv
      WHERE phv.league = p_league
        AND NOT EXISTS (
          SELECT 1 FROM public.league_team_divisions ltd2 WHERE ltd2.league = p_league
        )
    ) u
    WHERE u.pid IS NOT NULL
    GROUP BY u.pid
  )
  SELECT e.id::bigint,
         e.name,
         e.occurs_at_local,
         e.venue_name,
         e.primary_performer_id::bigint,
         e.primary_performer_name,
         a.conference,
         a.division,
         lem.tickets_count::integer,
         lem.retail_median,
         lem.getin_price,
         lem.owned_tickets_count::integer,
         lem.owned_share,
         lem.owned_median_retail
  FROM anchor a
  JOIN public.events e
    ON e.primary_performer_id = a.performer_id
  LEFT JOIN public.latest_event_metrics lem
    ON lem.event_id = e.id
  WHERE e.occurs_at_local >= to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS')
    AND e.occurs_at_local <= to_char(now() + make_interval(days => v_days), 'YYYY-MM-DD"T"HH24:MI:SS')
    AND coalesce(e.state, '') NOT IN ('completed', 'cancelled', 'postponed')
  ORDER BY e.occurs_at_local
  LIMIT v_limit;
END;
$func$;

REVOKE ALL ON FUNCTION public.get_league_slate(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_league_slate(text, integer, integer) TO anon, authenticated;

COMMENT ON FUNCTION public.get_league_slate(text, integer, integer) IS
  'D0 Leagues hub — per-league upcoming slate. Sports: home-team-anchored via league_team_divisions. Broadway: show-anchored via broadway_show_ref. Generic (Tennis/F1/WNBA/…): performer_home_venues-anchored when the league has no division map. Joined to events.primary_performer_id + latest_event_metrics; keyed on tevo event id -> event-page deep link. Email-gated read-only.';
